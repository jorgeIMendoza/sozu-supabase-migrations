-- Seed del evento "contrato_firmado_ambas_partes" en notificaciones_configuracion.
-- Aparece en la pantalla "Configuración de Notificaciones" (encender/apagar + plantilla).
-- Destinatarios fijos en destinatarios_extra (editables por SQL en cualquier momento):
--   venta_externa: oferta creada por agente externo (usuarios.rol_id IN (3,4)) -> incluye al vendedor externo
--   venta_sozu:    venta SOZU directo
-- Idempotente: solo inserta si el tipo_evento aún no existe.

INSERT INTO public.notificaciones_configuracion
  (tipo_evento, descripcion, canal, roles_destino, activo, requiere_acceso_proyecto,
   asunto_email, plantilla_wa, plantilla_email_detalles, postmark_template_id,
   mapeo_variables_postmark, destinatarios_extra)
SELECT
  'contrato_firmado_ambas_partes',
  'Se dispara cuando un contrato firmado por ambas partes se valida (documento tipo 18 -> Validado)',
  'email',
  '{1}'::int4[],
  true,
  false,
  'Contrato firmado — Depto {num_depa} de {desarrollo}',
  '',
  'Contrato firmado por ambas partes documentado en el sistema. Departamento {num_depa} de {desarrollo}.',
  41353048,
  '{}'::jsonb,
  jsonb_build_object(
    'venta_externa', jsonb_build_array(
      'joseramon.escobar@sozu.com',
      'jorge.mendoza@sozu.com',
      'pablo.espinosa@sozu.com',
      'keity.galindo@sozu.com',
      'abel.salazar@sozu.com',
      'rodrigo.terveen@sozu.com'
    ),
    'venta_sozu', jsonb_build_array(
      'jorge.mendoza@sozu.com',
      'joseramon.escobar@sozu.com',
      'abel.salazar@sozu.com',
      'pablo.espinosa@sozu.com',
      'manuel.nava@sozu.com',
      'rodrigo.terveen@sozu.com'
    ),
    'incluir_vendedor_externo', true
  )
WHERE NOT EXISTS (
  SELECT 1 FROM public.notificaciones_configuracion
  WHERE tipo_evento = 'contrato_firmado_ambas_partes'
);
