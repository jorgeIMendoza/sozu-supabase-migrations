-- Portal Condominio Administración: menú + 9 submenús + permisos Super Admin
-- Fecha: 2026-06-04
--
-- Crea el menú "Portal Condominio Administración" (orden 200) con 9 submenús y
-- otorga TODOS los permisos del catálogo (public.permisos) al rol Super Admin
-- (rol_id = 1) en cada submenú. Además registra el catálogo de permisos
-- disponibles por submenú y habilita el menú para el rol 1 en menus_roles.
--
-- Notas de diseño:
--  - menus.id / submenus.id son GENERATED ALWAYS AS IDENTITY → los INSERT NO fijan
--    id (sin OVERRIDING SYSTEM VALUE). submenus_permisos_disponibles.id es serial
--    (nextval) → también se omite.
--  - Idempotencia con guardas WHERE NOT EXISTS: NINGUNA de estas tablas
--    (menus, submenus, submenus_permisos, submenus_permisos_disponibles,
--    menus_roles) tiene PK/UNIQUE, por lo que NO se puede usar ON CONFLICT
--    (fallaría con "no unique or exclusion constraint matching"). Se usa el mismo
--    patrón que 20260529000000_portal_legal_flow_menus.sql.

-- 1) Menú principal
INSERT INTO public.menus (nombre, orden, activo)
SELECT 'Portal Condominio Administración', 200, true
WHERE NOT EXISTS (
  SELECT 1 FROM public.menus WHERE nombre = 'Portal Condominio Administración'
);

-- 2) Submenús (vista_front_end = ruta del front)
WITH m AS (
  SELECT id FROM public.menus WHERE nombre = 'Portal Condominio Administración'
)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo)
SELECT m.id, s.nombre, s.vista, s.orden, true
FROM m, (VALUES
  ('Dashboard',            '/admin/portal-condominio/dashboard',     10),
  ('Departamentos',        '/admin/portal-condominio/departamentos', 20),
  ('Cargos',               '/admin/portal-condominio/cargos',        30),
  ('Pagos y Conciliación', '/admin/portal-condominio/pagos',         40),
  ('Cobranza',             '/admin/portal-condominio/cobranza',      50),
  ('Tesorería',            '/admin/portal-condominio/tesoreria',     60),
  ('Amenidades',           '/admin/portal-condominio/amenidades',    70),
  ('Auditoría',            '/admin/portal-condominio/auditoria',     80),
  ('Configuración',        '/admin/portal-condominio/configuracion', 90)
) AS s(nombre, vista, orden)
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus sm
  WHERE sm.menu_id = m.id AND sm.vista_front_end = s.vista
);

-- 3) Permisos totales para Super Admin (rol_id = 1) en cada submenú del menú
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT sm.id, p.id, 1, true
FROM public.submenus sm
JOIN public.menus m ON m.id = sm.menu_id
CROSS JOIN public.permisos p
WHERE m.nombre = 'Portal Condominio Administración'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = sm.id AND sp.permiso_id = p.id AND sp.rol_id = 1
  );

-- 4) Catálogo de permisos disponibles por submenú (todos los permisos)
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT sm.id, p.id, true
FROM public.submenus sm
JOIN public.menus m ON m.id = sm.menu_id
CROSS JOIN public.permisos p
WHERE m.nombre = 'Portal Condominio Administración'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles spd
    WHERE spd.submenu_id = sm.id AND spd.permiso_id = p.id
  );

-- 5) Habilitar el menú para el rol Super Admin (rol_id = 1) en menus_roles
INSERT INTO public.menus_roles (menu_id, rol_id, activo)
SELECT m.id, 1, true
FROM public.menus m
WHERE m.nombre = 'Portal Condominio Administración'
  AND NOT EXISTS (
    SELECT 1 FROM public.menus_roles mr
    WHERE mr.menu_id = m.id AND mr.rol_id = 1
  );
