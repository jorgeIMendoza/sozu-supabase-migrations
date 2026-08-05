-- 20260804060000_get_pending_payments_filtro_periodo.sql
--
-- `get_pending_payments` acepta `p_anio` / `p_mes` para filtrar por periodo.
--
-- Contexto: el endpoint `/payments/batch` ya recibe `year` / `month` en el body, pero
-- la RPC no tiene esos parámetros, así que el micro pide TODOS los pendientes y filtra
-- en Python (`by_period` en `src/payments/base.py`). El resultado es correcto — el
-- `LIMIT` se aplica después del filtro local — pero un batch por periodo baja 3936
-- pendientes globales para quedarse con 16, y el `LIMIT` nunca llega a la base.
--
-- Los filtros van en el WHERE del CTE `base`, antes de la agrupación por
-- `clave_rastreo`, para que el `LIMIT NULLIF(p_limit, 0)` de `resultado` opere ya sobre
-- el periodo pedido (pushdown real).
--
-- `pagos.fecha_pago` es `date`, así que `EXTRACT` no depende del TimeZone de la sesión.
--
-- Semántica: `p_mes` sin `p_anio` filtra ese mes de todos los años. El micro ya rechaza
-- esa combinación con 400, así que no se agrega un CHECK dentro de la función.
--
-- Cambio de firma: se agregan dos parámetros al final con DEFAULT NULL, por lo que
-- `CREATE OR REPLACE` NO reemplaza — crearía una sobrecarga de 9 args conviviendo con
-- la de 7, y toda llamada por nombre con los 7 params originales quedaría ambigua
-- ("function is not unique"). Por eso se hace DROP de la firma vieja + CREATE de la
-- nueva dentro de la misma transacción del `db push`, y se reponen los grants a mano
-- (el DROP se lleva la ACL: authenticated + service_role, sin anon).
--
-- Base: definición viva post-20260804050000 (la que ya expone `tipo_propiedad`).
-- El único cambio respecto a esa definición son los dos parámetros, los dos predicados
-- del WHERE y las dos llaves `anio` / `mes` en `meta`.
--
-- No hay DDL de esquema ni cambio de datos. Sin `p_anio` / `p_mes` el resultado es
-- idéntico al actual.
--
-- Rollback: DROP de la firma de 9 args + CREATE OR REPLACE de la de 7 (definición de
-- 20260804050000) y volver a otorgar EXECUTE a authenticated y service_role.

-- 1) Anchor: la definición viva debe ser la de 20260804050000 y no tener ya el periodo.
DO $guard$
DECLARE
  v_def7 TEXT;
  v_def9 TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid)
    INTO v_def7
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'get_pending_payments'
     AND pg_get_function_identity_arguments(p.oid) =
         'p_proyecto text, p_metodo text, p_excluir_proyectos text[], p_excluir_metodos text[], p_limit integer, p_banco text, p_cuenta text';

  SELECT pg_get_functiondef(p.oid)
    INTO v_def9
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'get_pending_payments'
     AND pg_get_function_identity_arguments(p.oid) =
         'p_proyecto text, p_metodo text, p_excluir_proyectos text[], p_excluir_metodos text[], p_limit integer, p_banco text, p_cuenta text, p_anio integer, p_mes integer';

  -- Ya aplicada: la definición de abajo es la misma, se reaplica igual (idempotente).
  IF v_def9 IS NOT NULL THEN
    RAISE NOTICE 'get_pending_payments ya tiene p_anio/p_mes; se reaplica igual';
    RETURN;
  END IF;

  IF v_def7 IS NULL THEN
    RAISE EXCEPTION 'public.get_pending_payments(7 args) no existe; no hay nada que reemplazar';
  END IF;

  IF v_def7 NOT LIKE '%tipo_propiedad%' THEN
    RAISE EXCEPTION
      'get_pending_payments no expone tipo_propiedad: falta aplicar 20260804050000 antes de esta migración';
  END IF;

  IF v_def7 NOT LIKE '%pagos_dispersos%' OR v_def7 NOT LIKE '%statements_cfg%' THEN
    RAISE EXCEPTION
      'drift en get_pending_payments: la definición viva no tiene la forma esperada (md5 vivo %). Rebasar la migración sobre la definición viva antes de aplicar.',
      md5(v_def7);
  END IF;
END
$guard$;

-- 2) Fuera la firma de 7 args (si sigue viva) para no dejar la sobrecarga ambigua.
DROP FUNCTION IF EXISTS public.get_pending_payments(text, text, text[], text[], integer, text, text);

-- 3) Firma nueva: p_anio / p_mes al final, DEFAULT NULL.
CREATE OR REPLACE FUNCTION public.get_pending_payments(p_proyecto text DEFAULT NULL::text, p_metodo text DEFAULT NULL::text, p_excluir_proyectos text[] DEFAULT NULL::text[], p_excluir_metodos text[] DEFAULT NULL::text[], p_limit integer DEFAULT 0, p_banco text DEFAULT NULL::text, p_cuenta text DEFAULT NULL::text, p_anio integer DEFAULT NULL::integer, p_mes integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
WITH
base AS (
    SELECT
        pg.id,
        pg.id_cuenta_cobranza,
        pg.clave_rastreo,
        pg.monto,
        pg.fecha_pago,
        pg.url_recibo,
        pg.url_cep,
        mp.nombre                                       AS metodo_pago,
        prop.numero_propiedad,
        tp.nombre                                       AS tipo_propiedad,
        LOWER(ed.nombre)                                AS proyecto,
        COALESCE(psr.cuenta_beneficiario, cc.clabe_stp) AS num_cuenta,
        (
            SELECT STRING_AGG(per.nombre_legal, ' / ' ORDER BY comp.id_persona)
            FROM compradores comp
            JOIN personas per ON per.id = comp.id_persona
            WHERE comp.id_cuenta_cobranza = cc.id
              AND comp.activo = TRUE
        )                                               AS nombre_titular
    FROM pagos pg
    JOIN metodos_pago      mp   ON mp.id   = pg.id_metodos_pago
    JOIN cuentas_cobranza  cc   ON cc.id   = pg.id_cuenta_cobranza
    LEFT JOIN ofertas      o    ON o.id    = cc.id_oferta
    JOIN propiedades       prop ON prop.id = COALESCE(cc.id_propiedad, o.id_propiedad)
    LEFT JOIN tipos_propiedad tp ON tp.id  = prop.id_tipo_propiedad
    JOIN edificios_modelos em   ON em.id   = prop.id_edificio_modelo
    JOIN edificios         ed   ON ed.id   = em.id_edificio
    LEFT JOIN pagos_stp_raw psr ON psr.claverastreo = pg.clave_rastreo
    WHERE pg.activo = TRUE
      AND (p_proyecto IS NULL OR LOWER(ed.nombre) = LOWER(p_proyecto))
      -- Periodo: fecha_pago es date, EXTRACT no depende del TimeZone de la sesión.
      AND (p_anio IS NULL OR EXTRACT(YEAR  FROM pg.fecha_pago)::int = p_anio)
      AND (p_mes  IS NULL OR EXTRACT(MONTH FROM pg.fecha_pago)::int = p_mes)
      AND (
          p_excluir_proyectos IS NULL
       OR NOT EXISTS (
              SELECT 1
              FROM unnest(p_excluir_proyectos) AS excl
              WHERE LOWER(ed.nombre) = LOWER(TRIM(excl))
          )
      )
      AND (
          p_metodo IS NULL
       OR (LOWER(p_metodo) = 'efectivo'                AND mp.nombre ILIKE '%efectivo%')
       OR (LOWER(p_metodo) = 'cheque'                  AND mp.nombre ILIKE '%cheque%')
       OR (LOWER(p_metodo) = 'transferencia bancaria'
              AND (mp.nombre ILIKE '%transferencia%' OR mp.nombre ILIKE '%manual%'))
       OR (LOWER(p_metodo) NOT IN ('efectivo','cheque','transferencia bancaria')
              AND mp.nombre ILIKE '%' || p_metodo || '%')
      )
      AND (
          p_excluir_metodos IS NULL
       OR NOT EXISTS (
              SELECT 1
              FROM unnest(p_excluir_metodos) AS excl
              WHERE LOWER(mp.nombre) = LOWER(TRIM(excl))
          )
      )
),
con_clave AS (
    SELECT
        MIN(id)                       AS id_pago,
        clave_rastreo,
        proyecto,
        MIN(id_cuenta_cobranza)       AS id_cuenta_cobranza,
        MAX(nombre_titular)           AS nombre_titular,
        MAX(numero_propiedad)         AS num_propiedad,
        MAX(tipo_propiedad)           AS tipo_propiedad,
        MAX(metodo_pago)              AS metodo_pago,
        MIN(fecha_pago)               AS fecha_pago,
        SUM(monto)                    AS monto,
        MAX(url_recibo)               AS url_recibo_raw,
        MAX(num_cuenta)               AS num_cuenta,
        BOOL_OR(url_cep IS NOT NULL)  AS tiene_url_cep,
        COUNT(*)                      AS pagos_dispersos
    FROM base
    WHERE clave_rastreo IS NOT NULL
    GROUP BY clave_rastreo, proyecto
),
sin_clave AS (
    SELECT
        id                            AS id_pago,
        NULL::text                    AS clave_rastreo,
        proyecto,
        id_cuenta_cobranza,
        nombre_titular,
        numero_propiedad              AS num_propiedad,
        tipo_propiedad,
        metodo_pago,
        fecha_pago,
        monto,
        url_recibo                    AS url_recibo_raw,
        num_cuenta,
        (url_cep IS NOT NULL)         AS tiene_url_cep,
        1::bigint                     AS pagos_dispersos
    FROM base
    WHERE clave_rastreo IS NULL
),
pendientes AS (
    SELECT * FROM con_clave
    UNION ALL
    SELECT * FROM sin_clave
),
resultado AS (
    SELECT
        id_pago,
        clave_rastreo,
        proyecto,
        id_cuenta_cobranza,
        regexp_replace(
            url_recibo_raw,
            '^https?://[^/]+/storage/v1/object/(public|sign|authenticated)/',
            ''
        )                              AS url_recibo,
        fecha_pago,
        monto,
        num_cuenta,
        nombre_titular,
        num_propiedad,
        tipo_propiedad,
        metodo_pago,
        pagos_dispersos
    FROM pendientes
    WHERE NOT tiene_url_cep
      AND url_recibo_raw IS NOT NULL
      AND TRIM(url_recibo_raw) <> ''
    ORDER BY fecha_pago DESC
    LIMIT NULLIF(p_limit, 0)
),
statements_raw AS (
    -- Path: estados_cuenta/{proyecto}/{banco}/{cuenta}/{año}/{archivo}
    -- Positions: 1=proyecto, 2=banco, 3=cuenta, 4=año, 5=archivo
    SELECT
        SPLIT_PART(o.name, '/', 1)                              AS proyecto,
        SPLIT_PART(o.name, '/', 2)                              AS banco,
        SPLIT_PART(o.name, '/', 3)                              AS cuenta,
        SPLIT_PART(o.name, '/', 4)::int                         AS anio,
        RIGHT(
            SPLIT_PART(
                SPLIT_PART(SPLIT_PART(o.name, '/', 5), '.', 1),
                '_', 2
            ),
            2
        )                                                       AS mes,
        'estados_cuenta/' || o.name                             AS ruta
    FROM storage.objects o
    WHERE o.bucket_id = 'estados_cuenta'
      AND SPLIT_PART(o.name, '/', 5) <> ''
      AND SPLIT_PART(o.name, '/', 4) ~ '^\d{4}$'
      AND (p_proyecto IS NULL OR LOWER(SPLIT_PART(o.name, '/', 1)) = LOWER(p_proyecto))
      AND (p_banco    IS NULL OR LOWER(SPLIT_PART(o.name, '/', 2)) = LOWER(p_banco))
      AND (p_cuenta   IS NULL OR LOWER(SPLIT_PART(o.name, '/', 3)) = LOWER(p_cuenta))
      AND (
          p_excluir_proyectos IS NULL
       OR NOT EXISTS (
              SELECT 1
              FROM unnest(p_excluir_proyectos) AS excl
              WHERE LOWER(SPLIT_PART(o.name, '/', 1)) = LOWER(TRIM(excl))
          )
      )
),
statements_por_anio AS (
    SELECT
        proyecto,
        anio,
        json_agg(
            json_build_object('mes', mes, 'ruta', ruta)
            ORDER BY mes DESC
        )                                                       AS archivos
    FROM statements_raw
    WHERE mes ~ '^\d{2}$'
    GROUP BY proyecto, anio
),
statements_cfg AS (
    SELECT
        proyecto,
        SUM(json_array_length(archivos))                        AS total_archivos,
        json_object_agg(anio::text, archivos ORDER BY anio DESC) AS anios
    FROM statements_por_anio
    GROUP BY proyecto
)
SELECT json_build_object(
    'meta', json_build_object(
        'proyecto',           COALESCE(LOWER(p_proyecto), 'todos'),
        'metodo',             COALESCE(LOWER(p_metodo), 'todos'),
        'banco',              COALESCE(LOWER(p_banco), 'todos'),
        'cuenta',             COALESCE(LOWER(p_cuenta), 'todos'),
        'anio',               p_anio,
        'mes',                p_mes,
        'excluir_proyectos',  COALESCE(to_json(p_excluir_proyectos), '[]'::json),
        'excluir_metodos',    COALESCE(to_json(p_excluir_metodos), '[]'::json),
        'total_registros',    (SELECT COUNT(*) FROM resultado),
        'monto_total',        (SELECT COALESCE(SUM(monto), 0) FROM resultado),
        'limite_aplicado',    NULLIF(p_limit, 0),
        'bucket',             'evidencias_efectivo',
        'update_table',       'pagos',
        'update_pk_col',      'id',
        'update_pk_field',    'id_pago',
        'generado_en',        NOW()
    ),
    'data', COALESCE((SELECT json_agg(row_to_json(r)) FROM resultado r), '[]'::json),
    'statements', COALESCE((
        SELECT json_agg(
            json_build_object(
                sc.proyecto, json_build_object(
                    'bucket',         'estados_cuenta',
                    'total_archivos', sc.total_archivos,
                    'anios',          sc.anios
                )
            ) ORDER BY sc.proyecto
        )
        FROM statements_cfg sc
    ), '[]'::json)
);
$function$;

-- 4) Grants: el DROP se llevó la ACL. Se repone la que tenía (authenticated +
--    service_role) y se quita el EXECUTE que toda función nueva de public hereda
--    vía PUBLIC — sin esto, anon podría llamarla.
REVOKE ALL ON FUNCTION public.get_pending_payments(text, text, text[], text[], integer, text, text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_pending_payments(text, text, text[], text[], integer, text, text, integer, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_pending_payments(text, text, text[], text[], integer, text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_pending_payments(text, text, text[], text[], integer, text, text, integer, integer) TO service_role;

-- 5) Verificación post-aplicación: una sola firma, con periodo, sin anon.
DO $verify$
DECLARE
  v_total  INT;
  v_args   TEXT;
  v_def    TEXT;
  v_acl    TEXT;
BEGIN
  SELECT COUNT(*),
         MAX(pg_get_function_identity_arguments(p.oid)),
         MAX(pg_get_functiondef(p.oid)),
         MAX(COALESCE(p.proacl::text, ''))
    INTO v_total, v_args, v_def, v_acl
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'get_pending_payments';

  IF v_total <> 1 THEN
    RAISE EXCEPTION 'quedaron % firmas de get_pending_payments; debe quedar solo la de 9 args', v_total;
  END IF;

  IF v_args <> 'p_proyecto text, p_metodo text, p_excluir_proyectos text[], p_excluir_metodos text[], p_limit integer, p_banco text, p_cuenta text, p_anio integer, p_mes integer' THEN
    RAISE EXCEPTION 'firma inesperada de get_pending_payments: %', v_args;
  END IF;

  IF v_def NOT LIKE '%EXTRACT(YEAR  FROM pg.fecha_pago)%'
     OR v_def NOT LIKE '%EXTRACT(MONTH FROM pg.fecha_pago)%' THEN
    RAISE EXCEPTION 'get_pending_payments no quedó con los filtros de periodo';
  END IF;

  -- PUBLIC aparece en la ACL como una entrada sin grantee: '{=X/...' o ',=X/...'.
  IF v_acl LIKE '%anon=%' OR v_acl LIKE '{=X%' OR v_acl LIKE '%,=X%' THEN
    RAISE EXCEPTION 'get_pending_payments quedó ejecutable por anon/PUBLIC: %', v_acl;
  END IF;

  IF v_acl NOT LIKE '%authenticated=X%' OR v_acl NOT LIKE '%service_role=X%' THEN
    RAISE EXCEPTION 'get_pending_payments perdió grants esperados: %', v_acl;
  END IF;
END
$verify$;
