-- personas.url_sitio_web — sitio web oficial para footer de la oferta digital
-- ---------------------------------------------------------------------------------
-- Agrega la columna para la desarrolladora / dueño vendedor. Se muestra en el
-- footer de la oferta digital. Idempotente: ADD COLUMN IF NOT EXISTS.

ALTER TABLE public.personas
  ADD COLUMN IF NOT EXISTS url_sitio_web text;

COMMENT ON COLUMN public.personas.url_sitio_web IS
  'Sitio web oficial de la persona/empresa (desarrolladora, dueño vendedor). Footer de la oferta digital.';
