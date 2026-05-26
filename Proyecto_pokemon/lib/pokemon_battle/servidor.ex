defmodule PokemonBattle.Servidor do
  @moduledoc """
  Módulo de interfaz de consola y enrutamiento de comandos.

  Combina el loop de lectura (I/O) con el despacho de cada comando
  al módulo de lógica correspondiente. También procesa mensajes
  asíncronos que llegan de las batallas e intercambios.

  Punto de entrada:
    PokemonBattle.Servidor.iniciar()
  """

  alias PokemonBattle.{
    GestorEntrenadores,
    SistemaSobres,
    GestorSalas,
    SupervisorBatallas,
    Batalla,
    Intercambio,
    Persistencia,
    Cluster
  }

  @sesion_vacia %{
    entrenador:       nil,
    equipo_cargado:   nil,
    sala_batalla:     nil,
    sala_intercambio: nil   # {codigo, pid}
  }

  # ─── Inicio ──────────────────────────────────────────────────────────────────

  @doc "Inicia la consola interactiva. Conecta al servidor si se pasa nombre_nodo."
  def iniciar(nombre_servidor \\ nil) do
    if nombre_servidor do
      case Cluster.iniciar_cliente(nombre_servidor) do
        :ok -> :ok
        {:error, _} -> IO.puts("Continuando en modo local..."); :ok
      end
    end

    IO.puts(bienvenida())
    loop(@sesion_vacia)
  end

  # ─── Loop principal ───────────────────────────────────────────────────────────

  defp loop(sesion) do
    sesion = procesar_mensajes(sesion)
    prompt = if sesion.entrenador, do: "[#{sesion.entrenador}] > ", else: "> "
    linea  = IO.gets(prompt) |> String.trim()

    if linea == "" do
      loop(sesion)
    else
      {tipo, msg, nuevo_sesion} = despachar(String.split(linea, " ", trim: true), sesion)
      if msg != "", do: IO.puts("\n" <> msg)
      _ = tipo
      loop(nuevo_sesion)
    end
  end

  # ─── Mensajes asíncronos ─────────────────────────────────────────────────────

  defp procesar_mensajes(sesion) do
    receive do
      {:inicio_turno, _n, vista} ->
        IO.puts(vista)
        procesar_mensajes(sesion)

      {:mensaje_batalla, texto} ->
        IO.puts("\n[BATALLA] #{texto}")
        procesar_mensajes(sesion)

      {:batalla_terminada, _res, msg} ->
        IO.puts("\n" <> msg)
        procesar_mensajes(%{sesion | sala_batalla: nil, equipo_cargado: nil})

      {:mensaje_intercambio, texto} ->
        IO.puts("\n[INTERCAMBIO] #{texto}")
        procesar_mensajes(sesion)

      {:intercambio_completado, msg} ->
        IO.puts("\n" <> msg)
        procesar_mensajes(%{sesion | sala_intercambio: nil})

    after 0 -> sesion
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════════
  # ENRUTAMIENTO DE COMANDOS
  # ═══════════════════════════════════════════════════════════════════════════════

  # ─── Sesión ──────────────────────────────────────────────────────────────────

  defp despachar(["iniciar", usuario, clave], sesion) do
    case GestorEntrenadores.iniciar_sesion(usuario, clave) do
      {:ok, :registrado, e} ->
        {:ok, "✅ Bienvenido #{usuario}! Tienes 1 sobre basico gratis. Usa: abrir_sobre ultimo",
         %{sesion | entrenador: e.nombre}}

      {:ok, :sesion_iniciada, e} ->
        {:ok, "✅ Sesion iniciada. Bienvenido de vuelta, #{usuario}!",
         %{sesion | entrenador: e.nombre}}

      {:error, :clave_incorrecta} ->
        {:error, "❌ Clave incorrecta.", sesion}
    end
  end

  defp despachar(["salir"], sesion) do
    {:ok, "Sesion cerrada.", @sesion_vacia}
  end

  defp despachar(["ayuda"], sesion), do: {:ok, ayuda(), sesion}

  # ─── Requieren sesión ────────────────────────────────────────────────────────

  defp despachar(_cmd, %{entrenador: nil} = sesion) do
    {:error, "❌ Inicia sesion primero: iniciar <usuario> <clave>", sesion}
  end

  defp despachar(["perfil"], sesion) do
    e = GestorEntrenadores.obtener(sesion.entrenador)
    pendientes = Enum.count(e.sobres, fn s -> not s.abierto end)
    msg = """
    === Perfil de #{e.nombre} ===
    Monedas         : #{e.monedas}
    Sobres pendientes: #{pendientes}
    Pokemon en inventario: #{length(e.inventario)}
    Victorias       : #{e.victorias}
    """
    {:ok, msg, sesion}
  end

  defp despachar(["inventario"], sesion) do
    e        = GestorEntrenadores.obtener(sesion.entrenador)
    catalogo = Persistencia.cargar_pokemon()
    cabecera = "=== Inventario de #{e.nombre} (#{length(e.inventario)} Pokemon) ==="
    cuerpo =
      e.inventario
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {p, idx} ->
        esp      = catalogo[p.especie]
        tipos    = Enum.join(esp["tipos"], "/")
        rareza   = Atom.to_string(p.rareza)
        movs     = Enum.map_join(p.movimientos, ", ", fn m -> "#{m.nombre}(#{m.poder_base})" end)
        "  #{idx}. [##{p.id}] #{esp["nombre"]} (#{tipos}) [#{rareza}]\n" <>
        "     Ataque: #{p.ataque} | Defensa: #{p.defensa} | Velocidad: #{p.velocidad} | Salud max: 100\n" <>
        "     Duenio original: #{p.duenio_original}\n" <>
        "     Movimientos: #{movs}"
      end)
    {:ok, cabecera <> "\n" <> cuerpo, sesion}
  end

  defp despachar(["clasificacion"], sesion) do
    ranking  = GestorEntrenadores.clasificacion()
    cabecera = "=== Clasificacion Global ===\n#    Entrenador        Victorias   Monedas acum."
    filas    = Enum.map_join(ranking, "\n", fn {pos, nombre, v, m} ->
      "#{String.pad_trailing(to_string(pos), 5)}#{String.pad_trailing(nombre, 18)}#{String.pad_trailing(to_string(v), 12)}#{m}"
    end)
    {:ok, cabecera <> "\n" <> filas, sesion}
  end

  # ─── Tienda y sobres ─────────────────────────────────────────────────────────

  defp despachar(["tienda"], sesion) do
    msg = """
    === Tienda de Sobres ===
    Tipo       Precio  Comun  Raro  Epico
    basico      100     70%   25%    5%
    avanzado    250     40%   45%   15%
    """
    {:ok, msg, sesion}
  end

  defp despachar(["comprar_sobre", tipo_str], sesion) do
    tipo   = String.to_existing_atom(tipo_str)
    precio = SistemaSobres.precio(tipo)
    e      = GestorEntrenadores.obtener(sesion.entrenador)

    if e.monedas < precio do
      {:error, "❌ Monedas insuficientes. Necesitas #{precio}, tienes #{e.monedas}.", sesion}
    else
      sobre = SistemaSobres.nuevo_sobre(tipo)
      GestorEntrenadores.actualizar(%{e | monedas: e.monedas - precio})
      GestorEntrenadores.agregar_sobre(sesion.entrenador, sobre)
      {:ok, "✅ Sobre #{tipo_str} comprado (##{sobre.id}). Abrir con: abrir_sobre #{sobre.id}", sesion}
    end
  rescue
    _ -> {:error, "❌ Tipo invalido. Usa: basico | avanzado", sesion}
  end

  defp despachar(["abrir_sobre", ref], sesion) do
    e = GestorEntrenadores.obtener(sesion.entrenador)

    sobre =
      case ref do
        "ultimo" -> Enum.find(e.sobres, fn s -> not s.abierto end)
        id_str   ->
          id = String.to_integer(id_str)
          Enum.find(e.sobres, fn s -> s.id == id and not s.abierto end)
      end

    case sobre do
      nil -> {:error, "❌ No se encontro un sobre pendiente con ese identificador.", sesion}
      s ->
        case SistemaSobres.abrir_sobre(s, sesion.entrenador) do
          {:ok, pokemons} ->
            sobres_act = Enum.map(e.sobres, fn sb -> if sb.id == s.id, do: %{sb | abierto: true}, else: sb end)
            GestorEntrenadores.actualizar(%{e | sobres: sobres_act, inventario: e.inventario ++ pokemons})
            catalogo = Persistencia.cargar_pokemon()
            cuerpo =
              pokemons
              |> Enum.with_index(1)
              |> Enum.map_join("\n", fn {p, idx} ->
                esp  = catalogo[p.especie]
                tipos = Enum.join(esp["tipos"], "/")
                movs  = Enum.map_join(p.movimientos, ", ", fn m -> "#{m.nombre}(#{m.poder_base})" end)
                "  #{idx}. [##{p.id}] #{esp["nombre"]} (#{tipos}) [#{p.rareza}]\n     Movimientos: #{movs}"
              end)
            {:ok, "¡Sobre abierto! Obtuviste:\n" <> cuerpo, sesion}

          {:error, motivo} ->
            {:error, "❌ Error: #{inspect(motivo)}", sesion}
        end
    end
  rescue
    _ -> {:error, "❌ Referencia invalida.", sesion}
  end

  # ─── Equipos ─────────────────────────────────────────────────────────────────

  defp despachar(["crear_equipo", nombre_eq | resto], sesion) do
    e    = GestorEntrenadores.obtener(sesion.entrenador)
    ids  = Enum.join(resto, "") |> String.split(",", trim: true) |> Enum.map(&String.to_integer(String.trim(&1)))

    cond do
      Map.has_key?(e.equipos, nombre_eq) ->
        {:error, "❌ Ya existe un equipo con ese nombre.", sesion}
      length(ids) < 1 or length(ids) > 3 ->
        {:error, "❌ Un equipo debe tener entre 1 y 3 Pokemon.", sesion}
      not Enum.all?(ids, fn id -> Enum.any?(e.inventario, fn p -> p.id == id end) end) ->
        {:error, "❌ Alguno de los IDs no existe en tu inventario.", sesion}
      true ->
        GestorEntrenadores.actualizar(%{e | equipos: Map.put(e.equipos, nombre_eq, ids)})
        {:ok, "✅ Equipo '#{nombre_eq}' creado con #{length(ids)} Pokemon.", sesion}
    end
  rescue
    _ -> {:error, "❌ IDs invalidos.", sesion}
  end

  defp despachar(["listar_equipos"], sesion) do
    e = GestorEntrenadores.obtener(sesion.entrenador)
    if map_size(e.equipos) == 0 do
      {:ok, "No tienes equipos. Usa: crear_equipo <nombre> <id1,id2,id3>", sesion}
    else
      lista = Enum.map_join(e.equipos, "\n", fn {nombre, ids} ->
        nombres = Enum.map_join(ids, ", ", fn id ->
          case Enum.find(e.inventario, fn p -> p.id == id end) do
            nil -> "[##{id}]?"
            p   -> "[##{id}] #{p.especie}"
          end
        end)
        "  #{nombre} [#{length(ids)}/3]: #{nombres}"
      end)
      {:ok, "Equipos guardados:\n#{lista}", sesion}
    end
  end

  defp despachar(["usar_equipo", nombre_eq], sesion) do
    e = GestorEntrenadores.obtener(sesion.entrenador)
    case Map.get(e.equipos, nombre_eq) do
      nil  -> {:error, "❌ Equipo '#{nombre_eq}' no encontrado.", sesion}
      ids  ->
        faltantes = Enum.reject(ids, fn id -> Enum.any?(e.inventario, fn p -> p.id == id end) end)
        if faltantes != [] do
          {:error, "❌ Faltan Pokemon en inventario: #{inspect(faltantes)}", sesion}
        else
          equipo = Enum.map(ids, fn id -> Enum.find(e.inventario, fn p -> p.id == id end) end)
          {:ok, "✅ Equipo '#{nombre_eq}' cargado. Listo para batalla.", %{sesion | equipo_cargado: equipo}}
        end
    end
  end

  defp despachar(["agregar_pokemon_equipo", nombre_eq, id_str], sesion) do
    id = String.to_integer(id_str)
    e  = GestorEntrenadores.obtener(sesion.entrenador)
    case Map.get(e.equipos, nombre_eq) do
      nil -> {:error, "❌ Equipo no encontrado.", sesion}
      ids when length(ids) >= 3 -> {:error, "❌ El equipo ya tiene 3 Pokemon.", sesion}
      ids ->
        if Enum.any?(e.inventario, fn p -> p.id == id end) do
          GestorEntrenadores.actualizar(%{e | equipos: Map.put(e.equipos, nombre_eq, ids ++ [id])})
          {:ok, "✅ Pokemon ##{id} agregado a '#{nombre_eq}'.", sesion}
        else
          {:error, "❌ Pokemon ##{id} no en inventario.", sesion}
        end
    end
  rescue
    _ -> {:error, "❌ ID invalido.", sesion}
  end

  defp despachar(["quitar_pokemon_equipo", nombre_eq, id_str], sesion) do
    id = String.to_integer(id_str)
    e  = GestorEntrenadores.obtener(sesion.entrenador)
    case Map.get(e.equipos, nombre_eq) do
      nil -> {:error, "❌ Equipo no encontrado.", sesion}
      ids when length(ids) <= 1 -> {:error, "❌ No se puede quitar el unico Pokemon del equipo.", sesion}
      ids ->
        GestorEntrenadores.actualizar(%{e | equipos: Map.put(e.equipos, nombre_eq, Enum.reject(ids, &(&1 == id)))})
        {:ok, "✅ Pokemon ##{id} quitado de '#{nombre_eq}'.", sesion}
    end
  rescue
    _ -> {:error, "❌ ID invalido.", sesion}
  end

  # ─── Salas de batalla ────────────────────────────────────────────────────────

  defp pid_salas, do: Cluster.gestor_salas() || GestorSalas
  defp pid_supervisor, do: Cluster.supervisor_batallas() || SupervisorBatallas

  defp despachar(["listar_salas"], sesion) do
    salas = GenServer.call(pid_salas(), :listar)
    if map_size(salas) == 0 do
      {:ok, "No hay salas activas. Crea una con: crear_sala", sesion}
    else
      lista = Enum.map_join(salas, "\n", fn {id, _} -> "  - #{id}" end)
      {:ok, "=== Salas activas ===\n#{lista}", sesion}
    end
  end

  defp despachar(["crear_sala" | opts], sesion) do
    tiempo =
      Enum.find_value(opts, 20, fn opt ->
        case String.split(opt, "=") do
          ["tiempo_turno", t] -> String.to_integer(t)
          _ -> nil
        end
      end)

    id_sala = "BAT-#{:crypto.strong_rand_bytes(2) |> Base.encode16()}"
    {:ok, pid} = DynamicSupervisor.start_child(
      pid_supervisor(),
      {PokemonBattle.Batalla, [id_sala: id_sala, tiempo_turno: tiempo]}
    )
    GenServer.cast(pid_salas(), {:registrar, id_sala, pid})
    {:ok, "✅ Sala #{id_sala} creada (turno: #{tiempo}s). Usa: unirse_sala #{id_sala}", sesion}
  end

  defp despachar(["unirse_sala", id_sala], sesion) do
    pid = GenServer.call(pid_salas(), {:buscar, id_sala})
    if pid do
      if sesion.equipo_cargado in [nil, []] do
        {:error, "❌ Carga un equipo primero: usar_equipo <nombre>", sesion}
      else
        case Batalla.unirse(pid, sesion.entrenador, sesion.equipo_cargado) do
          :ok -> {:ok, "✅ Unido a sala #{id_sala}. Usa: iniciar_batalla #{id_sala}", %{sesion | sala_batalla: pid}}
          {:error, :sala_llena} -> {:error, "❌ Sala llena.", sesion}
          {:error, m} -> {:error, "❌ Error: #{inspect(m)}", sesion}
        end
      end
    else
      {:error, "❌ Sala '#{id_sala}' no encontrada.", sesion}
    end
  end

  defp despachar(["iniciar_batalla", id_sala], sesion) do
    pid = GenServer.call(pid_salas(), {:buscar, id_sala})
    if pid do
      case Batalla.iniciar(pid) do
        :ok -> {:ok, "⚔️  Batalla iniciada!", sesion}
        {:error, :faltan_jugadores} -> {:error, "❌ Se necesitan 2 jugadores.", sesion}
        {:error, m} -> {:error, "❌ Error: #{inspect(m)}", sesion}
      end
    else
      {:error, "❌ Sala no encontrada.", sesion}
    end
  end

  # ─── Acciones en batalla ─────────────────────────────────────────────────────

  defp despachar(["ataque", nombre_mov], %{sala_batalla: pid} = sesion) when pid != nil do
    case Batalla.accion(pid, sesion.entrenador, {:ataque, nombre_mov}) do
      :ok -> {:ok, "", sesion}
      {:error, m} -> {:error, "❌ #{inspect(m)}", sesion}
    end
  end

  defp despachar(["cambiar", id_str], %{sala_batalla: pid} = sesion) when pid != nil do
    id = String.to_integer(id_str)
    case Batalla.accion(pid, sesion.entrenador, {:cambiar, id}) do
      :ok -> {:ok, "", sesion}
      {:error, m} -> {:error, "❌ #{inspect(m)}", sesion}
    end
  rescue
    _ -> {:error, "❌ ID invalido.", sesion}
  end

  defp despachar(["rendirse"], %{sala_batalla: pid} = sesion) when pid != nil do
    Batalla.rendirse(pid, sesion.entrenador)
    {:ok, "Te has rendido.", %{sesion | sala_batalla: nil, equipo_cargado: nil}}
  end

  # ─── Intercambio ─────────────────────────────────────────────────────────────

  defp despachar(["crear_sala_intercambio"], sesion) do
  codigo = "IC-#{:crypto.strong_rand_bytes(2) |> Base.encode16()}"
  {:ok, pid} = DynamicSupervisor.start_child(
    pid_supervisor(),
    {PokemonBattle.Intercambio, [codigo: codigo]}
  )
  GenServer.cast(pid_salas(), {:registrar, codigo, pid})
  Intercambio.unirse(pid, sesion.entrenador, self())
  {:ok, "[Sala #{codigo} creada] Comparte este codigo con el otro entrenador.", %{sesion | sala_intercambio: {codigo, pid}}}
end

  defp despachar(["unirse_sala_intercambio", codigo], sesion) do
  pid = GenServer.call(pid_salas(), {:buscar, codigo})
  cond do
    pid == nil ->
      {:error, "Sala '#{codigo}' no encontrada.", sesion}
    true ->
      case Intercambio.unirse(pid, sesion.entrenador, self()) do
        :ok ->
          {:ok, "[Sala #{codigo}] Te uniste. Ya pueden intercambiar.", %{sesion | sala_intercambio: {codigo, pid}}}
        {:error, :sala_llena} ->
          {:error, "La sala ya tiene 2 participantes.", sesion}
        {:error, :ya_unido} ->
          {:error, "Ya estas en esta sala.", sesion}
        {:error, m} ->
          {:error, "Error: #{inspect(m)}", sesion}
      end
  end
end

  defp despachar(["ofrecer_pokemon", id_str], %{sala_intercambio: {_, pid}} = sesion) when pid != nil do
    id = String.to_integer(id_str)
    case Intercambio.ofrecer_pokemon(pid, sesion.entrenador, id) do
      :ok -> {:ok, "", sesion}
      {:error, m} -> {:error, "❌ #{inspect(m)}", sesion}
    end
  rescue
    _ -> {:error, "❌ ID invalido.", sesion}
  end

  defp despachar(["confirmar_intercambio"], %{sala_intercambio: {_, pid}} = sesion) when pid != nil do
    Intercambio.confirmar(pid, sesion.entrenador)
    {:ok, "✅ Confirmacion enviada.", sesion}
  end

  defp despachar(["cancelar_intercambio"], %{sala_intercambio: {_, pid}} = sesion) when pid != nil do
    Intercambio.cancelar(pid, sesion.entrenador)
    {:ok, "Intercambio cancelado.", %{sesion | sala_intercambio: nil}}
  end

  # ─── Comando no reconocido ────────────────────────────────────────────────────

  defp despachar(_, sesion) do
    {:error, "❌ Comando no reconocido. Escribe 'ayuda' para ver los comandos.", sesion}
  end

  # ─── Textos ──────────────────────────────────────────────────────────────────

  defp bienvenida do
    """
    ╔══════════════════════════════════════════════════════╗
    ║         PLATAFORMA BATALLAS POKEMON                ║
    ║   Universidad del Quindio - Programacion III        ║
    ║        Distribuida en nodos Elixir                  ║
    ╚══════════════════════════════════════════════════════╝
    Escribe 'ayuda' para ver los comandos disponibles.
    """
  end

  defp ayuda do
    """
    SESION       : iniciar <usuario> <clave> | salir | perfil | inventario | clasificacion
    TIENDA       : tienda | comprar_sobre <basico|avanzado> | abrir_sobre <id|ultimo>
    EQUIPOS      : crear_equipo <nombre> <ids> | listar_equipos | usar_equipo <nombre>
                   agregar_pokemon_equipo <eq> <id> | quitar_pokemon_equipo <eq> <id>
    BATALLAS     : listar_salas | crear_sala | unirse_sala <id> | iniciar_batalla <id>
    EN BATALLA   : ataque <movimiento> | cambiar <id> | rendirse
    INTERCAMBIO  : crear_sala_intercambio | ofrecer_pokemon <id> | confirmar_intercambio | cancelar_intercambio
    """
  end
end
