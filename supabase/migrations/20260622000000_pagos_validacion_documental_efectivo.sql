-- pagos.validacion_documental_efectivo
-- Fecha: 2026-06-22
--
-- Marca pagos en efectivo (sin clave de rastreo) cuyo comprobante fue revisado
-- manualmente y contiene ticket de depósito + estado de cuenta bancario. El motor PLD
-- (buildFlagsPorPago) lo usa para elevar el flag de amarillo a verde.
-- DEFAULT false → todos los pagos existentes quedan sin validar (backfill manual vía UI).
-- Idempotente (ADD COLUMN IF NOT EXISTS). Verificado en dev: no existía.
--
-- ⚠️ El frontend referencia esta columna en rpPagosCuenta → aplicar este DDL ANTES de
-- desplegar el frontend (si no, PostgREST devuelve 400).

ALTER TABLE public.pagos
  ADD COLUMN IF NOT EXISTS validacion_documental_efectivo boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.pagos.validacion_documental_efectivo IS
'Indica que un pago en efectivo sin clave de rastreo fue revisado manualmente y su comprobante contiene ticket de depósito bancario y estado de cuenta bancario.';
