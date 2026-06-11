-- Portal Bancos: rol "Banco" + menú + 4 submenús + permisos.
-- Fecha: 2026-06-11
--
-- Activa el Portal Bancos en el control de acceso: crea el rol "Banco", el menú
-- "Portal Bancos" (orden 250) con 4 submenús (Bandeja, Pipeline, Tablero, Equipo)
-- y otorga permisos leer(1)/crear(2)/actualizar(3)/eliminar(4) a Super
-- Administrador (rol 1) y al rol Banco.
--
-- Idempotente con WHERE NOT EXISTS: roles NO tiene UNIQUE en nombre (el ON CONFLICT
-- DO NOTHING del spec nunca conflictuaría y duplicaría al re-correr); menus/submenus/
-- submenus_permisos* no tienen PK/UNIQUE utilizables. IDs identity (roles.id ALWAYS,
-- menus.id, submenus.id) no se fijan. La asignación del rol Banco a un usuario real
-- y el rollback del spec son operaciones manuales — no van en esta migración.

-- 1) Rol "Banco"
INSERT INTO public.roles (nombre, activo)
SELECT 'Banco', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.roles WHERE nombre = 'Banco'
);

-- 2) Menú principal (orden 250)
INSERT INTO public.menus (nombre, orden, activo)
SELECT 'Portal Bancos', 250, true
WHERE NOT EXISTS (
  SELECT 1 FROM public.menus WHERE nombre = 'Portal Bancos'
);

-- 3) Submenús (idempotente por vista_front_end)
WITH m AS (
  SELECT id FROM public.menus WHERE nombre = 'Portal Bancos' LIMIT 1
)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT m.id, v.nombre, v.ruta, v.orden, true, false
FROM m
CROSS JOIN (VALUES
  ('Bandeja',  '/admin/portal-bancos/bandeja',  10),
  ('Pipeline', '/admin/portal-bancos/pipeline', 20),
  ('Tablero',  '/admin/portal-bancos/tablero',  30),
  ('Equipo',   '/admin/portal-bancos/equipo',   40)
) AS v(nombre, ruta, orden)
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus s WHERE s.vista_front_end = v.ruta
);

-- 4) Catálogo de permisos disponibles por submenú: 1,2,3,4
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(2),(3),(4)) AS p(permiso_id)
WHERE s.vista_front_end LIKE '/admin/portal-bancos/%'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- 5) Asignación a Super Administrador y Banco
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, r.id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(2),(3),(4)) AS p(permiso_id)
CROSS JOIN (
  SELECT id FROM public.roles
  WHERE nombre IN ('Super Administrador', 'Banco') AND activo = true
) AS r
WHERE s.vista_front_end LIKE '/admin/portal-bancos/%'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = r.id
  );
