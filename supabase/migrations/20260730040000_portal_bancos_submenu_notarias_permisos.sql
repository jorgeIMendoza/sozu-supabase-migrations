-- Portal Bancos — alta del submenú «Notarías» + permisos de Supervisor / Operador Banco
-- Fecha: 2026-07-30
--
-- 1) Registra el submenú «Notarías» del Portal Bancos (/admin/portal-bancos/notarias) en `submenus`
--    (menu_id de «Portal Bancos»), que hoy no existe y por eso no aparece en «Administrar Menús».
-- 2) Asigna permisos del submenú a Super Administrador (1-4) y lectura a los roles del portal.
-- 3) Da de alta permisos faltantes de Supervisor Banco (29) y Operador Banco (30) sobre los
--    submenús del Portal Bancos (incluido Equipo, que devolvía «Acceso denegado»).
-- 4) Quita ESCRITURA del rol legacy «Banco» (28) sobre Equipo (conserva solo `leer`): al mover
--    la autorización de hardcode a BD, sus permisos 2-4 le habrían dado alta/baja de usuarios.
--
-- Acompaña cambios de front en sozu-admin (PermissionRoute / PortalBancosLayout / portal-bancos/index).
-- Idempotente: submenus.id es GENERATED ALWAYS → CTE RETURNING (no se fija id); todos los INSERT
-- llevan WHERE NOT EXISTS / NOT EXISTS en el CTE; rol_id 28/29/30 resueltos por roles.nombre.
-- Corre igual en Preview y Producción. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

-- 1) Submenú «Notarías» del Portal Bancos + su catálogo de permisos + asignación a Super Admin
WITH nuevo_submenu AS (
  INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
  SELECT m.id, 'Notarías', '/admin/portal-bancos/notarias', 60, true, false
  FROM public.menus m
  WHERE m.nombre = 'Portal Bancos'
    AND NOT EXISTS (
      SELECT 1 FROM public.submenus s
      WHERE s.vista_front_end = '/admin/portal-bancos/notarias'
    )
  RETURNING id
),
disp AS (
  INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
  SELECT s.id, p.permiso_id, true
  FROM nuevo_submenu s
  CROSS JOIN (VALUES (1),(2),(3),(4)) AS p(permiso_id)
  RETURNING submenu_id
)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, 1, true
FROM nuevo_submenu s
CROSS JOIN (VALUES (1),(2),(3),(4)) AS p(permiso_id);

-- 2) Permisos de los roles del Portal Bancos (idempotente: solo inserta lo que falte)
WITH objetivo(vista, rol_nombre, permiso_id) AS (
  VALUES
    -- Bandeja
    ('/admin/portal-bancos/bandeja',  'Supervisor Banco', 1),
    ('/admin/portal-bancos/bandeja',  'Supervisor Banco', 2),
    ('/admin/portal-bancos/bandeja',  'Supervisor Banco', 3),
    ('/admin/portal-bancos/bandeja',  'Operador Banco',   1),
    ('/admin/portal-bancos/bandeja',  'Operador Banco',   2),
    ('/admin/portal-bancos/bandeja',  'Operador Banco',   3),
    -- Pipeline
    ('/admin/portal-bancos/pipeline', 'Supervisor Banco', 1),
    ('/admin/portal-bancos/pipeline', 'Supervisor Banco', 3),
    ('/admin/portal-bancos/pipeline', 'Operador Banco',   1),
    ('/admin/portal-bancos/pipeline', 'Operador Banco',   3),
    -- Tablero
    ('/admin/portal-bancos/tablero',  'Supervisor Banco', 1),
    ('/admin/portal-bancos/tablero',  'Operador Banco',   1),
    -- Equipo: Supervisor administra; Operador solo consulta
    ('/admin/portal-bancos/equipo',   'Supervisor Banco', 1),
    ('/admin/portal-bancos/equipo',   'Supervisor Banco', 2),
    ('/admin/portal-bancos/equipo',   'Supervisor Banco', 3),
    ('/admin/portal-bancos/equipo',   'Operador Banco',   1),
    -- Notarías: directorio de contacto, lectura para todos los roles del portal
    ('/admin/portal-bancos/notarias', 'Banco',            1),
    ('/admin/portal-bancos/notarias', 'Supervisor Banco', 1),
    ('/admin/portal-bancos/notarias', 'Operador Banco',   1)
)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, o.permiso_id, r.id, true
FROM objetivo o
JOIN public.submenus s ON s.vista_front_end = o.vista AND s.activo = true
JOIN public.roles r    ON r.nombre = o.rol_nombre AND r.activo = true
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos sp
  WHERE sp.submenu_id = s.id
    AND sp.permiso_id = o.permiso_id
    AND sp.rol_id     = r.id
);

-- 3) Reactivar filas que existieran pero apagadas
UPDATE public.submenus_permisos sp
SET activo = true
FROM public.submenus s, public.roles r
WHERE sp.submenu_id = s.id
  AND sp.rol_id = r.id
  AND sp.activo = false
  AND s.vista_front_end LIKE '/admin/portal-bancos/%'
  AND s.vista_front_end <> '/admin/portal-bancos/bancos'
  AND r.nombre IN ('Banco', 'Supervisor Banco', 'Operador Banco')
  -- El rol legacy «Banco» no recupera escritura sobre Equipo (ver paso 4).
  AND NOT (r.nombre = 'Banco'
           AND s.vista_front_end = '/admin/portal-bancos/equipo'
           AND sp.permiso_id <> 1);

-- 4) Rol legacy «Banco» (28): quitar ESCRITURA sobre Equipo (conservar solo `leer`)
UPDATE public.submenus_permisos sp
SET activo = false
FROM public.submenus s, public.roles r
WHERE sp.submenu_id = s.id
  AND sp.rol_id = r.id
  AND sp.activo = true
  AND r.nombre = 'Banco'
  AND s.vista_front_end = '/admin/portal-bancos/equipo'
  AND sp.permiso_id IN (2, 3, 4);
