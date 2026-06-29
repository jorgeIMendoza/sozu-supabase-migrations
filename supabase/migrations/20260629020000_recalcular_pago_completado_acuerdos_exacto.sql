-- P02: alinear recalcular_pago_completado_acuerdos a la regla exacta + guardas.
-- Fecha: 2026-06-29
--
-- La fn existía desde 2026-04-16 con tolerancia (- 0.01) y sin excluir 7/9. Se alinea
-- a la regla exacta (SUM no-multa >= monto), excluye conceptos 7/9 y cuentas inactivas,
-- para que el edge recalcular-aplicaciones y llamadas manuales por cuenta queden
-- consistentes con trg_recalc_pago_completado. Firma sin cambios -> CREATE OR REPLACE.
-- Idempotente. Verificado en dev: fn existe; id_concepto y columnas referenciadas existen.

CREATE OR REPLACE FUNCTION public.recalcular_pago_completado_acuerdos(
  p_id_cuenta_cobranza integer DEFAULT NULL::integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  n_actualizados integer := 0;
BEGIN
  WITH totales AS (
    SELECT
      ap.id AS id_acuerdo,
      ap.monto AS monto_requerido,
      COALESCE((
        SELECT SUM(apl.monto)
        FROM public.aplicaciones_pago apl
        WHERE apl.id_acuerdo_pago = ap.id
          AND apl.activo = true
          AND apl.es_multa = false
      ), 0) AS total_aplicado
    FROM public.acuerdos_pago ap
    JOIN public.cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza AND cc.activo = true
    WHERE ap.activo = true
      AND ap.id_concepto NOT IN (7, 9)                                  -- excluir cancelación/devolución
      AND (p_id_cuenta_cobranza IS NULL OR ap.id_cuenta_cobranza = p_id_cuenta_cobranza)
  ),
  cambios AS (
    UPDATE public.acuerdos_pago ap
    SET pago_completado = (t.total_aplicado >= t.monto_requerido)        -- EXACTO
    FROM totales t
    WHERE ap.id = t.id_acuerdo
      AND ap.pago_completado IS DISTINCT FROM (t.total_aplicado >= t.monto_requerido)
    RETURNING 1
  )
  SELECT COUNT(*) INTO n_actualizados FROM cambios;

  RETURN n_actualizados;
END;
$function$;
