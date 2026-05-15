-- ============================================================
-- User Roles — DML puntual: luis.munoz@investimento.mx (multi-rol)
-- Generado 2026-05-15
-- Requiere: 20260515000000_user_roles_backfill aplicado
-- ============================================================

-- Rol 3 (Agente Inmobiliario) como principal
INSERT INTO public.user_roles (email, rol_id, activo, es_principal, creado_por)
VALUES ('luis.munoz@investimento.mx', 3, true, true, 'system-fix-luis')
ON CONFLICT (email, rol_id) DO UPDATE
  SET activo       = true,
      es_principal = true;

-- Rol 23 (Cliente) como secundario
INSERT INTO public.user_roles (email, rol_id, activo, es_principal, creado_por)
VALUES ('luis.munoz@investimento.mx', 23, true, false, 'system-fix-luis')
ON CONFLICT (email, rol_id) DO UPDATE
  SET activo = true;
