-- =============================================================================
-- Cerrar `anon` sobre el ledger de pagos STP
-- =============================================================================
-- `pagos_stp_raw` no tiene RLS y `anon` —el rol de la llave pública que va embebida en el
-- bundle del front— tiene DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE y UPDATE.
--
-- Con esa llave, que se saca del JS del navegador en treinta segundos, cualquiera puede:
--   · LEER los 12,707 depósitos: nombre del ordenante, RFC/CURP, cuentas de origen y
--     destino, montos y claves de rastreo. Es el bloque más grave y no requiere sesión.
--   · INSERTAR movimientos falsos en el ledger que leen la conciliación y el motor de
--     aplicación, también vía `insertar_pago_stp`, que es SECURITY INVOKER y hoy tiene
--     EXECUTE para PUBLIC.
--   · BORRAR filas o TRUNCAR la tabla entera.
--
-- ─── Verificado read-only el 2026-08-14 en prod (tzmhgfjmddkfyffkkmto) ───────
-- · Grants de `pagos_stp_raw`: anon, authenticated, service_role y postgres con los siete
--   privilegios; georgia_mcp_ro y georgia_readonly con SELECT. RLS apagada, 0 policies.
-- · `insertar_pago_stp` con ACL {=X/postgres, postgres, anon, authenticated, service_role}
--   — el `=X` es PUBLIC. prosecdef = false (INVOKER).
-- · `service_role` tiene rolbypassrls = true. `authenticated`, `anon`, georgia_mcp_ro y
--   georgia_readonly NO.
-- · pg_stat_statements, con ventana de 183 días (reset 2026-02-12):
--       service_role  2,369 llamadas a insertar_pago_stp
--       postgres          1
--       anon              0
--       authenticated     0
--   El conector de STP entra con service_role. Revocarle el EXECUTE a anon y a PUBLIC no
--   toca el cobro.
-- · La EF `generar-recibo-pago` lee la tabla, pero con SERVICE_ROLE_KEY → BYPASSRLS.
-- · El panel la usa con sesión (`authenticated`) en CINCO lugares, no tres:
--   TransferPaymentDialog, TransferirEntreComisionesDialog, Propiedades (rastreo de
--   depósitos), AddManualPaymentDialog (borra la fila al capturar el pago a mano) y
--   portal-escrituracion/PldDashboard (PLD/antilavado). Ese acceso se conserva.
--
-- ─── Dos cosas que el documento no contemplaba ───────────────────────────────
-- 1. TRUNCATE se salta RLS. Encender policies no lo detiene: hay que revocar el privilegio.
--    Se revoca también a `authenticated`, porque ningún flujo del panel trunca la tabla.
-- 2. `georgia_mcp_ro` y `georgia_readonly` tienen SELECT y NO tienen BYPASSRLS. Encender
--    RLS con policies solo para `authenticated` los deja sin lectura. En esta base es
--    convención darles su policy explícita cuando la tabla tiene RLS (`georgia_mcp_ro_select`
--    existe en decenas de tablas), así que se replica aquí. Sin esto, esta migración rompe
--    los roles de solo lectura de analítica.
--
-- Orden: primero REVOKE, luego RLS + policies. Al revés queda una ventana con la tabla
-- abierta.
--
-- `anon` no pierde nada que use: el flujo público de la oferta consulta el estado del
-- apartado con `get_apartado_pagos`, que es SECURITY DEFINER con gate por token y nunca
-- toca esta tabla directo.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §0. Guards
-- -----------------------------------------------------------------------------
DO $guard$
BEGIN
  IF to_regclass('public.pagos_stp_raw') IS NULL THEN
    RAISE EXCEPTION 'No existe public.pagos_stp_raw';
  END IF;

  IF to_regprocedure('public.insertar_pago_stp(text,numeric,text,text,text,text,text,text,text,text,text,text,text,text,text,date,text,text,text,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'insertar_pago_stp no existe con la firma auditada; revisar antes de revocar';
  END IF;

  -- Si el conector cambiara de credencial, revocar aquí tumbaría el cobro.
  IF NOT has_function_privilege('service_role',
       'public.insertar_pago_stp(text,numeric,text,text,text,text,text,text,text,text,text,text,text,text,text,date,text,text,text,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role no puede ejecutar insertar_pago_stp; NO revocar sin revisar quién la llama';
  END IF;
END;
$guard$;

-- -----------------------------------------------------------------------------
-- §A. Quitarle a anon (y a PUBLIC) todo acceso al ledger
-- -----------------------------------------------------------------------------
REVOKE ALL ON TABLE public.pagos_stp_raw FROM anon;
REVOKE ALL ON TABLE public.pagos_stp_raw FROM PUBLIC;

-- TRUNCATE se salta RLS: se revoca aunque después se enciendan las policies.
REVOKE TRUNCATE ON TABLE public.pagos_stp_raw FROM authenticated;

-- La RPC que escribe en el ledger. El conector entra con service_role (2,369 llamadas en
-- 183 días), así que esto no toca el cobro.
REVOKE EXECUTE ON FUNCTION public.insertar_pago_stp(
  text, numeric, text, text, text, text, text, text, text, text, text, text,
  text, text, text, date, text, text, text, text, text, text, text
) FROM anon, PUBLIC;

-- -----------------------------------------------------------------------------
-- §B. RLS encendido. service_role tiene BYPASSRLS: el conector sigue igual.
--     Las policies solo reponen el acceso que el panel ya tiene con sesión.
-- -----------------------------------------------------------------------------
ALTER TABLE public.pagos_stp_raw ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pagos_stp_raw_authenticated_select ON public.pagos_stp_raw;
CREATE POLICY pagos_stp_raw_authenticated_select
  ON public.pagos_stp_raw FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS pagos_stp_raw_authenticated_write ON public.pagos_stp_raw;
CREATE POLICY pagos_stp_raw_authenticated_write
  ON public.pagos_stp_raw FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Los roles de solo lectura: sin esto pierden el SELECT que sí tienen otorgado.
-- Van condicionados a que el rol exista: `georgia_mcp_ro` y `georgia_readonly` están en
-- prod pero NO en el dev self-hosted, y `CREATE POLICY ... TO <rol inexistente>` aborta
-- con 42704 y tumba el deploy entero.
DO $georgia$
DECLARE
  v_rol text;
BEGIN
  FOREACH v_rol IN ARRAY ARRAY['georgia_mcp_ro', 'georgia_readonly']
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_rol) THEN
      RAISE NOTICE 'Rol % no existe en este entorno, se omite su policy de lectura', v_rol;
      CONTINUE;
    END IF;

    EXECUTE format('DROP POLICY IF EXISTS %I ON public.pagos_stp_raw', v_rol || '_select');
    EXECUTE format(
      'CREATE POLICY %I ON public.pagos_stp_raw FOR SELECT TO %I USING (true)',
      v_rol || '_select', v_rol
    );
    RAISE NOTICE 'Policy de lectura creada para %', v_rol;
  END LOOP;
END;
$georgia$;

COMMENT ON TABLE public.pagos_stp_raw IS
  'Ledger crudo de depósitos STP. Lo escribe el conector con service_role vía '
  'insertar_pago_stp. anon no tiene acceso: la oferta pública consulta su estado por '
  'get_apartado_pagos (SECURITY DEFINER con gate por token).';

-- -----------------------------------------------------------------------------
-- §C. Self-verifying
-- -----------------------------------------------------------------------------
DO $check$
DECLARE
  v_privs text;
BEGIN
  IF has_table_privilege('anon', 'public.pagos_stp_raw', 'SELECT')
     OR has_table_privilege('anon', 'public.pagos_stp_raw', 'INSERT') THEN
    RAISE EXCEPTION 'anon conserva acceso a pagos_stp_raw';
  END IF;

  IF has_function_privilege('anon',
       'public.insertar_pago_stp(text,numeric,text,text,text,text,text,text,text,text,text,text,text,text,text,date,text,text,text,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon conserva EXECUTE sobre insertar_pago_stp';
  END IF;

  IF has_table_privilege('authenticated', 'public.pagos_stp_raw', 'TRUNCATE') THEN
    RAISE EXCEPTION 'authenticated conserva TRUNCATE, que se salta RLS';
  END IF;

  -- Lo que el panel sí necesita
  SELECT string_agg(p, ',' ORDER BY p) INTO v_privs
  FROM unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE']) p
  WHERE NOT has_table_privilege('authenticated', 'public.pagos_stp_raw', p);

  IF v_privs IS NOT NULL THEN
    RAISE EXCEPTION 'authenticated perdió privilegios que usa el panel: %', v_privs;
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.pagos_stp_raw'::regclass) THEN
    RAISE EXCEPTION 'RLS no quedó encendida en pagos_stp_raw';
  END IF;

  IF NOT has_function_privilege('service_role',
       'public.insertar_pago_stp(text,numeric,text,text,text,text,text,text,text,text,text,text,text,text,text,date,text,text,text,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role perdió el EXECUTE; el conector de STP quedaría roto';
  END IF;
END;
$check$;

COMMIT;

-- =============================================================================
-- Pendiente que esta migración NO cierra
-- =============================================================================
-- `authenticated` conserva EXECUTE sobre `insertar_pago_stp`. Eso incluye a los 624
-- clientes con login del Portal Cliente, que podrían inyectar un depósito en el ledger.
-- pg_stat_statements no registra NI UNA llamada desde authenticated en 183 días, así que
-- revocarlo parece seguro, pero es el camino del dinero y se deja fuera a propósito:
--   REVOKE EXECUTE ON FUNCTION public.insertar_pago_stp(...) FROM authenticated;
--
-- Y `pagos_stp_raw` no es la única: el censo de tablas sin RLS con grants completos a anon
-- está en auth-accesos/06_estandar_rls_base.
-- =============================================================================
-- Validación (read-only, correr después del deploy)
-- =============================================================================
-- -- anon sin privilegios (esperado: 0 filas)
-- SELECT grantee, privilege_type FROM information_schema.role_table_grants
-- WHERE table_schema='public' AND table_name='pagos_stp_raw' AND grantee IN ('anon','PUBLIC');
--
-- -- authenticated conserva lo del panel, sin TRUNCATE
-- SELECT string_agg(privilege_type, ',' ORDER BY privilege_type)
-- FROM information_schema.role_table_grants
-- WHERE table_schema='public' AND table_name='pagos_stp_raw' AND grantee='authenticated';
-- -- esperado: DELETE,INSERT,REFERENCES,SELECT,TRIGGER,UPDATE
--
-- -- RLS y sus policies
-- SELECT c.relrowsecurity,
--        (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='pagos_stp_raw')
-- FROM pg_class c WHERE c.oid='public.pagos_stp_raw'::regclass;
-- -- esperado: true y 4 en prod; true y 2 en dev, donde los roles georgia no existen
--
-- -- Los roles de solo lectura siguen leyendo
-- SET LOCAL ROLE georgia_mcp_ro; SELECT count(*) FROM public.pagos_stp_raw; RESET ROLE;
--
-- UAT como anon (dentro de BEGIN ... ROLLBACK):
--   SET LOCAL ROLE anon;
--   SELECT count(*) FROM public.pagos_stp_raw;   -- 42501 permission denied
--   SELECT public.insertar_pago_stp(...);        -- 42501 permission denied
--   SELECT public.get_apartado_pagos(<oferta>, '<token>') ->> 'ok';  -- true (vía legítima)
--   RESET ROLE;
-- =============================================================================
