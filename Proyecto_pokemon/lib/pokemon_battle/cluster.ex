defmodule PokemonBattle.Cluster do
  @moduledoc """
  Módulo encargado de la configuración y conexión de nodos distribuidos.

  Maneja:
    - Inicialización del nodo servidor (registro global de servicios)
    - Inicialización del nodo cliente (conexión al servidor y sincronización)

  Los servicios se registran con :global para que sean accesibles
  desde cualquier nodo del clúster sin conocer en cuál están corriendo.

  Ejecución:
    # Terminal 1 - Servidor
    elixir --name servidor@127.0.0.1 --cookie pokemon_secret -S mix run -e "PokemonBattle.Cluster.iniciar_servidor()"

    # Terminal 2 - Cliente
    elixir --name cliente1@127.0.0.1 --cookie pokemon_secret -S mix run -e "PokemonBattle.Cluster.iniciar_cliente('servidor@127.0.0.1')"
  """

  @servicios_globales [
    {:gestor_entrenadores,  PokemonBattle.GestorEntrenadores},
    {:gestor_salas,         PokemonBattle.GestorSalas},
    {:supervisor_batallas,  PokemonBattle.SupervisorBatallas},
  ]

  # ─── Servidor ────────────────────────────────────────────────────────────────

  @doc """
  Inicia el nodo como servidor: registra todos los servicios globalmente
  y queda a la espera de conexiones de clientes.
  """
  def iniciar_servidor do
    IO.puts("[Servidor] Nodo: #{Node.self()}")
    IO.puts("[Servidor] Registrando servicios globales...")

    Enum.each(@servicios_globales, fn {nombre, modulo} ->
      pid = Process.whereis(modulo)
      case :global.register_name(nombre, pid) do
        :yes -> IO.puts("[Servidor]   ✅ #{nombre} registrado")
        :no  -> IO.puts("[Servidor]   ⚠️  #{nombre} ya estaba registrado")
      end
    end)

    IO.puts("[Servidor] Listo. Esperando conexiones...")
    Process.sleep(:infinity)
  end

  # ─── Cliente ─────────────────────────────────────────────────────────────────

  @doc """
  Conecta este nodo al servidor y sincroniza la tabla global.
  Retorna :ok | {:error, motivo}
  """
  def iniciar_cliente(nombre_servidor \\ "servidor@127.0.0.1") do
    nodo = String.to_atom(to_string(nombre_servidor))
    IO.puts("[Cliente] Conectando a #{nodo}...")

    case Node.connect(nodo) do
      true ->
        :global.sync()
        IO.puts("[Cliente] ✅ Conectado. Nodo: #{Node.self()}")
        :ok

      false ->
        IO.puts("[Cliente] ❌ No se pudo conectar a #{nodo}")
        {:error, :sin_conexion}

      :ignored ->
        IO.puts("[Cliente] ⚠️  El nodo no esta en modo distribuido")
        {:error, :no_distribuido}
    end
  end

  # ─── Helpers para acceder a servicios del servidor ───────────────────────────

  @doc "PID del GestorEntrenadores en el servidor (vía :global)."
  def gestor_entrenadores, do: :global.whereis_name(:gestor_entrenadores)

  @doc "PID del GestorSalas en el servidor (vía :global)."
  def gestor_salas, do: :global.whereis_name(:gestor_salas)

  @doc "PID del SupervisorBatallas en el servidor (vía :global)."
  def supervisor_batallas, do: :global.whereis_name(:supervisor_batallas)
end
