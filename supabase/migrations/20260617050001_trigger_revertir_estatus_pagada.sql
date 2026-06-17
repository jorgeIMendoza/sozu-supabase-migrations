-- Prevención: degradar el estatus al aparecer un acuerdo pendiente nuevo.
--
-- Si se inserta/activa un acuerdo pendiente (pago_completado = false, activo = true)
-- en la CUENTA PRINCIPAL de una propiedad que ya está en 9 (Pagada completamente)
-- o 7 (Escrituración) y existe saldo real > $0.01, regresa la propiedad a 5 (Vendido).
--
-- Coherente con los triggers de promoción y con la edge function
-- check-property-escrituracion-status: solo considera la cuenta principal
-- (ofertas.id_producto IS NULL). Saldo = precio_final - SUM(pagos activos).

CREATE OR REPLACE FUNCTION public.revertir_estatus_si_hay_pendiente()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_id_propiedad BIGINT;
  v_saldo NUMERIC;
BEGIN
  -- Solo nos interesan acuerdos pendientes y activos.
  IF NEW.pago_completado = true OR NEW.activo = false THEN
    RETURN NEW;
  END IF;

  -- Resolver la propiedad SOLO si la cuenta es la principal (no bodega/estacionamiento).
  SELECT o.id_propiedad
  INTO v_id_propiedad
  FROM cuentas_cobranza cc
  JOIN ofertas o ON o.id = cc.id_oferta AND o.id_producto IS NULL
  WHERE cc.id = NEW.id_cuenta_cobranza AND cc.activo = true;

  IF v_id_propiedad IS NULL THEN
    RETURN NEW;
  END IF;

  -- Saldo real de la cuenta principal.
  SELECT cc.precio_final - COALESCE(SUM(pg.monto), 0)
  INTO v_saldo
  FROM cuentas_cobranza cc
  LEFT JOIN pagos pg ON pg.id_cuenta_cobranza = cc.id AND pg.activo = true
  WHERE cc.id = NEW.id_cuenta_cobranza
  GROUP BY cc.precio_final;

  IF v_saldo > 0.01 THEN
    UPDATE propiedades
    SET id_estatus_disponibilidad = 5,
        fecha_actualizacion = NOW()
    WHERE id = v_id_propiedad
      AND id_estatus_disponibilidad IN (7, 9);

    RAISE LOG 'Propiedad % revertida a Vendido (5): acuerdo pendiente con saldo $% en cuenta %',
      v_id_propiedad, v_saldo, NEW.id_cuenta_cobranza;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_revertir_estatus_si_hay_pendiente ON public.acuerdos_pago;
CREATE TRIGGER trg_revertir_estatus_si_hay_pendiente
AFTER INSERT OR UPDATE OF pago_completado, activo, monto ON public.acuerdos_pago
FOR EACH ROW EXECUTE FUNCTION revertir_estatus_si_hay_pendiente();
