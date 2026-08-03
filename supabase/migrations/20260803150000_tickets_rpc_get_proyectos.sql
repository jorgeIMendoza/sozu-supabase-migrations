-- Portal Tickets de Seguimiento — RPC para el select de proyectos al crear un ticket.
--
-- Problema: el select consultaba `proyectos` directo, y esa tabla tiene RLS: un usuario con
-- socio bancario asignado (usuarios.id_socio_bancario) solo ve los proyectos de su socio, no
-- todos. Eso hacía que un usuario interno que además es cliente/socio (p.ej. un Super Admin con
-- departamentos) no viera todos los proyectos al crear tickets. NO se puede quitar el socio a
-- ese usuario (es socio legítimo), así que la solución vive dentro del módulo de tickets.
--
-- get_tickets_proyectos(): SECURITY DEFINER (se salta el RLS de socio bancario) y devuelve TODOS
-- los proyectos SOZU publicados, PERO solo si el rol del usuario actual tiene acceso al portal de
-- tickets (permiso en algún submenú /admin/portal-tickets/%). Para roles sin acceso: 0 filas.
--
-- No modifica proyectos, usuarios ni el RLS existente (solo agrega esta función). Idempotente
-- (CREATE OR REPLACE). Sin BEGIN/COMMIT. Corre en Preview y Producción.

CREATE OR REPLACE FUNCTION public.get_tickets_proyectos()
RETURNS TABLE(id integer, nombre text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT p.id, p.nombre
  FROM public.proyectos p
  WHERE p.activo = true
    AND p.publicar = true
    AND p.id IN (
      SELECT er.id_proyecto
      FROM public.entidades_relacionadas er
      WHERE er.id_tipo_entidad = 5 AND er.activo = true AND er.id_proyecto IS NOT NULL
    )
    -- Solo si el rol del usuario actual tiene acceso al Portal Tickets de Seguimiento.
    AND EXISTS (
      SELECT 1
      FROM public.usuarios u
      JOIN public.submenus_permisos sp ON sp.rol_id = u.rol_id AND sp.activo = true
      JOIN public.submenus s ON s.id = sp.submenu_id
      WHERE u.auth_user_id = auth.uid()
        AND u.activo = true
        AND s.vista_front_end LIKE '/admin/portal-tickets/%'
    )
  ORDER BY p.nombre;
$$;

REVOKE ALL ON FUNCTION public.get_tickets_proyectos() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_tickets_proyectos() TO authenticated;
