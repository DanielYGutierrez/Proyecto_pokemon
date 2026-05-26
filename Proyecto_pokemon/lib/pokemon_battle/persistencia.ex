defmodule PokemonBattle.Persistencia do
  @moduledoc """
  Módulo encargado de la lectura y escritura de archivos JSON y logs.
  Centraliza toda la persistencia del sistema.

  Archivos manejados:
    - data/trainers.json  → entrenadores, inventario, monedas, equipos
    - data/pokemon.json   → catálogo de especies base (solo lectura)
    - data/moves.json     → pool de movimientos (solo lectura)
    - data/tienda.json    → configuración de sobres (solo lectura)
    - data/battles.log    → registro de resultados de batallas
  """

  @trainers_path "data/trainers.json"
  @pokemon_path  "data/pokemon.json"
  @moves_path    "data/moves.json"
  @tienda_path   "data/tienda.json"
  @battles_log   "data/battles.log"

  # ─── Entrenadores ────────────────────────────────────────────────────────────

  @doc "Carga todos los entrenadores desde disco. Retorna mapa %{nombre => entrenador}."
  def cargar_entrenadores do
    leer_json(@trainers_path)
    |> Enum.into(%{}, fn e -> {e["nombre"], json_a_entrenador(e)} end)
  end

  @doc "Persiste el mapa completo de entrenadores en disco."
  def guardar_entrenadores(entrenadores) do
    datos = entrenadores |> Map.values() |> Enum.map(&entrenador_a_json/1)
    File.write!(@trainers_path, Jason.encode!(datos, pretty: true))
  end

  # ─── Catálogo (solo lectura) ─────────────────────────────────────────────────

  @doc "Carga el catálogo de especies indexado por clave de especie."
  def cargar_pokemon do
    leer_json(@pokemon_path)
    |> Enum.into(%{}, fn p -> {p["especie"], p} end)
  end

  @doc "Carga todos los movimientos del pool."
  def cargar_moves do
    leer_json(@moves_path)
  end

  @doc "Carga la configuración de tipos de sobre."
  def cargar_tienda do
    leer_json(@tienda_path)
    |> Enum.into(%{}, fn t -> {t["tipo"], t} end)
  end

  # ─── Log de batallas ─────────────────────────────────────────────────────────

  @doc "Agrega una línea al log de resultados de batallas."
  def registrar_batalla(ganador, perdedor, motivo) do
    timestamp = DateTime.utc_now() |> DateTime.to_string()
    linea = "#{timestamp} | Ganador: #{ganador} | Perdedor: #{perdedor} | Motivo: #{motivo}\n"
    File.write!(@battles_log, linea, [:append])
  end

  # ─── Conversión entrenador ────────────────────────────────────────────────────

  def entrenador_a_json(e) do
    %{
      "nombre"            => e.nombre,
      "clave"             => e.clave,
      "monedas"           => e.monedas,
      "monedas_acumuladas"=> e.monedas_acumuladas,
      "victorias"         => e.victorias,
      "inventario"        => Enum.map(e.inventario, &pokemon_a_json/1),
      "sobres"            => Enum.map(e.sobres, &sobre_a_json/1),
      "equipos"           => Enum.into(e.equipos, %{}, fn {k, v} -> {to_string(k), v} end)
    }
  end

  def json_a_entrenador(m) do
    %{
      nombre:             m["nombre"],
      clave:              m["clave"],
      monedas:            m["monedas"] || 0,
      monedas_acumuladas: m["monedas_acumuladas"] || 0,
      victorias:          m["victorias"] || 0,
      inventario:         Enum.map(m["inventario"] || [], &json_a_pokemon/1),
      sobres:             Enum.map(m["sobres"] || [], &json_a_sobre/1),
      equipos:            Enum.into(m["equipos"] || %{}, %{}, fn {k, v} -> {k, v} end)
    }
  end

  def pokemon_a_json(p) do
    %{
      "id"             => p.id,
      "especie"        => p.especie,
      "duenio_original"=> p.duenio_original,
      "rareza"         => to_string(p.rareza),
      "ataque"         => p.ataque,
      "defensa"        => p.defensa,
      "velocidad"      => p.velocidad,
      "movimientos"    => Enum.map(p.movimientos, fn m ->
        %{"nombre" => m.nombre, "tipo" => m.tipo, "poder_base" => m.poder_base}
      end)
    }
  end

  def json_a_pokemon(m) do
    %{
      id:              m["id"],
      especie:         m["especie"],
      duenio_original: m["duenio_original"],
      rareza:          String.to_atom(m["rareza"]),
      ataque:          m["ataque"],
      defensa:         m["defensa"],
      velocidad:       m["velocidad"],
      salud_maxima:    100,
      movimientos:     Enum.map(m["movimientos"] || [], fn mv ->
        %{nombre: mv["nombre"], tipo: mv["tipo"], poder_base: mv["poder_base"]}
      end)
    }
  end

  def sobre_a_json(s) do
    %{"id" => s.id, "tipo" => to_string(s.tipo), "abierto" => s.abierto}
  end

  def json_a_sobre(m) do
    %{id: m["id"], tipo: String.to_atom(m["tipo"]), abierto: m["abierto"]}
  end

  # ─── Privado ─────────────────────────────────────────────────────────────────

  defp leer_json(ruta) do
    case File.read(ruta) do
      {:ok, contenido} -> Jason.decode!(contenido)
      {:error, _}      -> []
    end
  end
end
