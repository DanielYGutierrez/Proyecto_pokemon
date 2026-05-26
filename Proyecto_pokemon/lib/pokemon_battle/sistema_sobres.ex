defmodule PokemonBattle.SistemaSobres do
  @moduledoc """
  Módulo de lógica pura para todo lo relacionado con sobres:
    - Compra de sobres (validación de monedas, creación del struct)
    - Apertura de sobres (sorteo de especie, rareza, stats y movimientos)
    - Asignación de 4 movimientos según los tipos de la especie

  Usa el catálogo y movimientos cargados en el estado del GestorEntrenadores.
  """

  alias PokemonBattle.Persistencia

  # Rangos de factor_rareza por rareza
  @rangos %{comun: {2, 8}, raro: {10, 20}, epico: {25, 40}}

  # ─── Sobres ──────────────────────────────────────────────────────────────────

  @doc "Crea un nuevo sobre con id único."
  def nuevo_sobre(tipo), do: %{id: gen_id(), tipo: tipo, abierto: false}

  @doc "Precio de un tipo de sobre según tienda.json."
  def precio(tipo) do
    tienda = Persistencia.cargar_tienda()
    get_in(tienda, [to_string(tipo), "precio"]) || 100
  end

  @doc """
  Abre un sobre y genera 3 instancias de Pokémon.
  Retorna {:ok, [pokemon1, pokemon2, pokemon3]} | {:error, motivo}
  """
  def abrir_sobre(%{abierto: true}, _duenio), do: {:error, :ya_abierto}

  def abrir_sobre(%{tipo: tipo}, duenio) do
    catalogo = Persistencia.cargar_pokemon()
    especies  = Map.values(catalogo)
    tienda    = Persistencia.cargar_tienda()
    probs     = get_in(tienda, [to_string(tipo), "probabilidades"])

    pokemons =
      Enum.map(1..3, fn _ ->
        especie = Enum.random(especies)
        rareza  = sortear_rareza(probs)
        crear_instancia(especie, rareza, duenio)
      end)

    {:ok, pokemons}
  end

  # ─── Movimientos ─────────────────────────────────────────────────────────────

  @doc """
  Asigna 4 movimientos a una instancia según los tipos de su especie.
  Reglas:
    - 1 tipo  → 2 movimientos del tipo + 2 complementarios
    - 2 tipos → 1 de cada tipo + 2 complementarios
    - Sin repetición
  """
  def asignar_movimientos(tipos) do
    todos = Persistencia.cargar_moves()

    movs_tipo =
      case tipos do
        [t1] ->
          pool = Enum.filter(todos, fn m -> m["tipo"] == t1 end)
          Enum.take(Enum.shuffle(pool), 2)

        [t1, t2] ->
          p1 = Enum.filter(todos, fn m -> m["tipo"] == t1 end)
          p2 = Enum.filter(todos, fn m -> m["tipo"] == t2 end)
          [Enum.random(p1), Enum.random(p2)]
      end

    usados = MapSet.new(movs_tipo, fn m -> m["nombre"] end)

    complementarios =
      todos
      |> Enum.filter(fn m -> not MapSet.member?(usados, m["nombre"]) end)
      |> Enum.shuffle()
      |> Enum.take(2)

    (movs_tipo ++ complementarios)
    |> Enum.map(fn m ->
      %{nombre: m["nombre"], tipo: m["tipo"], poder_base: m["poder_base"]}
    end)
  end

  # ─── Privado ─────────────────────────────────────────────────────────────────

  defp sortear_rareza(probs) do
    valor = :rand.uniform(100)
    orden = [{"comun", probs["comun"]}, {"raro", probs["raro"]}, {"epico", probs["epico"]}]

    Enum.reduce_while(orden, 0, fn {rareza, pct}, acc ->
      nuevo = acc + pct
      if valor <= nuevo, do: {:halt, String.to_atom(rareza)}, else: {:cont, nuevo}
    end)
  end

  defp crear_instancia(especie, rareza, duenio) do
    {min_f, max_f} = @rangos[rareza]
    factor = min_f + :rand.uniform(max_f - min_f)

    %{
      id:              gen_id(),
      especie:         especie["especie"],
      duenio_original: duenio,
      rareza:          rareza,
      ataque:          round(especie["ataque_base"]    * (1 + factor / 100)),
      defensa:         round(especie["defensa_base"]   * (1 + factor / 100)),
      velocidad:       round(especie["velocidad_base"] * (1 + factor / 100)),
      salud_maxima:    100,
      movimientos:     asignar_movimientos(especie["tipos"])
    }
  end

  defp gen_id, do: :crypto.strong_rand_bytes(3) |> :binary.decode_unsigned()
end
