-- Validación de pagos por monto — RPC v3 (filtros method/status) + CHECK 6 estados
-- Fecha: 2026-07-20
--
-- Adopta en el historial de migraciones cambios que ya están vivos en prod (aplicados
-- ad-hoc, fuera de CI). Idempotente => aplicar a dev lo pone al día y re-aplicar a prod
-- es no-op. Verificado 2026-07-20 contra prod: cuerpo de la RPC idéntico al de abajo,
-- CHECK ya con los 6 valores, y todas las filas de pago_validaciones dentro del set.
--
-- 1) get_payments_for_pago_validation v2 -> v3:
--    + p_metodos (TEXT[]): filtra por método (mp.nombre = ANY).
--    + p_estado_previo (TEXT): NULL = solo pagos no validados (gate original);
--      seteado = pagos cuya última validación (MAX(fecha_creacion)) tiene ese estado
--      (re-proceso de error/monto_ilegible/no_coincide/...).
--    Params nuevos al final => no rompe llamadas posicionales; el micro llama por nombre.
--
-- 2) CHECK pago_validaciones.estado: 6 valores (fuente de verdad). Aditivo sobre los 3
--    originales; filas viejas siguen válidas. La DB rechaza cualquier valor fuera del set.
--
-- save_pago_validation_results NO se toca: solo inserta el estado recibido (no lo
-- restringe contra un set), el CHECK de abajo es la única puerta. (Punto 3 del runbook.)

-- ── 1. RPC v3 ────────────────────────────────────────────────────────────────────
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

GRANT EXECUTE ON FUNCTION public.get_payments_for_pago_validation(TEXT, INTEGER, TEXT[], TEXT[], TEXT)
    TO service_role;

-- ── 2. CHECK 6 estados (fuente de verdad) ─────────────────────────────────────────
ALTER TABLE public.pago_validaciones DROP CONSTRAINT IF EXISTS pago_validaciones_estado_check;
ALTER TABLE public.pago_validaciones ADD CONSTRAINT pago_validaciones_estado_check
    CHECK (estado IN ('coincide', 'no_coincide', 'sin_evidencia', 'monto_ilegible', 'monto_ausente_db', 'error'));
