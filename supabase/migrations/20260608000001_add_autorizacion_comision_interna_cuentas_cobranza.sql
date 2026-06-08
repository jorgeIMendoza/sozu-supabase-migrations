-- Autorización de dispersión de comisión INTERNA en cuentas_cobranza.
-- Fecha: 2026-06-08
--
-- La sección "Comisiones internas" de la Bandeja de Validaciones (Portal Alta Dirección)
-- persiste la decisión de la dispersión por cuenta:
--   * "Aprobar todos y Guardar decisiones" → estatus 'Autorizado' (sale del listado).
--   * Rechazar ≥1 comisionista                → estatus 'Rechazado' (permanece visible).
--
-- Mismo patrón que las columnas SOZU (20260522000000) y externa (20260525000000).
-- Valores permitidos: 'Autorizado', 'Rechazado', 'En espera' (default).
--
-- Idempotente: ADD COLUMN IF NOT EXISTS + CHECK creado vía bloque DO guardado contra
-- pg_constraint (Postgres no soporta ADD CONSTRAINT IF NOT EXISTS). Verificado: las
-- columnas *_comision_interna no existían en dev; SOZU y externa ya estaban aplicadas.

ALTER TABLE public.cuentas_cobranza
  ADD COLUMN IF NOT EXISTS estatus_autorizacion_comision_interna text NOT NULL DEFAULT 'En espera',
  ADD COLUMN IF NOT EXISTS notas_rechazo_comision_interna        text,
  ADD COLUMN IF NOT EXISTS fecha_autorizacion_comision_interna   timestamptz,
  ADD COLUMN IF NOT EXISTS email_autoriza_comision_interna       text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'cuentas_cobranza_estatus_autorizacion_comision_interna_check'
  ) THEN
    ALTER TABLE public.cuentas_cobranza
      ADD CONSTRAINT cuentas_cobranza_estatus_autorizacion_comision_interna_check
      CHECK (estatus_autorizacion_comision_interna IN ('Autorizado', 'Rechazado', 'En espera'));
  END IF;
END $$;

-- Backfill: cuentas con todas sus comisiones internas ya pagadas se consideran
-- autorizadas (no requieren intervención de Dirección). Idempotente por el filtro
-- estatus = 'En espera'.
UPDATE public.cuentas_cobranza cc
   SET estatus_autorizacion_comision_interna = 'Autorizado',
       fecha_autorizacion_comision_interna   = COALESCE(cc.fecha_pago_comision::timestamptz, cc.fecha_actualizacion)
 WHERE cc.estatus_autorizacion_comision_interna = 'En espera'
   AND NOT EXISTS (
     SELECT 1 FROM public.comisionistas co
      WHERE co.id_cuenta_cobranza = cc.id
        AND co.activo = true
        AND co.pagada = false
   )
   AND EXISTS (
     SELECT 1 FROM public.comisionistas co2
      WHERE co2.id_cuenta_cobranza = cc.id
        AND co2.activo = true
   );
