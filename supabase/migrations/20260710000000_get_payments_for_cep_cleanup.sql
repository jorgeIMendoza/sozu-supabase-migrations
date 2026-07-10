-- get_payments_for_cep_cleanup v1
-- Returns STP / STP-manual payments for CEP consolidation.
-- Includes rows with BOTH url_cep AND url_recibo NULL (flagged as error downstream).
-- Not gated on pago_validaciones (amount validation is a separate concern).
-- Idempotente: safe to re-run.
--
-- Difiere de get_payments_for_pago_validation en:
--   - NO filtra (url_cep IS NOT NULL OR url_recibo IS NOT NULL): incluye ambos-null.
--   - NO excluye pagos ya validados en pago_validaciones (otro concern: validacion de monto).
--   - Agrega filtro por metodo (p_metodos) y devuelve clave_rastreo.
--
-- GRANT solo a service_role: la consume el endpoint /audit/cep/consolidate. A diferencia
-- de get_payments_for_pago_validation (que expone a anon/authenticated), aqui NO se abre a
-- roles publicos porque no la necesita el front.

CREATE OR REPLACE FUNCTION public.get_payments_for_cep_cleanup(
    p_proyecto           TEXT    DEFAULT NULL,
    p_metodos            TEXT[]  DEFAULT ARRAY['STP', 'STP-manual'],
    p_limit              INTEGER DEFAULT 0,
    p_excluir_proyectos  TEXT[]  DEFAULT NULL
)
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
            p.id            AS id_pago,
            mp.nombre       AS nombre_metodo,
            p.monto,
            p.fecha_pago,
            p.url_cep,
            p.url_recibo,
            p.clave_rastreo,
            LOWER(e.nombre) AS proyecto
        FROM public.pagos p
        JOIN public.cuentas_cobranza cc  ON cc.id = p.id_cuenta_cobranza
        JOIN public.propiedades       pr  ON pr.id = cc.id_propiedad
        JOIN public.edificios_modelos em  ON em.id = pr.id_edificio_modelo
        JOIN public.edificios         e   ON e.id  = em.id_edificio
        JOIN public.metodos_pago      mp  ON mp.id = p.id_metodos_pago
        WHERE p.activo = true
          AND mp.nombre = ANY(p_metodos)
          AND (p_proyecto IS NULL OR LOWER(e.nombre) = LOWER(p_proyecto))
          AND (
              p_excluir_proyectos IS NULL
              OR LOWER(e.nombre) != ALL(
                  SELECT LOWER(x) FROM unnest(p_excluir_proyectos) AS x
              )
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

GRANT EXECUTE ON FUNCTION public.get_payments_for_cep_cleanup(TEXT, TEXT[], INTEGER, TEXT[])
    TO service_role;
