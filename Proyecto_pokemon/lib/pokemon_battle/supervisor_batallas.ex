defmodule PokemonBattle.SupervisorBatallas do
  @moduledoc """
  DynamicSupervisor que gestiona el ciclo de vida de las salas de batalla.

  Cada batalla 1v1 es un proceso GenServer (Batalla) independiente supervisado aquí.
  Al fallar un proceso de batalla, solo ese proceso se reinicia sin afectar al resto.
  Permite múltiples batallas concurrentes simultáneas.
  """

  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Inicia una nueva sala de batalla y la agrega a la supervisión."
  def iniciar_batalla(id_sala, tiempo_turno \\ 20) do
    spec = {PokemonBattle.Batalla, [id_sala: id_sala, tiempo_turno: tiempo_turno]}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
