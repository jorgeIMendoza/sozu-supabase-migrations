-- Portal Embajadores — menús, submenús y permisos
-- NOTA: Los ids 130 y 131 del ejecutar.md ya estaban ocupados por submenús de
-- Portal Alta Dirección (Red Comercial y Reportes). Se reasignan a 161 y 162,
-- primeros ids disponibles tras el bloque 141-160 de Portal de Administración.

BEGIN;

-- 1. Menú principal
INSERT INTO public.menus (id, nombre, activo, orden)
OVERRIDING SYSTEM VALUE
VALUES (22, 'Portal Embajadores', true, 15)
ON CONFLICT (id) DO UPDATE SET
  nombre = EXCLUDED.nombre,
  activo = true,
  orden  = EXCLUDED.orden;

-- 2. Submenús
INSERT INTO public.submenus (id, menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
OVERRIDING SYSTEM VALUE
VALUES
  (161, 22, 'Gestión de Embajadores', '/admin/embajadores/gestion',       1, true, true),
  (162, 22, 'Portal del Embajador',   '/admin/portal-embajador/inicio',   2, true, true)
ON CONFLICT (id) DO UPDATE SET
  menu_id        = EXCLUDED.menu_id,
  nombre         = EXCLUDED.nombre,
  vista_front_end = EXCLUDED.vista_front_end,
  orden          = EXCLUDED.orden,
  activo         = true,
  solo_usuarioa  = true;

-- 3. Resync de secuencias
SELECT setval(pg_get_serial_sequence('public.menus',    'id'), (SELECT MAX(id) FROM public.menus));
SELECT setval(pg_get_serial_sequence('public.submenus', 'id'), (SELECT MAX(id) FROM public.submenus));

-- 4. Permisos completos para Super Admin (rol_id = 1)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.submenu_id, p.id, 1, true
FROM (VALUES (161), (162)) AS s(submenu_id)
CROSS JOIN public.permisos p
WHERE p.nombre IN ('leer', 'crear', 'actualizar', 'eliminar', 'aprobar', 'exportar')
ON CONFLICT (submenu_id, permiso_id, rol_id) DO UPDATE SET activo = true;

COMMIT;
