-- Portal Embajadores — permiso COMPLETO para TODOS los roles.
-- -----------------------------------------------------------------------------
-- A todos los roles que aún NO tienen completo el menú "Portal Embajadores" se
-- les otorgan todos los permisos de sus submenús y se les asocia el menú.
--
-- Modelo:
--   * Se resuelve el menú por NOMBRE ('Portal Embajadores'); sus ids se sembraron
--     de forma manual y difieren por ambiente.
--   * submenus_permisos(submenu_id, permiso_id, rol_id, activo) NO tiene PK/UNIQUE
--     -> idempotencia con WHERE NOT EXISTS (no ON CONFLICT).
--   * menus_roles(rol_id, menu_id): asociación menú↔rol (visibilidad del menú).
--   * submenus_permisos_disponibles: catálogo de permisos por submenú (toggles UI).
--
-- ALCANCE: TODOS los roles (sin filtro es_rol_interno), según lo solicitado.
--
-- NOTA de visibilidad: si los submenús del menú tienen solo_usuarioa = true, el
-- menú lo verá solo usuarioA aunque el permiso esté dado a todos los roles. Quitar
-- ese gate es una decisión aparte (no se incluye en esta migración).
-- -----------------------------------------------------------------------------

BEGIN;

-- Guard: el menú debe existir (falla ruidoso si el nombre no coincide en el ambiente).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.menus WHERE nombre = 'Portal Embajadores') THEN
    RAISE EXCEPTION 'No existe el menú "Portal Embajadores" en public.menus (revisa el nombre exacto).';
  END IF;
END $$;

-- 1. Asociar el menú a TODOS los roles.
INSERT INTO public.menus_roles (rol_id, menu_id, activo)
SELECT r.id, m.id, true
FROM public.roles r
JOIN public.menus m ON m.nombre = 'Portal Embajadores'
WHERE NOT EXISTS (
  SELECT 1 FROM public.menus_roles mr
  WHERE mr.rol_id = r.id AND mr.menu_id = m.id
);

-- 2. Catálogo: marcar TODOS los permisos como disponibles en cada submenú del menú.
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.id, true
FROM public.submenus s
JOIN public.menus m ON m.id = s.menu_id AND m.nombre = 'Portal Embajadores'
CROSS JOIN public.permisos p
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos_disponibles d
  WHERE d.submenu_id = s.id AND d.permiso_id = p.id
);

-- 3. Otorgar TODOS los permisos de cada submenú del menú a TODOS los roles.
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.id, r.id, true
FROM public.submenus s
JOIN public.menus m ON m.id = s.menu_id AND m.nombre = 'Portal Embajadores'
CROSS JOIN public.permisos p
CROSS JOIN public.roles r
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos sp
  WHERE sp.submenu_id = s.id AND sp.permiso_id = p.id AND sp.rol_id = r.id
);

COMMIT;
