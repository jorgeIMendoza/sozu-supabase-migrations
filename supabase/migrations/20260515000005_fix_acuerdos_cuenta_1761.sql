-- Fix acuerdos de pago cuenta_cobranza 1761 (oferta 2359 / propiedad 5331)
-- Precio final: 4,626,310.94
-- Estructura correcta:
--   Apartado:        20,000.00   (ya existe, no se toca)
--   Enganche:       257,578.66   (ya existe, no se toca)
--   Mensualidades:  775,000.00   (31 x 25,000 — jun-2026 a dic-2028)
--   Contra-entrega: 3,573,732.28
--   TOTAL:          4,626,310.94
--
-- Guard: solo ejecuta si cuenta_cobranza 1761 existe (parche exclusivo de PRD).

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.cuentas_cobranza WHERE id = 1761) THEN
    RAISE NOTICE 'cuenta_cobranza 1761 no existe en este ambiente — migración 20260515000005 omitida';
    RETURN;
  END IF;

  -- ─── PASO 1: Validar que los acuerdos a borrar no tengan aplicaciones ────────
  -- (ejecutado en tiempo de migración; resultado visible en logs si hay conflicto)
  PERFORM id_acuerdo_pago
  FROM public.aplicaciones_pago
  WHERE id_acuerdo_pago BETWEEN 26613 AND 26625
    AND activo = true
  LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'Existen aplicaciones_pago activas en acuerdos 26613-26625 — abortar migración';
  END IF;

  -- ─── PASO 2: Borrar los 12 acuerdos vacíos (concepto 5, monto=0) y la
  --             contra-entrega incorrecta (id 26625) ───────────────────────────
  DELETE FROM public.acuerdos_pago
  WHERE id BETWEEN 26613 AND 26625
    AND id_cuenta_cobranza = 1761;

  -- ─── PASO 3: Insertar las 31 mensualidades correctas de $25,000 ─────────────
  INSERT INTO public.acuerdos_pago
    (id_cuenta_cobranza, id_concepto, monto, fecha_pago, orden, pago_completado, activo)
  VALUES
    (1761, 5, 25000.00, '2026-06-30',  3, false, true),
    (1761, 5, 25000.00, '2026-07-31',  4, false, true),
    (1761, 5, 25000.00, '2026-08-31',  5, false, true),
    (1761, 5, 25000.00, '2026-09-30',  6, false, true),
    (1761, 5, 25000.00, '2026-10-31',  7, false, true),
    (1761, 5, 25000.00, '2026-11-30',  8, false, true),
    (1761, 5, 25000.00, '2026-12-31',  9, false, true),
    (1761, 5, 25000.00, '2027-01-31', 10, false, true),
    (1761, 5, 25000.00, '2027-02-28', 11, false, true),
    (1761, 5, 25000.00, '2027-03-31', 12, false, true),
    (1761, 5, 25000.00, '2027-04-30', 13, false, true),
    (1761, 5, 25000.00, '2027-05-31', 14, false, true),
    (1761, 5, 25000.00, '2027-06-30', 15, false, true),
    (1761, 5, 25000.00, '2027-07-31', 16, false, true),
    (1761, 5, 25000.00, '2027-08-31', 17, false, true),
    (1761, 5, 25000.00, '2027-09-30', 18, false, true),
    (1761, 5, 25000.00, '2027-10-31', 19, false, true),
    (1761, 5, 25000.00, '2027-11-30', 20, false, true),
    (1761, 5, 25000.00, '2027-12-31', 21, false, true),
    (1761, 5, 25000.00, '2028-01-31', 22, false, true),
    (1761, 5, 25000.00, '2028-02-29', 23, false, true),
    (1761, 5, 25000.00, '2028-03-31', 24, false, true),
    (1761, 5, 25000.00, '2028-04-30', 25, false, true),
    (1761, 5, 25000.00, '2028-05-31', 26, false, true),
    (1761, 5, 25000.00, '2028-06-30', 27, false, true),
    (1761, 5, 25000.00, '2028-07-31', 28, false, true),
    (1761, 5, 25000.00, '2028-08-31', 29, false, true),
    (1761, 5, 25000.00, '2028-09-30', 30, false, true),
    (1761, 5, 25000.00, '2028-10-31', 31, false, true),
    (1761, 5, 25000.00, '2028-11-30', 32, false, true),
    (1761, 5, 25000.00, '2028-12-31', 33, false, true);

  -- ─── PASO 4: Insertar contra-entrega corregida ───────────────────────────────
  -- 4,626,310.94 − 277,578.66 (enganche) − 775,000.00 (mensualidades) = 3,573,732.28
  INSERT INTO public.acuerdos_pago
    (id_cuenta_cobranza, id_concepto, monto, fecha_pago, orden, pago_completado, activo)
  VALUES
    (1761, 3, 3573732.28, NULL, 34, false, true);

  -- ─── PASO 5: Recalcular pago_completado ─────────────────────────────────────
  PERFORM public.recalcular_pago_completado_acuerdos(1761);

  RAISE NOTICE 'Migración 20260515000005 aplicada correctamente para cuenta_cobranza 1761';
END $$;
