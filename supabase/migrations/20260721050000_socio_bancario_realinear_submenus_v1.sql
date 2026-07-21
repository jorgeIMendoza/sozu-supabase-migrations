-- Portal Socio Bancario · Realinear submenús con el router V1
-- Fecha: 2026-07-21
--
-- Tras el reencuadre V1 el router quedó con 4 rutas (Resumen → Obra → Comercialización →
-- Evidencia) y se removieron las confidenciales. Los submenús en BD seguían apuntando a las
-- rutas viejas y el primero (orden 10) era "Histórico Comercial" → al entrar al portal la app
-- navegaba a una ruta removida → 404. Esta migración deja exactamente los 4 submenús del
-- router en el orden del flujo V1.
--
-- Estado final (menu 'Portal Socio Bancario', solo activos):
--   Resumen del Desarrollo /resumen           (10)
--   Avance de Obra         /avance-obra        (20)
--   Ventas e Inventario    /ventas-inventario  (30)
--   Expedientes            /expedientes        (40)
--
-- Soft-delete (activo=false) para deprecados; sin DELETE. Referencias por vista_front_end,
-- menú por nombre y rol 'Socio Bancario' por nombre (los ids IDENTITY difieren entre
-- ambientes; NO se hardcodean). Roles fijos 1 (Super Admin) y 2 (Administrador de Proyecto)
-- como en 20260716140000. Idempotente. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

-- ================================================================
-- 1) Desactivar submenús deprecados (rutas confidenciales removidas del router V1)
-- ================================================================
UPDATE public.submenus_permisos_disponibles SET activo = false
WHERE submenu_id IN (
  SELECT s.id FROM public.submenus s
  WHERE s.vista_front_end IN (
    '/admin/portal-socio-bancario/historico-comercial',
    '/admin/portal-socio-bancario/analisis-cobranza',
    '/admin/portal-socio-bancario/ingresos-egresos',
    '/admin/portal-socio-bancario/forecast-ingresos'
  )
);

UPDATE public.submenus_permisos SET activo = false
WHERE submenu_id IN (
  SELECT s.id FROM public.submenus s
  WHERE s.vista_front_end IN (
    '/admin/portal-socio-bancario/historico-comercial',
    '/admin/portal-socio-bancario/analisis-cobranza',
    '/admin/portal-socio-bancario/ingresos-egresos',
    '/admin/portal-socio-bancario/forecast-ingresos'
  )
);

UPDATE public.submenus SET activo = false
WHERE vista_front_end IN (
  '/admin/portal-socio-bancario/historico-comercial',
  '/admin/portal-socio-bancario/analisis-cobranza',
  '/admin/portal-socio-bancario/ingresos-egresos',
  '/admin/portal-socio-bancario/forecast-ingresos'
);

-- ================================================================
-- 2) Reordenar submenús válidos existentes al flujo V1
-- ================================================================
UPDATE public.submenus SET orden = 20 WHERE vista_front_end = '/admin/portal-socio-bancario/avance-obra';
UPDATE public.submenus SET orden = 40 WHERE vista_front_end = '/admin/portal-socio-bancario/expedientes';

-- ================================================================
-- 3) Insertar submenús faltantes (Resumen, Ventas e Inventario). Idempotente por ruta.
-- ================================================================
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT m.id, v.nombre, v.ruta, v.orden, true, false
FROM (SELECT id FROM public.menus WHERE nombre = 'Portal Socio Bancario') m
CROSS JOIN (VALUES
  ('Resumen del Desarrollo', '/admin/portal-socio-bancario/resumen',           10),
  ('Ventas e Inventario',    '/admin/portal-socio-bancario/ventas-inventario', 30)
) AS v(nombre, ruta, orden)
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus s WHERE s.vista_front_end = v.ruta
);

-- ================================================================
-- 4) Permisos DISPONIBLES de las 2 nuevas rutas (portal solo lectura: leer=1 + exportar=6)
-- ================================================================
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(6)) AS p(permiso_id)
WHERE s.vista_front_end IN (
    '/admin/portal-socio-bancario/resumen',
    '/admin/portal-socio-bancario/ventas-inventario'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- ================================================================
-- 5) Asignación por rol de las 2 nuevas rutas (lo que las hace VISIBLES)
--    Super Administrador (1): leer + exportar · Administrador de Proyecto (2): leer ·
--    Socio Bancario (id por nombre): leer. Se omite el rol que no exista (rol_id NULL).
-- ================================================================
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, a.permiso_id, a.rol_id, true
FROM public.submenus s
CROSS JOIN (
  SELECT 1 AS permiso_id, 1 AS rol_id
  UNION ALL SELECT 6, 1
  UNION ALL SELECT 1, 2
  UNION ALL SELECT 1, (SELECT id FROM public.roles WHERE nombre = 'Socio Bancario')
) AS a(permiso_id, rol_id)
WHERE s.vista_front_end IN (
    '/admin/portal-socio-bancario/resumen',
    '/admin/portal-socio-bancario/ventas-inventario'
  )
  AND a.rol_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = a.permiso_id AND sp.rol_id = a.rol_id
  );
