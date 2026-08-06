-- Alinea las cuentas existentes con el modelo nuevo de confirmacion de correo.
--
-- Va DESPUES de 20260805050000 a proposito: necesita `roles.requiere_confirmacion_email`
-- para distinguir a quien es legitimo confirmar. En su primera version este archivo iba
-- primero (con timestamp 040000) y tenia dos defectos graves:
--
--   * Confirmaba en Auth a TODA cuenta con el flag en true, sin mirar el rol. En
--     produccion esa poblacion son sobre todo altas de bulk-create-agents y migrate-*,
--     que heredaron el viejo DEFAULT true sin que nadie confirmara nada: habria
--     habilitado su login con la contrasena publica Temporal123!.
--   * Se protegia con un tope de 25 filas que abortaba la migracion. Como el CI aplica
--     los archivos en orden, ese RAISE habria impedido tambien la migracion principal, y
--     las edge functions y el front — que ya toleran la columna ausente — habrian tratado
--     a todo el mundo como interno y confirmado. El modelo entero desaparecia sin un solo
--     error visible.
--
-- Ahora la direccion de cada arreglo se decide por el tipo de rol, no por un tope.
--
-- Idempotente y sin BEGIN/COMMIT (el CI envuelve cada archivo en su transaccion).

-- ─── A. Auth ya confirmo -> subir el flag ─────────────────────────────────────
-- Vale para cualquier rol: Auth es la fuente de verdad y esas cuentas ya entraban.
UPDATE public.usuarios u
SET email_confirmado    = true,
    fecha_actualizacion = now()
FROM auth.users a
WHERE a.id                 = u.auth_user_id
  AND a.email_confirmed_at IS NOT NULL
  AND u.email_confirmado   = false;

-- ─── B. Rol de PORTAL con el flag en true pero sin confirmar en Auth ──────────
-- Se corrige BAJANDO el flag, nunca confirmando. Son cuentas que nacieron
-- "confirmadas" por el viejo DEFAULT sin que nadie abriera un enlace; confirmarlas
-- seria darles acceso con la contrasena temporal publica. Quedan pendientes de
-- confirmar, que es exactamente lo que el modelo nuevo espera de ellas.
UPDATE public.usuarios u
SET email_confirmado    = false,
    fecha_actualizacion = now()
FROM public.roles r
LEFT JOIN LATERAL (SELECT 1) _ ON true
WHERE r.id = u.rol_id
  AND r.requiere_confirmacion_email
  AND u.email_confirmado = true
  AND NOT EXISTS (
    SELECT 1 FROM auth.users a
    WHERE a.id = u.auth_user_id AND a.email_confirmed_at IS NOT NULL
  );

-- ─── C. Rol INTERNO sin confirmar en Auth -> confirmarlo ──────────────────────
-- Un interno nace confirmado por definicion: no hay enlace que abrir ni portal que
-- gatear. Sin esto quedarian fuera por el gate nuevo.
--
-- El UPDATE dispara on_auth_user_email_confirmed -> handle_email_confirmation(), que
-- hace net.http_post a notificar-confirmacion-email y mandaria un correo de credenciales
-- a cada persona tocada. No se puede evitar por las vias normales: el rol del CI es
-- `postgres`, que no es owner de auth.users ("must be owner of table users") ni puede
-- cambiar session_replication_role ("permission denied to set parameter") — ambas
-- comprobadas contra dev. Lo que si puede es reemplazar la funcion del trigger, de la que
-- es owner: se guarda su definicion VIVA, se sustituye por un no-op, se hace el UPDATE y
-- se restaura tal cual. Todo en la misma transaccion, asi que un fallo revierte tambien la
-- funcion. La ventana en la que una confirmacion concurrente no mandaria su correo es de
-- milisegundos.
DO $mig$
DECLARE
  v_pendientes int;
  v_def        text;
BEGIN
  SELECT count(*) INTO v_pendientes
  FROM public.usuarios u
  JOIN public.roles    r ON r.id = u.rol_id
  JOIN auth.users      a ON a.id = u.auth_user_id
  WHERE NOT r.requiere_confirmacion_email
    AND a.email_confirmed_at IS NULL;

  IF v_pendientes = 0 THEN
    RAISE NOTICE 'C: no hay cuentas internas por confirmar en auth.users';
    RETURN;
  END IF;

  v_def := pg_get_functiondef('public.handle_email_confirmation()'::regprocedure);
  IF v_def IS NULL OR v_def = '' THEN
    RAISE EXCEPTION 'C: no se pudo leer la definicion de handle_email_confirmation(); '
                    'se aborta para no dejarla en no-op.';
  END IF;

  EXECUTE $noop$
    CREATE OR REPLACE FUNCTION public.handle_email_confirmation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $f$ BEGIN RETURN NEW; END $f$;
  $noop$;

  UPDATE auth.users a
  SET email_confirmed_at = now()
  FROM public.usuarios u
  JOIN public.roles    r ON r.id = u.rol_id
  WHERE u.auth_user_id       = a.id
    AND NOT r.requiere_confirmacion_email
    AND a.email_confirmed_at IS NULL;

  EXECUTE v_def;

  RAISE NOTICE 'C: % cuentas internas confirmadas en auth.users (sin disparar correos)', v_pendientes;
END $mig$;

-- ─── D. Cuentas sin fila en auth.users ────────────────────────────────────────
-- No se puede confirmar lo que no existe en Auth. El flag en true solo puede venir del
-- viejo DEFAULT, asi que se baja para que la UI no muestre como confirmada una cuenta que
-- ni siquiera puede iniciar sesion.
UPDATE public.usuarios u
SET email_confirmado    = false,
    fecha_actualizacion = now()
WHERE u.email_confirmado = true
  AND (
    u.auth_user_id IS NULL
    OR NOT EXISTS (SELECT 1 FROM auth.users a WHERE a.id = u.auth_user_id)
  );

-- ─── E. validacion.banco@sozu.com: cuenta de prueba sin Auth -> baja ──────────
-- Peticion explicita: ademas de dejar el flag coherente (lo hace el bloque D), se
-- desactiva. No tiene fila en auth.users, asi que nunca podria entrar.
UPDATE public.usuarios
SET activo              = false,
    fecha_actualizacion = now()
WHERE lower(email) = 'validacion.banco@sozu.com'
  AND activo IS DISTINCT FROM false;

-- ─── Validacion (post-deploy) ─────────────────────────────────────────────────
-- Debe devolver solo true/true y false/false:
-- SELECT u.email_confirmado AS col_usuarios,
--        (a.email_confirmed_at IS NOT NULL) AS auth_confirmado,
--        count(*)
-- FROM public.usuarios u
-- LEFT JOIN auth.users a ON a.id = u.auth_user_id
-- GROUP BY 1, 2 ORDER BY 3 DESC;
--
-- Y ningun interno debe quedar sin confirmar:
-- SELECT count(*) FROM public.usuarios u JOIN public.roles r ON r.id = u.rol_id
--  JOIN auth.users a ON a.id = u.auth_user_id
--  WHERE NOT r.requiere_confirmacion_email AND a.email_confirmed_at IS NULL;  -- esperado 0
