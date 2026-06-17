-- Portal "Operación Comercial e Incentivos" — estructura definitiva.
-- Fecha: 2026-06-17
--
-- Estructura definitiva del portal de comisiones (rutas /admin/portal-estructura-
-- comisiones/*). REEMPLAZA al menú previo "Portal Estructura de Comisiones"
-- (20260616210000, 26 submenús): ambos exponen las mismas rutas, así que el viejo se
-- elimina para no duplicar items en el sidebar.
--
-- Menú raíz "Operación Comercial e Incentivos" (orden 200) con 16 submenús en 5
-- secciones (Configuración, Estructura, Simulación, Resultados, Análisis). Permisos
-- 1,2,3,4,6 disponibles y asignados a roles 1 (Super Administrador) y 2 (Administrador
-- de Proyecto).
--
-- Idempotente por diseño: el bloque 0 borra cualquier alta previa de AMBOS menús
-- (por nombre) y el bloque 1 reinserta limpio. menus.id/submenus.id GENERATED ALWAYS
-- → no se fijan.

BEGIN;

-- 0) Limpieza idempotente de ambos menús (el nuevo y el viejo que reemplaza).
WITH m AS (
  SELECT id FROM public.menus
  WHERE nombre IN ('Operación Comercial e Incentivos', 'Portal Estructura de Comisiones')
),
s AS (
  SELECT id FROM public.submenus WHERE menu_id IN (SELECT id FROM m)
),
del_perm AS (
  DELETE FROM public.submenus_permisos WHERE submenu_id IN (SELECT id FROM s) RETURNING 1
),
del_disp AS (
  DELETE FROM public.submenus_permisos_disponibles WHERE submenu_id IN (SELECT id FROM s) RETURNING 1
),
del_sub AS (
  DELETE FROM public.submenus WHERE id IN (SELECT id FROM s) RETURNING 1
)
DELETE FROM public.menus WHERE id IN (SELECT id FROM m);

-- 1) Alta del menú raíz + 16 submenús + permisos
WITH nuevo_menu AS (
  INSERT INTO public.menus (nombre, orden, activo)
  VALUES ('Operación Comercial e Incentivos', 200, true)
  RETURNING id
),
nuevos_submenus AS (
  INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
  SELECT m.id, v.nombre, v.ruta, v.orden, true, false
  FROM nuevo_menu m
  CROSS JOIN (VALUES
    -- Configuración
    ('Proyectos',             '/admin/portal-estructura-comisiones/projects',          110),
    ('Canales de Venta',      '/admin/portal-estructura-comisiones/channels',          120),
    ('Benchmark',             '/admin/portal-estructura-comisiones/benchmark',         130),
    -- Estructura
    ('Organigrama',           '/admin/portal-estructura-comisiones/org-chart',         210),
    ('Roles y Sueldos',       '/admin/portal-estructura-comisiones/structure',         220),
    ('Comisiones',            '/admin/portal-estructura-comisiones/commissions',       230),
    ('Incentivos Dinámicos',  '/admin/portal-estructura-comisiones/broker-incentives', 240),
    -- Simulación
    ('Escenarios',            '/admin/portal-estructura-comisiones/scenarios',         310),
    ('Distribución',          '/admin/portal-estructura-comisiones/dist-simulator',    320),
    ('Comisión / Unidad',     '/admin/portal-estructura-comisiones/unit-commission',   330),
    ('Flujo Comercial',       '/admin/portal-estructura-comisiones/monthly-flow',      340),
    -- Resultados
    ('Financieros',           '/admin/portal-estructura-comisiones/results',           410),
    ('Costos Comerciales',    '/admin/portal-estructura-comisiones/compensation',      420),
    ('Simulador de Ingresos', '/admin/portal-estructura-comisiones/broker-calc',       430),
    -- Análisis
    ('Comparador',            '/admin/portal-estructura-comisiones/comm-simulator',    510),
    ('Competitividad',        '/admin/portal-estructura-comisiones/competitividad',    520)
  ) AS v(nombre, ruta, orden)
  RETURNING id
),
disp AS (
  INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
  SELECT s.id, p.permiso_id, true
  FROM nuevos_submenus s
  CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
  RETURNING submenu_id
)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, r.rol_id, true
FROM nuevos_submenus s
CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
CROSS JOIN (VALUES (1),(2)) AS r(rol_id);

COMMIT;
