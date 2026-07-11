-- Validación de pagos por monto: filtros method/status + 6 estados
-- ------------------------------------------------------------------
-- 1) get_payments_for_pago_validation v3: + p_metodos, + p_estado_previo
-- 2) CHECK pago_validaciones.estado ampliado a 6 valores (aditivo)
-- 3) save_pago_validation_results: SIN cambio (inserta estado verbatim,
--    el CHECK del punto 2 es la única fuente de verdad).
--
-- Idempotente: safe to re-run.

-- ------------------------------------------------------------------
-- 1) RPC v3
-- ------------------------------------------------------------------
-- OJO: la firma cambia (nuevos tipos de arg) -> CREATE OR REPLACE NO
-- reemplaza, crearía un segundo overload y las llamadas de 3 args
-- quedarían ambiguas. Por eso se DROPEA la firma vieja primero.
DROP FUNCTION IF EXISTS public.get_payments_for_pago_validation(text, integer, text[]);

CREATE OR REPLACE FUNCTION public.get_payments_for_pago_validation(
    p_proyecto           TEXT    DEFAULT NULL,
    p_limit              INTEGER DEFAULT 0,
    p_excluir_proyectos  TEXT[]  DEFAULT NULL,
    p_metodos            TEXT[]  DEFAULT NULL,
    p_estado_previo      TEXT    DEFAULT NULL
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
            LOWER(e.nombre) AS proyecto
        FROM public.pagos p
        JOIN public.cuentas_cobranza cc  ON cc.id = p.id_cuenta_cobranza
        JOIN public.propiedades       pr  ON pr.id = cc.id_propiedad
        JOIN public.edificios_modelos em  ON em.id = pr.id_edificio_modelo
        JOIN public.edificios         e   ON e.id  = em.id_edificio
        JOIN public.metodos_pago      mp  ON mp.id = p.id_metodos_pago
        WHERE p.activo = true
          AND (p.url_cep IS NOT NULL OR p.url_recibo IS NOT NULL)
          AND (p_metodos IS NULL OR mp.nombre = ANY(p_metodos))
          AND (
              -- Sin filtro de estado previo: solo los no validados
              (p_estado_previo IS NULL AND NOT EXISTS (
                  SELECT 1 FROM public.pago_validaciones pv
                  WHERE pv.id_pago = p.id
                    AND pv.estado IS NOT NULL
              ))
              -- Con filtro: la última validación debe tener ese estado
              OR (p_estado_previo IS NOT NULL AND EXISTS (
                  SELECT 1 FROM public.pago_validaciones pv
                  WHERE pv.id_pago = p.id
                    AND pv.estado = p_estado_previo
                    AND pv.fecha_creacion = (
                        SELECT MAX(pv2.fecha_creacion)
                        FROM public.pago_validaciones pv2
                        WHERE pv2.id_pago = p.id
                    )
              ))
          )
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

-- Cierra la función a service_role (único caller: el micro).
-- Postgres re-otorga EXECUTE a PUBLIC por default al crear -> revocar.
REVOKE ALL ON FUNCTION public.get_payments_for_pago_validation(TEXT, INTEGER, TEXT[], TEXT[], TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_payments_for_pago_validation(TEXT, INTEGER, TEXT[], TEXT[], TEXT)
    TO service_role;

-- ------------------------------------------------------------------
-- 2) CHECK constraint: 3 -> 6 valores (aditivo, no migra filas)
-- ------------------------------------------------------------------
ALTER TABLE public.pago_validaciones DROP CONSTRAINT IF EXISTS pago_validaciones_estado_check;
ALTER TABLE public.pago_validaciones ADD CONSTRAINT pago_validaciones_estado_check
    CHECK (estado IN ('coincide', 'no_coincide', 'sin_evidencia', 'monto_ilegible', 'monto_ausente_db', 'error'));
