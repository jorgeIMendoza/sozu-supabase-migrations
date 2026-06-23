-- Convierte el evento 'contrato_firmado_ambas_partes' al modelo unificado de
-- destinatarios (roles + correos_manuales + excluidos + incluir_vendedor_externo),
-- eliminando el split venta_externa/venta_sozu.
--
-- Los destinatarios internos pasan a correos_manuales (unión de ambas listas previas).
-- roles_destino queda vacío (los internos son personas específicas, no un rol completo);
-- se puede agregar roles desde la UI cuando se requiera.
-- Idempotente: solo actúa si el registro aún tiene el formato viejo (clave venta_externa).

UPDATE public.notificaciones_configuracion
SET roles_destino = '{}'::int4[],
    destinatarios_extra = jsonb_build_object(
      'incluir_vendedor_externo', true,
      'correos_manuales', jsonb_build_array(
        jsonb_build_object('nombre', 'Ramón Escobar',  'email', 'joseramon.escobar@sozu.com', 'telefono', ''),
        jsonb_build_object('nombre', 'Jorge Mendoza',  'email', 'jorge.mendoza@sozu.com',     'telefono', ''),
        jsonb_build_object('nombre', 'Pablo Espinosa', 'email', 'pablo.espinosa@sozu.com',    'telefono', ''),
        jsonb_build_object('nombre', 'Keity Galindo',  'email', 'keity.galindo@sozu.com',     'telefono', ''),
        jsonb_build_object('nombre', 'Abel Salazar',   'email', 'abel.salazar@sozu.com',      'telefono', ''),
        jsonb_build_object('nombre', 'Manuel Nava',    'email', 'manuel.nava@sozu.com',       'telefono', ''),
        jsonb_build_object('nombre', 'Rodrigo Terveen','email', 'rodrigo.terveen@sozu.com',   'telefono', '')
      )
    ),
    updated_at = now()
WHERE tipo_evento = 'contrato_firmado_ambas_partes'
  AND destinatarios_extra ? 'venta_externa';
