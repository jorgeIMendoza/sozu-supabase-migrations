-- Categorías de multimedia de proyecto + foto real de amenidad por proyecto
-- ---------------------------------------------------------------------------------
-- Dos cambios independientes, aditivos, no rompen lo existente. Idempotente de verdad
-- (IF NOT EXISTS / ON CONFLICT), safe to re-run.
--
-- Ejes de multimedia (no mezclar): es_imagen (medio, ya existe, NO se toca) vs
-- id_categoria (sección semántica, nuevo). Amenidades: amenidades.url = icono genérico
-- del tipo (compartido, se conserva); la foto real por proyecto va en la puente
-- amenidades_proyectos.url_imagen.

-- ═══ DDL 1: catálogo de categorías + FK en multimedias_proyecto ═══
BEGIN;

CREATE TABLE IF NOT EXISTS public.categorias_multimedia_proyecto (
  id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre text    NOT NULL UNIQUE,
  orden  integer NOT NULL DEFAULT 100,
  activo boolean NOT NULL DEFAULT true,
  fecha_creacion      timestamp without time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fecha_actualizacion timestamp without time zone NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Seed base (solo secciones sin tabla propia; Planos/Videos NO van aquí)
INSERT INTO public.categorias_multimedia_proyecto (nombre, orden)
VALUES
  ('General',         10),
  ('Avances de obra', 20),
  ('Renders',         30),
  ('Fachada',         40),
  ('Interiores',      50),
  ('Amenidades',      60)
ON CONFLICT (nombre) DO NOTHING;

-- FK nullable (no rompe las filas existentes)
ALTER TABLE public.multimedias_proyecto
  ADD COLUMN IF NOT EXISTS id_categoria integer
  REFERENCES public.categorias_multimedia_proyecto(id);

-- Backfill: todo lo existente sin categoría -> 'General'
UPDATE public.multimedias_proyecto mp
SET id_categoria = (SELECT id FROM public.categorias_multimedia_proyecto WHERE nombre='General')
WHERE mp.id_categoria IS NULL;

COMMIT;

-- ═══ DDL 2: foto real de amenidad por proyecto ═══
-- Conserva el icono genérico (amenidades.url). Foto específica del proyecto en la puente
-- (nullable; si NULL, la UI cae al icono genérico).
ALTER TABLE public.amenidades_proyectos
  ADD COLUMN IF NOT EXISTS url_imagen text;
