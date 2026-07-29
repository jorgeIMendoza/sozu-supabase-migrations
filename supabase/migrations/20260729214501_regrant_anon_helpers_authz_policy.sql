-- Seguridad · Correctivo: devuelve EXECUTE a anon en los helpers de authz que las policies
--   de RLS invocan, y deja la regla derivada del catálogo en lugar de una lista a mano.
-- Fecha: 2026-07-29
--
-- PROBLEMA
--   Las expresiones de RLS se evalúan con los privilegios del INVOCADOR, no del dueño de la
--   policy. Si una policy que alcanza a anon llama a is_admin_user(), anon necesita EXECUTE
--   sobre esa función: sin él, tocar la tabla falla con "permission denied for function".
--
--   20260729204501_seguridad_revoke_anon_funciones_secdef revocó EXECUTE a anon en las
--   funciones SECURITY DEFINER de public y no contempló ese caso. El PR #468 lo detectó y
--   agregó una lista blanca de 16 helpers, pero la lista quedó incompleta: falta
--   get_current_user_persona_id(), invocada por la policy update_entidades_relacionadas
--   (rol PUBLIC) sobre public.entidades_relacionadas.
--
--   Estado en prod al escribir esto (verificado read-only): de los 9 helpers referenciados
--   por policies con rol anon/PUBLIC, 8 conservan EXECUTE y get_current_user_persona_id no.
--   authenticated y service_role sí lo conservan, así que la app autenticada no se afecta;
--   el camino roto es un UPDATE directo de anon sobre entidades_relacionadas. Hoy ninguna
--   página pública escribe ahí (todo pasa por RPCs SECURITY DEFINER que corren como postgres
--   y saltan RLS), así que no hay incidente activo — pero queda latente.
--
-- POR QUÉ UNA MIGRACIÓN NUEVA Y NO EDITAR LA ANTERIOR
--   20260729204501 ya está aplicada en dev y en prod. Editarla no cambiaría nada en esos
--   entornos y sí introduciría drift respecto de los `statements` registrados en
--   supabase_migrations.schema_migrations. Este archivo corre después y repara el estado.
--   Además, en un entorno nuevo (db reset, branch, restore) el orden garantiza que esta
--   migración corrija lo que la anterior revocó.
--
-- CORRECCIÓN
--   En lugar de nombrar get_current_user_persona_id, se deriva del catálogo: toda función de
--   public de la que dependa una policy con rol anon o PUBLIC debe ser ejecutable por anon.
--   pg_depend registra esa dependencia (por eso no se puede DROP una función usada por una
--   policy). Funciona aunque dev y prod tengan policies distintas, que es exactamente el
--   caso que nos vino mordiendo.
--
--   Esto NO reabre el hallazgo del lint: son predicados de autorización que devuelven
--   boolean o un id, no RPCs que vuelquen datos. Los get_*_export y compañía siguen
--   revocados. Que anon pueda evaluar `is_admin_user()` es justamente lo que hace que la
--   policy pueda decir "no".
--
-- Idempotente (solo otorga donde falta) y self-verifying.
-- Sin BEGIN/COMMIT (el CI envuelve en transacción).

DO $$
DECLARE
  r        record;
  n_grant  int := 0;
  n_ya     int := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT
           p.oid,
           p.oid::regprocedure::text AS firma,
           string_agg(DISTINCT c.relname || '.' || pol.polname, ', ') AS policies
    FROM pg_depend d
    JOIN pg_policy pol   ON pol.oid = d.objid    AND d.classid    = 'pg_policy'::regclass
    JOIN pg_proc p       ON p.oid   = d.refobjid AND d.refclassid = 'pg_proc'::regclass
    JOIN pg_namespace pn ON pn.oid  = p.pronamespace
    JOIN pg_class c      ON c.oid   = pol.polrelid
    JOIN pg_namespace n  ON n.oid   = c.relnamespace
    WHERE pn.nspname = 'public'      -- solo funciones que el REVOKE anterior pudo tocar
      AND n.nspname  = 'public'
      AND (pol.polroles = '{0}'::oid[] OR 'anon'::regrole::oid = ANY(pol.polroles))
    GROUP BY p.oid
    ORDER BY 2
  LOOP
    IF has_function_privilege('anon', r.oid, 'EXECUTE') THEN
      n_ya := n_ya + 1;
      CONTINUE;
    END IF;

    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon', r.firma);
    RAISE NOTICE 'GRANT EXECUTE a anon en % — invocada por %', r.firma, r.policies;
    n_grant := n_grant + 1;
  END LOOP;

  RAISE NOTICE 'helpers de authz: % reparados, % ya estaban bien', n_grant, n_ya;
END $$;

-- Verificación: toda función de public invocada por una policy con rol anon/PUBLIC tiene que
-- ser ejecutable por anon, o esa policy es una bomba de tiempo.
DO $$
DECLARE
  v_faltantes text;
BEGIN
  SELECT string_agg(x.firma, E'\n  - ' ORDER BY x.firma) INTO v_faltantes
  FROM (
    SELECT DISTINCT p.oid::regprocedure::text AS firma
    FROM pg_depend d
    JOIN pg_policy pol   ON pol.oid = d.objid    AND d.classid    = 'pg_policy'::regclass
    JOIN pg_proc p       ON p.oid   = d.refobjid AND d.refclassid = 'pg_proc'::regclass
    JOIN pg_namespace pn ON pn.oid  = p.pronamespace
    JOIN pg_class c      ON c.oid   = pol.polrelid
    JOIN pg_namespace n  ON n.oid   = c.relnamespace
    WHERE pn.nspname = 'public'
      AND n.nspname  = 'public'
      AND (pol.polroles = '{0}'::oid[] OR 'anon'::regrole::oid = ANY(pol.polroles))
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
  ) x;

  IF v_faltantes IS NOT NULL THEN
    RAISE EXCEPTION E'Hay funciones invocadas por policies con rol anon/PUBLIC que anon no puede ejecutar:\n  - %', v_faltantes;
  END IF;

  RAISE NOTICE 'Verificación OK: anon puede evaluar todos los helpers de authz de sus policies';
END $$;

-- Contraverificación: esto no debe haber reabierto el lint. Las RPCs que vuelcan datos
-- siguen cerradas a anon; solo pueden estar abiertas las declaradas como flujo público o
-- referenciadas por una policy.
DO $$
DECLARE
  v_inesperadas text;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, E'\n  - ' ORDER BY p.proname) INTO v_inesperadas
  FROM pg_proc p
  JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
  WHERE nsp.nspname = 'public'
    AND p.prosecdef
    AND has_function_privilege('anon', p.oid, 'EXECUTE')
    -- flujos públicos declarados en 20260729204501
    AND p.proname NOT IN (
      'landing_bottura_rpc', 'landing_daiku_rpc', 'landing_margot_rpc',
      'get_reservacion_publica', 'guardar_datos_reservacion', 'get_apartado_status',
      'update_lead_datos', 'get_cliente_estado_oferta', 'guardar_csf_oferta',
      'check_email_blocked_role'
    )
    -- helpers de authz: los de #468 más los que derive el catálogo
    AND p.proname NOT IN (
      'is_admin_user', 'is_super_admin', 'can_view_all_prospects',
      'can_access_agent_owned_lead', 'user_has_role', 'user_has_permission',
      'user_has_internal_role', 'current_es_super_admin', 'current_puede_impersonar',
      'current_persona_id', 'current_socio_bancario_id', 'socio_desarrollos_activos',
      'socio_tiene_proyecto', 'socio_tiene_edificio', 'socio_tiene_propiedad',
      'socio_tiene_cuenta'
    )
    AND p.oid NOT IN (
      SELECT d.refobjid
      FROM pg_depend d
      JOIN pg_policy pol ON pol.oid = d.objid AND d.classid = 'pg_policy'::regclass
      WHERE d.refclassid = 'pg_proc'::regclass
        AND (pol.polroles = '{0}'::oid[] OR 'anon'::regrole::oid = ANY(pol.polroles))
    );

  IF v_inesperadas IS NOT NULL THEN
    RAISE EXCEPTION E'Este correctivo dejó funciones SECURITY DEFINER expuestas a anon que no son flujo público ni helper de policy:\n  - %', v_inesperadas;
  END IF;

  RAISE NOTICE 'Contraverificación OK: no se reabrió el lint anon_security_definer_function_executable';
END $$;
