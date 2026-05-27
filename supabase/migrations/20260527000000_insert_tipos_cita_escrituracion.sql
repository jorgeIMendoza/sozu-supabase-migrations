-- Tipos de cita requeridos por el Portal Escrituración (/admin/portal-escrituracion/citas).
-- La tabla tipos_cita no tiene unique constraint en nombre — se usa WHERE NOT EXISTS para idempotencia.

INSERT INTO public.tipos_cita (nombre, descripcion, activo)
SELECT 'Firma de escritura', 'Cita notarial para firma de escritura de compraventa', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.tipos_cita WHERE nombre = 'Firma de escritura'
);

INSERT INTO public.tipos_cita (nombre, descripcion, activo)
SELECT 'Entrega de departamento', 'Cita para entrega física del departamento al comprador', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.tipos_cita WHERE nombre = 'Entrega de departamento'
);
