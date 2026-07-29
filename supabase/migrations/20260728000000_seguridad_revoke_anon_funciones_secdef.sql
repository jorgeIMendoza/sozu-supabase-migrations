-- Seguridad · Lints anon_security_definer_function_executable (87 hallazgos)
-- Fecha: 2026-07-28
--
-- PROBLEMA
--   Supabase aplica ALTER DEFAULT PRIVILEGES que otorga EXECUTE a anon (y en 63 casos a
--   PUBLIC) sobre toda función nueva del rol postgres. Resultado en prod (tzmhgfjmddkfyffkkmto):
--   87 funciones SECURITY DEFINER de public son invocables con la clave anon, es decir sin
--   sesión. Entre ellas RPCs de dinero y de control de acceso: get_cuentas_cobranza_export,
--   get_pcobranza_relacion_pagos, get_kpis_alta_direccion, eliminar_pago, is_admin_user,
--   get_usuarios_by_emails, crear_activo_comercial, etc. SECURITY DEFINER ejecuta como
--   postgres (BYPASSRLS), así que el RLS de las tablas base no protege nada aquí.
--
-- CORRECCIÓN
--   REVOKE EXECUTE a anon y a PUBLIC en las 79 funciones SECURITY DEFINER de public que NO
--   forman parte de un flujo público declarado. authenticated y service_role conservan su
--   GRANT explícito (verificado read-only: las 79 lo tienen), así que la app no cambia.
--
-- FLUJOS PÚBLICOS QUE CONSERVAN anon (verificados contra sozu-admin):
--   landing_bottura_rpc / landing_daiku_rpc / landing_margot_rpc  → landings con clave anon
--   get_reservacion_publica, guardar_datos_reservacion            → src/pages/public/CapturaDatosReservaPage
--   get_apartado_status                                           → src/pages/public/ReservarPage
--   update_lead_datos                                             → src/pages/public/ApartarDirectoCapturePage
--   check_email_blocked_role                                      → src/pages/auth/Login (pre-login)
--
--   NOTA: check_email_blocked_role(p_email) permite enumeración de correos desde la clave
--   anon. Se conserva porque el login la necesita; el fix correcto es moverla a edge
--   function con rate limit. Pendiente aparte.
--
-- NO SE TOCA authenticated: el lint authenticated_security_definer_function_executable (86)
--   es inherente al patrón RPC de Supabase — revocarlo dejaría la app sin backend.
--
-- Idempotente (el loop solo actúa si queda el GRANT) y self-verifying (aborta si al final
-- alguna función fuera de la lista blanca conserva EXECUTE para anon).
-- Sin BEGIN/COMMIT (el CI envuelve en transacción).

DO $$
DECLARE
  r       record;
  n_func  int := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS firma
    FROM pg_proc p
    JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
    WHERE nsp.nspname = 'public'
      AND p.prosecdef
      AND p.proname NOT IN (
        'landing_bottura_rpc', 'landing_daiku_rpc', 'landing_margot_rpc',
        'get_reservacion_publica', 'guardar_datos_reservacion',
        'get_apartado_status', 'update_lead_datos', 'check_email_blocked_role'
      )
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
      -- Guarda: solo revocamos si authenticated tiene GRANT explícito propio, para no
      -- dejar la función sin ninguna vía de invocación desde la app.
      AND EXISTS (
        SELECT 1 FROM aclexplode(p.proacl) a
        WHERE a.grantee = 'authenticated'::regrole AND a.privilege_type = 'EXECUTE'
      )
    ORDER BY 1
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', r.firma);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.firma);
    n_func := n_func + 1;
  END LOOP;

  RAISE NOTICE 'REVOKE EXECUTE (anon, PUBLIC) aplicado a % funciones SECURITY DEFINER', n_func;
END $$;

-- Verificación: ninguna función SECURITY DEFINER de public fuera de la lista blanca puede
-- quedar ejecutable por anon.
DO $$
DECLARE
  v_restantes text;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.proname)
    INTO v_restantes
  FROM pg_proc p
  JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
  WHERE nsp.nspname = 'public'
    AND p.prosecdef
    AND p.proname NOT IN (
      'landing_bottura_rpc', 'landing_daiku_rpc', 'landing_margot_rpc',
      'get_reservacion_publica', 'guardar_datos_reservacion',
      'get_apartado_status', 'update_lead_datos', 'check_email_blocked_role'
    )
    AND has_function_privilege('anon', p.oid, 'EXECUTE');

  IF v_restantes IS NOT NULL THEN
    RAISE EXCEPTION 'Quedan funciones SECURITY DEFINER ejecutables por anon: %', v_restantes;
  END IF;

  RAISE NOTICE 'Verificación OK: sin funciones SECURITY DEFINER expuestas a anon fuera de la lista blanca';
END $$;
