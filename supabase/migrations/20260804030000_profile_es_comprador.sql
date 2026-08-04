-- 20260804030000_profile_es_comprador.sql
--
-- Agrega la columna `es_comprador` a public.get_current_user_profile().
--
-- Contexto: el acceso al Portal del Cliente se gatea hoy por rol (rol_id = 23).
-- El rol describe para qué se contrató a la persona, no si compró: hay 8 usuarios
-- internos (rol != 23) que sí son compradores activos y quedan fuera del portal.
-- La regla nueva es "rol Cliente OR comprador activo", y el frontend necesita el
-- dato en el perfil para decidir el login. El scoping de datos ya es por
-- id_persona (Edge Functions con service_role), así que esto NO amplía lo que ve
-- nadie: solo expone un booleano derivado de compradores del propio usuario.
--
-- OJO: Postgres no permite cambiar las columnas de un RETURNS TABLE con
-- CREATE OR REPLACE, así que hay DROP + CREATE. `supabase db push` aplica cada
-- archivo en una transacción, por lo que la ventana sin RPC es de milisegundos y
-- no puede quedar a medias. La función no tiene dependientes (pg_depend = 0).
--
-- Grants: un DROP se lleva los ACL. Se recrean tal cual están hoy en dev y prod
-- ({=X/postgres, anon=X, authenticated=X, service_role=X}). anon conserva EXECUTE
-- como hasta ahora; sin sesión, auth.email() es NULL y la función no devuelve
-- filas. Si se quiere cerrar anon, va aparte: no es parte de este cambio.
--
-- Idempotente + self-verifying: si ya trae es_comprador se rehace igual (misma
-- definición); si la definición viva no es la esperada, aborta sin tocar nada.

-- 1) Anchor: la definición viva debe ser la que se validó en dev y prod.
DO $guard$
DECLARE
  v_hash        TEXT;
  v_result      TEXT;
  v_esperado    TEXT := '297bd4299b3aa6e76084b46c5df1c2f7';
BEGIN
  SELECT md5(pg_get_functiondef(p.oid)), pg_get_function_result(p.oid)
    INTO v_hash, v_result
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'get_current_user_profile'
     AND p.pronargs = 0;

  IF v_hash IS NULL THEN
    RAISE EXCEPTION
      'public.get_current_user_profile() no existe; no hay nada que reemplazar';
  END IF;

  -- Ya aplicada: la definición de abajo es idéntica, se deja pasar.
  IF v_result LIKE '%es_comprador%' THEN
    RAISE NOTICE 'get_current_user_profile ya expone es_comprador; se reaplica igual';
    RETURN;
  END IF;

  IF v_hash <> v_esperado THEN
    RAISE EXCEPTION
      'drift en get_current_user_profile: md5 vivo % <> esperado %. Rebasar la migración sobre la definición viva antes de aplicar.',
      v_hash, v_esperado;
  END IF;
END
$guard$;

-- 2) Reemplazo (DROP + CREATE por el cambio de RETURNS TABLE).
DROP FUNCTION IF EXISTS public.get_current_user_profile();

CREATE OR REPLACE FUNCTION public.get_current_user_profile()
 RETURNS TABLE(email text, nombre text, rol_id integer, rol_nombre text, debe_cambiar_password boolean, id_persona integer, activo boolean, ver_todos_prospectos_compradores boolean, ver_filtros_avanzados_eliminados boolean, id_notario integer, notaria_nombre text, id_perfil_juridico bigint, perfil_juridico_nombre text, puede_impersonar boolean, administrar_app_clientes boolean, id_banco integer, banco_nombre text, apps jsonb, es_comprador boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  WITH apps_rol AS (
    SELECT COALESCE(jsonb_agg(a.slug ORDER BY a.slug), '[]'::jsonb) AS slugs
    FROM public.usuarios u2
    JOIN public.roles_apps ra ON ra.id_rol = u2.rol_id AND ra.activo
    JOIN public.apps       a  ON a.id      = ra.id_app AND a.activo
    WHERE u2.email = auth.email()
  )
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
    -- Derivado de roles_apps (fuente de verdad). Se conserva el OR con las
    -- columnas legacy por si un rol se editara por fuera de roles_apps.
    ((SELECT slugs FROM apps_rol) ? 'clientes'
       OR COALESCE((r.apps -> 'administrar') ? 'clientes', false)
       OR COALESCE(r.administrar_app_clientes, false))::BOOLEAN AS administrar_app_clientes,
    u.id_banco::INTEGER,
    b.nombre::TEXT                           AS banco_nombre,
    -- Mismo contrato de siempre: {"administrar":[...]}.
    jsonb_build_object('administrar', (SELECT slugs FROM apps_rol)) AS apps,
    -- Acceso al Portal del Cliente: rol 23 OR comprador activo. El rol dice para
    -- qué se contrató a la persona, no si compró.
    EXISTS (
      SELECT 1
        FROM public.compradores c
       WHERE c.id_persona = u.id_persona
         AND c.activo = TRUE
    )::BOOLEAN                               AS es_comprador
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

-- 3) Grants: idénticos a los de antes del DROP.
GRANT EXECUTE ON FUNCTION public.get_current_user_profile()
  TO anon, authenticated, service_role;

-- 4) Verificación post-aplicación: la columna quedó en el contrato.
DO $verify$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'get_current_user_profile'
       AND p.pronargs = 0
       AND pg_get_function_result(p.oid) LIKE '%es_comprador boolean%'
  ) THEN
    RAISE EXCEPTION 'get_current_user_profile no quedó con es_comprador';
  END IF;
END
$verify$;
