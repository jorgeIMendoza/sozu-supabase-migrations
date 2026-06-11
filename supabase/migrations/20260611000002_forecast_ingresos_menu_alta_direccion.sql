-- Submenú "Forecast de Ingresos" en Portal Alta Dirección.
-- Fecha: 2026-06-11
--
-- Registra el submenú para que el sistema de roles/permisos reconozca la ruta
-- /admin/portal-alta-direccion/forecast-ingresos (ya existe como <Route> en App.tsx)
-- y se muestre en el sidebar. Permisos leer(1) + exportar(6) sólo a Super Admin
-- (rol 1); ampliable a otros roles después.
--
-- Idempotente con WHERE NOT EXISTS (tablas sin PK/UNIQUE → sin ON CONFLICT);
-- submenus.id es GENERATED ALWAYS → no se fija.

-- 1) Submenú (idempotente por vista_front_end)
WITH menu_ad AS (
  SELECT id FROM public.menus
   WHERE nombre = 'Portal Alta Dirección'
     AND activo = true
   LIMIT 1
)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT m.id, 'Forecast de Ingresos', '/admin/portal-alta-direccion/forecast-ingresos', 800, true, false
FROM menu_ad m
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus
  WHERE vista_front_end = '/admin/portal-alta-direccion/forecast-ingresos'
);

-- 2) Catálogo de permisos disponibles: leer(1) + exportar(6)
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1), (6)) AS p(permiso_id)
WHERE s.vista_front_end = '/admin/portal-alta-direccion/forecast-ingresos'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- 3) Asignación a Super Admin (rol_id=1)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, 1, true
FROM public.submenus s
CROSS JOIN (VALUES (1), (6)) AS p(permiso_id)
WHERE s.vista_front_end = '/admin/portal-alta-direccion/forecast-ingresos'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = 1
  );

-- Recarga del schema cache de PostgREST.
NOTIFY pgrst, 'reload schema';
