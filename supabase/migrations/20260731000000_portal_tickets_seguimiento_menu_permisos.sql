-- Portal Tickets de Seguimiento — menú, 9 submenús y permisos de Super Administrador (rol 1)
-- Fecha: 2026-07-31
--
-- Da de alta el menú `Portal Tickets de Seguimiento` con sus 9 submenús y otorga todos los
-- permisos (leer/crear/actualizar/eliminar/exportar) al rol Super Administrador (rol_id=1),
-- para que el portal aparezca en el sidebar y el sistema de roles/permisos controle su
-- visibilidad (el front lee menus/submenus y filtra con useAllowedMenus; sin fila en
-- submenus_permisos leer=1 un submenú no es visible). Cada vista_front_end ya existe en App.tsx.
--
-- menus/submenus tienen id GENERATED ALWAYS → nunca se fija id. Idempotente: NOT EXISTS en cada
-- INSERT (menus/submenus/*_permisos*/menus_roles NO tienen UNIQUE apto para ON CONFLICT).
-- No elimina nada. Corre en Preview y Producción. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

-- 1) Menú padre (idempotente)
INSERT INTO public.menus (nombre, orden, activo)
SELECT 'Portal Tickets de Seguimiento', 260, true
WHERE NOT EXISTS (
  SELECT 1 FROM public.menus WHERE nombre = 'Portal Tickets de Seguimiento'
);

UPDATE public.menus SET activo = true
WHERE nombre = 'Portal Tickets de Seguimiento' AND activo IS DISTINCT FROM true;

-- 2) Submenús
WITH m AS (
  SELECT id FROM public.menus WHERE nombre = 'Portal Tickets de Seguimiento'
), v(nombre, ruta, orden) AS (
  VALUES
    ('Todos los tickets', '/admin/portal-tickets/todos',                      10),
    ('Mis tickets',       '/admin/portal-tickets/mis-tickets',                20),
    ('Sin asignar',       '/admin/portal-tickets/sin-asignar',                30),
    ('Pipeline',          '/admin/portal-tickets/pipeline',                   40),
    ('Pipelines',         '/admin/portal-tickets/configuracion/pipelines',    50),
    ('Etapas',            '/admin/portal-tickets/configuracion/etapas',       60),
    ('Categorías',        '/admin/portal-tickets/configuracion/categorias',   70),
    ('Prioridades',       '/admin/portal-tickets/configuracion/prioridades',  80),
    ('Equipo',            '/admin/portal-tickets/configuracion/equipo',       90)
)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT m.id, v.nombre, v.ruta, v.orden, true, false
FROM m CROSS JOIN v
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus s WHERE s.vista_front_end = v.ruta
);

-- 3) Permisos DISPONIBLES por submenú (leer, crear, actualizar, eliminar, exportar)
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
JOIN public.menus mm ON mm.id = s.menu_id
CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
WHERE mm.nombre = 'Portal Tickets de Seguimiento'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- 4) Asignación de permisos al Super Administrador (rol_id = 1)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, 1, true
FROM public.submenus s
JOIN public.menus mm ON mm.id = s.menu_id
CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
WHERE mm.nombre = 'Portal Tickets de Seguimiento'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = 1
  );

-- 5) Relación menú ↔ rol (menus_roles) para el sidebar
INSERT INTO public.menus_roles (menu_id, rol_id, activo)
SELECT mm.id, 1, true
FROM public.menus mm
WHERE mm.nombre = 'Portal Tickets de Seguimiento'
  AND NOT EXISTS (
    SELECT 1 FROM public.menus_roles mr WHERE mr.menu_id = mm.id AND mr.rol_id = 1
  );
