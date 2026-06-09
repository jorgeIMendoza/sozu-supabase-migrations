CREATE OR REPLACE FUNCTION update_payment_cep_from_recibo(p_updates jsonb)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    rec     jsonb;
    updated int := 0;
BEGIN
    FOR rec IN SELECT * FROM jsonb_array_elements(p_updates) LOOP
        UPDATE pagos
        SET url_cep       = rec->>'url_cep',
            clave_rastreo = rec->>'clave_rastreo',
            url_recibo    = NULL
        WHERE id = (rec->>'id_pago')::bigint;
        updated := updated + 1;
    END LOOP;
    RETURN json_build_object('updated', updated);
END;
$$;

GRANT EXECUTE ON FUNCTION update_payment_cep_from_recibo(jsonb) TO service_role;
