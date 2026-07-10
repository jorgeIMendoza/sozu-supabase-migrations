-- Impersonación por atributo de rol en lugar de rol_id hardcodeado.
-- Los selectores de impersonación del front gateaban por rol_id IN (1, 2);
-- un rol nuevo (ej. 30 "Super Admin Fake") no podía impersonar aunque tuviera
-- acceso al portal. Se agrega roles.puede_impersonar y se expone en
-- get_current_user_profile para que el front gatee por dato, no por identidad.

ALTER TABLE public.roles
  ADD COLUMN IF NOT EXISTS puede_impersonar boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.roles.puede_impersonar IS
  'Habilita el selector de impersonación ("Ver como") en los portales para usuarios con este rol.';

-- Roles que hoy ya impersonan (1 = Super Administrador, 2 = Administrador de
-- Proyecto) + rol 30 (Super Admin Fake, existe solo en producción; en dev el
-- UPDATE simplemente no afecta esa fila).
UPDATE public.roles SET puede_impersonar = true WHERE id IN (1, 2, 30);

-- Recrear get_current_user_profile agregando puede_impersonar al final.
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
   puede_impersonar boolean
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
    COALESCE(r.puede_impersonar, false)::BOOLEAN AS puede_impersonar
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
