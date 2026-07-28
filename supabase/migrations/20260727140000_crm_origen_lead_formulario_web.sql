-- Soporte para leads del formulario web público de sozu.com.
--
-- (1) Columna `origen` en crm_leads_atribucion: registra la FUENTE del lead para poder
--     filtrar por dónde llegó. Valores previstos: 'formulario_web' | 'meta' | 'importacion'
--     | 'manual'. NULL = desconocido/legado (filas creadas antes de este campo).
--
-- (2) Categoría "Desarrollador" (nueva) usada por el mapeo del perfil ("soy") del
--     formulario web. Las otras (Lead Externo, Agente Externo) ya existen.

ALTER TABLE public.crm_leads_atribucion
  ADD COLUMN IF NOT EXISTS origen text;

COMMENT ON COLUMN public.crm_leads_atribucion.origen IS
  'Fuente del lead: formulario_web | meta | importacion | manual. NULL = desconocido/legado.';

INSERT INTO public.crm_categorias (nombre, descripcion, orden, activo)
SELECT 'Desarrollador', 'Perfil "Desarrollador" del formulario web público', 100, true
WHERE NOT EXISTS (
  SELECT 1 FROM public.crm_categorias WHERE lower(btrim(nombre)) = 'desarrollador'
);
