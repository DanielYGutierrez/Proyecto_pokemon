defmodule PokemonBattle.MotorCombate do
  @moduledoc """
  Módulo de lógica pura que implementa el motor de combate:
    - Tabla de efectividad de tipos (fuerte x2.0 / débil x0.5 / neutro x1.0)
    - Cálculo de STAB (Same Type Attack Bonus)
    - Fórmula de daño final
    - Orden de turno por velocidad
    - Aplicación de daño y detección de debilitados
    - Formateo de la vista de turno en consola
  """

  alias PokemonBattle.Persistencia

  # Tabla de ventajas: tipo_ataque fuerte contra tipo_defensor
  @ventajas %{
    {"Fuego",    "Planta"}    => 2.0,
    {"Fuego",    "Hielo"}     => 2.0,
    {"Fuego",    "Bicho"}     => 2.0,
    {"Agua",     "Fuego"}     => 2.0,
    {"Agua",     "Roca"}      => 2.0,
    {"Agua",     "Tierra"}    => 2.0,
    {"Planta",   "Agua"}      => 2.0,
    {"Planta",   "Roca"}      => 2.0,
    {"Planta",   "Tierra"}    => 2.0,
    {"Electrico","Agua"}      => 2.0,
    {"Electrico","Volador"}   => 2.0,
    {"Roca",     "Fuego"}     => 2.0,
    {"Roca",     "Hielo"}     => 2.0,
    {"Roca",     "Volador"}   => 2.0,
    {"Roca",     "Bicho"}     => 2.0
  }

  # ─── Efectividad y STAB ───────────────────────────────────────────────────────

  @doc "Modificador de efectividad del tipo de movimiento vs tipos del defensor."
  def efectividad(tipo_mov, tipos_defensor) do
    Enum.reduce(tipos_defensor, 1.0, fn tipo_def, acc ->
      acc * mod_simple(tipo_mov, tipo_def)
    end)
  end

  @doc "STAB: x1.5 si el movimiento coincide con algún tipo del atacante."
  def stab(tipo_mov, tipos_atacante) do
    if tipo_mov in tipos_atacante, do: 1.5, else: 1.0
  end

  # ─── Daño ────────────────────────────────────────────────────────────────────

  @doc """
  Calcula el daño final de un ataque.
  Fórmula:
    dano_base  = trunc((poder * (ataque_atacante / defensa_defensor)) / 5 + 2)
    dano_final = trunc(dano_base * efectividad * stab * factor_aleatorio)
  Mínimo: 1.
  """
  def calcular_dano(movimiento, atacante, defensor) do
    catalogo        = Persistencia.cargar_pokemon()
    tipos_atacante  = catalogo[atacante.especie]["tipos"]
    tipos_defensor  = catalogo[defensor.especie]["tipos"]
    tipo_mov        = movimiento.tipo

    ef      = efectividad(tipo_mov, tipos_defensor)
    st      = stab(tipo_mov, tipos_atacante)
    aleatorio = 0.85 + :rand.uniform() * 0.15

    base  = trunc((movimiento.poder_base * (atacante.ataque / defensor.defensa)) / 5 + 2)
    final = trunc(base * ef * st * aleatorio)
    max(1, final)
  end

  # ─── Turnos ───────────────────────────────────────────────────────────────────

  @doc "Determina el orden de acción. Retorna {:jugador1, :jugador2} o al revés."
  def orden_turno(pok1, pok2) do
    cond do
      pok1.velocidad > pok2.velocidad -> {:jugador1, :jugador2}
      pok2.velocidad > pok1.velocidad -> {:jugador2, :jugador1}
      true -> if :rand.uniform(2) == 1, do: {:jugador1, :jugador2}, else: {:jugador2, :jugador1}
    end
  end

  # ─── Estado de combate ────────────────────────────────────────────────────────

  @doc "Aplica daño a un Pokémon en combate. Marca debilitado si salud <= 0."
  def aplicar_dano(ec, dano) do
    nueva_salud = max(0, ec.salud_actual - dano)
    %{ec | salud_actual: nueva_salud, debilitado: nueva_salud <= 0}
  end

  @doc "True si todos los Pokémon del equipo están debilitados."
  def equipo_debilitado?(equipo), do: Enum.all?(equipo, fn ec -> ec.debilitado end)

  @doc "Primer Pokémon no debilitado del equipo. nil si no hay."
  def primer_disponible(equipo), do: Enum.find(equipo, fn ec -> not ec.debilitado end)

  @doc "Busca un movimiento en el Pokémon activo. nil si no existe."
  def obtener_movimiento(nombre, pokemon),
    do: Enum.find(pokemon.movimientos, fn m -> m.nombre == nombre end)

  # ─── Visualización de turno ───────────────────────────────────────────────────

  @doc "Construye el string de vista de turno para un jugador."
  def vista_turno(turno, nombre_jugador, rival, activo_propio, ec_propio, equipo_propio, activo_rival, salud_rival, equipo_rival) do
    catalogo    = Persistencia.cargar_pokemon()
    esp_propia  = catalogo[activo_propio.especie]
    tipos_str   = Enum.join(esp_propia["tipos"], "/")

    movs =
      activo_propio.movimientos
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {m, i} ->
        "  #{i}. #{String.pad_trailing(m.nombre, 18)} (#{m.tipo}, poder #{m.poder_base})"
      end)

    eq_rival_str =
      Enum.map_join(equipo_rival, " | ", fn r ->
        est = cond do
          r.especie == activo_rival.especie and not r.debilitado -> "(activo)"
          r.debilitado -> "(debilitado)"
          true -> "(vivo)"
        end
        "#{r.especie} #{est}"
      end)

    eq_propio_str =
      Enum.map_join(equipo_propio, " | ", fn p ->
        est = cond do
          p.id == activo_propio.id and not p.debilitado -> "(activo)"
          p.debilitado -> "(debilitado)"
          true -> "(vivo)"
        end
        "[##{p.id}] #{p.especie} #{est}"
      end)

    """

    ═══ Turno #{turno} ═══
    Rival: #{rival} → #{activo_rival.especie} | Salud: #{salud_rival}/100
    Equipo rival : #{eq_rival_str}

    Tu Pokemon: [##{activo_propio.id}] #{esp_propia["nombre"]} (#{tipos_str}) | Salud: #{ec_propio.salud_actual}/100 | Vel: #{activo_propio.velocidad}
    Tu equipo  : #{eq_propio_str}
    Movimientos:
    #{movs}

    Acciones: ataque <nombre> | cambiar <id> | rendirse
    Accion > \
    """
  end

  # ─── Privado ──────────────────────────────────────────────────────────────────

  defp mod_simple(ta, td) do
    cond do
      Map.get(@ventajas, {ta, td}) == 2.0 -> 2.0
      Map.get(@ventajas, {td, ta}) == 2.0 -> 0.5
      true -> 1.0
    end
  end
end
