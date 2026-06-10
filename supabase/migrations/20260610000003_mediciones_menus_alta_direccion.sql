-- Mediciones de uso de portales — Fase 1: submenús "Mediciones" en Alta Dirección.
-- Fecha: 2026-06-10
--
-- 3 submenús nuevos colgados del menú "Portal Alta Dirección" (id 21 en dev, resuelto
-- por nombre sin hardcodear) con permisos leer(1) + exportar(6) sólo para Super Admin
-- (rol_id=1). Las rutas React se crean en la Fase 4; mientras tanto el sidebar muestra
-- el ítem aunque la página esté pendiente.
--
-- Idempotente con WHERE NOT EXISTS (las tablas no tienen PK/UNIQUE → sin ON CONFLICT).
-- submenus.id es GENERATED ALWAYS → no se fija.

-- 1) Submenús (idempotente por vista_front_end)
WITH menu_ad AS (
  SELECT id FROM public.menus
   WHERE nombre = 'Portal Alta Dirección'
     AND activo = true
   LIMIT 1
)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT m.id, v.nombre, v.ruta, v.orden, true, false
FROM menu_ad m
CROSS JOIN (VALUES
  ('Mediciones · Uso por portal',      '/admin/portal-alta-direccion/mediciones/portales', 900),
  ('Mediciones · Mapa de calor menús', '/admin/portal-alta-direccion/mediciones/menus',    910),
  ('Mediciones · Mapa de calor CTAs',  '/admin/portal-alta-direccion/mediciones/ctas',     920)
) AS v(nombre, ruta, orden)
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus s WHERE s.vista_front_end = v.ruta
);

-- 2) Catálogo de permisos disponibles por submenú: leer(1) + exportar(6)
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1), (6)) AS p(permiso_id)
WHERE s.vista_front_end LIKE '/admin/portal-alta-direccion/mediciones/%'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- 3) Asignación a Super Admin (rol_id=1): leer + exportar
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, 1, true
FROM public.submenus s
CROSS JOIN (VALUES (1), (6)) AS p(permiso_id)
WHERE s.vista_front_end LIKE '/admin/portal-alta-direccion/mediciones/%'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = 1
  );
