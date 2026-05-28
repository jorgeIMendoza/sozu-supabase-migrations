-- Menú "Embajadores" (id=22) con submenu "Administración de Embajadores" para Super Admin.
-- solo_usuarioa=true → solo jorge.mendoza@sozu.com lo ve.

-- 1. Insertar menú 22 (forzar ID para que coincida con iconMapByMenuId del frontend)
INSERT INTO public.menus (id, nombre, activo, orden)
OVERRIDING SYSTEM VALUE
VALUES (22, 'Embajadores', true, 22)
ON CONFLICT (id) DO NOTHING;

-- Reajustar secuencia tras insert con ID explícito
SELECT setval(
  pg_get_serial_sequence('public.menus', 'id'),
  (SELECT MAX(id) FROM public.menus)
);

-- 2. Asociar menú 22 al rol Super Admin (rol_id = 1)
INSERT INTO public.menus_roles (rol_id, menu_id, activo)
VALUES (1, 22, true)
ON CONFLICT (rol_id, menu_id) DO NOTHING;

-- 3. Insertar submenu (solo_usuarioa = true → solo usuarioA lo ve)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, solo_usuarioa)
SELECT 22, 'Administración de Embajadores', '/admin/embajadores/gestion', 1, true
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus WHERE vista_front_end = '/admin/embajadores/gestion'
);

-- 4. Permiso de lectura (permiso_id = 1) para Super Admin
INSERT INTO public.submenus_permisos (submenu_id, rol_id, permiso_id, activo)
SELECT s.id, 1, 1, true
FROM public.submenus s
WHERE s.vista_front_end = '/admin/embajadores/gestion'
AND NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos sp
  WHERE sp.submenu_id = s.id AND sp.rol_id = 1
);
