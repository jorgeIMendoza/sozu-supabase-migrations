-- get_kpi_payment_report v3: + categoria_producto, tipo_propiedad (tipo de unidad).
-- Fecha: 2026-06-24
--
-- El Excel KPI distingue el tipo de unidad de cada pago para priorizar escrituración:
--   propiedad directa  → propiedades → tipos_propiedad.nombre (tipo_propiedad)
--   producto/servicio  → ofertas → productos_servicios → categorias_producto.nombre (categoria_producto)
-- Agrega 3 LEFT JOIN y 2 columnas al CTE base. Firma json sin cambios → CREATE OR REPLACE.
-- Idempotente. Verificado en dev: productos_servicios.id_categoria, categorias_producto.nombre,
-- tipos_propiedad, propiedades.id_tipo_propiedad, ofertas.id_producto existen.

CREATE OR REPLACE FUNCTION public.get_kpi_payment_report(
    p_proyecto        TEXT,
    p_metodos_excluir TEXT[]  DEFAULT NULL,
    p_limit           INTEGER DEFAULT 0
)
RETURNS json
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
WITH base AS (
    SELECT
        pg.id                                                       AS id_pago,
        cc.id                                                       AS id_cuenta_cobranza,
        pg.clave_rastreo,
        mp.nombre                                                   AS metodo_pago,
        prop.numero_propiedad                                       AS num_propiedad,
        LOWER(ed.nombre)                                            AS proyecto,
        pg.monto,
        pg.fecha_pago,
        pg.url_recibo,
        pg.url_cep,
        pg.descripcion,
        COALESCE(psr.cuenta_beneficiario, cc.clabe_stp)            AS num_cuenta,
        psr.nombre_beneficiario                                     AS nombre_beneficiario,
        psr.institucion_ordenante                                   AS banco_origen,
        catp.nombre                                                 AS categoria_producto,
        tp.nombre                                                   AS tipo_propiedad,
        (
            SELECT STRING_AGG(per.nombre_legal, ' / ' ORDER BY comp.id_persona)
            FROM compradores comp
            JOIN personas per ON per.id = comp.id_persona
            WHERE comp.id_cuenta_cobranza = cc.id
              AND comp.activo = TRUE
        )                                                           AS nombre_titular
    FROM pagos pg
    JOIN metodos_pago             mp    ON mp.id    = pg.id_metodos_pago
    JOIN cuentas_cobranza         cc    ON cc.id    = pg.id_cuenta_cobranza
    LEFT JOIN ofertas             o     ON o.id     = cc.id_oferta
    JOIN propiedades              prop  ON prop.id  = COALESCE(cc.id_propiedad, o.id_propiedad)
    JOIN edificios_modelos        em    ON em.id    = prop.id_edificio_modelo
    JOIN edificios                ed    ON ed.id    = em.id_edificio
    LEFT JOIN pagos_stp_raw       psr   ON psr.claverastreo = pg.clave_rastreo
    LEFT JOIN productos_servicios ps    ON ps.id    = o.id_producto
    LEFT JOIN categorias_producto catp  ON catp.id  = ps.id_categoria
    LEFT JOIN tipos_propiedad     tp    ON tp.id    = prop.id_tipo_propiedad
    WHERE pg.activo = TRUE
      AND LOWER(ed.nombre) = LOWER(p_proyecto)
      AND (
          p_metodos_excluir IS NULL
          OR NOT EXISTS (
              SELECT 1
              FROM unnest(p_metodos_excluir) AS excl
              WHERE LOWER(mp.nombre) = LOWER(TRIM(excl))
          )
      )
),
resultado AS (
    SELECT *
    FROM base
    ORDER BY metodo_pago, nombre_titular, fecha_pago
    LIMIT NULLIF(p_limit, 0)
)
SELECT json_build_object(
    'records', COALESCE((SELECT json_agg(row_to_json(r)) FROM resultado r), '[]'::json),
    'meta',    json_build_object(
        'proyecto', p_proyecto,
        'total',    (SELECT COUNT(*) FROM resultado)
    )
);
$$;

GRANT EXECUTE ON FUNCTION public.get_kpi_payment_report(TEXT, TEXT[], INTEGER) TO service_role;

NOTIFY pgrst, 'reload schema';
