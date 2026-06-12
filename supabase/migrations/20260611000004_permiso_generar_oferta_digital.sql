-- Permiso generar_oferta_digital (id=9) y asignación al submenú Inventario del
-- portal agente (id=68) para Super Admin (1) y rol 3.
-- Fecha: 2026-06-11
--
-- Sin esto el botón "Oferta digital" no aparece para los agentes — sólo Super Admin
-- lo ve por fallback en código.
--
-- permisos.id es GENERATED ALWAYS AS IDENTITY y el permiso necesita id estable 9
-- (referenciado por el front) → INSERT con OVERRIDING SYSTEM VALUE + setval para no
-- romper futuros inserts (regla del proyecto). Idempotente vía WHERE NOT EXISTS.
-- Verificado en dev: max(permisos.id)=8, submenú 68 = "Inventario"
-- (/admin/agent/inventario).

-- 1) Catálogo de permisos: id estable 9
INSERT INTO public.permisos (id, nombre, descripcion, activo)
OVERRIDING SYSTEM VALUE
SELECT 9, 'generar_oferta_digital', 'Permite generar oferta digital con link de reservación', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.permisos WHERE id = 9
);

-- Reajustar la secuencia para futuros inserts sin id explícito
SELECT setval(
  pg_get_serial_sequence('public.permisos', 'id'),
  (SELECT MAX(id) FROM public.permisos)
);

-- 2) Disponible en el submenú Inventario del portal agente (id=68)
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT 68, 9, true
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos_disponibles
  WHERE submenu_id = 68 AND permiso_id = 9
);

-- 3) Asignación a Super Admin (1) y rol 3
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT 68, 9, r.rol_id, true
FROM (VALUES (1), (3)) AS r(rol_id)
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus_permisos sp
  WHERE sp.submenu_id = 68 AND sp.permiso_id = 9 AND sp.rol_id = r.rol_id
);
