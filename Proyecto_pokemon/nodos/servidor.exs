# Script de arranque del nodo SERVIDOR
#
# Uso:
#   elixir --name servidor@127.0.0.1 --cookie pokemon_secret -S mix run nodos/servidor.exs

PokemonBattle.Cluster.iniciar_servidor()
