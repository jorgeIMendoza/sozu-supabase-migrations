-- Submenú "WhatsApp" en el Portal CRM (grupo Operación) para la bandeja de conversaciones.
-- Ruta front: /admin/portal-crm/operacion/whatsapp (existe como <Route> + PATH_ICONS en sozu-admin).
-- Menú referenciado por NOMBRE (los ids difieren dev/prod). submenus.id es IDENTITY (no fijar).

WITH nuevo AS (
  INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
  SELECT m.id, 'WhatsApp', '/admin/portal-crm/operacion/whatsapp', 390, true, false
  FROM public.menus m
  WHERE m.nombre = 'Portal CRM Sozu'
    AND NOT EXISTS (
      SELECT 1 FROM public.submenus s
      WHERE s.vista_front_end = '/admin/portal-crm/operacion/whatsapp'
    )
  RETURNING id
),
disp AS (
  INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
  SELECT n.id, p.permiso_id, true
  FROM nuevo n CROSS JOIN (VALUES (1),(2),(3),(4)) AS p(permiso_id)
  RETURNING submenu_id
)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT n.id, p.permiso_id, r.rol_id, true
FROM nuevo n
CROSS JOIN (VALUES (1),(2),(3)) AS p(permiso_id)
CROSS JOIN (VALUES (1)) AS r(rol_id);   -- rol 1 = Super Administrador; demás roles desde Roles y Permisos
