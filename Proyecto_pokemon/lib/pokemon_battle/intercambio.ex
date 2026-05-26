defmodule PokemonBattle.Intercambio do
  @moduledoc """
  GenServer que gestiona una sala de intercambio de Pokémon en tiempo real.

  Ambos entrenadores deben estar conectados simultáneamente.
  Si alguno se desconecta (detectado via Process.monitor), la sala se cancela.

  Flujo:
    1. Entrenador A crea la sala → recibe código IC-XXXX
    2. Entrenador B se une con el código
    3. Cada uno ofrece un Pokémon con ofrecer_pokemon/3
    4. Ambos confirman → los Pokémon cambian de inventario y la sala se cierra
    5. Cualquiera puede cancelar en cualquier momento
  """

  use GenServer

  alias PokemonBattle.{GestorEntrenadores, Persistencia}

  def start_link(opts) do
    codigo = Keyword.fetch!(opts, :codigo)
    GenServer.start_link(__MODULE__, %{codigo: codigo})
  end

  # ─── API pública ─────────────────────────────────────────────────────────────

  def unirse(pid, nombre, pid_jugador),
    do: GenServer.call(pid, {:unirse, nombre, pid_jugador})

  def ofrecer_pokemon(pid, nombre, id_pokemon),
    do: GenServer.call(pid, {:ofrecer, nombre, id_pokemon})

  def confirmar(pid, nombre),
    do: GenServer.call(pid, {:confirmar, nombre})

  def cancelar(pid, nombre),
    do: GenServer.cast(pid, {:cancelar, nombre})

  # ─── Callbacks GenServer ─────────────────────────────────────────────────────

  @impl true
  def init(%{codigo: codigo}) do
    {:ok, %{codigo: codigo, jugadores: %{}, fase: :esperando}}
  end

  @impl true
 def handle_call({:unirse, nombre, pid_jugador}, _from, st) do
  cond do
    map_size(st.jugadores) >= 2 ->
      {:reply, {:error, :sala_llena}, st}
    Map.has_key?(st.jugadores, nombre) ->
      {:reply, {:error, :ya_unido}, st}
    true ->
      # Solo monitorear si el PID es local al nodo donde vive el GenServer
      if node(pid_jugador) == node() do
        Process.monitor(pid_jugador)
      end
      datos    = %{pid: pid_jugador, oferta_id: nil, confirmado: false}
      nuevo_st = put_in(st, [:jugadores, nombre], datos)
      fase     = if map_size(nuevo_st.jugadores) == 2, do: :activa, else: :esperando
      nuevo_st = %{nuevo_st | fase: fase}

      if fase == :activa do
        broadcast(nuevo_st, "[Sala #{st.codigo}] #{nombre} se ha unido. Ya pueden intercambiar.")
      end

      {:reply, :ok, nuevo_st}
  end
end

  @impl true
  def handle_call({:ofrecer, nombre, id_pokemon}, _from, st) do
    if st.fase != :activa do
      {:reply, {:error, :sala_no_activa}, st}
    else
      entrenador = GestorEntrenadores.obtener(nombre)
      pokemon    = Enum.find(entrenador.inventario, fn p -> p.id == id_pokemon end)

      if pokemon do
        nuevo_st = put_in(st, [:jugadores, nombre, :oferta_id], id_pokemon)
        broadcast(nuevo_st, "[Sala #{st.codigo}] #{nombre} ofrece [##{id_pokemon}] #{pokemon.especie} (#{pokemon.rareza})")

        if Enum.all?(nuevo_st.jugadores, fn {_, j} -> j.oferta_id != nil end) do
          broadcast(nuevo_st, "Ambos han ofrecido. Confirma con: confirmar_intercambio")
        end

        {:reply, :ok, nuevo_st}
      else
        {:reply, {:error, :pokemon_no_encontrado}, st}
      end
    end
  end

  @impl true
  def handle_call({:confirmar, nombre}, _from, st) do
    nuevo_st = put_in(st, [:jugadores, nombre, :confirmado], true)

    if Enum.all?(nuevo_st.jugadores, fn {_, j} -> j.confirmado and j.oferta_id != nil end) do
      ejecutar_intercambio(nuevo_st)
      {:reply, :ok, %{nuevo_st | fase: :finalizada}}
    else
      {:reply, :ok, nuevo_st}
    end
  end

  @impl true
  def handle_cast({:cancelar, nombre}, st) do
    broadcast(st, "[Sala #{st.codigo}] #{nombre} cancelo el intercambio.")
    {:stop, :normal, %{st | fase: :finalizada}}
  end

  # Detecta desconexión de un jugador
  @impl true
  def handle_info({:DOWN, _ref, :process, pid_caido, _}, st) do
    nombre_caido =
      Enum.find_value(st.jugadores, fn {n, j} -> if j.pid == pid_caido, do: n end)

    if nombre_caido do
      broadcast(st, "[Sala #{st.codigo}] #{nombre_caido} se desconecto. Intercambio cancelado.")
      {:stop, :normal, %{st | fase: :finalizada}}
    else
      {:noreply, st}
    end
  end

  # ─── Privado ─────────────────────────────────────────────────────────────────

  defp ejecutar_intercambio(st) do
    [{na, ja}, {nb, jb}] = Map.to_list(st.jugadores)

    ea = GestorEntrenadores.obtener(na)
    eb = GestorEntrenadores.obtener(nb)

    pok_a = Enum.find(ea.inventario, fn p -> p.id == ja.oferta_id end)
    pok_b = Enum.find(eb.inventario, fn p -> p.id == jb.oferta_id end)

    nuevo_inv_a = ea.inventario |> Enum.reject(&(&1.id == pok_a.id)) |> then(&[pok_b | &1])
    nuevo_inv_b = eb.inventario |> Enum.reject(&(&1.id == pok_b.id)) |> then(&[pok_a | &1])

    GestorEntrenadores.actualizar(%{ea | inventario: nuevo_inv_a})
    GestorEntrenadores.actualizar(%{eb | inventario: nuevo_inv_b})

    send(ja.pid, {:intercambio_completado, "Recibiste [##{pok_b.id}] #{pok_b.especie}."})
    send(jb.pid, {:intercambio_completado, "Recibiste [##{pok_a.id}] #{pok_a.especie}."})
  end

  defp broadcast(st, msg) do
    Enum.each(st.jugadores, fn {_, j} -> if j.pid, do: send(j.pid, {:mensaje_intercambio, msg}) end)
  end
end
