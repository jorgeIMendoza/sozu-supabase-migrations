-- get_pending_payments v10
-- Estructura bucket: {proyecto}/{banco}/{año}/{cuenta}_{YYYYMM}.pdf
-- Idempotente: safe to re-run.
--
-- NOTA: esta migración se aplicó directamente en producción (version 20260606101440,
-- 2026-06-06) sin commitearse al repo, lo que rompía el deploy CI/CD con
-- "Remote migration versions not found in local migrations directory". Se recupera aquí
-- (contenido exacto extraído de supabase_migrations.schema_migrations en prod) para
-- reconciliar el historial local con el remoto.

DROP FUNCTION IF EXISTS get_pending_payments(TEXT, TEXT, TEXT[], TEXT[], INTEGER);
DROP FUNCTION IF EXISTS get_pending_payments(TEXT, TEXT, TEXT[], INTEGER);
DROP FUNCTION IF EXISTS get_pending_payments(TEXT, TEXT, TEXT[], TEXT[], INTEGER, TEXT);

CREATE OR REPLACE FUNCTION get_pending_payments(
    p_proyecto           TEXT    DEFAULT NULL,
    p_metodo             TEXT    DEFAULT NULL,
    p_excluir_proyectos  TEXT[]  DEFAULT NULL,
    p_excluir_metodos    TEXT[]  DEFAULT NULL,
    p_limit              INTEGER DEFAULT 0,
    p_banco              TEXT    DEFAULT NULL
)
RETURNS json
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
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
    SELECT
        SPLIT_PART(o.name, '/', 1)                              AS proyecto,
        SPLIT_PART(o.name, '/', 2)                              AS banco,
        SPLIT_PART(o.name, '/', 3)::int                         AS anio,
        RIGHT(
            SPLIT_PART(
                SPLIT_PART(SPLIT_PART(o.name, '/', 4), '.', 1),
                '_', 2
            ),
            2
        )                                                       AS mes,
        'estados_cuenta/' || o.name                             AS ruta
    FROM storage.objects o
    WHERE o.bucket_id = 'estados_cuenta'
      AND SPLIT_PART(o.name, '/', 4) <> ''
      AND SPLIT_PART(o.name, '/', 3) ~ '^\d{4}$'
      AND (p_proyecto IS NULL OR LOWER(SPLIT_PART(o.name, '/', 1)) = LOWER(p_proyecto))
      AND (p_banco IS NULL OR LOWER(SPLIT_PART(o.name, '/', 2)) = LOWER(p_banco))
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
$$;

GRANT EXECUTE ON FUNCTION get_pending_payments(TEXT, TEXT, TEXT[], TEXT[], INTEGER, TEXT)
    TO service_role;
