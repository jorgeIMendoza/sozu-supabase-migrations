-- Foto de perfil y frase del agente en usuarios.
-- Fecha: 2026-06-10
--
-- foto_perfil_url: URL pública de la imagen (Storage de Supabase u otro CDN).
-- frase_perfil:    frase/tagline corta que el agente muestra en su perfil.
-- Ambas opcionales (nullable), sin default. Idempotente (ADD COLUMN IF NOT EXISTS).

ALTER TABLE public.usuarios
  ADD COLUMN IF NOT EXISTS foto_perfil_url TEXT,
  ADD COLUMN IF NOT EXISTS frase_perfil    TEXT;
