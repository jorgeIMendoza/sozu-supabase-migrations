-- fix(rbac): user_has_permission dejaba de reconocer permisos por menus_roles legacy
--
-- La función exigía una fila en `menus_roles` para el par (rol, menú) además del
-- permiso en `submenus_permisos`. Esa tabla se poblo una sola vez (migración
-- 20251209185857) y nunca se mantuvo: hoy el rol 2 (Administrador de Proyecto)
-- tiene ahí 6 menús de los 14+ que existen, y roles nuevos (23 Cliente,
-- 25 Embajador, etc.) no aparecen. El sidebar (useDynamicMenus) nunca consultó
-- `menus_roles` — resuelve visibilidad con submenus_permisos + submenus.activo +
-- menus.activo — así que un rol podía ver el submenú y recibir 403 al operar.
--
-- Síntoma reportado: rol 2 con permiso 'leer' sobre /admin/usuarios (submenu 33,
-- menú "Sistema" = id 10, ausente de menus_roles para rol 2) obtenía
-- "No tienes permisos para consultar usuarios del sistema" desde la edge
-- function list-system-users.
--
-- La fuente de verdad pasa a ser submenus_permisos, alineada con el sidebar, y
-- se añaden los filtros de activo de submenú y menú que el front ya aplicaba.

CREATE OR REPLACE FUNCTION public.user_has_permission(_submenu_path text, _permission_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM usuarios u
    JOIN submenus s ON s.vista_front_end = _submenu_path AND s.activo = true
    JOIN menus m ON m.id = s.menu_id AND m.activo = true
    JOIN submenus_permisos sp ON sp.submenu_id = s.id AND sp.rol_id = u.rol_id AND sp.activo = true
    JOIN permisos perm ON perm.id = sp.permiso_id
    WHERE u.auth_user_id = auth.uid()
      AND perm.nombre = _permission_name
      AND u.activo = true
  );
END; $function$;
