-- ============================================================================
-- Portal Socio Bancario — menú, submenús y permisos
-- Fecha: 2026-07-16
--
-- Crea el menú "Portal Socio Bancario" con 6 submenús (copias funcionales de
-- Alta Dirección / Legal Flow + Avance de Obra) y puebla:
--   - submenus_permisos_disponibles: catálogo de permisos que ofrece cada vista
--   - submenus_permisos: asignación efectiva
--       · rol 1 (Super Administrador): todos los permisos disponibles
--       · rol 2 (Administrador de Proyecto): leer (1) — necesario para la
--         impersonación "Ver como Administrador de Proyecto" del portal
--
-- Idempotente: todos los INSERT llevan guard WHERE NOT EXISTS.
-- menus.id y submenus.id son GENERATED ALWAYS AS IDENTITY → nunca se fijan.
-- ============================================================================

BEGIN;

-- 1) Menú -------------------------------------------------------------------
INSERT INTO public.menus (nombre, orden, activo)
SELECT 'Portal Socio Bancario', 30, true
WHERE NOT EXISTS (
  SELECT 1 FROM public.menus WHERE nombre = 'Portal Socio Bancario'
);

-- 2) Submenús ---------------------------------------------------------------
WITH menu AS (
  SELECT id FROM public.menus WHERE nombre = 'Portal Socio Bancario'
),
vals(nombre, ruta, orden) AS (
  VALUES
    ('Histórico Comercial',  '/admin/portal-socio-bancario/historico-comercial', 10),
    ('Análisis de Cobranza', '/admin/portal-socio-bancario/analisis-cobranza',   20),
    ('Ingresos y Egresos',   '/admin/portal-socio-bancario/ingresos-egresos',    30),
    ('Forecast de Ingresos', '/admin/portal-socio-bancario/forecast-ingresos',   40),
    ('Expedientes',          '/admin/portal-socio-bancario/expedientes',         50),
    ('Avance de Obra',       '/admin/portal-socio-bancario/avance-obra',         60)
)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT m.id, v.nombre, v.ruta, v.orden, true, false
FROM menu m
CROSS JOIN vals v
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus s WHERE s.vista_front_end = v.ruta
);

-- 3) Permisos disponibles por submenú ----------------------------------------
-- Espejo de los portales de origen:
--   Histórico Comercial / Análisis de Cobranza / Ingresos y Egresos:
--     1=leer, 2=crear, 3=actualizar, 4=eliminar, 5=aprobar, 6=exportar, 8=generar_oferta
--   Forecast de Ingresos / Expedientes / Avance de Obra: 1=leer, 6=exportar
WITH perms(ruta, permiso_id) AS (
  VALUES
    ('/admin/portal-socio-bancario/historico-comercial', 1),
    ('/admin/portal-socio-bancario/historico-comercial', 2),
    ('/admin/portal-socio-bancario/historico-comercial', 3),
    ('/admin/portal-socio-bancario/historico-comercial', 4),
    ('/admin/portal-socio-bancario/historico-comercial', 5),
    ('/admin/portal-socio-bancario/historico-comercial', 6),
    ('/admin/portal-socio-bancario/historico-comercial', 8),
    ('/admin/portal-socio-bancario/analisis-cobranza',   1),
    ('/admin/portal-socio-bancario/analisis-cobranza',   2),
    ('/admin/portal-socio-bancario/analisis-cobranza',   3),
    ('/admin/portal-socio-bancario/analisis-cobranza',   4),
    ('/admin/portal-socio-bancario/analisis-cobranza',   5),
    ('/admin/portal-socio-bancario/analisis-cobranza',   6),
    ('/admin/portal-socio-bancario/analisis-cobranza',   8),
    ('/admin/portal-socio-bancario/ingresos-egresos',    1),
    ('/admin/portal-socio-bancario/ingresos-egresos',    2),
    ('/admin/portal-socio-bancario/ingresos-egresos',    3),
    ('/admin/portal-socio-bancario/ingresos-egresos',    4),
    ('/admin/portal-socio-bancario/ingresos-egresos',    5),
    ('/admin/portal-socio-bancario/ingresos-egresos',    6),
    ('/admin/portal-socio-bancario/ingresos-egresos',    8),
    ('/admin/portal-socio-bancario/forecast-ingresos',   1),
    ('/admin/portal-socio-bancario/forecast-ingresos',   6),
    ('/admin/portal-socio-bancario/expedientes',         1),
    ('/admin/portal-socio-bancario/expedientes',         6),
    ('/admin/portal-socio-bancario/avance-obra',         1),
    ('/admin/portal-socio-bancario/avance-obra',         6)
)
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM perms p
JOIN public.submenus s ON s.vista_front_end = p.ruta
WHERE NOT EXISTS (
  SELECT 1
  FROM public.submenus_permisos_disponibles d
  WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
);

-- 4) Asignación de permisos por rol ------------------------------------------
-- 4a) Super Administrador (rol 1): todos los permisos disponibles del portal.
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT d.submenu_id, d.permiso_id, 1, true
FROM public.submenus_permisos_disponibles d
JOIN public.submenus s ON s.id = d.submenu_id
WHERE s.vista_front_end LIKE '/admin/portal-socio-bancario/%'
  AND NOT EXISTS (
    SELECT 1
    FROM public.submenus_permisos sp
    WHERE sp.submenu_id = d.submenu_id
      AND sp.permiso_id = d.permiso_id
      AND sp.rol_id = 1
  );

-- 4b) Administrador de Proyecto (rol 2): lectura de todo el portal, para que
--     la vista impersonada "Ver como Administrador de Proyecto" muestre menús.
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, 1, 2, true
FROM public.submenus s
WHERE s.vista_front_end LIKE '/admin/portal-socio-bancario/%'
  AND NOT EXISTS (
    SELECT 1
    FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id
      AND sp.permiso_id = 1
      AND sp.rol_id = 2
  );

COMMIT;
