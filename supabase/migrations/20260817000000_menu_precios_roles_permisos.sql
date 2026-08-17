-- =============================================================================
-- Submenú "Precios" (Inventarios) dentro del sistema de roles y permisos
-- =============================================================================
-- El módulo de Precios (/admin/inventario/precios/*) existía solo como entrada
-- fija en el front (useDynamicMenus lo inyectaba a mano para Super Admin) y por
-- tanto quedaba fuera de submenus / submenus_permisos: no se podía apagar desde
-- "Administrar Menús" ni asignar a otros roles.
--
-- Esta migración lo registra en BD:
--   1. submenus                        → la vista y su lugar en el menú Inventarios (id=2)
--   2. submenus_permisos_disponibles   → catálogo de acciones que ofrece la vista
--   3. submenus_permisos               → asignación efectiva a Super Administrador (rol 1)
--
-- vista_front_end usa el prefijo del módulo ('/admin/inventario/precios') y no
-- una pestaña concreta, para que las subrutas (tabla, motor, calibracion,
-- escenarios, auditoria) hereden el apagado del submenú en useAllowedMenus
-- (isPathDisabled resuelve por prefijo con frontera "/").
--
-- Idempotente: se puede reaplicar sin duplicar filas.
-- `submenus.id` es GENERATED ALWAYS AS IDENTITY → nunca se fija a mano.
-- =============================================================================

BEGIN;

-- 1. Submenú
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT 2, 'Precios', '/admin/inventario/precios', 9, true, false
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus
  WHERE vista_front_end = '/admin/inventario/precios'
);

-- 2. Permisos disponibles: leer(1), crear(2), actualizar(3), eliminar(4), exportar(6)
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
WHERE s.vista_front_end = '/admin/inventario/precios'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- 3. Asignación a Super Administrador (rol_id = 1)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, 1, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
WHERE s.vista_front_end = '/admin/inventario/precios'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id
      AND sp.permiso_id = p.permiso_id
      AND sp.rol_id = 1
  );

COMMIT;
