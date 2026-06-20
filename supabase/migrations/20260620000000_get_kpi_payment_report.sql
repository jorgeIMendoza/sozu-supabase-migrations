-- RPC get_kpi_payment_report: universo completo de pagos activos por proyecto.
-- Fecha: 2026-06-20
--
-- Alimenta POST /api/v1/audit/kpi-report (análisis de cobertura KPI). Solo lectura.
-- Acceso service_role vía RPC SECURITY DEFINER.
--
-- Diferencias vs get_pending_payments: devuelve TODOS los pagos activos (con y sin
-- comprobante), NO deduplica por clave_rastreo (1 pago = 1 fila), retorna url_recibo/
-- url_cep sin regexp, y acepta p_metodos_excluir. "proyecto" = nombre del edificio
-- (LOWER(ed.nombre)), igual que get_pending_payments.
--
-- Verificado en dev: pagos.descripcion, pagos_stp_raw.claverastreo/cuenta_beneficiario,
-- cuentas_cobranza.clabe_stp existen; la función no existía. Idempotente (CREATE OR REPLACE).

CREATE OR REPLACE FUNCTION public.get_kpi_payment_report(
    p_proyecto        text,
    p_metodos_excluir text[] DEFAULT NULL::text[],
    p_limit           int    DEFAULT 0
)
RETURNS json
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
WITH base AS (
    SELECT
        pg.id                                                       AS id_pago,
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
        (
            SELECT STRING_AGG(per.nombre_legal, ' / ' ORDER BY comp.id_persona)
            FROM compradores comp
            JOIN personas per ON per.id = comp.id_persona
            WHERE comp.id_cuenta_cobranza = cc.id
              AND comp.activo = TRUE
        )                                                           AS nombre_titular
    FROM pagos pg
    JOIN metodos_pago       mp   ON mp.id   = pg.id_metodos_pago
    JOIN cuentas_cobranza   cc   ON cc.id   = pg.id_cuenta_cobranza
    LEFT JOIN ofertas       o    ON o.id    = cc.id_oferta
    JOIN propiedades        prop ON prop.id = COALESCE(cc.id_propiedad, o.id_propiedad)
    JOIN edificios_modelos  em   ON em.id   = prop.id_edificio_modelo
    JOIN edificios          ed   ON ed.id   = em.id_edificio
    LEFT JOIN pagos_stp_raw psr  ON psr.claverastreo = pg.clave_rastreo
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

GRANT EXECUTE ON FUNCTION public.get_kpi_payment_report(text, text[], int) TO service_role;

NOTIFY pgrst, 'reload schema';
