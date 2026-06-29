-- P02: pago_completado autoritativo vía trigger sobre aplicaciones_pago.
-- Fecha: 2026-06-29
--
-- Regla exacta: acuerdos_pago.pago_completado = (SUM(aplicaciones no-multa) >= acuerdos_pago.monto).
-- Cada cambio de abono recalcula el/los acuerdo(s) afectado(s). Excluye conceptos
-- 7 (cancelación) y 9 (devolución) y cuentas inactivas (asientos de cierre, flag fijo).
-- Sin recursión: escribe en acuerdos_pago, cuyos triggers no escriben en aplicaciones_pago.
-- Idempotente (CREATE OR REPLACE + DROP TRIGGER IF EXISTS). Verificado en dev: fn/trigger
-- no existían; acuerdos_pago.id_concepto y columnas de aplicaciones_pago existen.

CREATE OR REPLACE FUNCTION public.trg_recalc_pago_completado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_id     bigint;
  v_monto  numeric;
  v_pagado boolean;
BEGIN
  -- Recalcular el acuerdo nuevo y, si la aplicación se movió de acuerdo, también el viejo.
  FOREACH v_id IN ARRAY ARRAY[NEW.id_acuerdo_pago, OLD.id_acuerdo_pago] LOOP
    IF v_id IS NULL THEN CONTINUE; END IF;

    -- Solo acuerdos activos, de cuenta activa, y que NO sean cancelación/devolución (7,9)
    SELECT ap.monto INTO v_monto
    FROM public.acuerdos_pago ap
    JOIN public.cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza AND cc.activo = true
    WHERE ap.id = v_id
      AND ap.activo = true
      AND ap.id_concepto NOT IN (7, 9);
    IF NOT FOUND THEN CONTINUE; END IF;

    -- Comparación EXACTA
    v_pagado := COALESCE((
      SELECT SUM(a.monto)
      FROM public.aplicaciones_pago a
      WHERE a.id_acuerdo_pago = v_id
        AND a.activo   = true
        AND a.es_multa = false
    ), 0) >= v_monto;

    UPDATE public.acuerdos_pago
    SET pago_completado = v_pagado
    WHERE id = v_id
      AND pago_completado IS DISTINCT FROM v_pagado;  -- evita writes/triggers redundantes
  END LOOP;

  RETURN NULL;  -- AFTER trigger
END;
$$;

DROP TRIGGER IF EXISTS trg_aplicaciones_recalc_pago_completado ON public.aplicaciones_pago;

CREATE TRIGGER trg_aplicaciones_recalc_pago_completado
AFTER INSERT OR DELETE OR UPDATE OF monto, activo, es_multa, id_acuerdo_pago
ON public.aplicaciones_pago
FOR EACH ROW
EXECUTE FUNCTION public.trg_recalc_pago_completado();
