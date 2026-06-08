-- Fix acceso cliente Miguel Airland (miguelairland@gmail.com, rol 23).
-- Fecha: 2026-06-08
--
-- ADVERTENCIA: esto es un PARCHE DE DATOS puntual de PRODUCCIÓN, no una evolución de
-- schema. Se versiona como migración por decisión explícita. Diseñado para ser:
--   * Idempotente y auto-deshabilitante: todos los UPDATE están guardados por
--     usuarios.auth_user_id IS NULL (el estado roto). Una vez enlazado el usuario, la
--     migración es no-op en deploys posteriores → NO vuelve a re-hashear el password.
--   * No-op en ambientes donde el usuario no existe (dev) → 0 filas afectadas.
--
-- Causa: "Sincronizar" (create-client-user) usó generateLink('magiclink') → creó la fila en
-- auth.users SIN contraseña. Al confirmar email, post-confirmacion-registro entró a la rama
-- else: confirmó email pero dejó usuarios.auth_user_id = NULL y el auth user sin password →
-- login imposible. Aquí se fija el password y se enlaza el auth_user_id.
--
-- pgcrypto en Supabase Cloud vive en el schema `extensions` (extensions.crypt / gen_salt).

BEGIN;

-- 1. Fijar password Temporal123! + asegurar email confirmado en auth.users.
--    Sólo si el usuario público sigue en estado roto (auth_user_id IS NULL) → evita
--    re-hashear el password en cada deploy una vez aplicado el fix.
UPDATE auth.users au
SET encrypted_password = extensions.crypt('Temporal123!', extensions.gen_salt('bf')),
    email_confirmed_at  = COALESCE(au.email_confirmed_at, now()),
    updated_at          = now()
WHERE au.email ILIKE 'miguelairland@gmail.com'
  AND EXISTS (
    SELECT 1 FROM public.usuarios u
    WHERE u.email ILIKE 'miguelairland@gmail.com' AND u.auth_user_id IS NULL
  );

-- 2. Crear identity provider='email' si falta (GoTrue reciente la requiere para login).
INSERT INTO auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
SELECT au.id::text, au.id,
       jsonb_build_object('sub', au.id::text, 'email', au.email, 'email_verified', true),
       'email', now(), now(), now()
FROM auth.users au
WHERE au.email ILIKE 'miguelairland@gmail.com'
  AND EXISTS (
    SELECT 1 FROM public.usuarios u
    WHERE u.email ILIKE 'miguelairland@gmail.com' AND u.auth_user_id IS NULL
  )
  AND NOT EXISTS (
    SELECT 1 FROM auth.identities i
    WHERE i.user_id = au.id AND i.provider = 'email'
  );

-- 3. Enlazar auth_user_id en usuarios + flags. Este es el UPDATE que "cierra" el fix:
--    deja auth_user_id NOT NULL y por tanto deshabilita los pasos 1-2 en futuros deploys.
UPDATE public.usuarios u
SET auth_user_id          = au.id,
    email_confirmado      = true,
    debe_cambiar_password = true,
    fecha_actualizacion   = now()
FROM auth.users au
WHERE au.email ILIKE 'miguelairland@gmail.com'
  AND u.email  ILIKE 'miguelairland@gmail.com'
  AND u.auth_user_id IS NULL;

COMMIT;
