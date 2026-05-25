-- Portal de Administración — menús, submenús y permisos
-- Espejo del Portal Alta Dirección (id 21) bajo la ruta /admin/portal-administracion/*.
-- Submenús ids 141-160 (bloque contiguo al 121-140 de Portal Alta Dirección).

BEGIN;

-- 1. Menú principal
INSERT INTO public.menus (id, nombre, activo, orden)
OVERRIDING SYSTEM VALUE
VALUES (23, 'Portal de Administración', true, 16)
ON CONFLICT (id) DO UPDATE SET
  nombre = EXCLUDED.nombre,
  activo = true,
  orden  = EXCLUDED.orden;

-- 2. Submenús (ids 141..160)
INSERT INTO public.submenus (id, menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
OVERRIDING SYSTEM VALUE
VALUES
  (141, 23, 'Dashboard',               '/admin/portal-administracion/dashboard',            1,  true, true),
  (142, 23, 'Citas',                   '/admin/portal-administracion/citas',                2,  true, true),
  (143, 23, 'Prospectos',              '/admin/portal-administracion/prospectos',           3,  true, true),
  (144, 23, 'Pipeline',                '/admin/portal-administracion/pipeline',             4,  true, true),
  (145, 23, 'Ofertas',                 '/admin/portal-administracion/ofertas',              5,  true, true),
  (146, 23, 'Cobranza',                '/admin/portal-administracion/cobranza',             6,  true, true),
  (147, 23, 'Contratos',               '/admin/portal-administracion/contratos',            7,  true, true),
  (148, 23, 'Facturas',                '/admin/portal-administracion/facturas',             8,  true, true),
  (149, 23, 'Comisiones',              '/admin/portal-administracion/comisiones',           9,  true, true),
  (150, 23, 'Red Comercial',           '/admin/portal-administracion/red-comercial',        10, true, true),
  (151, 23, 'Reportes',                '/admin/portal-administracion/reportes',             11, true, true),
  (152, 23, 'Auditoría',               '/admin/portal-administracion/auditoria',            12, true, true),
  (153, 23, 'Configuración',           '/admin/portal-administracion/configuracion',        13, true, true),
  (154, 23, 'Notificaciones',          '/admin/portal-administracion/notificaciones',       14, true, true),
  (155, 23, 'Bandeja de Validaciones', '/admin/portal-administracion/bandeja',              15, true, true),
  (156, 23, 'Ciclo de Venta',          '/admin/portal-administracion/ciclo-venta',          16, true, true),
  (157, 23, 'Facturas por Cobrar',     '/admin/portal-administracion/facturas-por-cobrar',  17, true, true),
  (158, 23, 'Facturas por Pagar',      '/admin/portal-administracion/facturas-por-pagar',   18, true, true),
  (159, 23, 'Comisiones Externas',     '/admin/portal-administracion/comisiones-externas',  19, true, true),
  (160, 23, 'Comisiones Internas',     '/admin/portal-administracion/comisiones-internas',  20, true, true)
ON CONFLICT (id) DO UPDATE SET
  menu_id         = EXCLUDED.menu_id,
  nombre          = EXCLUDED.nombre,
  vista_front_end = EXCLUDED.vista_front_end,
  orden           = EXCLUDED.orden,
  activo          = true,
  solo_usuarioa   = true;

-- 3. Resync de secuencias
SELECT setval(pg_get_serial_sequence('public.menus',    'id'), (SELECT MAX(id) FROM public.menus));
SELECT setval(pg_get_serial_sequence('public.submenus', 'id'), (SELECT MAX(id) FROM public.submenus));

-- 4. Permisos completos para Super Admin (rol_id = 1)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.submenu_id, p.id, 1, true
FROM (VALUES
  (141),(142),(143),(144),(145),(146),(147),(148),(149),(150),
  (151),(152),(153),(154),(155),(156),(157),(158),(159),(160)
) AS s(submenu_id)
CROSS JOIN public.permisos p
WHERE p.nombre IN ('leer', 'crear', 'actualizar', 'eliminar', 'aprobar', 'exportar')
ON CONFLICT (submenu_id, permiso_id, rol_id) DO UPDATE SET activo = true;

COMMIT;
