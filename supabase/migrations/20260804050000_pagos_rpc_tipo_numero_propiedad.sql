-- 20260804050000_pagos_rpc_tipo_numero_propiedad.sql
--
-- Las 3 RPC de pagos exponen `tipo_propiedad` (y `numero_propiedad` donde falta).
--
-- Contexto: los Excel de reportes traen columnas Tipo y No. propiedad, y el log de
-- validate imprime `prop=Departamento 501`. Ninguna RPC devuelve esos campos, así
-- que el micro los resuelve con lecturas PostgREST encadenadas
-- (`DbClient.get_property_labels`, ~4 requests por cada 200 pagos), duplicando en
-- Python el COALESCE de rutas que las RPC ya tienen para resolver el proyecto.
-- Este cambio expone dos campos más del `propiedades` que ya joinean.
--
-- No funcional: sin cambio de firma, sin DDL de esquema, sin cambio de datos, solo
-- columnas nuevas en el JSON de salida. Los tres son CREATE OR REPLACE, así que
-- conservan SECURITY DEFINER, search_path y ACL.
--
-- Definiciones base tomadas de la definición viva (dev y prod idénticos):
--   get_payments_for_cep_cleanup      7015f485d80b6a04c515bed927d28c28
--   get_payments_for_pago_validation  04eabfa70c7abcd7b3e23e6b4116b1e9
--   get_pending_payments              b3f7a02b5c745457dc3b4fba5a9a45be
--
-- Idempotente + self-verifying: si la función ya expone tipo_propiedad se reaplica
-- la misma definición; si la definición viva no es la esperada, aborta sin tocar.
--
-- Verificación manual posterior (no se corre aquí para no escanear 22k pagos en CI):
--   SELECT r->>'id_pago', r->>'tipo_propiedad', r->>'numero_propiedad'
--     FROM json_array_elements(
--            (public.get_payments_for_cep_cleanup('bottura', NULL, 5, NULL))->'records') r;

-- 1) Anchor: las definiciones vivas deben ser las que se validaron en dev y prod.
DO $guard$
DECLARE
  r          RECORD;
  v_def      TEXT;
  v_esperado TEXT;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('get_payments_for_cep_cleanup',     '7015f485d80b6a04c515bed927d28c28'),
      ('get_payments_for_pago_validation', '04eabfa70c7abcd7b3e23e6b4116b1e9'),
      ('get_pending_payments',             'b3f7a02b5c745457dc3b4fba5a9a45be')
    ) AS t(fn, md5_esperado)
  LOOP
    v_esperado := r.md5_esperado;

    SELECT pg_get_functiondef(p.oid)
      INTO v_def
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = r.fn;

    IF v_def IS NULL THEN
      RAISE EXCEPTION 'public.%() no existe; no hay nada que reemplazar', r.fn;
    END IF;

    -- Ya aplicada: la definición de abajo es idéntica, se deja pasar.
    IF v_def LIKE '%tipo_propiedad%' THEN
      RAISE NOTICE '% ya expone tipo_propiedad; se reaplica igual', r.fn;
      CONTINUE;
    END IF;

    IF md5(v_def) <> v_esperado THEN
      RAISE EXCEPTION
        'drift en %: md5 vivo % <> esperado %. Rebasar la migración sobre la definición viva antes de aplicar.',
        r.fn, md5(v_def), v_esperado;
    END IF;
  END LOOP;
END
$guard$;

-- 2) consolidate: get_payments_for_cep_cleanup
--    Se agregan los joins de catálogo (tp, ps) y las dos columnas. El COALESCE de
--    4 rutas hacia propiedades ya existía.
CREATE OR REPLACE FUNCTION public.get_payments_for_cep_cleanup(p_proyecto text DEFAULT NULL::text, p_metodos text[] DEFAULT NULL::text[], p_limit integer DEFAULT 0, p_excluir_proyectos text[] DEFAULT NULL::text[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_rows  JSON;
    v_total INT;
BEGIN
    SELECT json_agg(sub), COUNT(*)
    INTO v_rows, v_total
    FROM (
        SELECT
            p.id                  AS id_pago,
            p.id_cuenta_cobranza,
            mp.nombre             AS nombre_metodo,
            p.monto,
            p.fecha_pago,
            p.url_cep,
            p.url_recibo,
            p.clave_rastreo,
            pr.numero_propiedad   AS numero_propiedad,  -- NULL en el caso producto
            -- tipos_propiedad cuando el pago va contra una propiedad;
            -- productos_servicios cuando la oferta trae id_producto.
            COALESCE(tp.nombre, ps.nombre) AS tipo_propiedad,
            LOWER(e.nombre)       AS proyecto     -- NULL solo si ninguna ruta resuelve
        FROM public.pagos p
        JOIN      public.metodos_pago      mp ON mp.id = p.id_metodos_pago
        LEFT JOIN public.cuentas_cobranza  cc ON cc.id = p.id_cuenta_cobranza
        LEFT JOIN public.ofertas           o  ON o.id  = cc.id_oferta
        LEFT JOIN public.cuentas_cobranza  cp ON cp.id = cc.id_cuenta_cobranza_padre
        LEFT JOIN public.ofertas           op ON op.id = cp.id_oferta
        LEFT JOIN public.propiedades       pr ON pr.id = COALESCE(
                                                     cc.id_propiedad,
                                                     o.id_propiedad,
                                                     cp.id_propiedad,
                                                     op.id_propiedad
                                                 )
        LEFT JOIN public.tipos_propiedad     tp ON tp.id = pr.id_tipo_propiedad
        LEFT JOIN public.productos_servicios ps ON ps.id = COALESCE(o.id_producto, op.id_producto)
        LEFT JOIN public.edificios_modelos em ON em.id = pr.id_edificio_modelo
        LEFT JOIN public.edificios         e  ON e.id  = em.id_edificio
        WHERE p.activo = true
          AND (p_metodos IS NULL OR mp.nombre = ANY(p_metodos))
          AND (p_proyecto IS NULL OR LOWER(e.nombre) = LOWER(p_proyecto))
          AND (
              p_excluir_proyectos IS NULL
              OR e.nombre IS NULL
              OR LOWER(e.nombre) != ALL(SELECT LOWER(x) FROM unnest(p_excluir_proyectos) AS x)
          )
        ORDER BY p.fecha_pago DESC
        LIMIT CASE WHEN p_limit = 0 THEN NULL ELSE p_limit END
    ) sub;

    RETURN json_build_object(
        'records', COALESCE(v_rows, '[]'::JSON),
        'total',   COALESCE(v_total, 0)
    );
END;
$function$;

-- 3) validate de monto: get_payments_for_pago_validation
CREATE OR REPLACE FUNCTION public.get_payments_for_pago_validation(p_proyecto text DEFAULT NULL::text, p_limit integer DEFAULT 0, p_excluir_proyectos text[] DEFAULT NULL::text[], p_metodos text[] DEFAULT NULL::text[], p_estado_previo text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_rows  JSON;
    v_total INT;
BEGIN
    SELECT json_agg(sub), COUNT(*)
    INTO v_rows, v_total
    FROM (
        SELECT
            p.id                  AS id_pago,
            p.id_cuenta_cobranza,
            mp.nombre             AS nombre_metodo,
            p.monto,
            p.fecha_pago,
            p.url_cep,
            p.url_recibo,
            pr.numero_propiedad   AS numero_propiedad,  -- NULL en el caso producto
            -- tipos_propiedad cuando el pago va contra una propiedad;
            -- productos_servicios cuando la oferta trae id_producto.
            COALESCE(tp.nombre, ps.nombre) AS tipo_propiedad,
            LOWER(e.nombre)       AS proyecto
        FROM public.pagos p
        JOIN      public.metodos_pago      mp ON mp.id = p.id_metodos_pago
        LEFT JOIN public.cuentas_cobranza  cc ON cc.id = p.id_cuenta_cobranza
        LEFT JOIN public.ofertas           o  ON o.id  = cc.id_oferta
        LEFT JOIN public.cuentas_cobranza  cp ON cp.id = cc.id_cuenta_cobranza_padre
        LEFT JOIN public.ofertas           op ON op.id = cp.id_oferta
        LEFT JOIN public.propiedades       pr ON pr.id = COALESCE(
                                                     cc.id_propiedad,
                                                     o.id_propiedad,
                                                     cp.id_propiedad,
                                                     op.id_propiedad
                                                 )
        LEFT JOIN public.tipos_propiedad     tp ON tp.id = pr.id_tipo_propiedad
        LEFT JOIN public.productos_servicios ps ON ps.id = COALESCE(o.id_producto, op.id_producto)
        LEFT JOIN public.edificios_modelos em ON em.id = pr.id_edificio_modelo
        LEFT JOIN public.edificios         e  ON e.id  = em.id_edificio
        WHERE p.activo = true
          AND (p.url_cep IS NOT NULL OR p.url_recibo IS NOT NULL)
          AND (p_metodos IS NULL OR mp.nombre = ANY(p_metodos))
          AND (
              -- Sin filtro de estado previo: solo los no validados
              (p_estado_previo IS NULL AND NOT EXISTS (
                  SELECT 1 FROM public.pago_validaciones pv
                  WHERE pv.id_pago = p.id AND pv.estado IS NOT NULL
              ))
              -- Con filtro: la última validación debe tener ese estado
              OR (p_estado_previo IS NOT NULL AND EXISTS (
                  SELECT 1 FROM public.pago_validaciones pv
                  WHERE pv.id_pago = p.id
                    AND pv.estado = p_estado_previo
                    AND pv.fecha_creacion = (
                        SELECT MAX(pv2.fecha_creacion)
                        FROM public.pago_validaciones pv2
                        WHERE pv2.id_pago = p.id
                    )
              ))
          )
          AND (p_proyecto IS NULL OR LOWER(e.nombre) = LOWER(p_proyecto))
          AND (
              p_excluir_proyectos IS NULL
              OR e.nombre IS NULL
              OR LOWER(e.nombre) != ALL(SELECT LOWER(x) FROM unnest(p_excluir_proyectos) AS x)
          )
        ORDER BY p.fecha_pago DESC
        LIMIT CASE WHEN p_limit = 0 THEN NULL ELSE p_limit END
    ) sub;

    RETURN json_build_object(
        'records', COALESCE(v_rows, '[]'::JSON),
        'total',   COALESCE(v_total, 0)
    );
END;
$function$;

-- 4) batch: get_pending_payments
--    Ya devolvía num_propiedad; se agrega tipo_propiedad y hay que hilarlo por las
--    CTE (base → con_clave/sin_clave → resultado), manteniendo el mismo orden de
--    columnas en las dos ramas del UNION ALL.
--
--    Aquí NO se joinea productos_servicios: el JOIN a propiedades es INNER, así que
--    un pago contra producto (sin propiedad) ya queda fuera del resultado y la
--    columna nunca podría llenarse por esa vía. Tampoco se toca el COALESCE de 2
--    rutas (cc.id_propiedad, o.id_propiedad) — alinearlo a las 4 rutas es el otro
--    pendiente y cambia qué filas devuelve, no solo qué columnas.
CREATE OR REPLACE FUNCTION public.get_pending_payments(p_proyecto text DEFAULT NULL::text, p_metodo text DEFAULT NULL::text, p_excluir_proyectos text[] DEFAULT NULL::text[], p_excluir_metodos text[] DEFAULT NULL::text[], p_limit integer DEFAULT 0, p_banco text DEFAULT NULL::text, p_cuenta text DEFAULT NULL::text)
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

-- 5) Verificación post-aplicación: las tres exponen tipo_propiedad.
DO $verify$
DECLARE
  v_faltan TEXT;
BEGIN
  SELECT string_agg(p.proname, ', ')
    INTO v_faltan
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('get_payments_for_cep_cleanup',
                       'get_payments_for_pago_validation',
                       'get_pending_payments')
     AND pg_get_functiondef(p.oid) NOT LIKE '%tipo_propiedad%';

  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'estas funciones no quedaron con tipo_propiedad: %', v_faltan;
  END IF;
END
$verify$;
