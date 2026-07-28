-- Campo `origen` de crm_leads_atribucion (agregado en 20260727140000): fuente del lead.
--
-- (1) DEFAULT 'manual': cualquier inserción que no especifique `origen` queda clasificada
--     como manual (el "resto" del mapeo). Los puntos de creación que sí conocen su fuente
--     la setean explícito: 'formulario_web' (edge lead-formulario-web), 'crm' (alta manual
--     en el panel), 'importacion' (carga masiva), 'meta' (webhook de Meta).
--
-- (2) BACKFILL de las filas que ya existen (origen NULL) según las señales disponibles,
--     para que la columna "Fuente del registro" también tenga sentido en los históricos.

ALTER TABLE public.crm_leads_atribucion
  ALTER COLUMN origen SET DEFAULT 'manual';

-- Orden importante: primero las señales fuertes, al final el resto a 'manual'.
UPDATE public.crm_leads_atribucion
   SET origen = 'meta'
 WHERE origen IS NULL
   AND (meta_leadgen_id IS NOT NULL OR meta_platform IS NOT NULL);

UPDATE public.crm_leads_atribucion
   SET origen = 'importacion'
 WHERE origen IS NULL
   AND origen_agente IS NOT NULL;

UPDATE public.crm_leads_atribucion
   SET origen = 'manual'
 WHERE origen IS NULL;
