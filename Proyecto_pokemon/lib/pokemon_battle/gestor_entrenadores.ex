defmodule PokemonBattle.GestorEntrenadores do
  @moduledoc """
  GenServer central que gestiona todos los entrenadores del sistema.

  Responsabilidades:
    - Registro e inicio de sesión
    - Consulta de perfil, inventario y clasificación
    - Actualización de monedas, victorias, sobres, inventario y equipos
    - Persistencia automática tras cada cambio usando Persistencia
  """

  use GenServer
  alias PokemonBattle.Persistencia

  # ─── API pública ─────────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Inicia sesión o registra automáticamente. Retorna {:ok, tipo, entrenador} | {:error, motivo}"
  def iniciar_sesion(nombre, clave),
    do: GenServer.call(__MODULE__, {:iniciar_sesion, nombre, clave})

  @doc "Retorna el mapa del entrenador dado su nombre."
  def obtener(nombre),
    do: GenServer.call(__MODULE__, {:obtener, nombre})

  @doc "Reemplaza el estado completo de un entrenador y persiste."
  def actualizar(entrenador),
    do: GenServer.call(__MODULE__, {:actualizar, entrenador})

  @doc "Suma monedas al saldo actual y al acumulado histórico."
  def agregar_monedas(nombre, cantidad),
    do: GenServer.call(__MODULE__, {:agregar_monedas, nombre, cantidad})

  @doc "Registra una victoria para el entrenador."
  def registrar_victoria(nombre),
    do: GenServer.call(__MODULE__, {:registrar_victoria, nombre})

  @doc "Agrega un sobre pendiente al entrenador."
  def agregar_sobre(nombre, sobre),
    do: GenServer.call(__MODULE__, {:agregar_sobre, nombre, sobre})

  @doc "Retorna la clasificación global: lista de {pos, nombre, victorias, monedas_acum}."
  def clasificacion,
    do: GenServer.call(__MODULE__, :clasificacion)

  # ─── Callbacks GenServer ─────────────────────────────────────────────────────

  @impl true
  def init(_) do
    entrenadores = Persistencia.cargar_entrenadores()
    {:ok, entrenadores}
  end

  @impl true
  def handle_call({:iniciar_sesion, nombre, clave}, _from, estado) do
    case Map.get(estado, nombre) do
      nil ->
        # Sobre básico gratis al crear cuenta
        sobre = %{id: gen_id(), tipo: :basico, abierto: false}
        nuevo = %{
          nombre: nombre, clave: clave,
          monedas: 0, monedas_acumuladas: 0, victorias: 0,
          inventario: [], sobres: [sobre], equipos: %{}
        }
        nuevo_estado = Map.put(estado, nombre, nuevo)
        Persistencia.guardar_entrenadores(nuevo_estado)
        {:reply, {:ok, :registrado, nuevo}, nuevo_estado}

      entrenador ->
        if entrenador.clave == clave do
          {:reply, {:ok, :sesion_iniciada, entrenador}, estado}
        else
          {:reply, {:error, :clave_incorrecta}, estado}
        end
    end
  end

  @impl true
  def handle_call({:obtener, nombre}, _from, estado),
    do: {:reply, Map.get(estado, nombre), estado}

  @impl true
  def handle_call({:actualizar, entrenador}, _from, estado) do
    nuevo_estado = Map.put(estado, entrenador.nombre, entrenador)
    Persistencia.guardar_entrenadores(nuevo_estado)
    {:reply, :ok, nuevo_estado}
  end

  @impl true
  def handle_call({:agregar_monedas, nombre, cantidad}, _from, estado) do
    case Map.get(estado, nombre) do
      nil -> {:reply, {:error, :no_encontrado}, estado}
      e ->
        actualizado = %{e |
          monedas:             e.monedas + cantidad,
          monedas_acumuladas:  e.monedas_acumuladas + cantidad
        }
        nuevo_estado = Map.put(estado, nombre, actualizado)
        Persistencia.guardar_entrenadores(nuevo_estado)
        {:reply, :ok, nuevo_estado}
    end
  end

  @impl true
  def handle_call({:registrar_victoria, nombre}, _from, estado) do
    case Map.get(estado, nombre) do
      nil -> {:reply, {:error, :no_encontrado}, estado}
      e ->
        actualizado = %{e | victorias: e.victorias + 1}
        nuevo_estado = Map.put(estado, nombre, actualizado)
        Persistencia.guardar_entrenadores(nuevo_estado)
        {:reply, :ok, nuevo_estado}
    end
  end

  @impl true
  def handle_call({:agregar_sobre, nombre, sobre}, _from, estado) do
    case Map.get(estado, nombre) do
      nil -> {:reply, {:error, :no_encontrado}, estado}
      e ->
        actualizado = %{e | sobres: [sobre | e.sobres]}
        nuevo_estado = Map.put(estado, nombre, actualizado)
        Persistencia.guardar_entrenadores(nuevo_estado)
        {:reply, :ok, nuevo_estado}
    end
  end

  @impl true
  def handle_call(:clasificacion, _from, estado) do
    ranking =
      estado
      |> Map.values()
      |> Enum.sort_by(fn e -> {-e.victorias, -e.monedas_acumuladas} end)
      |> Enum.with_index(1)
      |> Enum.map(fn {e, pos} -> {pos, e.nombre, e.victorias, e.monedas_acumuladas} end)
    {:reply, ranking, estado}
  end

  defp gen_id, do: :crypto.strong_rand_bytes(3) |> :binary.decode_unsigned()
end
