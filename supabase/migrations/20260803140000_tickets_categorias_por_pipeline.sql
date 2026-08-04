-- Portal Tickets de Seguimiento — categorías por pipeline.
--
-- Cada categoría puede pertenecer a un pipeline (p.ej. "Atención al Cliente" tiene sus
-- categorías y "Mantenimiento Interno" las suyas). id_pipeline NULL = categoría global
-- (disponible en todos los pipelines). Las categorías sembradas originalmente quedan como
-- globales (NULL) hasta que se reasignen desde la configuración de Pipelines.
--
-- ON DELETE SET NULL: si un pipeline se elimina, sus categorías no se pierden (pasan a globales).
-- Idempotente (ADD COLUMN IF NOT EXISTS). Sin BEGIN/COMMIT. Corre en Preview y Producción.

ALTER TABLE public.tickets_categorias
  ADD COLUMN IF NOT EXISTS id_pipeline INTEGER
    REFERENCES public.tickets_pipelines(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_tickets_categorias_pipeline
  ON public.tickets_categorias (id_pipeline);
