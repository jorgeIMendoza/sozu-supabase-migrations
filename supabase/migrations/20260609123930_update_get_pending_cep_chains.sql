CREATE OR REPLACE FUNCTION get_pending_cep_chains(
    p_limit  int DEFAULT 200,
    p_offset int DEFAULT 0
)
RETURNS json
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
WITH base AS (
    SELECT DISTINCT ON (id_pago)
        id_pago,
        clave_rastreo,
        fecha_pago,
        monto,
        banco_ordenante,
        banco_beneficiario,
        num_cuenta
    FROM cep_audit_log
    WHERE estado != 'valido'
      AND clave_rastreo      IS NOT NULL
      AND fecha_pago         IS NOT NULL
      AND monto              IS NOT NULL
      AND banco_ordenante    IS NOT NULL
      AND banco_beneficiario IS NOT NULL
      AND num_cuenta         IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM cep_audit_log cal2
          WHERE cal2.id_pago = cep_audit_log.id_pago
            AND cal2.estado  = 'valido'
      )
    ORDER BY id_pago, auditado_en DESC
),
paginated AS (
    SELECT * FROM base
    ORDER BY id_pago
    LIMIT p_limit OFFSET p_offset
)
SELECT json_build_object(
    'total', (SELECT COUNT(*) FROM base),
    'data',  COALESCE(
        (
            SELECT json_agg(
                json_build_object(
                    'cadena', fecha_pago             || ',' ||
                              clave_rastreo          || ',' ||
                              banco_ordenante        || ',' ||
                              banco_beneficiario     || ',' ||
                              num_cuenta             || ',' ||
                              TRIM(TO_CHAR(monto, 'FM9999999999.00'))
                ) ORDER BY id_pago
            ) FROM paginated
        ),
        '[]'::json
    )
);
$$;

GRANT EXECUTE ON FUNCTION get_pending_cep_chains(int, int) TO service_role;
