-- Titularidad (Portal Condominio) visible y accesible para la administración.
--
-- Problema: el módulo "Titularidad" (/admin/portal-condominio/titularidad) se
-- inyectaba solo en el front y NO existía como submenú en la BD. Como la nav del
-- portal filtra por permisos de submenú, únicamente lo veía el Super Admin (por
-- su comodín); a cualquier otro rol —o al impersonar— el filtro lo ocultaba.
-- Además, aunque se mostrara el link, el RLS de solicitudes_propietario solo
-- dejaba ver a "admin de condominio" (rol que ya no existe con ese nombre) y
-- "super admin", por lo que el Supervisor Condominio veía la bandeja vacía.
--
-- Solución (2 piezas):
--   1) Registrar el submenú "Titularidad" bajo el menú "Portal Condominio
--      Administración" y darle permiso de lectura a Super Administrador y
--      Supervisor Condominio.
--   2) Ampliar el helper de RLS para incluir a "Supervisor Condominio".
--
-- Roles/menú/permiso se resuelven por NOMBRE (los ids difieren entre ambientes).
-- `submenus` es GENERATED ALWAYS AS IDENTITY → no se fija id (CTE RETURNING).
-- Idempotente: no duplica el submenú si ya existe (guard por vista_front_end).

-- ── 1. Submenú "Titularidad" + permisos ─────────────────────────────────────
WITH nuevo AS (
  INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
  SELECT m.id, 'Titularidad', '/admin/portal-condominio/titularidad', 55, true, false
  FROM public.menus m
  WHERE m.nombre = 'Portal Condominio Administración'
    AND NOT EXISTS (
      SELECT 1 FROM public.submenus s
      WHERE s.vista_front_end = '/admin/portal-condominio/titularidad'
    )
  RETURNING id
),
-- Permisos DISPONIBLES del submenú: leer, actualizar, aprobar (la revisión legal).
disp AS (
  INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
  SELECT n.id, p.permiso_id, true
  FROM nuevo n
  CROSS JOIN (VALUES (1), (3), (5)) AS p(permiso_id)
  RETURNING submenu_id
)
-- ASIGNACIÓN a roles (lo que hace VISIBLE el link): permiso leer (1) a
-- Super Administrador y Supervisor Condominio.
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT n.id, 1, r.id, true
FROM nuevo n
CROSS JOIN public.roles r
WHERE lower(btrim(r.nombre)) = 'supervisor condominio'
   OR lower(btrim(r.nombre)) LIKE 'super admin%';

-- ── 2. RLS: quién puede ver/gestionar las solicitudes de titularidad ─────────
-- Se agrega "Supervisor Condominio" (la administración del condominio). Se
-- conserva "admin de condominio" por compatibilidad si existiera en algún
-- ambiente. Detección por nombre.
CREATE OR REPLACE FUNCTION public.current_user_is_condominio_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.usuarios u
    JOIN public.roles r ON r.id = u.rol_id
    WHERE u.auth_user_id = auth.uid()
      AND u.activo = true
      AND (
        lower(btrim(r.nombre)) = 'supervisor condominio'
        OR lower(btrim(r.nombre)) = 'admin de condominio'
        OR lower(btrim(r.nombre)) LIKE 'super admin%'
      )
  );
$function$;
