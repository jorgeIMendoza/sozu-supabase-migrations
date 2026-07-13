-- Nueva configuración especial de rol: "Administrar app clientes".
-- Permite al rol administrar la app de clientes. Default deseleccionado para
-- todos los roles; solo Super Administrador (id 1) lo tiene por default.
-- Se expone en get_current_user_profile para que el front gatee por dato,
-- siguiendo el mismo patrón que puede_impersonar.

ALTER TABLE public.roles
  ADD COLUMN IF NOT EXISTS administrar_app_clientes boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.roles.administrar_app_clientes IS
  'Habilita la administración de la app de clientes para usuarios con este rol.';

UPDATE public.roles SET administrar_app_clientes = true WHERE id = 1;

-- Recrear get_current_user_profile agregando administrar_app_clientes al final.
-- DROP requerido: cambia el tipo de retorno (RETURNS TABLE).
DROP FUNCTION IF EXISTS public.get_current_user_profile();

CREATE OR REPLACE FUNCTION public.get_current_user_profile()
 RETURNS TABLE(
   email text,
   nombre text,
   rol_id integer,
   rol_nombre text,
   debe_cambiar_password boolean,
   id_persona integer,
   activo boolean,
   ver_todos_prospectos_compradores boolean,
   ver_filtros_avanzados_eliminados boolean,
   id_notario integer,
   notaria_nombre text,
   id_perfil_juridico bigint,
   perfil_juridico_nombre text,
   puede_impersonar boolean,
   administrar_app_clientes boolean
 )
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
    j.nombre_completo::TEXT                  AS perfil_juridico_nombre,
    COALESCE(r.puede_impersonar, false)::BOOLEAN AS puede_impersonar,
    COALESCE(r.administrar_app_clientes, false)::BOOLEAN AS administrar_app_clientes
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

GRANT EXECUTE ON FUNCTION public.get_current_user_profile() TO anon, authenticated, service_role;
