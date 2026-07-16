-- Cobranza — Sincroniza cuentas_cobranza.precio_final con la suma de acuerdos_pago
-- ---------------------------------------------------------------------------------
-- BUG (verificado prod 2026-07-16): cuando el front actualiza
-- cuentas_cobranza.precio_final (ValidacionContratosPDF.tsx:838 y
-- EditCuentaCobranzaDialog.tsx:2382), el trigger ajustar_ultimo_acuerdo_pago NO
-- dispara porque vive en acuerdos_pago, no en cuentas_cobranza. Los acuerdos quedan
-- desincronizados y el front muestra "Discrepancia detectada" indefinidamente.
-- Magnitud prod: 318 de 1348 cuentas activas con precio_final != suma acuerdos.
--
-- Bug secundario: la función viva suma TODOS los acuerdos activos, pero el front
-- excluye conceptos 7 ("Pago por cancelación") y 9 ("Devolución de pago") por ser
-- movimientos de reversa. Hoy en prod hay 0 acuerdos activos con 7/9 => la exclusión
-- es defensiva (no cambia números hoy), pero alinea la lógica con el front.
--
-- IMPORTANTE (es dinero): estos triggers sincronizan HACIA ADELANTE (cuando
-- precio_final cambie de aquí en más). NO corrigen retroactivamente las 318
-- existentes; solo se ajustan al re-editar precio_final. Casos "manual" (último
-- acuerdo ya pagado), sin acuerdos, y diffs raros (ej. CC-000995 precio_final=$1.00)
-- deben revisarse a mano contra el contrato real.
--
-- Guards de dinero: NO ajusta si el último acuerdo está pago_completado=TRUE ni si
-- el ajuste dejaría el monto en negativo (lanza NOTICE => revisar manual).
-- Anti-recursión: ambos usan pg_trigger_depth() > 1. El UPDATE interno a
-- acuerdos_pago desde Fix 2 dispara ajustar_ultimo_acuerdo_pago a depth 2, que sale
-- por su propio guard => sin loop.
--
-- Idempotente: CREATE OR REPLACE FUNCTION + DROP TRIGGER IF EXISTS + CREATE TRIGGER
-- => seguro re-aplicar por CI.

-- =================================================================================
-- Fix 1 — Corregir función existente (excluir cancelaciones 7/9 + guard negativo)
--          Los triggers actuales sobre acuerdos_pago la siguen usando (no cambian).
-- =================================================================================
CREATE OR REPLACE FUNCTION public.ajustar_ultimo_acuerdo_pago()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_suma_acuerdos NUMERIC;
    v_precio_final  NUMERIC;
    v_diferencia    NUMERIC;
    v_id_ultimo_acuerdo INTEGER;
    v_monto_ultimo  NUMERIC;
    v_orden_ultimo  INTEGER;
    v_pago_completado BOOLEAN;
BEGIN
    IF pg_trigger_depth() > 1 THEN RETURN NEW; END IF;
    IF NEW.activo = FALSE THEN RETURN NEW; END IF;

    SELECT precio_final INTO v_precio_final
    FROM cuentas_cobranza
    WHERE id = NEW.id_cuenta_cobranza AND activo = TRUE;

    IF v_precio_final IS NULL OR v_precio_final <= 0 THEN RETURN NEW; END IF;

    -- Excluir conceptos de cancelación/devolución (7, 9) — igual que el frontend
    SELECT COALESCE(SUM(monto), 0) INTO v_suma_acuerdos
    FROM acuerdos_pago
    WHERE id_cuenta_cobranza = NEW.id_cuenta_cobranza
      AND activo = TRUE
      AND id_concepto NOT IN (7, 9);

    v_diferencia := v_precio_final - v_suma_acuerdos;

    IF ABS(v_diferencia) <= 0.01 THEN RETURN NEW; END IF;

    SELECT id, monto, orden, pago_completado
    INTO v_id_ultimo_acuerdo, v_monto_ultimo, v_orden_ultimo, v_pago_completado
    FROM acuerdos_pago
    WHERE id_cuenta_cobranza = NEW.id_cuenta_cobranza
      AND activo = TRUE
      AND id_concepto NOT IN (7, 9)
    ORDER BY orden DESC
    LIMIT 1;

    IF v_id_ultimo_acuerdo IS NULL OR v_pago_completado = TRUE THEN RETURN NEW; END IF;

    -- Guard de dinero: no dejar el acuerdo en negativo
    IF (v_monto_ultimo + v_diferencia) < 0 THEN
        RAISE NOTICE 'Cuenta %: ajuste omitido, el ultimo acuerdo quedaria negativo (% + %). Revisar manual.',
            NEW.id_cuenta_cobranza, v_monto_ultimo, v_diferencia;
        RETURN NEW;
    END IF;

    UPDATE acuerdos_pago
    SET monto = v_monto_ultimo + v_diferencia,
        fecha_actualizacion = CURRENT_TIMESTAMP
    WHERE id = v_id_ultimo_acuerdo;

    RETURN NEW;
END;
$function$;

-- =================================================================================
-- Fix 2 — Nuevo trigger en cuentas_cobranza cuando cambia precio_final
-- =================================================================================
CREATE OR REPLACE FUNCTION public.ajustar_acuerdos_por_precio_final()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_suma_acuerdos NUMERIC;
    v_diferencia    NUMERIC;
    v_id_ultimo_acuerdo INTEGER;
    v_monto_ultimo  NUMERIC;
    v_pago_completado BOOLEAN;
BEGIN
    -- Defensa anti-recursión cruzada: si venimos de un UPDATE anidado (depth>1), salir.
    -- El UPDATE interno a acuerdos_pago dispara ajustar_ultimo_acuerdo_pago; ese guard + este evitan loop.
    IF pg_trigger_depth() > 1 THEN RETURN NEW; END IF;

    -- Solo proceder si precio_final realmente cambió
    IF NEW.precio_final = OLD.precio_final THEN RETURN NEW; END IF;
    IF NEW.precio_final IS NULL OR NEW.precio_final <= 0 THEN RETURN NEW; END IF;

    -- Suma de acuerdos activos, excluyendo cancelaciones/devoluciones (7, 9)
    SELECT COALESCE(SUM(monto), 0) INTO v_suma_acuerdos
    FROM acuerdos_pago
    WHERE id_cuenta_cobranza = NEW.id
      AND activo = TRUE
      AND id_concepto NOT IN (7, 9);

    v_diferencia := NEW.precio_final - v_suma_acuerdos;

    IF ABS(v_diferencia) <= 0.01 THEN RETURN NEW; END IF;

    -- Último acuerdo no completado (excluir cancelaciones)
    SELECT id, monto, pago_completado
    INTO v_id_ultimo_acuerdo, v_monto_ultimo, v_pago_completado
    FROM acuerdos_pago
    WHERE id_cuenta_cobranza = NEW.id
      AND activo = TRUE
      AND id_concepto NOT IN (7, 9)
    ORDER BY orden DESC
    LIMIT 1;

    IF v_id_ultimo_acuerdo IS NULL OR v_pago_completado = TRUE THEN
        RAISE NOTICE 'No hay acuerdo ajustable en cuenta % (ultimo pagado o inexistente). Revisar manual.', NEW.id;
        RETURN NEW;
    END IF;

    -- Guard de dinero: no dejar el acuerdo en negativo
    IF (v_monto_ultimo + v_diferencia) < 0 THEN
        RAISE NOTICE 'Cuenta %: ajuste omitido, el ultimo acuerdo quedaria negativo (% + %). Revisar manual.',
            NEW.id, v_monto_ultimo, v_diferencia;
        RETURN NEW;
    END IF;

    UPDATE acuerdos_pago
    SET monto = v_monto_ultimo + v_diferencia,
        fecha_actualizacion = CURRENT_TIMESTAMP
    WHERE id = v_id_ultimo_acuerdo;

    RAISE NOTICE 'Cuenta %. precio_final % -> %. Acuerdo % ajustado: % -> %',
        NEW.id, OLD.precio_final, NEW.precio_final,
        v_id_ultimo_acuerdo, v_monto_ultimo, v_monto_ultimo + v_diferencia;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trigger_ajustar_acuerdos_precio_final ON cuentas_cobranza;

CREATE TRIGGER trigger_ajustar_acuerdos_precio_final
    AFTER UPDATE OF precio_final ON cuentas_cobranza
    FOR EACH ROW
    EXECUTE FUNCTION ajustar_acuerdos_por_precio_final();
