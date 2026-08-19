-- Buscador de clientes del selector admin: sin acentos y paginado.
-- Fecha: 2026-08-19
--
-- La Edge Function `admin-clientes` devuelve hoy el padrón completo y filtra en el
-- navegador con `contains` sobre `toLowerCase()`. Dos defectos independientes:
--
--   1. Sin paginación ni búsqueda en servidor: 630 filas por cada entrada a la pantalla,
--      y crece sola con el padrón.
--   2. La comparación no ignora acentos: "hernandez" no encuentra "Hernández".
--
-- Medido read-only en prod (`admin_sozu`) el 2026-08-19:
--   · 630 clientes con acceso al Portal del Cliente (5,184 personas en total).
--   · 314 de esos 630 (50%) llevan al menos un acento en `nombre_legal`.
--   · "hernandez" encuentra 9 de 20 (55% invisibles); "martinez" 5 de 16 (69%).
--   · `roles.id = 23` es 'Cliente' en prod. El id NO se codifica aquí: llega por
--     parámetro desde la Edge Function, que lo resuelve del secret `CLIENTE_ROL_ID`
--     con respaldo por nombre.
--
-- Alcance: 1 extensión + 2 funciones nuevas. NO se altera ninguna tabla, columna ni dato.
-- Es aditivo: mientras la Edge Function nueva no se despliegue, nada llama a esto.
--
-- Pareja obligatoria: la EF `admin-clientes` (repo sozu-edge-functions). Esta migración
-- va PRIMERO; al revés la EF responde 500.

-- ---------------------------------------------------------------------------
-- 1. Extensión `unaccent`
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA extensions;

-- `IF NOT EXISTS` ignora la cláusula `WITH SCHEMA` cuando la extensión ya está
-- instalada en otro esquema, y no avisa. Si eso pasara, `extensions.unaccent(...)`
-- de más abajo fallaría en tiempo de ejecución, no aquí. Se aborta ahora.
DO $guard$
DECLARE
  v_esquema text;
BEGIN
  SELECT n.nspname INTO v_esquema
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
  WHERE e.extname = 'unaccent';

  IF v_esquema IS DISTINCT FROM 'extensions' THEN
    RAISE EXCEPTION
      'unaccent está instalada en el esquema %, se esperaba extensions. Corregir con: ALTER EXTENSION unaccent SET SCHEMA extensions;',
      coalesce(v_esquema, '(ninguno)');
  END IF;
END
$guard$;

-- ---------------------------------------------------------------------------
-- 2. Envoltura inmutable de `unaccent`
-- ---------------------------------------------------------------------------
-- `unaccent(text)` de una sola firma es STABLE, no IMMUTABLE, porque resuelve el
-- diccionario por search_path. La forma de dos argumentos con el diccionario explícito
-- sí es determinista, y es el patrón que documenta PostgreSQL para poder indexarla.
--
-- Tres razones para la envoltura: nombra el concepto una sola vez; no depende de
-- search_path (funciona dentro de una función con search_path fijado); y al ser
-- IMMUTABLE permite agregar después el índice GIN diferido sin tocar la función de
-- búsqueda.
--
-- OJO: IMMUTABLE aquí es una promesa sobre el archivo de reglas del diccionario
-- `unaccent`. Si una actualización de la extensión cambia esas reglas y para entonces
-- existe un índice sobre esta expresión, hay que REINDEX. Sin índice —el estado que
-- deja esta migración— la advertencia no aplica todavía.
CREATE OR REPLACE FUNCTION public.sozu_unaccent(p_texto text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
RETURNS NULL ON NULL INPUT
SET search_path = ''
AS $fn$
  SELECT extensions.unaccent('extensions.unaccent'::regdictionary, p_texto)
$fn$;

COMMENT ON FUNCTION public.sozu_unaccent(text) IS
  'unaccent() determinista (diccionario explícito), apta para expresiones de índice.';

-- ---------------------------------------------------------------------------
-- 3. Búsqueda paginada del padrón de clientes impersonables
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_clientes_buscar(
  p_busqueda           text    DEFAULT NULL,
  p_limite             integer DEFAULT 50,
  p_desplazamiento     integer DEFAULT 0,
  p_rol_cliente_id     integer DEFAULT NULL,
  p_rol_cliente_nombre text    DEFAULT 'Cliente'
)
RETURNS TABLE (
  id_persona integer,
  nombre     text,
  email      text,
  total      bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
  WITH patron AS (
    -- El texto se normaliza UNA vez. El escapado va antes de envolver en % %: sin él,
    -- un admin que escriba "50%" hace que LIKE case con todo. La barra invertida se
    -- escapa PRIMERO o se re-escapan las otras dos.
    SELECT CASE
      WHEN p_busqueda IS NULL OR btrim(p_busqueda) = '' THEN NULL
      ELSE '%' || replace(replace(replace(
             public.sozu_unaccent(lower(btrim(p_busqueda))),
             '\', '\\'), '%', '\%'), '_', '\_') || '%'
    END AS like_patron
  ),
  acceso AS (
    -- Quién puede entrar al Portal del Cliente: usuario ACTIVO con rol Cliente, O
    -- usuario ACTIVO que además es comprador activo. El usuario activo es requisito
    -- SIEMPRE: una compra sin login es una compra, no un acceso.
    SELECT DISTINCT u.id_persona
    FROM public.usuarios u
    LEFT JOIN public.roles r ON r.id = u.rol_id
    LEFT JOIN public.compradores c
           ON c.id_persona = u.id_persona AND c.activo
    WHERE u.activo
      AND u.id_persona IS NOT NULL
      AND (
        c.id_persona IS NOT NULL
        OR CASE
             WHEN p_rol_cliente_id IS NOT NULL THEN u.rol_id = p_rol_cliente_id
             ELSE lower(btrim(r.nombre)) = lower(btrim(p_rol_cliente_nombre))
           END
      )
  ),
  filtrados AS (
    SELECT p.id,
           coalesce(p.nombre_legal, 'Cliente') AS nombre_cliente,
           p.email
    FROM public.personas p
    JOIN acceso a ON a.id_persona = p.id
    CROSS JOIN patron
    WHERE patron.like_patron IS NULL
       OR public.sozu_unaccent(lower(coalesce(p.nombre_legal, '')))
            LIKE patron.like_patron ESCAPE '\'
       OR public.sozu_unaccent(lower(coalesce(p.email, '')))
            LIKE patron.like_patron ESCAPE '\'
  )
  -- Todas las referencias van calificadas (u., p., f.): en una función `language sql`
  -- con RETURNS TABLE los nombres de salida (nombre, email, total) son visibles dentro
  -- del cuerpo y una referencia sin calificar aborta con "column reference is ambiguous".
  -- Por eso los alias internos son nombre_cliente y total_filas.
  SELECT f.id,
         f.nombre_cliente,
         f.email,
         count(*) OVER () AS total_filas
  FROM filtrados f
  -- El desempate por id NO es adorno: sin un orden total, dos páginas con nombres
  -- repetidos se pisan y una fila se repite o se pierde.
  ORDER BY public.sozu_unaccent(lower(f.nombre_cliente)), f.id
  -- `p_limite => null` devuelve TODO (`limit null` en Postgres es "sin tope"). Es lo que
  -- usa la ruta heredada `POST {}`, y es lo que permite que exista UNA sola
  -- implementación de la lista: con esto la cascada en TypeScript de admin-clientes se
  -- borra y la regla de "quién es cliente impersonable" deja de estar escrita dos veces.
  -- `greatest(null, 1)` es 1, no null: por eso el CASE y no la saturación a secas.
  LIMIT  (CASE WHEN p_limite IS NULL
               THEN NULL
               ELSE least(greatest(p_limite, 1), 200) END)
  OFFSET greatest(p_desplazamiento, 0);
$fn$;

COMMENT ON FUNCTION public.admin_clientes_buscar(text, integer, integer, integer, text) IS
  'Padrón de clientes impersonables, buscado sin acentos y paginado. Solo service_role.';

-- ---------------------------------------------------------------------------
-- 4. Permisos
-- ---------------------------------------------------------------------------
-- `admin_clientes_buscar` NO se otorga a authenticated ni a anon. Es SECURITY DEFINER y
-- devuelve nombre y correo del padrón completo de clientes: otorgarla a authenticated
-- convierte a cualquier usuario con sesión —incluido cualquier cliente del portal— en
-- alguien que puede enumerar a todos los demás con su correo. La autorización de quién
-- puede llamarla vive en authAdmin() de la Edge Function, que exige un rol con
-- roles.apps.administrar incluyendo 'clientes'.
--
-- REVOKE FROM PUBLIC no basta en este proyecto: `pg_default_acl` de public/postgres
-- concede EXECUTE explícito a anon, authenticated y service_role en cada función nueva
-- del esquema public (verificado read-only en prod el 2026-08-19). Ese grant es
-- nominal, no vía PUBLIC, así que hay que revocarlo por rol.
REVOKE ALL ON FUNCTION public.admin_clientes_buscar(text, integer, integer, integer, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_clientes_buscar(text, integer, integer, integer, text)
  TO service_role;

-- Defensa en profundidad, no crítico: sozu_unaccent no es SECURITY DEFINER y solo quita
-- acentos de una cadena, así que exponerla no filtra nada. Se cierra igual para no
-- publicar un endpoint RPC que nadie necesita.
REVOKE ALL ON FUNCTION public.sozu_unaccent(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sozu_unaccent(text) TO service_role;

-- `create or replace` sobre una función que YA existe conserva su ACL, así que re-aplicar
-- esta migración no reabre el permiso. Un `drop` + `create` sí lo reabre: por eso el guard
-- de abajo no es opcional, y por eso va DESPUÉS de los grants (antes pasaría siempre).

-- ---------------------------------------------------------------------------
-- 5. Auto-verificación: los permisos quedaron cerrados
-- ---------------------------------------------------------------------------
-- Va al final del archivo a propósito: si se pusiera antes de los GRANT, pasaría siempre.
DO $verify$
DECLARE
  v_abiertos text;
  v_oid      oid := 'public.admin_clientes_buscar(text, integer, integer, integer, text)'::regprocedure;
BEGIN
  SELECT string_agg(r.rolname, ', ' ORDER BY r.rolname)
    INTO v_abiertos
  FROM (VALUES ('anon'), ('authenticated'), ('public')) AS r(rolname)
  WHERE has_function_privilege(r.rolname, v_oid, 'EXECUTE');

  IF v_abiertos IS NOT NULL THEN
    RAISE EXCEPTION
      'admin_clientes_buscar sigue ejecutable por: %. Es SECURITY DEFINER y devuelve el padrón con correos.',
      v_abiertos;
  END IF;

  -- Se comprueban las dos direcciones a propósito: solo la primera mitad dejaría pasar
  -- una migración que cierra tanto que la Edge Function deja de funcionar.
  IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role NO puede ejecutar admin_clientes_buscar: la Edge Function respondería 500.';
  END IF;
END
$verify$;

-- ---------------------------------------------------------------------------
-- Lo que deliberadamente NO se crea
-- ---------------------------------------------------------------------------
-- `pg_trgm` y el índice GIN sobre sozu_unaccent(lower(nombre_legal)) serían hoy un
-- índice muerto: el plan no arranca del filtro de texto, arranca de `acceso` (630
-- personas) y sobre esas aplica el LIKE, ~630 llamadas a unaccent, del orden de 1-2 ms.
-- Un GIN sobre personas (5,184 filas) no se usaría y sí costaría amplificación de
-- escritura en cada alta o edición de persona. Cuando el conjunto de `acceso` pase de
-- ~10,000, o si algún día se busca sobre personas sin acotar antes por el gate:
--
--   CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;
--   CREATE INDEX CONCURRENTLY idx_personas_nombre_sin_acento_trgm
--     ON public.personas USING gin
--     (public.sozu_unaccent(lower(coalesce(nombre_legal, ''))) extensions.gin_trgm_ops);
--
-- Es aditivo y no cambia la función.

-- ---------------------------------------------------------------------------
-- Rollback (el orden importa: la extensión no cae mientras sozu_unaccent dependa de ella)
-- ---------------------------------------------------------------------------
--   DROP FUNCTION IF EXISTS public.admin_clientes_buscar(text, integer, integer, integer, text);
--   DROP FUNCTION IF EXISTS public.sozu_unaccent(text);
--   DROP EXTENSION IF EXISTS unaccent;  -- solo si nada más la usa
--
-- Sin riesgo de pérdida de datos: no se creó ni se modificó ninguna tabla. Revertir la
-- BD requiere haber revertido antes la Edge Function (o no haberla desplegado todavía).
