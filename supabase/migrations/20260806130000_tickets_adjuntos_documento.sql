-- ============================================================================
-- #1014 — Subir documentos a tickets: permitir adjuntos de tipo 'documento'
-- (PDF, Word, Excel, PowerPoint, etc.) además de foto/video/audio.
--
-- La tabla public.tickets_adjuntos ya guarda evidencia con un CHECK
-- `tipo IN ('foto','video','audio')` (migraciones 20260805020000 + 20260805050000).
-- Aquí se amplía a 'documento'. Reusa el mismo bucket `documentos` y las mismas
-- RLS; no crea tablas ni buckets.
--
-- Idempotente: quita cualquier CHECK sobre la columna `tipo` (cubre variaciones
-- del nombre auto-generado entre ambientes) y lo recrea con los cuatro valores.
-- ============================================================================

BEGIN;

DO $$
DECLARE c text;
BEGIN
  FOR c IN
    SELECT con.conname
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace ns ON ns.oid = rel.relnamespace
    WHERE ns.nspname = 'public'
      AND rel.relname = 'tickets_adjuntos'
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%tipo%'
  LOOP
    EXECUTE format('ALTER TABLE public.tickets_adjuntos DROP CONSTRAINT %I', c);
  END LOOP;
END $$;

ALTER TABLE public.tickets_adjuntos
  ADD CONSTRAINT tickets_adjuntos_tipo_check CHECK (tipo IN ('foto', 'video', 'audio', 'documento'));

COMMIT;
