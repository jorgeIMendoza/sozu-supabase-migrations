CREATE OR REPLACE FUNCTION migrate_invalid_cep_to_recibo(p_ids text[])
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    migrated int := 0;
    skipped  int := 0;
BEGIN
    UPDATE pagos
    SET url_recibo = url_cep,
        url_cep    = NULL
    WHERE id::text = ANY(p_ids)
      AND (url_recibo IS NULL OR url_recibo = '');

    GET DIAGNOSTICS migrated = ROW_COUNT;

    SELECT COUNT(*) INTO skipped
    FROM pagos
    WHERE id::text = ANY(p_ids)
      AND url_recibo IS NOT NULL
      AND url_recibo <> '';

    RETURN json_build_object('migrated', migrated, 'skipped', skipped);
END;
$$;

GRANT EXECUTE ON FUNCTION migrate_invalid_cep_to_recibo(text[]) TO service_role;
