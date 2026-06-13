-- Menú "Escrituración" + submenú "Expedientes" (SOZU Legal Flow).
-- Fecha: 2026-06-12
--
-- Registra la ruta /admin/legal-flow/escrituracion/expedientes en el sistema de
-- roles/permisos. Permisos leer(1) + exportar(6) a Super Admin (rol 1); agregar más
-- roles después si debe aparecer a otros.
--
-- NOTA: el spec pide crear un menú NUEVO "Escrituración" (orden 210), distinto de los
-- existentes "Portal Escrituración" (id 20) y "Portal Legal Flow" (id 29).
--
-- El bloque DDL del mismo spec (legal_flow_etapas/expedientes/historial + trigger)
-- NO se incluye: ya está migrado en 20260601000000_legal_flow_expedientes.sql con
-- nombres adaptados (legal_flow_historico, legal_flow_registrar_cambio_etapa, códigos
-- de etapa en español) y aplicado en dev.
--
-- Idempotente con WHERE NOT EXISTS; menus.id/submenus.id GENERATED ALWAYS → no se fijan.

-- 1) Menú "Escrituración" (orden 210)
INSERT INTO public.menus (nombre, orden, activo)
SELECT 'Escrituración', 210, true
WHERE NOT EXISTS (
  SELECT 1 FROM public.menus WHERE nombre = 'Escrituración' AND activo = true
);

-- 2) Submenú "Expedientes" (idempotente por vista_front_end)
WITH m AS (
  SELECT id FROM public.menus
   WHERE nombre = 'Escrituración' AND activo = true
   LIMIT 1
)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT m.id, 'Expedientes', '/admin/legal-flow/escrituracion/expedientes', 10, true, false
FROM m
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus
  WHERE vista_front_end = '/admin/legal-flow/escrituracion/expedientes'
);

-- 3) Catálogo de permisos disponibles: leer(1) + exportar(6)
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1), (6)) AS p(permiso_id)
WHERE s.vista_front_end = '/admin/legal-flow/escrituracion/expedientes'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- 4) Asignación a Super Admin (rol_id=1)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, 1, true
FROM public.submenus s
CROSS JOIN (VALUES (1), (6)) AS p(permiso_id)
WHERE s.vista_front_end = '/admin/legal-flow/escrituracion/expedientes'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = 1
  );
