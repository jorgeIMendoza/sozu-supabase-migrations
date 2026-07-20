-- Permite configurar los pipelines del CRM a "Agente Interno" (rol 9) y "Admin CRM"
-- (rol 31, el rol admin del CRM = "super admin fake"). Hasta ahora la config de
-- pipelines (`.../configuracion/pipelines` y `.../configuracion/etapas-pipeline`)
-- solo la tenían Super Admin (1) y Admin CRM (31).
--
-- Se resuelve el submenú por su `vista_front_end` y menú ACTIVO (no por id fijo,
-- que puede diferir entre dev y prod) y se conceden solo los permisos que el submenú
-- realmente OFRECE (`submenus_permisos_disponibles`). Idempotente (NOT EXISTS).
--
-- NOTA prod: si el "super admin fake" de producción es un rol distinto a 31, agrégalo
-- a la lista de rol_id de abajo (mismo patrón); no se hardcodea porque su id no es
-- conocido/estable entre ambientes.

INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT d.submenu_id, d.permiso_id, r.rol_id, true
FROM public.submenus_permisos_disponibles d
JOIN public.submenus s ON s.id = d.submenu_id
JOIN public.menus   m ON m.id = s.menu_id
CROSS JOIN (VALUES (9), (31)) AS r(rol_id)
WHERE m.activo = true
  AND s.activo = true
  AND d.activo = true
  AND s.vista_front_end IN (
        '/admin/portal-crm/configuracion/pipelines',
        '/admin/portal-crm/configuracion/etapas-pipeline')
  AND EXISTS (SELECT 1 FROM public.roles ro WHERE ro.id = r.rol_id AND ro.activo)
  AND NOT EXISTS (
        SELECT 1 FROM public.submenus_permisos sp
        WHERE sp.submenu_id = d.submenu_id
          AND sp.permiso_id = d.permiso_id
          AND sp.rol_id     = r.rol_id);
