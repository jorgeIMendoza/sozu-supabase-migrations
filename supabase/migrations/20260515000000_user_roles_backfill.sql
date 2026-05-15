-- ============================================================
-- User Roles — Backfill desde usuarios
-- Generado 2026-05-15
-- NOTA: DDL, funciones, trigger y RLS ya incluidos en baseline (20260513*)
-- ============================================================

-- Poblar user_roles con los roles actuales de todos los usuarios existentes
INSERT INTO public.user_roles (email, rol_id, activo, es_principal, creado_por)
SELECT lower(btrim(u.email)), u.rol_id, true, true, 'system-backfill'
FROM public.usuarios u
WHERE u.rol_id IS NOT NULL
ON CONFLICT (email, rol_id) DO UPDATE
  SET activo       = true,
      es_principal = EXCLUDED.es_principal;
