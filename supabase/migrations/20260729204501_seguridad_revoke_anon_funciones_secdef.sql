-- Seguridad · Lints anon_security_definer_function_executable
-- Fecha: 2026-07-28
--
-- PROBLEMA
--   Supabase aplica ALTER DEFAULT PRIVILEGES que otorga EXECUTE a anon (y en la mayoría de
--   los casos también a PUBLIC) sobre toda función nueva del rol postgres. Resultado en prod
--   (tzmhgfjmddkfyffkkmto): las funciones SECURITY DEFINER de public son invocables con la
--   clave anon, es decir sin sesión. Entre ellas RPCs de dinero y de control de acceso:
--   get_cuentas_cobranza_export, get_pcobranza_relacion_pagos, get_kpis_alta_direccion,
--   eliminar_pago, is_admin_user, get_usuarios_by_emails, crear_activo_comercial, etc.
--   SECURITY DEFINER ejecuta como postgres (BYPASSRLS), así que el RLS de las tablas base
--   no protege nada aquí.
--
-- CORRECCIÓN
--   REVOKE EXECUTE a anon y a PUBLIC en las funciones SECURITY DEFINER de public que NO
--   forman parte de un flujo público declarado. authenticated y service_role conservan su
--   GRANT explícito, así que la app no cambia. El conjunto se calcula en vivo (no hay una
--   lista fija de N funciones): al escribir esto eran 81, y el número crece con cada RPC
--   nueva que se despliega.
--
-- FLUJOS PÚBLICOS QUE CONSERVAN anon (verificados contra sozu-admin)
--   Ver la tabla _rpc_publicas más abajo: cada fila cita dónde se consume.
--
--   GUARDA AUTOMÁTICA: los 6 flujos públicos con token comparten un parámetro `p_token uuid`.
--   Antes de revocar nada, la migración aborta si encuentra una función SECURITY DEFINER con
--   un parámetro `p_token` que no esté declarada en _rpc_publicas. Así una RPC pública nueva
--   no se rompe en silencio: obliga a que alguien decida y la agregue a la lista.
--
--   Esta guarda existe porque el primer intento de esta migración iba a revocar
--   get_cliente_estado_oferta y guardar_csf_oferta, desplegadas después del análisis inicial,
--   lo que habría roto el flujo público de apartado directo (ApartarDirectoCapturePage).
--
--   NOTA: check_email_blocked_role(p_email) permite enumeración de correos desde la clave
--   anon. Se conserva porque el login la necesita; el fix correcto es moverla a edge
--   function con rate limit. Pendiente aparte.
--
-- NO SE TOCA authenticated: el lint authenticated_security_definer_function_executable es
--   inherente al patrón RPC de Supabase — revocarlo dejaría la app sin backend.
--
-- Idempotente (el loop solo actúa si queda el GRANT) y self-verifying.
-- Sin BEGIN/COMMIT (el CI envuelve en transacción).

-- Sin ON COMMIT DROP: así funciona igual en transacción o en autocommit. Se elimina al final.
DROP TABLE IF EXISTS _rpc_publicas;
CREATE TEMP TABLE _rpc_publicas (proname text PRIMARY KEY, consumo text NOT NULL);

INSERT INTO _rpc_publicas (proname, consumo) VALUES
  ('landing_bottura_rpc',        'landing bottura-web, clave anon'),
  ('landing_daiku_rpc',          'landing daiku, clave anon'),
  ('landing_margot_rpc',         'landing margot, clave anon'),
  ('get_reservacion_publica',    'src/lib/offers/reservation-token.ts + pages/public/CapturaDatosReservaPage'),
  ('guardar_datos_reservacion',  'pages/public/CapturaDatosReservaPage'),
  ('get_apartado_status',        'pages/public/ReservarPage'),
  ('update_lead_datos',          'pages/public/ApartarDirectoCapturePage'),
  ('get_cliente_estado_oferta',  'pages/public/ApartarDirectoCapturePage'),
  ('guardar_csf_oferta',         'pages/public/ApartarDirectoCapturePage'),
  ('check_email_blocked_role',   'pages/auth/Login, pre-login'),
  -- Helpers de autorización invocados por policies TO public/anon. Anon los EVALÚA al leer
  -- tablas del sitio público (p.ej. oferta digital lee entidades_relacionadas); si se revoca
  -- su EXECUTE, anon truena con "permission denied for function" y cae el flujo público.
  -- Son predicados de authz, no vuelcan datos (a diferencia de los get_*_export que sí se revocan).
  ('is_admin_user',              'policy TO public: entidades_relacionadas/usuarios/avisos'),
  ('is_super_admin',             'policy TO public: usuarios/avisos/aviso_triggers (2 sobrecargas)'),
  ('can_view_all_prospects',     'policy TO public: entidades_relacionadas.select'),
  ('can_access_agent_owned_lead','policy TO public: entidades_relacionadas.select'),
  ('user_has_role',              'helper authz (familia user_has_*)'),
  ('user_has_permission',        'helper authz (familia user_has_*)'),
  ('user_has_internal_role',     'helper authz (familia user_has_*)'),
  ('current_es_super_admin',     'helper authz usado por RLS'),
  ('current_puede_impersonar',   'helper authz usado por RLS'),
  ('current_persona_id',         'helper authz usado por RLS (anon en oferta pública)'),
  ('current_socio_bancario_id',  'helper RLS socio bancario (policies passthrough a anon)'),
  ('socio_desarrollos_activos',  'helper RLS socio bancario'),
  ('socio_tiene_proyecto',       'helper RLS socio bancario'),
  ('socio_tiene_edificio',       'helper RLS socio bancario'),
  ('socio_tiene_propiedad',      'helper RLS socio bancario'),
  ('socio_tiene_cuenta',         'helper RLS socio bancario');

-- ════════════════════════════════════════════════════════════════════════════════════
-- Guarda: ninguna RPC con `p_token` puede quedar fuera de la lista de flujos públicos.
-- ════════════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_faltantes text;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, E'\n  - ' ORDER BY p.proname)
    INTO v_faltantes
  FROM pg_proc p
  JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
  WHERE nsp.nspname = 'public'
    AND p.prosecdef
    AND p.proargnames IS NOT NULL
    AND 'p_token' = ANY(p.proargnames)
    AND p.proname NOT IN (SELECT proname FROM _rpc_publicas);

  IF v_faltantes IS NOT NULL THEN
    RAISE EXCEPTION E'Hay RPCs con parámetro p_token fuera de _rpc_publicas:\n  - %\n\nSon flujos públicos con token. Revisar si deben conservar anon y agregarlas a la lista, o quitarles el p_token si no lo son.', v_faltantes;
  END IF;

  RAISE NOTICE 'Guarda OK: las % RPCs con p_token están declaradas como flujo público',
    (SELECT count(*) FROM pg_proc p JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
     WHERE nsp.nspname='public' AND p.prosecdef AND p.proargnames IS NOT NULL
       AND 'p_token' = ANY(p.proargnames));
END $$;

-- ════════════════════════════════════════════════════════════════════════════════════
-- REVOKE
-- ════════════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  r         record;
  n_func    int := 0;
  n_ajenas  int := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS firma,
           pg_get_userbyid(p.proowner) AS duenio,
           pg_has_role(current_user, p.proowner, 'USAGE') AS podemos_revocar
    FROM pg_proc p
    JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
    WHERE nsp.nspname = 'public'
      AND p.prosecdef
      AND p.proname NOT IN (SELECT proname FROM _rpc_publicas)
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
      -- Guarda: solo revocamos si authenticated tiene GRANT explícito propio, para no
      -- dejar la función sin ninguna vía de invocación desde la app.
      AND EXISTS (
        SELECT 1 FROM aclexplode(p.proacl) a
        WHERE a.grantee = 'authenticated'::regrole AND a.privilege_type = 'EXECUTE'
      )
    ORDER BY 1
  LOOP
    -- Sin poder actuar como el dueño, REVOKE es un no-op silencioso (WARNING 01006).
    -- Se cuenta aparte en lugar de fingir que se aplicó.
    IF NOT r.podemos_revocar THEN
      n_ajenas := n_ajenas + 1;
      RAISE NOTICE 'omitida %: dueño % no alcanzable desde current_user %',
        r.firma, r.duenio, current_user;
      CONTINUE;
    END IF;

    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', r.firma);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.firma);
    n_func := n_func + 1;
  END LOOP;

  RAISE NOTICE 'REVOKE EXECUTE (anon, PUBLIC) aplicado a % funciones SECURITY DEFINER (% omitidas por dueño ajeno)',
    n_func, n_ajenas;
END $$;

-- ════════════════════════════════════════════════════════════════════════════════════
-- Verificación
-- ════════════════════════════════════════════════════════════════════════════════════
-- `has_function_privilege('anon', …)` sigue la herencia por membresía de roles, así que un
-- residuo no siempre es un fallo de esta migración. Se separan dos casos:
--
--   BLOQUEANTE — sobrevive un GRANT directo a anon o a PUBLIC en el ACL y current_user
--     puede actuar como dueño. El REVOKE debió funcionar y no lo hizo → aborta.
--
--   AVISO — anon conserva el privilegio pero no hay GRANT directo que revocar (lo hereda por
--     membresía de rol), o la función pertenece a un dueño fuera del alcance de current_user
--     (WARNING 01006: "no privileges could be revoked"). Ninguno se arregla con un REVOKE
--     por función: hace falta `REVOKE <rol> FROM anon` o cambiar el dueño. Se reporta con
--     detalle y NO se aborta, para no bloquear el resto del fix.
--
-- Caso conocido: en el dev self-hosted, public.user_has_role(text,integer) cae en AVISO —
-- el REVOKE sale con WARNING 01006 y anon conserva el EXECUTE por otra vía.
DO $$
DECLARE
  r            record;
  v_bloqueante text := '';
  v_aviso      text := '';
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure::text AS firma,
           pg_get_userbyid(p.proowner) AS duenio,
           pg_has_role(current_user, p.proowner, 'USAGE') AS podemos_revocar,
           EXISTS (
             SELECT 1 FROM aclexplode(p.proacl) a
             WHERE a.privilege_type = 'EXECUTE'
               AND (a.grantee = 'anon'::regrole OR a.grantee = 0)   -- 0 = PUBLIC
           ) AS grant_directo,
           COALESCE((
             SELECT string_agg(
                      CASE WHEN a.grantee = 0 THEN 'PUBLIC'
                           ELSE a.grantee::regrole::text END, '/' ORDER BY 1)
             FROM aclexplode(p.proacl) a WHERE a.privilege_type = 'EXECUTE'
           ), '(acl nula)') AS grantees
    FROM pg_proc p
    JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
    WHERE nsp.nspname = 'public'
      AND p.prosecdef
      AND p.proname NOT IN (SELECT proname FROM _rpc_publicas)
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
    ORDER BY 1
  LOOP
    IF r.grant_directo AND r.podemos_revocar THEN
      v_bloqueante := v_bloqueante ||
        format(E'\n  - %s · dueño %s · grants EXECUTE: %s', r.firma, r.duenio, r.grantees);
    ELSE
      v_aviso := v_aviso ||
        format(E'\n  - %s · dueño %s · grant directo a anon/PUBLIC: %s · alcanzable por %s: %s · grants EXECUTE: %s',
               r.firma, r.duenio, r.grant_directo, current_user, r.podemos_revocar, r.grantees);
    END IF;
  END LOOP;

  IF v_bloqueante <> '' THEN
    RAISE EXCEPTION 'El REVOKE no surtió efecto en funciones que sí podíamos modificar:%',
      v_bloqueante;
  END IF;

  IF v_aviso <> '' THEN
    RAISE WARNING 'anon conserva EXECUTE en funciones que este REVOKE no puede tocar. Requieren intervención manual (REVOKE <rol> FROM anon, o cambio de dueño):%',
      v_aviso;
  ELSE
    RAISE NOTICE 'Verificación OK: sin funciones SECURITY DEFINER expuestas a anon fuera de los flujos públicos declarados';
  END IF;
END $$;

DROP TABLE IF EXISTS _rpc_publicas;
