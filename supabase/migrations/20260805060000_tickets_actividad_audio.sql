-- ============================================================================
-- Fase 2b — Mensajes de voz en los seguimientos (notas del timeline del ticket).
--
-- Cada entrada de public.tickets_actividad puede llevar UNA nota de voz. El
-- archivo vive en el bucket `documentos` (tickets/<id_ticket>/...); aquí solo se
-- guardan la URL pública y metadatos. Idempotente (ADD COLUMN IF NOT EXISTS).
-- ============================================================================

BEGIN;

ALTER TABLE public.tickets_actividad ADD COLUMN IF NOT EXISTS audio_url text;
ALTER TABLE public.tickets_actividad ADD COLUMN IF NOT EXISTS audio_nombre text;
ALTER TABLE public.tickets_actividad ADD COLUMN IF NOT EXISTS audio_mime text;

COMMIT;
