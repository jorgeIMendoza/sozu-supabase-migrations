-- Fix esquema de pago — CC-000497 (Ricardo López Herrera, Bottura 510)
--
-- La sección "Información del contrato" del estado de cuenta de CC-000497 mostraba
-- un esquema incorrecto (12 parcialidades, enganche 10%, mensualidades 20%, entrega 70%)
-- porque la oferta id=564 apuntaba al esquema id=704 (manual_migracion_generico_Bottura),
-- compartido por 55 ofertas y que por lo tanto no puede modificarse.
-- Los acuerdos_pago de la cuenta 497 ya son correctos; el error era solo de visualización
-- (los montos del contrato se calculan como porcentaje × precio_final).
--
-- Solución: crear un esquema dedicado con porcentajes correctos y reapuntar SOLO la oferta 564.
--
-- Nota sobre los porcentajes (precio_final = 2,443,487.17):
--   La restricción chk_esq_suma_100 exige enganche+mensualidades+entrega = 100. Los montos
--   reales son enganche $468,697.43 (19.18%), parcialidades $1,466,092.44 (59.99%),
--   contraentrega $488,697.43 (20%) y apartado $20,000 (0.82%). El apartado es un 4º concepto
--   que el esquema no modela, por lo que se absorbe en el enganche → 20% / 60% / 20% (= 100).
--   Montos mostrados resultantes: enganche $488,697.43, parcialidades $1,466,092.30
--   (mensual $40,724.79), contraentrega $488,697.43.
--
-- Idempotente: hace upsert del esquema por nombre y reaplica el reapuntado y el ajuste.

DO $$
DECLARE
  v_esquema_id bigint;
BEGIN
  -- 1) Upsert del esquema dedicado (clave natural: nombre)
  SELECT id INTO v_esquema_id
  FROM public.esquemas_pago
  WHERE nombre = 'manual_CC497_Ricardo_Lopez_Bottura510';

  IF v_esquema_id IS NULL THEN
    INSERT INTO public.esquemas_pago (
      id_proyecto, nombre, porcentaje_descuento_aumento, porcentaje_enganche,
      porcentaje_mensualidades, numero_mensualidades, porcentaje_entrega,
      activo, es_manual, numero_pagos_enganche, orden
    )
    VALUES (
      2, 'manual_CC497_Ricardo_Lopez_Bottura510', 0.00, 20.00,
      60.00, 36, 20.00,
      true, true, 1, 57
    )
    RETURNING id INTO v_esquema_id;
  ELSE
    UPDATE public.esquemas_pago
    SET id_proyecto                   = 2,
        porcentaje_descuento_aumento  = 0.00,
        porcentaje_enganche           = 20.00,
        porcentaje_mensualidades      = 60.00,
        numero_mensualidades          = 36,
        porcentaje_entrega            = 20.00,
        activo                        = true,
        es_manual                     = true,
        numero_pagos_enganche         = 1,
        orden                         = 57,
        fecha_actualizacion           = now()
    WHERE id = v_esquema_id;
  END IF;

  -- 2) Reapuntar únicamente la oferta 564 (NO tocar el esquema 704 compartido)
  UPDATE public.ofertas
  SET id_esquema_pago_seleccionado = v_esquema_id
  WHERE id = 564;

  -- 3) Corregir la contraentrega del acuerdo de pago (diferencia de $0.13)
  UPDATE public.acuerdos_pago
  SET monto = 488697.43
  WHERE id = 17683;
END $$;
