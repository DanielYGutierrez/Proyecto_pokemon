defmodule PokemonBattle.Batalla do
  @moduledoc """
  GenServer que gestiona el estado completo de una batalla 1v1 por turnos.

  Cada instancia es un proceso independiente supervisado por SupervisorBatallas.
  Maneja:
    - Incorporación de jugadores con su equipo
    - Inicio de batalla
    - Recepción de acciones (ataque, cambio, rendición)
    - Resolución de turno según velocidad
    - Timer de turno (acción automática :pasar si vence el tiempo)
    - Notificación a jugadores vía send/2
    - Otorgamiento de monedas y registro de resultado al terminar
  """

  use GenServer

  alias PokemonBattle.{MotorCombate, GestorEntrenadores, GestorSalas, Persistencia}

  @timeout_turno_ms 20_000

  # ─── API pública ─────────────────────────────────────────────────────────────

  def start_link(opts) do
    id_sala      = Keyword.fetch!(opts, :id_sala)
    tiempo_turno = Keyword.get(opts, :tiempo_turno, 20)
    GenServer.start_link(__MODULE__, %{id_sala: id_sala, tiempo_turno_ms: tiempo_turno * 1_000})
  end

  def unirse(pid, nombre, equipo),
    do: GenServer.call(pid, {:unirse, nombre, equipo, self()})

  def iniciar(pid),
    do: GenServer.call(pid, :iniciar)

  def accion(pid, nombre, accion),
    do: GenServer.call(pid, {:accion, nombre, accion})

  def rendirse(pid, nombre),
    do: GenServer.cast(pid, {:rendirse, nombre})

  def estado(pid),
    do: GenServer.call(pid, :estado)

  # ─── Callbacks GenServer ─────────────────────────────────────────────────────

  @impl true
  def init(%{id_sala: id_sala, tiempo_turno_ms: tiempo_turno_ms}) do
    {:ok, %{
      id_sala:        id_sala,
      tiempo_turno_ms: tiempo_turno_ms,
      fase:           :esperando,
      jugadores:      %{},    # nombre => %{equipo: [ec], activo_idx: 0, pid: pid}
      turno:          0,
      acciones_turno: %{},
      timer_ref:      nil,
      ganador:        nil
    }}
  end

  @impl true
  def handle_call({:unirse, nombre, equipo, pid_jugador}, _from, st) do
    cond do
      map_size(st.jugadores) >= 2 ->
        {:reply, {:error, :sala_llena}, st}
      Map.has_key?(st.jugadores, nombre) ->
        {:reply, {:error, :ya_unido}, st}
      true ->
        ec_equipo = Enum.map(equipo, fn p -> %{pokemon: p, salud_actual: 100, debilitado: false} end)
        nuevo_st  = put_in(st, [:jugadores, nombre], %{equipo: ec_equipo, activo_idx: 0, pid: pid_jugador})
        {:reply, :ok, nuevo_st}
    end
  end

  @impl true
  def handle_call(:iniciar, _from, st) do
    if map_size(st.jugadores) < 2 do
      {:reply, {:error, :faltan_jugadores}, st}
    else
      nuevo_st = %{st | fase: :en_batalla, turno: 1} |> activar_timer()
      notificar_turno(nuevo_st)
      {:reply, :ok, nuevo_st}
    end
  end

  @impl true
  def handle_call({:accion, nombre, accion}, _from, st) do
    if st.fase != :en_batalla do
      {:reply, {:error, :batalla_no_activa}, st}
    else
      nuevas = Map.put(st.acciones_turno, nombre, accion)
      if map_size(nuevas) == 2 do
        nuevo_st = %{st | acciones_turno: nuevas} |> cancelar_timer() |> resolver_turno()
        {:reply, :ok, nuevo_st}
      else
        {:reply, :ok, %{st | acciones_turno: nuevas}}
      end
    end
  end

  @impl true
  def handle_cast({:rendirse, nombre}, st) do
    [rival] = Map.keys(st.jugadores) |> Enum.reject(&(&1 == nombre))
    finalizar(st, rival, nombre, "rendicion")
    {:noreply, %{st | fase: :finalizada, ganador: rival}}
  end

  @impl true
  def handle_call(:estado, _from, st) do
    {:reply, %{id_sala: st.id_sala, fase: st.fase, turno: st.turno, ganador: st.ganador}, st}
  end

  # Timer de turno: asigna :pasar al jugador que no actuó
  @impl true
  def handle_info(:timeout_turno, st) do
    if st.fase == :en_batalla do
      acciones =
        Enum.reduce(Map.keys(st.jugadores), st.acciones_turno, fn nombre, acc ->
          if Map.has_key?(acc, nombre), do: acc, else: Map.put(acc, nombre, :pasar)
        end)
      nuevo_st = %{st | acciones_turno: acciones} |> resolver_turno()
      {:noreply, nuevo_st}
    else
      {:noreply, st}
    end
  end

  # ─── Lógica interna de turnos ─────────────────────────────────────────────────

  defp resolver_turno(st) do
    [n1, n2] = Map.keys(st.jugadores)
    j1 = st.jugadores[n1]
    j2 = st.jugadores[n2]

    pok1 = Enum.at(j1.equipo, j1.activo_idx).pokemon
    pok2 = Enum.at(j2.equipo, j2.activo_idx).pokemon

    {primero, segundo} = MotorCombate.orden_turno(pok1, pok2)
    {np, ns}           = if primero == :jugador1, do: {n1, n2}, else: {n2, n1}

    st1 = ejecutar_accion(st, np, ns, st.acciones_turno[np])

    # Si el Pokémon del segundo fue debilitado, no actúa
    ec_seg = Enum.at(st1.jugadores[ns].equipo, st1.jugadores[ns].activo_idx)
    st2 =
      if ec_seg.debilitado do
        avanzar_pokemon(st1, ns)
      else
        ejecutar_accion(st1, ns, np, st.acciones_turno[ns])
      end

    # Verificar victoria
    [na, nb] = Map.keys(st2.jugadores)
    cond do
      MotorCombate.equipo_debilitado?(st2.jugadores[na].equipo) ->
        finalizar(st2, nb, na, "combate")
        %{st2 | fase: :finalizada, ganador: nb, acciones_turno: %{}}

      MotorCombate.equipo_debilitado?(st2.jugadores[nb].equipo) ->
        finalizar(st2, na, nb, "combate")
        %{st2 | fase: :finalizada, ganador: na, acciones_turno: %{}}

      true ->
        nuevo_st = %{st2 | turno: st2.turno + 1, acciones_turno: %{}} |> activar_timer()
        notificar_turno(nuevo_st)
        nuevo_st
    end
  end

  defp ejecutar_accion(st, nombre_atac, nombre_def, accion) do
    j_atac = st.jugadores[nombre_atac]
    j_def  = st.jugadores[nombre_def]
    pok_atac  = Enum.at(j_atac.equipo, j_atac.activo_idx).pokemon
    idx_def   = j_def.activo_idx
    ec_def    = Enum.at(j_def.equipo, idx_def)

    case accion do
      {:ataque, nombre_mov} ->
        mov = MotorCombate.obtener_movimiento(nombre_mov, pok_atac)
        if mov && not ec_def.debilitado do
          dano     = MotorCombate.calcular_dano(mov, pok_atac, ec_def.pokemon)
          nuevo_ec = MotorCombate.aplicar_dano(ec_def, dano)
          msg = "[T#{st.turno}] #{nombre_atac} usa #{nombre_mov} → #{dano} daño a #{ec_def.pokemon.especie} (salud: #{nuevo_ec.salud_actual}/100)"
          broadcast(st, msg)
          nuevo_eq = List.replace_at(j_def.equipo, idx_def, nuevo_ec)
          put_in(st, [:jugadores, nombre_def, :equipo], nuevo_eq)
        else
          st
        end

      {:cambiar, id_pokemon} ->
        nuevo_idx = Enum.find_index(j_atac.equipo, fn ec ->
          ec.pokemon.id == id_pokemon and not ec.debilitado
        end)
        if nuevo_idx do
          nuevo_nombre = Enum.at(j_atac.equipo, nuevo_idx).pokemon.especie
          broadcast(st, "[T#{st.turno}] #{nombre_atac} cambia a #{nuevo_nombre}")
          put_in(st, [:jugadores, nombre_atac, :activo_idx], nuevo_idx)
        else
          st
        end

      :pasar ->
        broadcast(st, "[T#{st.turno}] #{nombre_atac} pasa (tiempo agotado)")
        st

      _ -> st
    end
  end

  defp avanzar_pokemon(st, nombre) do
    j = st.jugadores[nombre]
    case MotorCombate.primer_disponible(j.equipo) do
      nil -> st
      ec  ->
        nuevo_idx = Enum.find_index(j.equipo, fn e -> e.pokemon.id == ec.pokemon.id end)
        broadcast(st, "Pokemon de #{nombre} debilitado. Entra #{ec.pokemon.especie}")
        put_in(st, [:jugadores, nombre, :activo_idx], nuevo_idx)
    end
  end

  defp finalizar(st, ganador, perdedor, motivo) do
    GestorEntrenadores.registrar_victoria(ganador)
    GestorEntrenadores.agregar_monedas(ganador, 100)
    GestorEntrenadores.agregar_monedas(perdedor, 30)
    Persistencia.registrar_batalla(ganador, perdedor, motivo)
    GestorSalas.eliminar(st.id_sala)

    if pid = get_in(st, [:jugadores, ganador, :pid]),
      do: send(pid, {:batalla_terminada, :ganador, "Ganaste la batalla! +100 monedas"})
    if pid = get_in(st, [:jugadores, perdedor, :pid]),
      do: send(pid, {:batalla_terminada, :perdedor, "Perdiste. +30 monedas de participacion"})
  end

  defp notificar_turno(st) do
    Enum.each(st.jugadores, fn {nombre, _j} ->
      if pid = get_in(st, [:jugadores, nombre, :pid]) do
        send(pid, {:inicio_turno, st.turno, construir_vista(st, nombre)})
      end
    end)
  end

  defp construir_vista(st, nombre) do
    [rival] = Map.keys(st.jugadores) |> Enum.reject(&(&1 == nombre))
    j_prop  = st.jugadores[nombre]
    j_riv   = st.jugadores[rival]
    ec_prop = Enum.at(j_prop.equipo, j_prop.activo_idx)
    ec_riv  = Enum.at(j_riv.equipo, j_riv.activo_idx)

    MotorCombate.vista_turno(
      st.turno, nombre, rival,
      ec_prop.pokemon, ec_prop,
      Enum.map(j_prop.equipo, fn ec -> ec.pokemon |> Map.put(:debilitado, ec.debilitado) end),
      ec_riv.pokemon, ec_riv.salud_actual,
      Enum.map(j_riv.equipo, fn ec -> ec.pokemon |> Map.put(:debilitado, ec.debilitado) end)
    )
  end

  defp broadcast(st, msg) do
    Enum.each(st.jugadores, fn {_, j} ->
      if j.pid, do: send(j.pid, {:mensaje_batalla, msg})
    end)
  end

  defp activar_timer(st) do
    ref = Process.send_after(self(), :timeout_turno, st.tiempo_turno_ms)
    %{st | timer_ref: ref}
  end

  defp cancelar_timer(st) do
    if st.timer_ref, do: Process.cancel_timer(st.timer_ref)
    %{st | timer_ref: nil}
  end
end
