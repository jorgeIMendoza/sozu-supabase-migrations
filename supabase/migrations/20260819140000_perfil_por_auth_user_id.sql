-- El perfil del usuario se resuelve por auth_user_id, no por el correo exacto.
-- Fecha: 2026-08-19
--
-- SÍNTOMA: el login con contraseña del Portal del Cliente (app Flutter sozu-cliente-app)
-- responde "Correo o contraseña incorrectos." con la contraseña correcta.
--
-- CAUSA: public.get_current_user_profile() resuelve al usuario con `u.email = auth.email()`
-- (comparación exacta). `auth.email()` sale del JWT y GoTrue guarda el correo SIEMPRE en
-- minúsculas; usuarios.email conserva la caja con la que se capturó. Cuando difieren la RPC
-- devuelve 0 filas -> el perfil llega null -> PortalAccess.allows(null) == false -> la app
-- hace signOut() ella misma. En auth.audit_log_entries queda la huella: cada `login` con
-- provider email va seguido de un `logout` 0.3-0.6 s después, y NO hay un solo registro de
-- credencial rechazada. La caja que se teclea en el formulario es irrelevante: GoTrue baja
-- el correo a minúsculas antes de buscar al usuario.
--
-- ORIGEN DEL DATO: el trigger create_client_user_on_comprador_insert() inserta
-- usuarios.email con el valor CRUDO de personas.email, mientras la EF create-client-user
-- sí normaliza (body?.email?.toLowerCase()?.trim()) y GoTrue también. La caja del alta
-- manual en personas es la que se cuela.
--
-- Nadie rompió el login: el `=` exacto viene del baseline (20260513000001) y lo arrastraron
-- las dos reescrituras posteriores (20260804030000 y 20260806000000, que es la definición
-- viva). Las correcciones de acceso de agosto arreglaron OTROS modos de falla de la misma
-- pantalla y ninguna tocó la resolución de identidad.
--
-- Verificado read-only en prod (tzmhgfjmddkfyffkkmto) el 2026-08-19:
--   · usuarios: 1,950 filas, 0 con auth_user_id nulo -> resolver por uuid cubre el 100%.
--   · usuarios con email <> lower(btrim(email)): 3, todas rol 23, activas y con uuid
--     (ASDS@gmail.com, CarlosArmin.CanasCarrillo@gmail.com, Juan.pablo@hotmail.com).
--   · personas con email sin normalizar: 31 -> al darlas de alta como comprador nacen
--     igual de rotas. Por eso también se normaliza en la escritura.
--   · Colisiones de lower(btrim(email)) en usuarios: 0 -> el fallback por correo no puede
--     devolver dos filas, y normalizar no choca con la PK.
--   · Caso reportado (Carlos Armin Cañas Carrillo): usuarios.email
--     'CarlosArmin.CanasCarrillo@gmail.com' vs auth.users.email
--     'carlosarmin.canascarrillo@gmail.com', mismo auth_user_id
--     4c925b75-33bc-47c0-941d-c07d7ec69774, rol 23, activo, email_confirmado.
--   · Ninguno de los 3 correos aparece en puestos_organizacionales ni en
--     personal_organizacional (las 2 FKs a usuarios.email SIN cascade). Juan.pablo tiene
--     1 fila en logs_actividad, que sí es ON UPDATE CASCADE.
--   · usuarios_bloquea_autoescalada() ya compara con lower() en los dos lados, así que un
--     cambio de solo-caja no la dispara.
--   · Super Administradores: 6, ninguno con el correo en mayúsculas hoy.
--
-- NO REPARA LOS DATOS YA ESCRITOS. Las 3 filas de usuarios y las 31 de personas se
-- normalizan con el DML que va aparte.

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Anclaje: confirmar que se reemplaza lo que se cree
-- ---------------------------------------------------------------------------
-- Las dos funciones se reemplazan enteras, así que hay que verificar contra la definición
-- VIVA (fuente de verdad) y no contra el archivo del repo, que puede tener drift. Se acepta
-- también el estado ya migrado para que re-aplicar no reviente el CI.
DO $anchor$
DECLARE
  v_nombre   text;
  v_def      text;
  v_objetivo text := 'u.email=auth.email()';
  v_migrado  text := 'u.auth_user_id=auth.uid()';
BEGIN
  FOR v_nombre, v_def IN
    -- Se comparan las definiciones SIN espacios: prod y el dev self-hosted no tienen por
    -- qué haber formateado igual el mismo predicado, y un anclaje sensible al espaciado
    -- tumbaría el CI en un entorno y no en el otro.
    SELECT p.proname, regexp_replace(pg_get_functiondef(p.oid), '\s+', '', 'g')
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND ((p.proname = 'get_current_user_profile' AND p.pronargs = 0)
        OR (p.proname = 'is_super_admin'           AND p.pronargs = 0))
  LOOP
    IF position(v_objetivo in v_def) = 0 AND position(v_migrado in v_def) = 0 THEN
      RAISE EXCEPTION
        'La definición viva de %() no resuelve la identidad ni por "%" ni por "%": hay drift sin revisar. Abortando para no pisarlo.',
        v_nombre, v_objetivo, v_migrado;
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'get_current_user_profile' AND p.pronargs = 0
  ) THEN
    RAISE EXCEPTION 'public.get_current_user_profile() no existe: esta migración la reemplaza, no la crea de cero.';
  END IF;
END
$anchor$;

-- ---------------------------------------------------------------------------
-- 1. El perfil se resuelve por auth_user_id
-- ---------------------------------------------------------------------------
-- El correo queda como fallback INSENSIBLE A LA CAJA, no se elimina: el perfil también se
-- pide desde el panel admin y quedan altas a medio hacer sin auth_user_id poblado. Con 0
-- colisiones de lower(email) el fallback no puede devolver dos filas; aun así el ORDER BY
-- prioriza la coincidencia por auth_user_id antes del LIMIT 1.
CREATE OR REPLACE FUNCTION public.get_current_user_profile()
 RETURNS TABLE(email text, nombre text, rol_id integer, rol_nombre text, debe_cambiar_password boolean, id_persona integer, activo boolean, ver_todos_prospectos_compradores boolean, ver_filtros_avanzados_eliminados boolean, id_notario integer, notaria_nombre text, id_perfil_juridico bigint, perfil_juridico_nombre text, puede_impersonar boolean, administrar_app_clientes boolean, id_banco integer, banco_nombre text, apps jsonb, es_comprador boolean, email_confirmado boolean, requiere_confirmacion_email boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  RETURN QUERY
  WITH yo AS (
    -- Una sola resolución de identidad, compartida por el perfil y por apps_rol: tenerla
    -- dos veces es cómo se desincronizaron el gate y el listado de apps.
    SELECT u.*
    FROM public.usuarios u
    WHERE (auth.uid() IS NOT NULL AND u.auth_user_id = auth.uid())
       OR (auth.email() IS NOT NULL AND lower(btrim(u.email)) = lower(btrim(auth.email())))
    ORDER BY (auth.uid() IS NOT NULL AND u.auth_user_id = auth.uid()) DESC
    LIMIT 1
  ),
  apps_rol AS (
    SELECT COALESCE(jsonb_agg(a.slug ORDER BY a.slug), '[]'::jsonb) AS slugs
    FROM yo u2
    JOIN public.roles_apps ra ON ra.id_rol = u2.rol_id AND ra.activo
    JOIN public.apps       a  ON a.id      = ra.id_app AND a.activo
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
  FROM yo u
  JOIN  public.roles    r ON r.id  = u.rol_id
  LEFT JOIN public.notarios n
         ON n.id     = u.id_notario
        AND n.activo = TRUE
  -- Se conserva el `=` exacto a propósito. Bajarlo a lower(btrim()) es un cambio de
  -- comportamiento ajeno al síntoma y hoy sería no-op (0 filas casan antes y 0 después,
  -- verificado en prod el 2026-08-19). El criterio se consolida en el doc 03.
  LEFT JOIN public.perfiles_juridicos j
         ON j.email  = u.email
        AND j.activo = TRUE
  LEFT JOIN public.bancos b
         ON b.id     = u.id_banco
  LIMIT 1;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. is_super_admin() sin argumentos: mismo `=` exacto contra auth.email()
-- ---------------------------------------------------------------------------
-- Un Super Administrador con el correo en mayúsculas perdía el bypass. La sobrecarga
-- is_super_admin(uuid) ya va por auth_user_id y NO se toca.
--
-- No amplía privilegios: con 0 colisiones de lower(btrim(email)) en usuarios, la variante
-- insensible a la caja no puede casar con una fila distinta de la del propio llamador.
CREATE OR REPLACE FUNCTION public.is_super_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM usuarios u
    JOIN roles r ON r.id = u.rol_id
    WHERE ((auth.uid() IS NOT NULL AND u.auth_user_id = auth.uid())
        OR (auth.email() IS NOT NULL AND lower(btrim(u.email)) = lower(btrim(auth.email()))))
      AND r.nombre = 'Super Administrador'
  )
$function$;

-- ---------------------------------------------------------------------------
-- 3. El alta del comprador deja de propagar la caja de captura
-- ---------------------------------------------------------------------------
-- La EF create-client-user y GoTrue ya normalizan; este trigger era el único que no.
-- Se reemplaza la definición viva completa, cambiando solo el manejo del correo.
CREATE OR REPLACE FUNCTION public.create_client_user_on_comprador_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_persona RECORD;
  v_email TEXT;
  v_existing_user_email TEXT;
  v_cliente_rol_id INTEGER;
  v_edge_function_url TEXT;
  v_service_role_key TEXT;
BEGIN
  -- Obtener datos de la persona
  SELECT id, nombre_legal, email INTO v_persona
  FROM personas
  WHERE id = NEW.id_persona;

  -- Correo normalizado: auth.users lo guarda en minúsculas y el perfil se resuelve
  -- contra él. Guardarlo con otra caja dejaba al cliente sin perfil.
  v_email := lower(btrim(v_persona.email));

  -- Si no tiene email válido, no podemos crear usuario
  IF v_email IS NULL OR v_email = '' THEN
    RETURN NEW;
  END IF;

  -- Obtener el ID del rol Cliente
  SELECT id INTO v_cliente_rol_id
  FROM roles
  WHERE nombre = 'Cliente' AND activo = true
  LIMIT 1;

  -- Si no existe el rol Cliente, salir
  IF v_cliente_rol_id IS NULL THEN
    RAISE WARNING 'Rol Cliente no encontrado';
    RETURN NEW;
  END IF;

  -- Verificar si ya existe usuario con ese email (la tabla usuarios usa email como
  -- identificador, no tiene columna id). Sin caja: si la fila vieja quedó con
  -- mayúsculas, insertar la normalizada duplicaría a la persona.
  SELECT email INTO v_existing_user_email
  FROM usuarios
  WHERE lower(btrim(email)) = v_email;

  -- Si no existe, crear el registro en usuarios
  IF v_existing_user_email IS NULL THEN
    INSERT INTO usuarios (email, nombre, rol_id, activo, debe_cambiar_password, id_persona)
    VALUES (v_email, v_persona.nombre_legal, v_cliente_rol_id, true, true, v_persona.id);
  END IF;

  -- URL de la edge function
  v_edge_function_url := 'https://tzmhgfjmddkfyffkkmto.supabase.co/functions/v1/create-client-user';

  -- Obtener el service role key desde Vault
  BEGIN
    SELECT decrypted_secret INTO v_service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'SUPABASE_SERVICE_ROLE_KEY'
    LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    v_service_role_key := NULL;
    RAISE WARNING 'No se pudo obtener SUPABASE_SERVICE_ROLE_KEY desde Vault: %', SQLERRM;
  END;

  -- Si tenemos el service role key, llamar a la edge function via pg_net
  IF v_service_role_key IS NOT NULL AND v_service_role_key != '' THEN
    PERFORM net.http_post(
      url := v_edge_function_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_service_role_key
      ),
      body := jsonb_build_object(
        'email', v_email,
        'nombre', v_persona.nombre_legal,
        'id_persona', v_persona.id
      )
    );
  ELSE
    RAISE WARNING 'SUPABASE_SERVICE_ROLE_KEY no configurado en Vault - no se puede crear usuario en auth.users';
  END IF;

  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Red de seguridad en la tabla
-- ---------------------------------------------------------------------------
-- Cualquier otra vía de escritura (panel admin, n8n, carga manual) queda normalizada sin
-- tener que encontrarla primero.
CREATE OR REPLACE FUNCTION public.usuarios_normaliza_email()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.email IS NOT NULL THEN
    NEW.email := lower(btrim(NEW.email));
  END IF;
  RETURN NEW;
END;
$function$;

-- Nombre con prefijo `a_` a propósito: los BEFORE del mismo evento corren en orden de
-- BYTES del nombre (strcmp, no la colación de la base) y este tiene que normalizar antes
-- de que otro trigger lea NEW.email. Hoy
-- conviven trg_usuarios_bloquea_autoescalada (BEFORE UPDATE) y
-- trg_usuarios_email_confirmado_por_rol (BEFORE INSERT); 'a_' ordena antes de los dos.
DROP TRIGGER IF EXISTS a_trg_usuarios_normaliza_email ON public.usuarios;
CREATE TRIGGER a_trg_usuarios_normaliza_email
  BEFORE INSERT OR UPDATE OF email ON public.usuarios
  FOR EACH ROW EXECUTE FUNCTION public.usuarios_normaliza_email();

COMMENT ON FUNCTION public.get_current_user_profile() IS
  'Perfil del usuario autenticado. Resuelve por auth_user_id, con fallback por correo insensible a la caja: auth.users.email vive en minúsculas y usuarios.email conserva la caja de captura (2026-08-19).';
COMMENT ON FUNCTION public.usuarios_normaliza_email() IS
  'Normaliza usuarios.email a lower(btrim()) en cada escritura: la PK de usuarios se compara contra auth.users.email, que GoTrue guarda en minúsculas.';

-- ---------------------------------------------------------------------------
-- 5. Auto-verificación
-- ---------------------------------------------------------------------------
DO $verify$
DECLARE
  v_pendientes text;
BEGIN
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname)
    INTO v_pendientes
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.pronargs = 0
    AND p.proname IN ('get_current_user_profile', 'is_super_admin')
    AND position('u.email=auth.email()' in regexp_replace(pg_get_functiondef(p.oid), '\s+', '', 'g')) > 0;

  IF v_pendientes IS NOT NULL THEN
    RAISE EXCEPTION 'Sigue habiendo comparación exacta contra auth.email() en: %', v_pendientes;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t
    WHERE t.tgrelid = 'public.usuarios'::regclass
      AND t.tgname  = 'a_trg_usuarios_normaliza_email'
      AND t.tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'a_trg_usuarios_normaliza_email no quedó armado sobre public.usuarios.';
  END IF;

  -- El prefijo `a_` solo sirve si de verdad ordena primero entre los BEFORE de la tabla.
  -- COLLATE "C" a propósito: Postgres ordena los triggers por bytes (strcmp), no por la
  -- colación de la base. Sin fijarla, el guard mediría una cosa y el motor haría otra, y
  -- además dev y prod no tienen por qué compartir datcollate.
  IF EXISTS (
    SELECT 1 FROM pg_trigger t
    WHERE t.tgrelid = 'public.usuarios'::regclass
      AND NOT t.tgisinternal
      AND t.tgname COLLATE "C" < 'a_trg_usuarios_normaliza_email' COLLATE "C"
  ) THEN
    RAISE EXCEPTION 'Hay un trigger en public.usuarios que ordena antes del normalizador: revisar el nombre.';
  END IF;

  -- Las 4 funciones del documento quedan con search_path fijado. get_current_user_profile
  -- venía sin él (proconfig nulo) siendo SECURITY DEFINER y alcanzable por anon: es el
  -- hallazgo function_search_path_mutable del linter, y se cierra aquí porque de todos
  -- modos se estaba reescribiendo la función.
  SELECT string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ' ORDER BY p.proname)
    INTO v_pendientes
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proconfig IS NULL
    AND ((p.proname = 'get_current_user_profile'               AND p.pronargs = 0)
      OR (p.proname = 'is_super_admin'                         AND p.pronargs = 0)
      OR (p.proname = 'create_client_user_on_comprador_insert')
      OR (p.proname = 'usuarios_normaliza_email'));

  IF v_pendientes IS NOT NULL THEN
    RAISE EXCEPTION 'Quedaron funciones sin search_path fijado: %', v_pendientes;
  END IF;
END
$verify$;

COMMIT;

-- ---------------------------------------------------------------------------
-- Rollback
-- ---------------------------------------------------------------------------
-- No hay DROP que revierta un CREATE OR REPLACE: para volver atrás se re-aplica la
-- definición previa, que es la de 20260806000000_confirmacion_email_por_rol.sql para
-- get_current_user_profile() y is_super_admin(), más:
--
--   DROP TRIGGER IF EXISTS a_trg_usuarios_normaliza_email ON public.usuarios;
--   DROP FUNCTION IF EXISTS public.usuarios_normaliza_email();
--
-- Revertir devuelve el bug: las 3 cuentas con el correo en mayúsculas vuelven a quedar
-- sin perfil y el Portal del Cliente vuelve a rechazarlas.
