-- Seguridad · Fase 0 — Contención inmediata (auditoría RLS/PostgREST 2026-07-27)
-- Fecha: 2026-07-27
--
-- Cierra los vectores de MÁS impacto y MENOR riesgo de ruptura de la auditoría, sin tocar
-- todavía los grants amplios de `anon` (el sitio público depende de ellos; el allowlist de
-- accesos anónimos legítimos está pendiente — §9/§10). NO incluye Fases 1-5 (RLS masivo,
-- reemplazo de policies passthrough, DROP de tablas basura): requieren diseño + allowlist +
-- aprobación explícita (algunas destructivas).
--
-- 0.1 REVOKE execute_safe_query de anon/authenticated/PUBLIC (lectura arbitraria SECURITY
--     DEFINER de postgres) → solo service_role (la usa ai-database-query).
-- 0.2 REVOKE de funciones que MUTAN datos, callable hoy por anon/authenticated (las llaman
--     n8n/edge con service_role).
-- 0.3 security_invoker=on en 3 vistas expuestas.
-- 0.4 REVOKE del API de las funciones de trigger, respaldos olvidados y helpers de
--     autorización (las triggers las invoca el motor; los helpers se evalúan como owner
--     dentro de las policies) → no las necesita el cliente.
-- 0.5 search_path fijo en funciones public/private que hoy lo tienen mutable.
-- 0-bis (Storage): quitar el listado del bucket `documentos` — GUARDADO: en self-hosted el
--     rol de migración no es owner de storage.objects (42501); se omite con NOTICE y se
--     aplica manual en el dashboard/como storage_admin donde no haya privilegio.
--
-- Todo por loops dinámicos con guarda por sentencia: objetos ausentes o sin privilegio en un
-- ambiente (p.ej. dev) NO abortan la migración. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

-- ================================================================
-- 0.1 execute_safe_query → solo service_role
-- ================================================================
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public' AND p.proname = 'execute_safe_query'
  LOOP
    BEGIN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
      EXECUTE format('GRANT  EXECUTE ON FUNCTION %s TO service_role', f.sig);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '0.1 omitido % (%)', f.sig, SQLERRM;
    END;
  END LOOP;
END $$;

-- ================================================================
-- 0.2 Funciones que MUTAN datos → solo service_role
-- ================================================================
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public'
      AND p.proname IN (
        'incrementar_precio_m2_mensual','recalcular_pago_completado_acuerdos',
        'regenerar_clabes_faltantes','actualizar_estatus_reservas',
        'save_cep_audit_results','save_contract_validation_results',
        'save_pago_validation_results','sync_conyuge_compradores',
        'procesar_avisos_app','disparar_bancos_solicitudes_expirar',
        'disparar_crm_recordatorios_tareas','get_payments_for_cep_cleanup'
      )
  LOOP
    BEGIN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
      EXECUTE format('GRANT  EXECUTE ON FUNCTION %s TO service_role', f.sig);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '0.2 omitido % (%)', f.sig, SQLERRM;
    END;
  END LOOP;
END $$;

-- ================================================================
-- 0.3 security_invoker en vistas expuestas
-- ================================================================
DO $$
DECLARE v text;
BEGIN
  FOREACH v IN ARRAY ARRAY['v_pagos_detalle','v_pagos_efectivo','v_borra_extraccion_ceps_solo'] LOOP
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_views WHERE schemaname = 'public' AND viewname = v) THEN
        EXECUTE format('ALTER VIEW public.%I SET (security_invoker = on)', v);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '0.3 omitido vista % (%)', v, SQLERRM;
    END;
  END LOOP;
END $$;

-- ================================================================
-- 0.4 Sacar del API: funciones de trigger, respaldos y helpers de autorización
-- ================================================================
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public'
      AND (
        pg_get_function_result(p.oid) = 'trigger'
        OR p.proname LIKE 'get_cuentas_cobranza_paginadas_backup%'
        OR p.proname IN ('is_super_admin','is_admin_user','user_has_permission','user_has_role',
                         'user_has_internal_role','current_es_super_admin','current_puede_impersonar',
                         'can_view_all_prospects','can_access_agent_owned_lead',
                         'socio_tiene_cuenta','socio_tiene_edificio','socio_tiene_propiedad',
                         'socio_tiene_proyecto','socio_desarrollos_activos')
      )
  LOOP
    BEGIN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '0.4 omitido % (%)', f.sig, SQLERRM;
    END;
  END LOOP;
END $$;

-- ================================================================
-- 0.5 search_path fijo en funciones public/private mutables
-- ================================================================
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname IN ('public','private')
      AND p.prokind = 'f'
      AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig,'{}')) c WHERE c LIKE 'search_path=%')
  LOOP
    BEGIN
      EXECUTE format('ALTER FUNCTION %s SET search_path = public, pg_temp', f.sig);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '0.5 omitido % (%)', f.sig, SQLERRM;
    END;
  END LOOP;
END $$;

-- ================================================================
-- 0-bis Storage: quitar el listado del bucket `documentos`
--   storage.objects es de supabase_storage_admin; si el rol de migración no es owner
--   (self-hosted) se omite con NOTICE → aplicar manual en el dashboard.
-- ================================================================
DO $$
BEGIN
  DROP POLICY IF EXISTS "Anyone can view documents" ON storage.objects;
  DROP POLICY IF EXISTS documentos_list_interno ON storage.objects;
  CREATE POLICY documentos_list_interno ON storage.objects
    FOR SELECT TO authenticated
    USING (bucket_id = 'documentos' AND public.user_has_internal_role(auth.uid()));
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE '0-bis omitido: sin privilegio sobre storage.objects. Aplicar manual en Storage (dashboard).';
WHEN undefined_function THEN
  RAISE NOTICE '0-bis omitido: user_has_internal_role no disponible en este ambiente.';
END $$;
