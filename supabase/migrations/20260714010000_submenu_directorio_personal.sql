-- Submenu "Directorio de Personal" — Portal Operación Comercial e Incentivos (menu 35)
-- Fecha: 2026-07-14
--
-- El menu 35 y sus 16 submenus ya existen con permisos a rol 1 (Super Admin) y rol 2
-- (Admin de Proyecto). Falta el submenu de "Directorio de Personal"
-- (/admin/portal-estructura-comisiones/directorio), agregado al front sin este INSERT.
--
-- submenus.id es GENERATED ALWAYS AS IDENTITY → no se fija; se encadena vía CTE + RETURNING.
-- orden=225 lo ubica entre "Puestos y Sueldos" (220) y "Comisiones" (230).
-- Idempotente: el submenu se inserta solo si no existe (WHERE NOT EXISTS) → si ya existe,
-- los CTE dependientes no insertan nada. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

WITH nuevo_submenu AS (
  INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
  SELECT 35, 'Directorio de Personal', '/admin/portal-estructura-comisiones/directorio', 225, true, false
  WHERE NOT EXISTS (
    SELECT 1 FROM public.submenus
    WHERE vista_front_end = '/admin/portal-estructura-comisiones/directorio'
  )
  RETURNING id
),
disp AS (
  INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
  SELECT s.id, p.permiso_id, true
  FROM nuevo_submenu s
  CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
  RETURNING submenu_id
)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, r.rol_id, true
FROM nuevo_submenu s
CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
CROSS JOIN (VALUES (1),(2)) AS r(rol_id);
