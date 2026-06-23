-- Seed del evento 'documento_legal_subido' (notifica al rol Admin Legal cuando se
-- sube un Contrato firmado completamente o un Convenio modificatorio).
-- Idempotente: solo inserta si el tipo_evento aún no existe.

INSERT INTO public.notificaciones_configuracion
  (tipo_evento, descripcion, canal, roles_destino, activo, requiere_acceso_proyecto,
   asunto_email, plantilla_wa, plantilla_email_detalles, postmark_template_id,
   mapeo_variables_postmark, destinatarios_extra)
SELECT
  'documento_legal_subido',
  'Se dispara al subir un Contrato firmado completamente o un Convenio modificatorio',
  'email',
  '{18}'::int4[],   -- rol Admin Legal
  true,
  false,
  'Nuevo documento legal: {tipo_documento} — Depto {num_depa} de {desarrollo}',
  '',
  'Se subió el documento "{tipo_documento}" en el sistema. Departamento {num_depa} de {desarrollo}.',
  41353048,
  '{}'::jsonb,
  NULL
WHERE NOT EXISTS (
  SELECT 1 FROM public.notificaciones_configuracion
  WHERE tipo_evento = 'documento_legal_subido'
);
