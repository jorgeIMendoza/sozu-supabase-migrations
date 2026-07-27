-- Seguridad · Fix de la Fase 0 — re-otorgar EXECUTE de los helpers de autorización
-- Fecha: 2026-07-27
--
-- La Fase 0 (20260727000000, bloque 0.4) revocó EXECUTE de los helpers de autorización a
-- anon/authenticated bajo el supuesto (del doc de auditoría) de que las policies los evalúan
-- "como owner". Es INCORRECTO: en Postgres la expresión de una policy se evalúa como el rol
-- invocante y SÍ exige EXECUTE sobre la función. El revoke rompió toda lectura de tablas cuyas
-- policies llaman estos helpers → Portal de Agentes/Admin en blanco ('permission denied for
-- function'). Confirmado y ya restaurado a mano en prod; esta migración deja el repo (dev/main)
-- consistente y evita que un apply limpio vuelva a romper (corre DESPUÉS del revoke).
--
-- Se conservan revocados (correcto, no los llama el cliente): funciones de trigger, respaldos
-- olvidados, execute_safe_query y las 12 funciones mutadoras (bloques 0.1/0.2/0.4-triggers).
--
-- Idempotente: GRANT por loop dinámico (cubre todas las sobrecargas). Sin BEGIN/COMMIT.

DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public'
      AND p.proname IN (
        'is_super_admin','is_admin_user','user_has_permission','user_has_role',
        'user_has_internal_role','current_es_super_admin','current_puede_impersonar',
        'can_view_all_prospects','can_access_agent_owned_lead',
        'socio_tiene_cuenta','socio_tiene_edificio','socio_tiene_propiedad',
        'socio_tiene_proyecto','socio_desarrollos_activos'
      )
  LOOP
    BEGIN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', f.sig);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'regrant omitido % (%)', f.sig, SQLERRM;
    END;
  END LOOP;
END $$;
