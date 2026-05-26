# Script de arranque del nodo CLIENTE
#
# Uso (cliente 1):
#   elixir --name cliente1@127.0.0.1 --cookie pokemon_secret -S mix run nodos/cliente.exs
#
# Uso (cliente 2):
#   elixir --name cliente2@127.0.0.1 --cookie pokemon_secret -S mix run nodos/cliente.exs

PokemonBattle.Servidor.iniciar("servidor@127.0.0.1")
