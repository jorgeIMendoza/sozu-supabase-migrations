-- Base de datos del nuevo modelo de confirmacion de correo por tipo de rol.
--
-- Regla de negocio (definida por Jorge el 2026-08-05):
--   * Roles DE PORTAL (tienen portal/subdominio propio y son externos a SOZU):
--     Cliente, Agente Inmobiliario, Inmobiliaria, Embajador, Notario, Socio Bancario
--     y los roles de banco (Banco / Supervisor Banco / Operador Banco).
--     -> nacen SIN confirmar, pasan por el correo de confirmacion, y su portal
--        debe negarles el acceso mientras email_confirmado = false.
--   * Roles INTERNOS (todo lo demas, incluido Agente Interno y Directores):
--     -> nacen confirmados en AMBAS tablas, sin correo de confirmacion. Entran con
--        Temporal123!, cambian contrasena y vuelven al login.
--
-- Hasta hoy esa clasificacion vivia repartida en ~6 listas de rol_id en edge
-- functions y front, y los ids de banco NO coinciden entre dev y prod (dev:
-- 29/30 = Supervisor/Operador Banco; prod difiere), asi que las listas por id
-- estaban mal en algun ambiente por construccion. Se centraliza en una columna,
-- poblada por NOMBRE de rol.
--
-- OJO orden de merge: esta migracion va ANTES que las edge functions y el front,
-- que pasan a leer roles.requiere_confirmacion_email y las columnas nuevas del
-- perfil. Es compatible hacia atras: el codigo viejo ignora lo que no conoce.
--
-- Idempotente y sin BEGIN/COMMIT (el CI envuelve cada archivo en su transaccion).

-- ─── 1. Clasificacion del rol ─────────────────────────────────────────────────
-- DEFAULT true a proposito: un rol nuevo (los crea la pantalla Roles y Permisos, que no
-- fija esta columna) nace EXIGIENDO confirmacion. Si alguien da de alta un rol externo y
-- olvida clasificarlo, el fallo es que se pide un correo de confirmacion de mas; con el
-- default contrario seria que sus usuarios nacen confirmados y con la contrasena publica
-- Temporal123!. Se falla hacia el lado seguro.
ALTER TABLE public.roles
  ADD COLUMN IF NOT EXISTS requiere_confirmacion_email boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.roles.requiere_confirmacion_email IS
  'true = rol de portal/externo: el usuario nace con email_confirmado=false, recibe '
  'correo de confirmacion y su portal le niega el acceso hasta confirmarlo. '
  'false = rol interno: nace confirmado, sin correo. Fuente de verdad unica; '
  'no duplicar esta clasificacion como listas de rol_id en el codigo. Se administra '
  'desde Roles y Permisos; esta migracion solo siembra el valor inicial. DEFAULT true: '
  'un rol sin clasificar se trata como externo, que es el lado seguro.';

-- Se asigna por NOMBRE, nunca por id (los ids difieren entre dev y prod).
-- El UPDATE es absoluto (fija true y false) para que correr la migracion de nuevo
-- corrija cualquier drift manual.
UPDATE public.roles r
SET requiere_confirmacion_email = v.requiere,
    fecha_actualizacion         = CURRENT_TIMESTAMP
FROM (
  SELECT id,
         (
              lower(btrim(nombre)) IN ('cliente', 'agente inmobiliario', 'inmobiliaria',
                                       'embajador', 'socio bancario')
           -- Notario y sus variantes ("Notario Auxiliar"…): create-user ya clasifica con
           -- targetRoleName.includes("Notario"), asi que aqui se usa el mismo criterio
           -- amplio. Con la comparacion exacta, un rol nuevo "Notario Auxiliar" seria
           -- notario para create-user e interno para esta tabla.
           OR lower(btrim(nombre)) LIKE '%notario%'
           OR lower(btrim(nombre)) = 'banco'
           OR lower(btrim(nombre)) LIKE 'operador banco%'
           OR lower(btrim(nombre)) LIKE 'supervisor banco%'
         ) AS requiere
  FROM public.roles
) v
WHERE v.id = r.id
  AND r.requiere_confirmacion_email IS DISTINCT FROM v.requiere;

-- ─── 2. El alta ya no nace "confirmada" por descuido ──────────────────────────
-- El DEFAULT era TRUE: cualquier INSERT que omitiera la columna nacia confirmado
-- sin que nadie hubiera confirmado nada (bulk-create-agents, migrate-*, el trigger
-- de compradores). Ahora el DEFAULT es FALSE y un trigger sube a TRUE solo lo que
-- corresponde por rol, de modo que da igual si el INSERT trae la columna o no.
ALTER TABLE public.usuarios ALTER COLUMN email_confirmado SET DEFAULT false;

CREATE OR REPLACE FUNCTION public.usuarios_email_confirmado_por_rol()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  -- Rol interno -> siempre confirmado, aunque el INSERT diga lo contrario.
  -- Rol de portal -> se respeta lo que traiga el INSERT (create-user manda TRUE
  -- cuando la cuenta ya venia confirmada en Auth); si se omite, el DEFAULT es FALSE.
  IF NOT EXISTS (
    SELECT 1 FROM public.roles r
    WHERE r.id = NEW.rol_id AND r.requiere_confirmacion_email
  ) THEN
    NEW.email_confirmado := true;
  END IF;
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.usuarios_email_confirmado_por_rol() IS
  'BEFORE INSERT de usuarios: fuerza email_confirmado=true para roles internos. '
  'Solo INSERT: un cambio posterior de rol_id no reevalua la bandera a proposito, '
  'para no confirmar cuentas por el simple hecho de moverlas de rol.';

DROP TRIGGER IF EXISTS trg_usuarios_email_confirmado_por_rol ON public.usuarios;
CREATE TRIGGER trg_usuarios_email_confirmado_por_rol
  BEFORE INSERT ON public.usuarios
  FOR EACH ROW EXECUTE FUNCTION public.usuarios_email_confirmado_por_rol();

-- ─── 3. RPC para que las edge functions confirmen / des-confirmen de verdad ───
-- No se puede depender de auth.admin.updateUserById({email_confirm:false}) para
-- des-confirmar: el reset lo viene haciendo desde julio y las cuentas siguen
-- entrando con Temporal123!, con auth.users.email_confirmed_at intacto. Esta RPC
-- escribe las dos fuentes de una vez y de forma verificable.
CREATE OR REPLACE FUNCTION public.admin_set_email_confirmado(
  p_email      text,
  p_confirmado boolean
)
RETURNS TABLE(email text, email_confirmado boolean, auth_confirmado boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_email      text := lower(btrim(p_email));
  v_en_usuarios boolean;
  v_en_auth     boolean;
BEGIN
  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'admin_set_email_confirmado: p_email es obligatorio';
  END IF;

  -- Fail-closed. Los UPDATE de abajo no fallan cuando no hay a quien actualizar:
  -- afectan cero filas en silencio. Quien llama (el reset) daria por des-confirmada
  -- una cuenta que sigue confirmada, y acaba de dejarle la contrasena temporal
  -- publica: justo el escenario de toma de cuenta que este gate existe para cerrar.
  -- Alias obligatorio: la funcion declara una columna de salida llamada `email`, asi que
  -- `lower(email)` a secas es ambiguo entre esa variable y la columna de la tabla.
  SELECT EXISTS (SELECT 1 FROM public.usuarios uu WHERE lower(uu.email) = v_email),
         EXISTS (SELECT 1 FROM auth.users     au WHERE lower(au.email) = v_email)
    INTO v_en_usuarios, v_en_auth;

  IF NOT v_en_usuarios AND NOT v_en_auth THEN
    RAISE EXCEPTION 'admin_set_email_confirmado: no existe ninguna cuenta con el correo %', p_email
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Cuando el correo de auth.users y el de usuarios divergen (correo cambiado solo en
  -- un lado) tampoco vale seguir: se tocaria una fuente y la otra no.
  IF v_en_usuarios <> v_en_auth THEN
    RAISE EXCEPTION 'admin_set_email_confirmado: % existe en % pero no en la otra fuente; '
                    'no se puede sincronizar la confirmacion',
                    p_email, CASE WHEN v_en_usuarios THEN 'usuarios' ELSE 'auth.users' END
      USING ERRCODE = 'data_exception';
  END IF;

  UPDATE public.usuarios u
  SET email_confirmado    = p_confirmado,
      fecha_actualizacion = now()
  WHERE lower(u.email) = v_email
    AND u.email_confirmado IS DISTINCT FROM p_confirmado;

  -- Al pasar de NULL a un valor se dispara on_auth_user_email_confirmed, que manda
  -- el correo de credenciales. Es el comportamiento deseado cuando la confirmacion
  -- es real; por eso esta RPC no debe usarse para "confirmar en bloque".
  UPDATE auth.users a
  SET email_confirmed_at = CASE
        WHEN p_confirmado THEN COALESCE(a.email_confirmed_at, now())
        ELSE NULL
      END
  WHERE lower(a.email) = v_email
    AND (p_confirmado IS TRUE) <> (a.email_confirmed_at IS NOT NULL);

  RETURN QUERY
  SELECT u.email::text,
         u.email_confirmado,
         (a.email_confirmed_at IS NOT NULL)
  FROM public.usuarios u
  LEFT JOIN auth.users a ON a.id = u.auth_user_id
  WHERE lower(u.email) = v_email;
END;
$function$;

COMMENT ON FUNCTION public.admin_set_email_confirmado(text, boolean) IS
  'Sincroniza usuarios.email_confirmado y auth.users.email_confirmed_at. Solo '
  'service_role (la usan las edge functions de reset/reactivacion).';

REVOKE ALL ON FUNCTION public.admin_set_email_confirmado(text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_email_confirmado(text, boolean) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_email_confirmado(text, boolean) TO service_role;

-- ─── 4. mark_email_confirmed deja de mentir ───────────────────────────────────
-- Antes ponia email_confirmado=true por el solo hecho de que el usuario cargara su
-- perfil ("si puede entrar es que Auth lo confirmo"). Con el gate nuevo eso borraria
-- la bandera que justamente impide entrar. Ahora sincroniza desde Auth: sube el flag
-- unicamente si auth.users.email_confirmed_at existe de verdad.
CREATE OR REPLACE FUNCTION public.mark_email_confirmed()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  user_email text;
BEGIN
  user_email := current_setting('request.jwt.claims', true)::json->>'email';
  IF user_email IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.usuarios u
  SET email_confirmado    = true,
      fecha_actualizacion = now()
  FROM auth.users a
  WHERE lower(u.email)       = lower(user_email)
    AND a.id                 = u.auth_user_id
    AND a.email_confirmed_at IS NOT NULL
    AND u.email_confirmado   = false;
END;
$function$;

-- ─── 5. El perfil expone lo que el front necesita para gatear ─────────────────
-- Dos cambios:
--   a) Agrega email_confirmado y requiere_confirmacion_email.
--   b) Quita el filtro `AND u.activo = TRUE`. Ese filtro hacia que un usuario
--      desactivado recibiera CERO filas -> profile = null en el front -> el guard
--      `profile && !profile.activo` no se cumplia y la cuenta desactivada pasaba de
--      largo (fail-open). Devolviendo la fila con activo=false, el front puede
--      cerrar la puerta explicitamente.
-- Cambia el tipo de retorno, asi que hay que DROP + CREATE (no CREATE OR REPLACE).
DROP FUNCTION IF EXISTS public.get_current_user_profile();

CREATE FUNCTION public.get_current_user_profile()
RETURNS TABLE(
  email text, nombre text, rol_id integer, rol_nombre text,
  debe_cambiar_password boolean, id_persona integer, activo boolean,
  ver_todos_prospectos_compradores boolean, ver_filtros_avanzados_eliminados boolean,
  id_notario integer, notaria_nombre text, id_perfil_juridico bigint,
  perfil_juridico_nombre text, puede_impersonar boolean, administrar_app_clientes boolean,
  id_banco integer, banco_nombre text, apps jsonb, es_comprador boolean,
  email_confirmado boolean, requiere_confirmacion_email boolean
)
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
    )::BOOLEAN                               AS es_comprador,
    COALESCE(u.email_confirmado, false)::BOOLEAN            AS email_confirmado,
    COALESCE(r.requiere_confirmacion_email, false)::BOOLEAN AS requiere_confirmacion_email
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
  WHERE u.email = auth.email()
  LIMIT 1;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_current_user_profile() TO anon, authenticated, service_role;

-- ─── Validacion (post-deploy) ─────────────────────────────────────────────────
-- SELECT nombre, requiere_confirmacion_email FROM public.roles WHERE activo ORDER BY 2 DESC, 1;
-- SELECT column_default FROM information_schema.columns
--  WHERE table_name='usuarios' AND column_name='email_confirmado';   -- esperado: false
-- SELECT tgname FROM pg_trigger WHERE tgrelid='public.usuarios'::regclass AND NOT tgisinternal;
