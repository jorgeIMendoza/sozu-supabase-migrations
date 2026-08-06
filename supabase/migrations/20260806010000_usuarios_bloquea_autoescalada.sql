-- Impide que un usuario se modifique a si mismo las columnas que deciden su acceso.
--
-- ─── El agujero ───────────────────────────────────────────────────────────────
-- La policy `Users can update own record` sobre public.usuarios permite UPDATE de la
-- propia fila (`email = auth.jwt()->>'email' OR auth_user_id = auth.uid()`) SIN acotar
-- columnas, y el rol `authenticated` tiene privilegio de UPDATE sobre `rol_id`, `activo`
-- y `email_confirmado` (verificado con has_column_privilege en dev). Con eso, desde la
-- consola del navegador:
--
--   supabase.from('usuarios').update({ rol_id: 1 }).eq('email', <su propio correo>)
--
-- convierte a cualquier cliente en Super Administrador. Y en el modelo de confirmacion
-- de correo (20260805050000) bastaria `{ email_confirmado: true }` para saltarse el gate
-- del portal, o `{ activo: true }` para revertir una baja.
--
-- ─── Por que un trigger y no RLS ──────────────────────────────────────────────
-- Las policies de Postgres no distinguen columnas, asi que no se puede expresar "puedes
-- editar tu fila, menos estas tres columnas". La otra via, REVOKE UPDATE(columna) FROM
-- authenticated, romperia los flujos legitimos: el panel da de alta y de baja usuarios
-- desde el cliente con el JWT del admin, no con service_role.
--
-- ─── Por que no rompe nada ────────────────────────────────────────────────────
-- Solo bloquea cuando la fila modificada ES la del propio llamante. Las demas policies de
-- UPDATE ya operan sobre filas ajenas: `Super admins can update users`,
-- `Inmobiliaria can update own agents` (is_inmob_agent_owner) y `Bank supervisors can
-- update own bank users`, que incluso excluye la propia fila de forma explicita
-- (auth_user_id IS DISTINCT FROM auth.uid()).
--
-- Las funciones SECURITY DEFINER siguen pasando: dentro de ellas current_user es el owner
-- (postgres), no `authenticated`. Eso mantiene vivas mark_email_confirmed(),
-- mark_password_changed() y admin_set_email_confirmado(), que si tienen que escribir estas
-- columnas sobre la fila del propio usuario. Las edge functions usan service_role, tambien
-- exento.
--
-- Idempotente y sin BEGIN/COMMIT (el CI envuelve cada archivo en su transaccion).

-- SECURITY INVOKER (o sea, sin SECURITY DEFINER) a proposito, y es la clave de todo el
-- mecanismo: dentro de una funcion SECURITY DEFINER `current_user` pasa a ser el owner,
-- asi que si este trigger fuese DEFINER veria siempre `postgres` y no bloquearia nada
-- (comprobado en dev: los tres UPDATE de escalada pasaban). Siendo INVOKER, `current_user`
-- es `authenticated` cuando el UPDATE viene de PostgREST, y `postgres` cuando viene de
-- dentro de una funcion SECURITY DEFINER — que es justo la exencion que se busca.
-- No necesita privilegios extra: solo lee OLD/NEW y los claims del JWT.
CREATE OR REPLACE FUNCTION public.usuarios_bloquea_autoescalada()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid       uuid := auth.uid();
  v_jwt_email text := auth.email();
  v_es_propia boolean;
BEGIN
  -- service_role, el owner y las llamadas internas (SECURITY DEFINER) quedan fuera.
  IF current_user IN ('postgres', 'supabase_admin', 'service_role', 'supabase_auth_admin') THEN
    RETURN NEW;
  END IF;

  v_es_propia :=
       (v_uid IS NOT NULL AND OLD.auth_user_id IS NOT DISTINCT FROM v_uid)
    OR (v_jwt_email IS NOT NULL AND lower(OLD.email) = lower(v_jwt_email));

  IF NOT v_es_propia THEN
    RETURN NEW;
  END IF;

  IF NEW.rol_id           IS DISTINCT FROM OLD.rol_id
     OR NEW.activo           IS DISTINCT FROM OLD.activo
     OR NEW.email_confirmado IS DISTINCT FROM OLD.email_confirmado
     OR NEW.id_banco         IS DISTINCT FROM OLD.id_banco
     OR NEW.id_notario       IS DISTINCT FROM OLD.id_notario
     OR NEW.auth_user_id     IS DISTINCT FROM OLD.auth_user_id
     OR lower(NEW.email)     IS DISTINCT FROM lower(OLD.email)
  THEN
    RAISE EXCEPTION
      'No puedes modificar tu propio rol, estado de cuenta ni la confirmacion de tu correo'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.usuarios_bloquea_autoescalada() IS
  'BEFORE UPDATE de usuarios: nadie puede auto-asignarse rol, activo, email_confirmado, '
  'banco, notaria, auth_user_id ni cambiarse el correo. Exentos service_role y las '
  'funciones SECURITY DEFINER (current_user = owner).';

DROP TRIGGER IF EXISTS trg_usuarios_bloquea_autoescalada ON public.usuarios;
CREATE TRIGGER trg_usuarios_bloquea_autoescalada
  BEFORE UPDATE ON public.usuarios
  FOR EACH ROW EXECUTE FUNCTION public.usuarios_bloquea_autoescalada();

-- ─── Validacion (post-deploy) ─────────────────────────────────────────────────
-- Con el JWT de un usuario cualquiera, esto debe responder 42501:
--   UPDATE public.usuarios SET rol_id = 1 WHERE email = '<su propio correo>';
-- Y esto debe seguir funcionando (fila ajena, con un JWT de Super Admin):
--   UPDATE public.usuarios SET activo = false WHERE email = '<otro correo>';
