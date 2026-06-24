-- RPC rescue_recibo_to_cep: mover url_recibo → url_cep para pagos no-STP.
-- Fecha: 2026-06-24
--
-- Corrige pagos donde el PDF de CEP (2 páginas) se subió por error a url_recibo en vez
-- de url_cep. Guardia: solo actualiza filas con url_cep IS NULL (nunca sobreescribe un
-- CEP existente). Alimenta POST /api/v1/audit/recibo/rescue. SECURITY DEFINER, grant
-- service_role. Idempotente (CREATE OR REPLACE; el UPDATE es no-op si ya se rescató).
-- Verificado en dev: función no existía; pagos.url_recibo/url_cep/id existen.

CREATE OR REPLACE FUNCTION public.rescue_recibo_to_cep(p_ids TEXT[])
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rescued         INT := 0;
  v_skipped_has_cep INT := 0;
  v_id              TEXT;
  v_rows            INT;
BEGIN
  FOREACH v_id IN ARRAY p_ids LOOP
    UPDATE public.pagos
    SET    url_cep    = url_recibo,
           url_recibo = NULL
    WHERE  id::TEXT       = v_id
      AND  url_cep        IS NULL
      AND  url_recibo     IS NOT NULL;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows > 0 THEN
      v_rescued := v_rescued + 1;
    ELSE
      v_skipped_has_cep := v_skipped_has_cep + 1;
    END IF;
  END LOOP;

  RETURN json_build_object(
    'rescued',         v_rescued,
    'skipped_has_cep', v_skipped_has_cep
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rescue_recibo_to_cep(TEXT[]) TO service_role;

NOTIFY pgrst, 'reload schema';
