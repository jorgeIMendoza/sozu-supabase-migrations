-- Columnas de autorización de comisión SOZU en cuentas_cobranza
-- Registra la decisión tomada en la Bandeja de Validaciones del Portal Alta Dirección.

ALTER TABLE public.cuentas_cobranza
  ADD COLUMN estatus_autorizacion_comision text NOT NULL DEFAULT 'En espera',
  ADD COLUMN notas_rechazo_comision        text,
  ADD COLUMN fecha_autorizacion_comision   timestamptz,
  ADD COLUMN email_autoriza_comision       text;

ALTER TABLE public.cuentas_cobranza
  ADD CONSTRAINT cuentas_cobranza_estatus_autorizacion_comision_check
  CHECK (estatus_autorizacion_comision IN ('Autorizado', 'Rechazado', 'En espera'));

-- Backfill: cuentas que ya están pagadas se marcan como autorizadas.
UPDATE public.cuentas_cobranza
   SET estatus_autorizacion_comision = 'Autorizado',
       fecha_autorizacion_comision   = COALESCE(fecha_pago_comision::timestamptz, fecha_actualizacion)
 WHERE es_pagada_comision_venta = true
   AND estatus_autorizacion_comision = 'En espera';
