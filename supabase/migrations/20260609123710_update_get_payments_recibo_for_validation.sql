CREATE OR REPLACE FUNCTION get_payments_recibo_for_validation(
    p_proyecto          text    DEFAULT NULL,
    p_limit             int     DEFAULT 0,
    p_excluir_proyectos text[]  DEFAULT NULL,
    p_metodos           text[]  DEFAULT NULL
)
RETURNS json
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
SELECT json_build_object(
    'records', COALESCE(
        json_agg(r ORDER BY r.fecha_pago DESC),
        '[]'::json
    )
)
FROM (
    SELECT
        pg.id::text                    AS id_pago,
        mp.nombre                      AS nombre_metodo,
        pg.monto::numeric              AS monto,
        pg.fecha_pago::text,
        pg.url_recibo,
        LOWER(ed.nombre)               AS proyecto
    FROM pagos pg
    JOIN metodos_pago      mp   ON mp.id   = pg.id_metodos_pago
    JOIN cuentas_cobranza  cc   ON cc.id   = pg.id_cuenta_cobranza
    LEFT JOIN ofertas      o    ON o.id    = cc.id_oferta
    JOIN propiedades       prop ON prop.id = COALESCE(cc.id_propiedad, o.id_propiedad)
    JOIN edificios_modelos em   ON em.id   = prop.id_edificio_modelo
    JOIN edificios         ed   ON ed.id   = em.id_edificio
    WHERE pg.activo = TRUE
      AND pg.url_recibo IS NOT NULL
      AND pg.url_recibo <> ''
      AND (p_proyecto IS NULL OR LOWER(ed.nombre) = LOWER(p_proyecto))
      AND (
          p_excluir_proyectos IS NULL
       OR NOT EXISTS (
              SELECT 1
              FROM unnest(p_excluir_proyectos) AS excl
              WHERE LOWER(ed.nombre) = LOWER(TRIM(excl))
          )
      )
      AND (p_metodos IS NULL OR mp.nombre = ANY(p_metodos))
      AND NOT EXISTS (
          SELECT 1 FROM cep_audit_log cal
          WHERE cal.id_pago = pg.id
            AND cal.estado  = 'valido'
      )
    ORDER BY pg.fecha_pago DESC
    LIMIT NULLIF(p_limit, 0)
) r;
$$;

GRANT EXECUTE ON FUNCTION get_payments_recibo_for_validation(text, int, text[], text[])
    TO service_role;
