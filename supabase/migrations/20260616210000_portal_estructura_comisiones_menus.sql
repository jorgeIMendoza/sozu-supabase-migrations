-- Portal Estructura de Comisiones: menú + 26 submenús + permisos.
-- Fecha: 2026-06-16
--
-- Crea el menú "Portal Estructura de Comisiones" (orden 300) con 26 submenús
-- (Resumen, Configuración, Estructura de Comisiones, Simulación, Resultados,
-- Análisis, Portales). Permisos disponibles 1,2,3,4 por submenú; asignación de
-- 1(leer)/2(crear)/3(actualizar) a Super Administrador (1) y Administrador de
-- Proyecto (2) — lo que hace visible el portal.
--
-- Idempotente con WHERE NOT EXISTS (las tablas no tienen PK/UNIQUE → sin ON CONFLICT);
-- menus.id/submenus.id GENERATED ALWAYS → no se fijan.
-- Verificado en dev: menú/submenús no existen; permisos 1-4 y roles 1/2 existen.

-- 1) Menú principal (orden 300)
INSERT INTO public.menus (nombre, orden, activo)
SELECT 'Portal Estructura de Comisiones', 300, true
WHERE NOT EXISTS (
  SELECT 1 FROM public.menus WHERE nombre = 'Portal Estructura de Comisiones'
);

-- 2) Submenús (26) — idempotente por vista_front_end
WITH m AS (
  SELECT id FROM public.menus WHERE nombre = 'Portal Estructura de Comisiones' LIMIT 1
)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT m.id, v.nombre, v.ruta, v.orden, true, false
FROM m
CROSS JOIN (VALUES
  ('Resumen Ejecutivo',          '/admin/portal-estructura-comisiones/dashboard',             10),
  ('Dashboard Ejecutivo',        '/admin/portal-estructura-comisiones/executive',             20),
  ('Proyectos',                  '/admin/portal-estructura-comisiones/projects',              30),
  ('Canales de Venta',           '/admin/portal-estructura-comisiones/channels',              40),
  ('Organigrama',                '/admin/portal-estructura-comisiones/org-chart',             50),
  ('Roles y Sueldos',            '/admin/portal-estructura-comisiones/structure',             60),
  ('Distribución de Comisiones', '/admin/portal-estructura-comisiones/commissions',           70),
  ('Políticas de Pago',          '/admin/portal-estructura-comisiones/payment-policies',      80),
  ('Comisión por Unidad',        '/admin/portal-estructura-comisiones/unit-commission',       90),
  ('Incentivos Dinámicos',       '/admin/portal-estructura-comisiones/broker-incentives',    100),
  ('Escenarios',                 '/admin/portal-estructura-comisiones/scenarios',            110),
  ('Comparador de Escenarios',   '/admin/portal-estructura-comisiones/comm-simulator',       120),
  ('Simulador de Distribución',  '/admin/portal-estructura-comisiones/dist-simulator',       130),
  ('Ingresos Mensuales',         '/admin/portal-estructura-comisiones/broker-calc',          140),
  ('Calculadora Broker',         '/admin/portal-estructura-comisiones/broker-calculator',    150),
  ('Simulador Financiero',       '/admin/portal-estructura-comisiones/financial-simulator',  160),
  ('Flujo Comercial',            '/admin/portal-estructura-comisiones/monthly-flow',         170),
  ('Resultados Financieros',     '/admin/portal-estructura-comisiones/results',              180),
  ('Costo Comercial',            '/admin/portal-estructura-comisiones/compensation',         190),
  ('Competitividad Comercial',   '/admin/portal-estructura-comisiones/competitividad',       200),
  ('Benchmark de Mercado',       '/admin/portal-estructura-comisiones/benchmark',            210),
  ('Benchmark Competidores',     '/admin/portal-estructura-comisiones/competitors-benchmark',220),
  ('Inventario Avanzado',        '/admin/portal-estructura-comisiones/inventory-advanced',   230),
  ('Portal de Agentes',          '/admin/portal-estructura-comisiones/agent-portal',         240),
  ('Gestión de Embajadores',     '/admin/portal-estructura-comisiones/ambassadors-admin',    250),
  ('Portal del Embajador',       '/admin/portal-estructura-comisiones/ambassadors-portal',   260)
) AS v(nombre, ruta, orden)
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus s WHERE s.vista_front_end = v.ruta
);

-- 3) Catálogo de permisos disponibles por submenú: 1,2,3,4
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
JOIN public.menus m ON m.id = s.menu_id
CROSS JOIN (VALUES (1),(2),(3),(4)) AS p(permiso_id)
WHERE m.nombre = 'Portal Estructura de Comisiones'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- 4) Asignación a roles 1 (Super Admin) y 2 (Admin de Proyecto): permisos 1,2,3
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, r.rol_id, true
FROM public.submenus s
JOIN public.menus m ON m.id = s.menu_id
CROSS JOIN (VALUES (1),(2),(3)) AS p(permiso_id)
CROSS JOIN (VALUES (1),(2)) AS r(rol_id)
WHERE m.nombre = 'Portal Estructura de Comisiones'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = r.rol_id
  );
