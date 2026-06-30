-- Submenú "Información Financiera" en el menú Finanzas (id 6).
-- Fecha: 2026-06-30
--
-- Nuevo submenú bajo Finanzas, ruta /admin/informacion-financiera, orden 9.
-- Permisos disponibles 1,2,3,4 (leer/crear/actualizar/eliminar) y asignación a
-- Super Admin (rol 1). Idempotente (WHERE NOT EXISTS; menus/submenus son
-- GENERATED ALWAYS -> id autogenerado, nunca se fija). Verificado en dev: menú
-- Finanzas = id 6; no existe submenú con esa ruta; permisos 1-4 y rol 1 existen.
--
-- NOTA: la vista /admin/informacion-financiera debe existir como <Route> en
-- App.tsx (sozu-admin) para que cargue; sin ella el submenú aparece pero da 404.

-- 1. Submenú
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT 6, 'Información Financiera', '/admin/informacion-financiera', 9, true, false
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus
  WHERE menu_id = 6 AND vista_front_end = '/admin/informacion-financiera'
);

-- 2. Permisos disponibles del submenú (leer, crear, actualizar, eliminar)
WITH sub AS (
  SELECT id FROM public.submenus
  WHERE menu_id = 6 AND vista_front_end = '/admin/informacion-financiera'
),
perms(permiso_id) AS (VALUES (1),(2),(3),(4))
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM sub s
CROSS JOIN perms p
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos_disponibles d
  WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
);

-- 3. Asignación a Super Admin (rol 1)
WITH sub AS (
  SELECT id FROM public.submenus
  WHERE menu_id = 6 AND vista_front_end = '/admin/informacion-financiera'
),
perms(permiso_id) AS (VALUES (1),(2),(3),(4))
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, 1, true
FROM sub s
CROSS JOIN perms p
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos sp
  WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = 1
);
