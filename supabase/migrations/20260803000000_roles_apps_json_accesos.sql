-- Accesos de rol por app, escalables: nueva columna roles.apps (jsonb).
-- -----------------------------------------------------------------------------
-- Motivación: hoy el acceso administrador a la app de clientes es el booleano
-- roles.administrar_app_clientes. Con varias apps por venir (agentes, etc.) no
-- queremos ir agregando una columna booleana por app. En su lugar un solo campo
-- jsonb escalable:
--
--   roles.apps = { "administrar": ["clientes", "agentes"] }
--
--   administrar → lista de slugs de app que el rol puede ADMINISTRAR
--                 (modo admin / impersonación). Reemplaza administrar_app_clientes.
--
-- El acceso de USUARIO FINAL de cada app NO va aquí: se gatea por rol_id (cada
-- app conoce el id de su rol de usuario final por variable de entorno). Ver
-- edge functions (_shared/cliente.ts) y la app de clientes (auth).
--
-- Transición sin riesgo:
--   * apps queda como FUENTE DE VERDAD.
--   * get_current_user_profile DERIVA administrar_app_clientes desde apps (con
--     fallback a la columna vieja), así ningún lector queda con dato stale.
--   * La columna roles.administrar_app_clientes se conserva (sin lectores nuevos)
--     y se elimina en una migración posterior una vez desplegado todo.
-- -----------------------------------------------------------------------------

ALTER TABLE public.roles
  ADD COLUMN IF NOT EXISTS apps jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.roles.apps IS
  'Accesos del rol por app (escalable). Forma: {"administrar":["clientes","agentes"]}. '
  'administrar = apps que el rol puede administrar/impersonar. El acceso de usuario '
  'final de cada app se gatea por rol_id, no aquí.';

-- Backfill desde el flag booleano actual: roles con administrar_app_clientes=true
-- pasan a apps.administrar = ["clientes"].
UPDATE public.roles
   SET apps = jsonb_build_object('administrar', jsonb_build_array('clientes'))
 WHERE administrar_app_clientes = true
   AND NOT (COALESCE(apps->'administrar', '[]'::jsonb) ? 'clientes');

-- Recrear get_current_user_profile: agrega `apps`; administrar_app_clientes ahora
-- se deriva de apps (fallback a la columna vieja). DROP requerido: cambia el tipo
-- de retorno (RETURNS TABLE).
--
-- IMPORTANTE: el cuerpo parte de la versión VIGENTE (migración
-- 20260713050000_portal_bancos_usuarios_banco), conservando id_banco/banco_nombre
-- y el LEFT JOIN bancos (scoping del Portal Bancos). Solo se agrega `apps` al
-- final y se deriva administrar_app_clientes desde apps.
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
   administrar_app_clientes boolean,
   id_banco integer,
   banco_nombre text,
   apps jsonb
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
    -- Flag EFECTIVO: usuario OR rol, espejo de can_view_all_prospects().
    (COALESCE(u.ver_todos_prospectos_compradores, false)
       OR COALESCE(r.ver_todos_prospectos_compradores, false))::BOOLEAN
                                             AS ver_todos_prospectos_compradores,
    COALESCE(r.ver_filtros_avanzados_eliminados, true)::BOOLEAN AS ver_filtros_avanzados_eliminados,
    u.id_notario::INTEGER,
    n.notaria::TEXT                          AS notaria_nombre,
    j.id::BIGINT                             AS id_perfil_juridico,
    j.nombre_completo::TEXT                  AS perfil_juridico_nombre,
    COALESCE(r.puede_impersonar, false)::BOOLEAN AS puede_impersonar,
    -- Derivado de apps (fuente de verdad) con fallback a la columna vieja.
    (COALESCE((r.apps -> 'administrar') ? 'clientes', false)
       OR COALESCE(r.administrar_app_clientes, false))::BOOLEAN AS administrar_app_clientes,
    u.id_banco::INTEGER,
    b.nombre::TEXT                           AS banco_nombre,
    COALESCE(r.apps, '{}'::jsonb)            AS apps
  FROM public.usuarios u
  JOIN  public.roles    r ON r.id  = u.rol_id
  LEFT JOIN public.notarios n
         ON n.id     = u.id_notario
        AND n.activo = TRUE
  LEFT JOIN public.perfiles_juridicos j
         ON j.email  = u.email
        AND j.activo = TRUE
  LEFT JOIN public.bancos b
         ON b.id     = u.id_banco
  WHERE u.email  = auth.email()
    AND u.activo = TRUE
  LIMIT 1;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_current_user_profile() TO anon, authenticated, service_role;
