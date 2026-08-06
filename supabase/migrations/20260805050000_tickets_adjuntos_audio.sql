-- ============================================================================
-- Fase 2a — Mensajes de voz: permitir adjuntos de tipo 'audio' en tickets.
--
-- La evidencia multimedia de tickets ya vive en public.tickets_adjuntos con un
-- CHECK `tipo IN ('foto','video')` (migración 20260805020000). Aquí se amplía a
-- 'audio' para poder grabar/importar notas de voz a nivel ticket. Reusa el mismo
-- bucket `documentos` y las mismas RLS; no crea tablas ni buckets.
--
-- Idempotente: quita cualquier CHECK sobre la columna `tipo` (cubre variaciones
-- del nombre auto-generado entre ambientes) y lo recrea con los tres valores.
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
  ADD CONSTRAINT tickets_adjuntos_tipo_check CHECK (tipo IN ('foto', 'video', 'audio'));

COMMIT;
