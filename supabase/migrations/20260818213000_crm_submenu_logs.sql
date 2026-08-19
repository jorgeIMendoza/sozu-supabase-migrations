-- Nuevo submenú "Logs" del CRM (menu_id 31 = "Portal CRM Sozu", sección Configuración):
-- página de auditoría que lee logs_actividad filtrado a acciones del CRM.
-- Acceso: SOLO Super Administrador (rol_id 1) por ahora (se amplía desde Roles y Permisos).
-- Permisos ofrecidos: leer (1) + exportar (6).
--
-- submenus / submenus_permisos_disponibles usan id IDENTITY -> NUNCA se fija el id; se encadena
-- con RETURNING. Idempotente: si ya existe la vista, no inserta nada (CTEs quedan vacías).
-- Sin BEGIN/COMMIT (supabase db push envuelve cada migración en su propia tx).

WITH nuevo AS (
  INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
  SELECT 31, 'Logs', '/admin/portal-crm/configuracion/logs', 671, true, false
  WHERE NOT EXISTS (
    SELECT 1 FROM public.submenus WHERE vista_front_end = '/admin/portal-crm/configuracion/logs'
  )
  RETURNING id
),
disp AS (
  INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
  SELECT n.id, p.permiso_id, true
  FROM nuevo n
  CROSS JOIN (VALUES (1), (6)) AS p(permiso_id)   -- 1 = leer, 6 = exportar
  RETURNING submenu_id
)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT n.id, p.permiso_id, r.rol_id, true
FROM nuevo n
CROSS JOIN (VALUES (1), (6)) AS p(permiso_id)
CROSS JOIN (VALUES (1)) AS r(rol_id);             -- rol_id 1 = Super Administrador
