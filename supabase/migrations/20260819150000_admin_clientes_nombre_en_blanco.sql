-- Seguimiento de 20260819120000: un nombre en blanco pinta una fila vacía.
-- Fecha: 2026-08-19
--
-- La migración anterior dejó `coalesce(p.nombre_legal, 'Cliente')`, que solo atrapa el NULL.
-- Un nombre_legal que sea cadena vacía o puros espacios pasa de largo: el coalesce no lo ve
-- (no es NULL) y el `?? "Cliente"` de la Edge Function tampoco ('' ?? x devuelve ''). El
-- admin ve una fila del selector sin texto y sin manera de saber a quién corresponde.
--
-- Hoy es LATENTE, no un bug visible. Verificado read-only en prod el 2026-08-19: de las 630
-- personas del padrón impersonable, 0 tienen nombre_legal nulo y 0 lo tienen en blanco (0 en
-- toda la tabla personas). Se corrige igual porque el dato entra por captura manual y la
-- guarda cuesta una línea.
--
-- Va como migración de seguimiento y no como edición del archivo anterior: 20260819120000
-- ya está en `dev` (PR #644, mergeado el 2026-08-19), así que editarlo cambiaría un archivo
-- ya aplicado y el CI lo rechazaría.
--
-- Único cambio respecto a la definición de 20260819120000:
--   coalesce(p.nombre_legal, 'Cliente')
--   -> coalesce(nullif(btrim(p.nombre_legal), ''), 'Cliente')

BEGIN;

DO $anchor$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'admin_clientes_buscar'
  ) THEN
    RAISE EXCEPTION 'public.admin_clientes_buscar no existe: falta aplicar 20260819120000 antes que esta.';
  END IF;
END
$anchor$;

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
    -- nullif(btrim(...), '') y no solo coalesce: un nombre en blanco no es NULL, así que
    -- el coalesce lo dejaba pasar y el `?? "Cliente"` de la Edge Function tampoco lo
    -- atrapa ('' ?? x devuelve ''). Salía una fila sin texto en el selector.
    SELECT p.id,
           coalesce(nullif(btrim(p.nombre_legal), ''), 'Cliente') AS nombre_cliente,
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
  SELECT f.id,
         f.nombre_cliente,
         f.email,
         count(*) OVER () AS total_filas
  FROM filtrados f
  -- El desempate por id NO es adorno: sin un orden total, dos páginas con nombres
  -- repetidos se pisan y una fila se repite o se pierde.
  ORDER BY public.sozu_unaccent(lower(f.nombre_cliente)), f.id
  -- `p_limite => null` devuelve TODO (`limit null` en Postgres es "sin tope"), que es lo
  -- que usa la ruta heredada `POST {}`. `greatest(null, 1)` es 1, no null: por eso el CASE.
  LIMIT  (CASE WHEN p_limite IS NULL
               THEN NULL
               ELSE least(greatest(p_limite, 1), 200) END)
  OFFSET greatest(p_desplazamiento, 0);
$fn$;

COMMENT ON FUNCTION public.admin_clientes_buscar(text, integer, integer, integer, text) IS
  'Padrón de clientes impersonables, buscado sin acentos y paginado. Solo service_role. El nombre en blanco cae a ''Cliente'' (2026-08-19).';

-- CREATE OR REPLACE conserva el ACL, así que los revokes de 20260819120000 siguen en pie.
-- Se re-emiten porque son idempotentes y porque el pg_default_acl de este proyecto concede
-- EXECUTE nominal a anon y authenticated en cada función nueva del esquema public: si algún
-- día alguien hace drop + create, esto y el guard de abajo son la única red.
REVOKE ALL ON FUNCTION public.admin_clientes_buscar(text, integer, integer, integer, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_clientes_buscar(text, integer, integer, integer, text)
  TO service_role;

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

  IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role NO puede ejecutar admin_clientes_buscar: la Edge Function respondería 500.';
  END IF;

  IF position('nullif(btrim(p.nombre_legal)' in pg_get_functiondef(v_oid)) = 0 THEN
    RAISE EXCEPTION 'La definición viva no trae la guarda de nombre en blanco.';
  END IF;
END
$verify$;

COMMIT;

-- ---------------------------------------------------------------------------
-- Rollback
-- ---------------------------------------------------------------------------
-- Re-aplicar la definición de 20260819120000_admin_clientes_busqueda_sin_acentos.sql.
-- Sin riesgo de datos: la función no escribe.
