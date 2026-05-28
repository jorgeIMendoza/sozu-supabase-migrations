-- Portales Notario y Jurídico + Menús admin Notarios y Jurídico
-- Patrón: igual que Portal Embajadores (menú id=24) y Embajadores admin (menú id=22).
--
-- Nuevos menús principales:
--   Portal Notario   (solo_usuarioa=true)  → /admin/portal-escrituracion/app-notaria
--   Portal Jurídico  (solo_usuarioa=true)  → /admin/portal-escrituracion/app-juridico
--   Notarios         (admin)              → /admin/portal-escrituracion/notarios
--   Jurídico         (admin)              → /admin/portal-escrituracion/app-juridico
--
-- Requiere: public.menus, public.submenus, public.submenus_permisos, public.permisos.

-- ════════════════════════════════════════════════════════════════════════════
--  PASO 1: Menús principales
-- ════════════════════════════════════════════════════════════════════════════

-- Portal Notario (id=25)
INSERT INTO public.menus (id, nombre, activo, orden)
OVERRIDING SYSTEM VALUE
VALUES (25, 'Portal Notario', true, 20)
ON CONFLICT (id) DO NOTHING;

-- Portal Jurídico (id=26)
INSERT INTO public.menus (id, nombre, activo, orden)
OVERRIDING SYSTEM VALUE
VALUES (26, 'Portal Jurídico', true, 21)
ON CONFLICT (id) DO NOTHING;

-- Notarios — menú admin (id=27)
INSERT INTO public.menus (id, nombre, activo, orden)
OVERRIDING SYSTEM VALUE
VALUES (27, 'Notarios', true, 22)
ON CONFLICT (id) DO NOTHING;

-- Jurídico — menú admin (id=28)
INSERT INTO public.menus (id, nombre, activo, orden)
OVERRIDING SYSTEM VALUE
VALUES (28, 'Jurídico', true, 23)
ON CONFLICT (id) DO NOTHING;

-- Reajustar secuencia
SELECT setval(pg_get_serial_sequence('public.menus', 'id'),
              (SELECT MAX(id) FROM public.menus));


-- ════════════════════════════════════════════════════════════════════════════
--  PASO 2: Submenús
-- ════════════════════════════════════════════════════════════════════════════

-- Submenú Portal Notario (id=165) — solo_usuarioa=true (igual que Portal Embajadores)
INSERT INTO public.submenus (id, menu_id, nombre, vista_front_end, activo, orden, solo_usuarioa)
OVERRIDING SYSTEM VALUE
VALUES (165, 25, 'Inicio',
        '/admin/portal-escrituracion/app-notaria',
        true, 1, true)
ON CONFLICT (id) DO NOTHING;

-- Submenú Portal Jurídico (id=166) — solo_usuarioa=true
INSERT INTO public.submenus (id, menu_id, nombre, vista_front_end, activo, orden, solo_usuarioa)
OVERRIDING SYSTEM VALUE
VALUES (166, 26, 'Inicio',
        '/admin/portal-escrituracion/app-juridico',
        true, 1, true)
ON CONFLICT (id) DO NOTHING;

-- Submenú Administrar Notarios (id=167) — solo_usuarioa=false (admin)
INSERT INTO public.submenus (id, menu_id, nombre, vista_front_end, activo, orden, solo_usuarioa)
OVERRIDING SYSTEM VALUE
VALUES (167, 27, 'Administrar Notarios',
        '/admin/portal-escrituracion/notarios',
        true, 1, false)
ON CONFLICT (id) DO NOTHING;

-- Submenú Administrar Jurídico (id=168) — solo_usuarioa=false (admin)
INSERT INTO public.submenus (id, menu_id, nombre, vista_front_end, activo, orden, solo_usuarioa)
OVERRIDING SYSTEM VALUE
VALUES (168, 28, 'Administrar Jurídico',
        '/admin/portal-escrituracion/app-juridico',
        true, 1, false)
ON CONFLICT (id) DO NOTHING;

-- Reajustar secuencia
SELECT setval(pg_get_serial_sequence('public.submenus', 'id'),
              (SELECT MAX(id) FROM public.submenus));


-- ════════════════════════════════════════════════════════════════════════════
--  PASO 3: Permisos de submenús
-- ════════════════════════════════════════════════════════════════════════════

-- Portal Notario (165) → solo leer (igual que Portal Embajadores id=164)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id)
VALUES (165, 1)          -- leer
ON CONFLICT DO NOTHING;

-- Portal Jurídico (166) → solo leer
INSERT INTO public.submenus_permisos (submenu_id, permiso_id)
VALUES (166, 1)          -- leer
ON CONFLICT DO NOTHING;

-- Administrar Notarios (167) → todos los permisos (igual que Administración de Embajadores id=161)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id)
SELECT 167, p.id FROM public.permisos p
ON CONFLICT DO NOTHING;

-- Administrar Jurídico (168) → todos los permisos
INSERT INTO public.submenus_permisos (submenu_id, permiso_id)
SELECT 168, p.id FROM public.permisos p
ON CONFLICT DO NOTHING;
