-- Storage: bucket "avatar" (público) + políticas RLS para fotos de perfil de agentes.
-- Fecha: 2026-06-11
--
-- Complementa 20260610000005 (usuarios.foto_perfil_url / frase_perfil — ya migrada,
-- por eso NO se repite aquí). La foto se sube al bucket público `avatar` bajo la
-- carpeta avatars/; el front guarda la URL pública en usuarios.foto_perfil_url.
-- Usado en /admin/agent/perfil (agente edita lo suyo) y /admin/agentes (admin carga
-- foto de cualquier usuario).
--
-- Idempotente: bucket con ON CONFLICT (id) DO UPDATE (storage.buckets tiene PK en id;
-- en dev el bucket ya existe creado a mano — el UPDATE homologa public/límite/MIME);
-- políticas con DROP POLICY IF EXISTS + CREATE.

-- 1) Bucket público avatar (5 MB, jpeg/png/webp)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'avatar',
  'avatar',
  true,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
SET public             = EXCLUDED.public,
    file_size_limit    = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 2) Políticas RLS sobre storage.objects para el bucket avatar

-- Cualquier usuario autenticado puede subir su propio avatar (carpeta avatars/)
DROP POLICY IF EXISTS "Agente sube su avatar" ON storage.objects;
CREATE POLICY "Agente sube su avatar"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'avatar'
  AND (storage.foldername(name))[1] = 'avatars'
);

-- Super admin puede subir avatar de cualquier agente
DROP POLICY IF EXISTS "Admin sube avatares" ON storage.objects;
CREATE POLICY "Admin sube avatares"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'avatar'
  AND EXISTS (
    SELECT 1 FROM public.usuarios
    WHERE email = auth.jwt()->>'email'
      AND rol_id = 1
      AND activo = true
  )
);

-- Lectura pública (el bucket ya es público; refuerzo para acceso via API)
DROP POLICY IF EXISTS "Avatar público" ON storage.objects;
CREATE POLICY "Avatar público"
ON storage.objects FOR SELECT
USING (bucket_id = 'avatar');

-- Agente puede actualizar/borrar su propio avatar
DROP POLICY IF EXISTS "Agente actualiza su avatar" ON storage.objects;
CREATE POLICY "Agente actualiza su avatar"
ON storage.objects FOR UPDATE
TO authenticated
USING (
  bucket_id = 'avatar'
  AND (storage.foldername(name))[1] = 'avatars'
);

DROP POLICY IF EXISTS "Agente borra su avatar" ON storage.objects;
CREATE POLICY "Agente borra su avatar"
ON storage.objects FOR DELETE
TO authenticated
USING (
  bucket_id = 'avatar'
  AND (storage.foldername(name))[1] = 'avatars'
);
