defmodule PokemonBattle.GestorSalas do
  @moduledoc """
  GenServer que mantiene el registro global de salas de batalla activas.

  Almacena un mapa %{id_sala => pid_batalla} visible para todos los nodos
  del clúster. Los clientes consultan aquí para listar, buscar y unirse a salas.
  """

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  # ─── API pública ─────────────────────────────────────────────────────────────

  def registrar(id_sala, pid),
    do: GenServer.cast(__MODULE__, {:registrar, id_sala, pid})

  def eliminar(id_sala),
    do: GenServer.cast(__MODULE__, {:eliminar, id_sala})

  def listar,
    do: GenServer.call(__MODULE__, :listar)

  def buscar(id_sala),
    do: GenServer.call(__MODULE__, {:buscar, id_sala})

  # ─── Callbacks GenServer ─────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_cast({:registrar, id, pid}, estado),
    do: {:noreply, Map.put(estado, id, pid)}

  @impl true
  def handle_cast({:eliminar, id}, estado),
    do: {:noreply, Map.delete(estado, id)}

  @impl true
  def handle_call(:listar, _from, estado),
    do: {:reply, estado, estado}

  @impl true
  def handle_call({:buscar, id}, _from, estado),
    do: {:reply, Map.get(estado, id), estado}
end
