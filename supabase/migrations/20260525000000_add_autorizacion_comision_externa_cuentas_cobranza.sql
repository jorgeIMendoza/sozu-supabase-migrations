-- Columnas paralelas para autorización de pago a comisionistas externos
-- La autorización del pago a externos es una decisión independiente de la
-- autorización de comisión SOZU; ambas se toman en la Bandeja de Validaciones
-- del Portal Alta Dirección (sección "Pagos a externos").

ALTER TABLE public.cuentas_cobranza
  ADD COLUMN estatus_autorizacion_comision_externa text NOT NULL DEFAULT 'En espera',
  ADD COLUMN notas_rechazo_comision_externa        text,
  ADD COLUMN fecha_autorizacion_comision_externa   timestamptz,
  ADD COLUMN email_autoriza_comision_externa       text;

ALTER TABLE public.cuentas_cobranza
  ADD CONSTRAINT cuentas_cobranza_estatus_autorizacion_comision_externa_check
  CHECK (estatus_autorizacion_comision_externa IN ('Autorizado', 'Rechazado', 'En espera'));
