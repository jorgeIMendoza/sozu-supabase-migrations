-- Marketing y presencia digital en la oferta pública.
-- Fecha: 2026-06-10
--
-- Habilita redes sociales, sitio web, slogan (proyectos) y tour 360 + highlights
-- (modelos, a nivel modelo para no duplicar por propiedad) en la oferta pública.
-- Consumido por use-offer-db.ts: url_tour_360 → offer.tour360.embedUrl,
-- highlights → offer.highlights[]. Idempotente (ADD COLUMN IF NOT EXISTS).

-- Proyectos: marketing y presencia digital
ALTER TABLE public.proyectos
  ADD COLUMN IF NOT EXISTS url_sitio_web    TEXT,
  ADD COLUMN IF NOT EXISTS instagram_handle TEXT,
  ADD COLUMN IF NOT EXISTS facebook_handle  TEXT,
  ADD COLUMN IF NOT EXISTS youtube_handle   TEXT,
  ADD COLUMN IF NOT EXISTS slogan           TEXT;

-- Modelos: tour 360 + highlights (a nivel modelo, no por propiedad)
ALTER TABLE public.modelos
  ADD COLUMN IF NOT EXISTS url_tour_360 TEXT,
  ADD COLUMN IF NOT EXISTS highlights   JSONB DEFAULT '[]';
