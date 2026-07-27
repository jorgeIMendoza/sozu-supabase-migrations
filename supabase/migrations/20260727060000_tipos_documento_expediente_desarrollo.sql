-- Catálogo tipos_documento · Expediente Desarrollo (Portal Notaría)
-- Fecha: 2026-07-27
--
-- Agrega 2 filas al catálogo tipos_documento para "Expediente Desarrollo" del Portal Notaría:
-- documentos a nivel PROYECTO (no por unidad/cuenta). "Pagos de Predial" ya existe
-- (id=14 'Recibo de pago predial'). Patrón replicado de id=30 'Brochure' (padre='p',
-- asignado_a='prop', id_categoria_documento=10 'Documentos de proyecto').
--
-- tipos_documento.id es entero asignado MANUALMENTE (no IDENTITY, sin secuencia); MAX(id)=60
-- al momento del doc → 61/62. UNIQUE(nombre): los nombres nuevos no colisionan. Idempotente:
-- ON CONFLICT DO NOTHING (cubre PK id y UNIQUE nombre). Sin BEGIN/COMMIT (CI/CD envuelve en tx).

INSERT INTO public.tipos_documento (id, nombre, activo, padre, id_categoria_documento, asignado_a)
VALUES
  (61, 'Régimen de condominio',        true, 'p', 10, 'prop'),
  (62, 'Certificado de habitabilidad', true, 'p', 10, 'prop')
ON CONFLICT DO NOTHING;
