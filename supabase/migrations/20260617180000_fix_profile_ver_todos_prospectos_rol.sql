-- Fix: el guard de frontend "El prospecto no te pertenece" bloqueaba ofertas a roles
-- internos (p. ej. Administrador de cobranza, rol 12) aunque el backend sí los autoriza.
--
-- Causa: el frontend usa profile.ver_todos_prospectos_compradores (proveniente de esta
-- función) que se tomaba a nivel USUARIO (usuarios.ver_todos_prospectos_compradores),
-- mientras que la autoridad real del backend, can_view_all_prospects(), lo evalúa a nivel
-- ROL (roles.ver_todos_prospectos_compradores). Desincronización front/back.
--
-- Solución: devolver el flag EFECTIVO = (usuario OR rol), espejando can_view_all_prospects().
-- Único consumidor en el front: canSeeAllProspects en src/pages/admin/Propiedades.tsx.

CREATE OR REPLACE FUNCTION public.get_current_user_profile()
 RETURNS TABLE(email text, nombre text, rol_id integer, rol_nombre text, debe_cambiar_password boolean, id_persona integer, activo boolean, ver_todos_prospectos_compradores boolean, ver_filtros_avanzados_eliminados boolean, id_notario integer, notaria_nombre text, id_perfil_juridico bigint, perfil_juridico_nombre text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    u.email::TEXT,
    u.nombre::TEXT,
    u.rol_id::INTEGER,
    r.nombre::TEXT                           AS rol_nombre,
    u.debe_cambiar_password::BOOLEAN,
    u.id_persona::INTEGER,
    u.activo::BOOLEAN,
    -- Flag EFECTIVO: usuario OR rol, espejo de can_view_all_prospects() (que lee el flag del rol).
    (COALESCE(u.ver_todos_prospectos_compradores, false)
       OR COALESCE(r.ver_todos_prospectos_compradores, false))::BOOLEAN
                                             AS ver_todos_prospectos_compradores,
    COALESCE(r.ver_filtros_avanzados_eliminados, true)::BOOLEAN AS ver_filtros_avanzados_eliminados,
    u.id_notario::INTEGER,
    n.notaria::TEXT                          AS notaria_nombre,
    j.id::BIGINT                             AS id_perfil_juridico,
    j.nombre_completo::TEXT                  AS perfil_juridico_nombre
  FROM public.usuarios u
  JOIN  public.roles    r ON r.id  = u.rol_id
  LEFT JOIN public.notarios n
         ON n.id     = u.id_notario
        AND n.activo = TRUE
  LEFT JOIN public.perfiles_juridicos j
         ON j.email  = u.email
        AND j.activo = TRUE
  WHERE u.email  = auth.email()
    AND u.activo = TRUE
  LIMIT 1;
END;
$function$;
