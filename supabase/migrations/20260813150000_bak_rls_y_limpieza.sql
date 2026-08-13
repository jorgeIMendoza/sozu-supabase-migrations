-- =============================================================================
-- Respaldos `_bak_*`: cerrar los que siguen sirviendo, borrar el que ya no
-- =============================================================================
-- `20260729224501_seguridad_rls_disabled_in_public.sql` encendió RLS en 97 tablas de
-- `public` y clasificó los respaldos como RESTRINGIDA. Los `_bak_*` creados DESPUÉS de esa
-- fecha se quedaron fuera y nacieron abiertos: en este proyecto los DEFAULT PRIVILEGES de
-- `public` le dan `arwdDxtm` a `anon` y `authenticated` sobre toda tabla nueva, y sin RLS
-- PostgREST las expone con la anon key, que es pública.
--
-- ─── Verificado read-only el 2026-08-13 ──────────────────────────────────────
-- Estado en prod (tzmhgfjmddkfyffkkmto):
--
--   tabla                              filas   RLS    aún difieren del valor actual
--   _bak_documentos_estatus_20260803   449     NO     448 de 449
--   _bak_personas_ocupacion_20260722   452     sí     293 de 452
--   _bak_conflicto_dueno_lead_20260807   0     NO     —
--
-- En dev existen solo `_bak_personas_ocupacion_20260722` y
-- `_bak_conflicto_dueno_lead_20260807`, las dos SIN RLS. Por eso todo va guardado por
-- existencia: los dos entornos no tienen el mismo conjunto de tablas.
--
-- Ninguna tiene FKs apuntándole, ni vistas, ni funciones que la lean, ni una sola
-- referencia en sozu-admin, sozu-edge-functions ni sozu-cliente-app.
--
-- ─── Por qué NO se borran las dos con datos ──────────────────────────────────
-- Que nadie las lea no significa que sobren: son la única copia del valor previo. En
-- `_bak_documentos_estatus_20260803` 448 de 449 filas siguen difiriendo del
-- `documentos.id_estatus_verificacion` de hoy, y en `_bak_personas_ocupacion_20260722`
-- difieren 293 de 452. Borrarlas cierra la puerta a revertir o auditar esos dos cambios.
-- Se les enciende RLS y se decide su baja aparte, cuando el negocio confirme que ya no hay
-- nada que reclamar.
--
-- `public.pagos_stp_raw` NO se toca, igual que en la migración del 29 de julio: queda con
-- RLS apagada por indicación expresa.
--
-- Idempotente: guardado por existencia de tabla, de política y por relrowsecurity.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §A. RLS en los respaldos que se quedan
-- -----------------------------------------------------------------------------
-- Misma clase RESTRINGIDA de 20260729224501: lectura y escritura solo para
-- authenticated. service_role tiene rolbypassrls, así que edge functions y crons no se
-- ven afectados.
DO $rls$
DECLARE
  v_tabla text;
  v_pol   text;
BEGIN
  FOREACH v_tabla IN ARRAY ARRAY[
    '_bak_documentos_estatus_20260803',
    '_bak_personas_ocupacion_20260722'
  ]
  LOOP
    IF to_regclass('public.' || quote_ident(v_tabla)) IS NULL THEN
      RAISE NOTICE 'public.% no existe en este entorno, se omite', v_tabla;
      CONTINUE;
    END IF;

    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', v_tabla);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM anon', v_tabla);

    v_pol := v_tabla || '_rls_auth';

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'public' AND tablename = v_tabla AND policyname = v_pol
    ) THEN
      EXECUTE format(
        'CREATE POLICY %I ON public.%I FOR ALL TO authenticated '
        'USING ((SELECT auth.uid()) IS NOT NULL) '
        'WITH CHECK ((SELECT auth.uid()) IS NOT NULL)',
        v_pol, v_tabla
      );
      RAISE NOTICE 'RLS + política % en public.%', v_pol, v_tabla;
    ELSE
      RAISE NOTICE 'public.% ya tenía la política %, solo se aseguró RLS', v_tabla, v_pol;
    END IF;
  END LOOP;
END;
$rls$;

-- -----------------------------------------------------------------------------
-- §B. Baja del respaldo que quedó vacío
-- -----------------------------------------------------------------------------
-- `_bak_conflicto_dueno_lead_20260807` lo creó 20260807040000 para que quien perdiera un
-- lead en el desempate CRM↔Portal tuviera con qué reclamar, porque la bitácora definitiva
-- (`crm_leads_reasignaciones`) todavía no existía cuando corrió esa migración. Hoy la
-- bitácora existe y tiene 45 filas, y el respaldo quedó en 0 en prod.
--
-- Se borra solo si está vacío. Si algún entorno tiene filas, NO se borra: se le enciende
-- RLS y se avisa, en vez de tirar datos que nadie revisó.
DO $drop$
DECLARE
  v_filas bigint;
BEGIN
  IF to_regclass('public._bak_conflicto_dueno_lead_20260807') IS NULL THEN
    RAISE NOTICE '_bak_conflicto_dueno_lead_20260807 no existe en este entorno, nada que hacer';
    RETURN;
  END IF;

  EXECUTE 'SELECT count(*) FROM public._bak_conflicto_dueno_lead_20260807' INTO v_filas;

  IF v_filas = 0 THEN
    DROP TABLE public._bak_conflicto_dueno_lead_20260807;
    RAISE NOTICE '_bak_conflicto_dueno_lead_20260807 estaba vacío → tabla eliminada';
  ELSE
    EXECUTE 'ALTER TABLE public._bak_conflicto_dueno_lead_20260807 ENABLE ROW LEVEL SECURITY';
    EXECUTE 'REVOKE ALL ON TABLE public._bak_conflicto_dueno_lead_20260807 FROM anon';

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = '_bak_conflicto_dueno_lead_20260807'
        AND policyname = '_bak_conflicto_dueno_lead_20260807_rls_auth'
    ) THEN
      CREATE POLICY "_bak_conflicto_dueno_lead_20260807_rls_auth"
        ON public._bak_conflicto_dueno_lead_20260807
        FOR ALL TO authenticated
        USING ((SELECT auth.uid()) IS NOT NULL)
        WITH CHECK ((SELECT auth.uid()) IS NOT NULL);
    END IF;

    RAISE WARNING
      '_bak_conflicto_dueno_lead_20260807 tiene % fila(s): NO se eliminó, solo se cerró con RLS. Revisar contra crm_leads_reasignaciones antes de darlo de baja.',
      v_filas;
  END IF;
END;
$drop$;

-- -----------------------------------------------------------------------------
-- §C. Self-verifying: ningún `_bak_*` puede quedar sin RLS
-- -----------------------------------------------------------------------------
DO $check$
DECLARE
  v_abiertas text;
BEGIN
  SELECT string_agg(c.relname, ', ')
    INTO v_abiertas
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND c.relname LIKE '\_bak\_%'
    AND NOT c.relrowsecurity;

  IF v_abiertas IS NOT NULL THEN
    RAISE EXCEPTION 'Quedaron respaldos sin RLS: %', v_abiertas;
  END IF;
END;
$check$;

COMMIT;

-- =============================================================================
-- Verificación (read-only, correr después del deploy)
-- =============================================================================
-- -- Ningún _bak_* sin RLS (esperado: 0 filas)
-- SELECT c.relname, c.relrowsecurity
-- FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
-- WHERE n.nspname = 'public' AND c.relkind = 'r'
--   AND c.relname LIKE '\_bak\_%' AND NOT c.relrowsecurity;
--
-- -- El vacío ya no existe (esperado: NULL)
-- SELECT to_regclass('public._bak_conflicto_dueno_lead_20260807');
--
-- -- Los otros dos conservan sus filas
-- SELECT (SELECT count(*) FROM public._bak_documentos_estatus_20260803) AS docs,
--        (SELECT count(*) FROM public._bak_personas_ocupacion_20260722) AS ocupacion;
--
-- -- anon ya no puede leerlos
-- SELECT c.relname, has_table_privilege('anon', c.oid, 'SELECT') AS anon_lee
-- FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
-- WHERE n.nspname = 'public' AND c.relname LIKE '\_bak\_%';
-- =============================================================================
