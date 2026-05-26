defmodule PokemonBattle.Application do
  @moduledoc "Árbol de supervisión OTP del sistema de batallas Pokémon."

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PokemonBattle.GestorEntrenadores,
      PokemonBattle.GestorSalas,
      PokemonBattle.SupervisorBatallas,
    ]

    opts = [strategy: :one_for_one, name: PokemonBattle.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
