-- Portal Legal Flow: menú + submenús + permisos Super Administrador
-- Fecha: 2026-05-29
--
-- Crea el menú "Portal Legal Flow" (orden 29) con 7 submenús (incluye el dashboard
-- "Panel de Operaciones") y otorga los 7 permisos al rol Super Administrador (rol_id=1)
-- en cada submenú.
--
-- Notas:
--  - menus.id / submenus.id son GENERATED ALWAYS AS IDENTITY; los INSERT no fijan id,
--    por lo que NO se requiere OVERRIDING SYSTEM VALUE.
--  - Los 7 permisos del proyecto: leer, crear, actualizar, eliminar, aprobar, exportar,
--    generar_oferta (el CROSS JOIN con public.permisos los cubre todos).
--  - Idempotencia: ver guardas WHERE NOT EXISTS para permitir re-ejecución segura.

-- 1) Menú principal
INSERT INTO public.menus (nombre, orden, activo)
SELECT 'Portal Legal Flow', 29, true
WHERE NOT EXISTS (
  SELECT 1 FROM public.menus WHERE nombre = 'Portal Legal Flow'
);

-- 2) Submenús (usan el id del menú recién insertado)
WITH m AS (
  SELECT id FROM public.menus WHERE nombre = 'Portal Legal Flow'
)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo)
SELECT m.id, s.nombre, s.vista, s.orden, true
FROM m, (VALUES
  ('Panel de Operaciones',     '/admin/legal-flow',                 1),
  ('Solicitudes Legales',      '/admin/legal-flow/requests',        2),
  ('Nueva Solicitud',          '/admin/legal-flow/requests/new',    3),
  ('Catálogo de Plantillas',   '/admin/legal-flow/templates',       4),
  ('Expedientes Archivados',   '/admin/legal-flow/archived',        5),
  ('Notificaciones',           '/admin/legal-flow/notifications',   6),
  ('Configuración',            '/admin/legal-flow/settings',        7)
) AS s(nombre, vista, orden)
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus sm
  WHERE sm.menu_id = m.id AND sm.vista_front_end = s.vista
);

-- 3) Permisos para Super Administrador (rol_id = 1) — los 7 permisos en cada submenú
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT sm.id, p.id, 1, true
FROM public.submenus sm
JOIN public.menus m ON m.id = sm.menu_id
CROSS JOIN public.permisos p
WHERE m.nombre = 'Portal Legal Flow'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = sm.id AND sp.permiso_id = p.id AND sp.rol_id = 1
  );

-- (Opcional) Permisos también para rol 2 (Administrador) si aplica:
-- INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
-- SELECT sm.id, p.id, 2, true
-- FROM public.submenus sm
-- JOIN public.menus m ON m.id = sm.menu_id
-- CROSS JOIN public.permisos p
-- WHERE m.nombre = 'Portal Legal Flow';
