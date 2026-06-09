-- Fix: save_cep_audit_results insertaba en columnas proyecto/metodo que NO existen
-- en cep_audit_log, por lo que fallaba en runtime (la versión aplicada en prod por
-- 20260609123819 quedó rota). Se quitan ambas columnas del INSERT.
-- CREATE OR REPLACE idempotente: aplica tanto a prod (corrige la rota) como a dev.

CREATE OR REPLACE FUNCTION save_cep_audit_results(p_results jsonb)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    rec      jsonb;
    inserted int := 0;
BEGIN
    FOR rec IN SELECT * FROM jsonb_array_elements(p_results) LOOP
        INSERT INTO cep_audit_log (
            id_pago, url_cep, estado, motivo,
            clave_rastreo, fecha_pago, monto,
            banco_ordenante, banco_beneficiario, num_cuenta
        )
        VALUES (
            (rec->>'id_pago')::bigint,
            rec->>'url_cep',
            rec->>'estado',
            NULLIF(rec->>'motivo', ''),
            NULLIF(rec->>'clave_rastreo', ''),
            NULLIF(rec->>'fecha_pago', ''),
            (NULLIF(rec->>'monto', ''))::numeric,
            NULLIF(rec->>'banco_ordenante', ''),
            NULLIF(rec->>'banco_beneficiario', ''),
            NULLIF(rec->>'num_cuenta', '')
        );
        inserted := inserted + 1;
    END LOOP;
    RETURN json_build_object('inserted', inserted);
END;
$$;

GRANT EXECUTE ON FUNCTION save_cep_audit_results(jsonb) TO service_role;
