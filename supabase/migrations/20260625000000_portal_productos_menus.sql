-- Portal de Productos: menú + 4 submenús + permisos.
-- Fecha: 2026-06-25
--
-- Menú raíz "Portal de Productos" (orden 260) con 4 submenús (Resumen Ejecutivo,
-- Cartera de Productos, Análisis de Cobranza, Histórico de Ventas), permisos
-- disponibles 1,2,3,4,6 y asignación a Super Admin (1) y Administrador de Proyectos (2).
-- Idempotente (WHERE NOT EXISTS). Verificado en dev: menú/submenús no existen;
-- permisos 1-4,6 y roles 1,2 existen.

-- 1) Menú raíz
INSERT INTO public.menus (nombre, orden, activo)
SELECT 'Portal de Productos', 260, true
WHERE NOT EXISTS (
  SELECT 1 FROM public.menus WHERE nombre = 'Portal de Productos'
);

-- 2) Submenús
WITH menu AS (
  SELECT id FROM public.menus WHERE nombre = 'Portal de Productos'
),
vals(nombre, ruta, orden) AS (
  VALUES
    ('Resumen Ejecutivo',   '/admin/portal-productos/resumen',   10),
    ('Cartera de Productos','/admin/portal-productos/cartera',   20),
    ('Análisis de Cobranza','/admin/portal-productos/analisis',  30),
    ('Histórico de Ventas', '/admin/portal-productos/historico', 40)
)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT m.id, v.nombre, v.ruta, v.orden, true, false
FROM menu m
CROSS JOIN vals v
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus s
  WHERE s.menu_id = m.id AND s.vista_front_end = v.ruta
);

-- 3) Permisos disponibles por submenú (leer, crear, actualizar, eliminar, exportar)
WITH subs AS (
  SELECT s.id
  FROM public.submenus s
  JOIN public.menus m ON m.id = s.menu_id
  WHERE m.nombre = 'Portal de Productos'
),
perms(permiso_id) AS (
  VALUES (1),(2),(3),(4),(6)
)
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM subs s
CROSS JOIN perms p
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos_disponibles d
  WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
);

-- 4) Asignación a roles (Super Admin = 1, Administrador de Proyectos = 2)
WITH subs AS (
  SELECT s.id
  FROM public.submenus s
  JOIN public.menus m ON m.id = s.menu_id
  WHERE m.nombre = 'Portal de Productos'
),
perms(permiso_id) AS (
  VALUES (1),(2),(3),(4),(6)
),
roles_target(rol_id) AS (
  VALUES (1),(2)
)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, r.rol_id, true
FROM subs s
CROSS JOIN perms p
CROSS JOIN roles_target r
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos sp
  WHERE sp.submenu_id = s.id
    AND sp.permiso_id = p.permiso_id
    AND sp.rol_id = r.rol_id
);
