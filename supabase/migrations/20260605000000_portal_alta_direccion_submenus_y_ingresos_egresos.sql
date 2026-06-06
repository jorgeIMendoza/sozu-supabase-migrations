-- Portal Alta Dirección (menu_id=21): submenus faltantes + permisos.
-- Fecha: 2026-06-05
--
-- Reúne dos requerimientos del portal Alta Dirección que sólo se habían aplicado en la
-- BD de desarrollo (vía Studio) y faltaban como migración para paridad con producción:
--
--   Bloque A (2026-05-21): 7 submenus (Notificaciones, Bandeja de Validaciones, Ciclo de
--     Venta, Facturas por Cobrar/Pagar, Comisiones Externas/Internas) + permiso 'leer' (1)
--     al rol Gerente general (rol_id=17). Sin ellos isPathAllowed devuelve false y
--     PermissionRoute redirige al dashboard.
--   Bloque B (2026-06-05): submenu "Ingresos y Egresos" (sección Finanzas) + catálogo de
--     permisos disponibles + 'leer' para rol 17 + todos los permisos para Super Admin (1).
--
-- Idempotente (WHERE NOT EXISTS por fila); submenus.id es GENERATED ALWAYS → no se fija.
-- En dev el Bloque A y los submenus existentes quedan como no-op.
-- Verificado: menu 21 = "Portal Alta Dirección"; rol 17 = "Gerente general";
-- permisos 1,2,3,4,5,6,8 existen.

-- ===========================================================================
-- BLOQUE A — submenus 2026-05-21
-- ===========================================================================

-- A.1: alta de los 7 submenus (idempotente por vista_front_end)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT 21, v.nombre, v.vista, v.orden, true, false
FROM (VALUES
  ('Notificaciones',          '/admin/portal-alta-direccion/notificaciones',       14),
  ('Bandeja de Validaciones', '/admin/portal-alta-direccion/bandeja',              15),
  ('Ciclo de Venta',          '/admin/portal-alta-direccion/ciclo-venta',          16),
  ('Facturas por Cobrar',     '/admin/portal-alta-direccion/facturas-por-cobrar',  17),
  ('Facturas por Pagar',      '/admin/portal-alta-direccion/facturas-por-pagar',   18),
  ('Comisiones Externas',     '/admin/portal-alta-direccion/comisiones-externas',  19),
  ('Comisiones Internas',     '/admin/portal-alta-direccion/comisiones-internas',  20)
) AS v(nombre, vista, orden)
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus s WHERE s.vista_front_end = v.vista
);

-- A.2: permiso 'leer' (1) a Gerente general (rol_id=17) en esos 7 submenus
INSERT INTO public.submenus_permisos (submenu_id, rol_id, permiso_id, activo)
SELECT s.id, 17, 1, true
FROM public.submenus s
WHERE s.vista_front_end IN (
  '/admin/portal-alta-direccion/notificaciones',
  '/admin/portal-alta-direccion/bandeja',
  '/admin/portal-alta-direccion/ciclo-venta',
  '/admin/portal-alta-direccion/facturas-por-cobrar',
  '/admin/portal-alta-direccion/facturas-por-pagar',
  '/admin/portal-alta-direccion/comisiones-externas',
  '/admin/portal-alta-direccion/comisiones-internas'
)
AND NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos sp
  WHERE sp.submenu_id = s.id AND sp.rol_id = 17 AND sp.permiso_id = 1
);

-- ===========================================================================
-- BLOQUE B — submenu "Ingresos y Egresos" 2026-06-05
-- ===========================================================================

-- B.1: alta del submenu (idempotente)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT 21, 'Ingresos y Egresos', '/admin/portal-alta-direccion/ingresos-egresos', 21, true, false
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus
  WHERE vista_front_end = '/admin/portal-alta-direccion/ingresos-egresos'
);

-- B.2: permisos DISPONIBLES del submenu (catálogo para "Administrar Menús")
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(2),(3),(4),(5),(6),(8)) AS p(permiso_id)
WHERE s.vista_front_end = '/admin/portal-alta-direccion/ingresos-egresos'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- B.3: asignar 'leer' (1) a Gerente general (rol_id=17)
INSERT INTO public.submenus_permisos (submenu_id, rol_id, permiso_id, activo)
SELECT s.id, 17, 1, true
FROM public.submenus s
WHERE s.vista_front_end = '/admin/portal-alta-direccion/ingresos-egresos'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.rol_id = 17 AND sp.permiso_id = 1
  );

-- B.4: Super Admin (rol_id=1) — todos los permisos disponibles (refuerzo en BD)
INSERT INTO public.submenus_permisos (submenu_id, rol_id, permiso_id, activo)
SELECT s.id, 1, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(2),(3),(4),(5),(6),(8)) AS p(permiso_id)
WHERE s.vista_front_end = '/admin/portal-alta-direccion/ingresos-egresos'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.rol_id = 1 AND sp.permiso_id = p.permiso_id
  );
