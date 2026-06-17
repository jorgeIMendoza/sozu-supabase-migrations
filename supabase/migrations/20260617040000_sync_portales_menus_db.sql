-- Sync Portal Menus → DB (fuente de verdad para nav DB-driven).
-- Fecha: 2026-06-17
--
-- Completa la BD para migrar el nav de varios portales de hardcodeado a DB-driven:
--   1. Activa menus inactivos (Cobranza=19; 30/32 ya activos → no-op).
--   2. Renombra submenu 155 (Bandeja de Validaciones → Bandeja de Ejecución) en Administración.
--   3. Inserta submenus faltantes en Administración (23), Escrituración (20) y Alta Dirección (21),
--      cada uno CON sus permisos (disponibles + asignados por rol). Sin permisos un submenu no
--      aparece para ningún rol.
--
-- Idempotente (WHERE NOT EXISTS por fila). submenus.id es GENERATED ALWAYS → no se fija.
-- Permisos referenciados por vista_front_end → se backfillean aunque el submenu ya exista.
--
-- Patrón de roles/permisos por portal (verificado contra submenus existentes):
--   menu 20 Escrituración   → roles 1, 21  · permisos 1,2,3,4,6
--   menu 21 Alta Dirección  → roles 1, 17  · permisos 1,2,3,4,5,6,8
--   menu 23 Administración  → rol 1 (1,2,3,4,5,6) · rol 7 (1,2,3,4,5,6,8)
--
-- Verificado: las 11 rutas existen como <Route> en src/App.tsx (sozu-admin).
-- Fuera de alcance: CRM (menu 31) y validacion-contratos (Legal Flow/Escrituración).

-- ===========================================================================
-- PASO 1 — activar menus inactivos
-- ===========================================================================
UPDATE public.menus
SET activo = true
WHERE id IN (19, 30, 32)
  AND activo = false;

-- ===========================================================================
-- PASO 2 — Administración (menu 23)
-- ===========================================================================

-- 2a: renombrar submenu 155 (Validaciones → Bandeja de Ejecución).
-- Conserva sus permisos existentes. Guard por vista vieja → no-op si ya renombrado.
UPDATE public.submenus
SET vista_front_end = '/admin/portal-administracion/bandeja-ejecucion',
    nombre          = 'Bandeja de Ejecución'
WHERE id = 155
  AND vista_front_end = '/admin/portal-administracion/bandeja';

-- 2b: 3 submenus nuevos (idempotente por vista_front_end)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT 23, v.nombre, v.vista, v.orden, true, false
FROM (VALUES
  ('Pagos Ejecutados', '/admin/portal-administracion/pagos-ejecutados', 21),
  ('CFDIs Emitidos',   '/admin/portal-administracion/cfdis-emitidos',   22),
  ('Conciliación STP', '/admin/portal-administracion/conciliacion-stp', 23)
) AS v(nombre, vista, orden)
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus s WHERE s.vista_front_end = v.vista
);

-- 2c: permisos DISPONIBLES (catálogo) — unión de los usados por rol 1 y rol 7
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(2),(3),(4),(5),(6),(8)) AS p(permiso_id)
WHERE s.vista_front_end IN (
  '/admin/portal-administracion/pagos-ejecutados',
  '/admin/portal-administracion/cfdis-emitidos',
  '/admin/portal-administracion/conciliacion-stp'
)
AND NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos_disponibles d
  WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
);

-- 2d: asignar a Super Admin (rol 1) — permisos 1,2,3,4,5,6
INSERT INTO public.submenus_permisos (submenu_id, rol_id, permiso_id, activo)
SELECT s.id, 1, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(2),(3),(4),(5),(6)) AS p(permiso_id)
WHERE s.vista_front_end IN (
  '/admin/portal-administracion/pagos-ejecutados',
  '/admin/portal-administracion/cfdis-emitidos',
  '/admin/portal-administracion/conciliacion-stp'
)
AND NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos sp
  WHERE sp.submenu_id = s.id AND sp.rol_id = 1 AND sp.permiso_id = p.permiso_id
);

-- 2e: asignar a rol 7 — permisos 1,2,3,4,5,6,8
INSERT INTO public.submenus_permisos (submenu_id, rol_id, permiso_id, activo)
SELECT s.id, 7, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(2),(3),(4),(5),(6),(8)) AS p(permiso_id)
WHERE s.vista_front_end IN (
  '/admin/portal-administracion/pagos-ejecutados',
  '/admin/portal-administracion/cfdis-emitidos',
  '/admin/portal-administracion/conciliacion-stp'
)
AND NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos sp
  WHERE sp.submenu_id = s.id AND sp.rol_id = 7 AND sp.permiso_id = p.permiso_id
);

-- ===========================================================================
-- PASO 3 — Escrituración (menu 20)
-- ===========================================================================

-- 3a: 5 submenus nuevos (idempotente por vista_front_end)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT 20, v.nombre, v.vista, v.orden, true, false
FROM (VALUES
  ('Relación de Pagos', '/admin/portal-escrituracion/relacion-pagos', 18),
  ('Programar Citas',   '/admin/portal-escrituracion/citas',          19),
  ('Demandas',          '/admin/portal-escrituracion/demandas',       20),
  ('Postventa',         '/admin/portal-escrituracion/postventa',      21),
  ('Workflow',          '/admin/portal-escrituracion/workflow',       22)
) AS v(nombre, vista, orden)
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus s WHERE s.vista_front_end = v.vista
);

-- 3b: permisos DISPONIBLES (1,2,3,4,6)
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
WHERE s.vista_front_end IN (
  '/admin/portal-escrituracion/relacion-pagos',
  '/admin/portal-escrituracion/citas',
  '/admin/portal-escrituracion/demandas',
  '/admin/portal-escrituracion/postventa',
  '/admin/portal-escrituracion/workflow'
)
AND NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos_disponibles d
  WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
);

-- 3c: asignar a roles 1 y 21 — permisos 1,2,3,4,6
INSERT INTO public.submenus_permisos (submenu_id, rol_id, permiso_id, activo)
SELECT s.id, r.rol_id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(21)) AS r(rol_id)
CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
WHERE s.vista_front_end IN (
  '/admin/portal-escrituracion/relacion-pagos',
  '/admin/portal-escrituracion/citas',
  '/admin/portal-escrituracion/demandas',
  '/admin/portal-escrituracion/postventa',
  '/admin/portal-escrituracion/workflow'
)
AND NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos sp
  WHERE sp.submenu_id = s.id AND sp.rol_id = r.rol_id AND sp.permiso_id = p.permiso_id
);

-- ===========================================================================
-- PASO 4 — Alta Dirección (menu 21)
-- ===========================================================================

-- 4a: 2 submenus nuevos (idempotente por vista_front_end)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT 21, v.nombre, v.vista, v.orden, true, false
FROM (VALUES
  ('Histórico Comercial',  '/admin/portal-alta-direccion/historico-comercial', 22),
  ('Análisis de Cobranza', '/admin/portal-alta-direccion/analisis-cobranza',   23)
) AS v(nombre, vista, orden)
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus s WHERE s.vista_front_end = v.vista
);

-- 4b: permisos DISPONIBLES (1,2,3,4,5,6,8)
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(2),(3),(4),(5),(6),(8)) AS p(permiso_id)
WHERE s.vista_front_end IN (
  '/admin/portal-alta-direccion/historico-comercial',
  '/admin/portal-alta-direccion/analisis-cobranza'
)
AND NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos_disponibles d
  WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
);

-- 4c: asignar a roles 1 y 17 — permisos 1,2,3,4,5,6,8
INSERT INTO public.submenus_permisos (submenu_id, rol_id, permiso_id, activo)
SELECT s.id, r.rol_id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(17)) AS r(rol_id)
CROSS JOIN (VALUES (1),(2),(3),(4),(5),(6),(8)) AS p(permiso_id)
WHERE s.vista_front_end IN (
  '/admin/portal-alta-direccion/historico-comercial',
  '/admin/portal-alta-direccion/analisis-cobranza'
)
AND NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos sp
  WHERE sp.submenu_id = s.id AND sp.rol_id = r.rol_id AND sp.permiso_id = p.permiso_id
);
