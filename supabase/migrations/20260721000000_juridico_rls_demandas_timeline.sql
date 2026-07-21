-- Portal Jurídico Fase 1 · DDL-2 · RLS demandas + demandas_timeline
-- Fecha: 2026-07-21
--
-- Reemplaza las políticas {public} por políticas {authenticated}:
--   · demandas: SELECT/INSERT/UPDATE abiertos a authenticated (USING true). Sin DELETE
--     (el borrado vía CASCADE desde propiedades opera a nivel motor, no pasa por RLS).
--   · demandas_timeline: SELECT/INSERT solo para roles jurídicos (1 Super Admin, 18 Admin
--     Legal, 26 Jurídico). Sin UPDATE/DELETE (bitácora inmutable; corrección = nuevo evento;
--     borrado solo por CASCADE).
--
-- Idempotente: ENABLE RLS (no-op si ya on), DROP POLICY IF EXISTS (viejas {public} + nuevas)
-- antes de cada CREATE. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

ALTER TABLE public.demandas          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.demandas_timeline ENABLE ROW LEVEL SECURITY;

-- ================================================================
-- BLOQUE 2.A — public.demandas
-- ================================================================
DROP POLICY IF EXISTS demandas_insert ON public.demandas;
DROP POLICY IF EXISTS demandas_select ON public.demandas;
DROP POLICY IF EXISTS demandas_update ON public.demandas;

DROP POLICY IF EXISTS "juridico_auth_select_demandas" ON public.demandas;
CREATE POLICY "juridico_auth_select_demandas" ON public.demandas
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "juridico_auth_insert_demandas" ON public.demandas;
CREATE POLICY "juridico_auth_insert_demandas" ON public.demandas
  FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "juridico_auth_update_demandas" ON public.demandas;
CREATE POLICY "juridico_auth_update_demandas" ON public.demandas
  FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

-- ================================================================
-- BLOQUE 2.B — public.demandas_timeline
-- ================================================================
DROP POLICY IF EXISTS demandas_timeline_insert ON public.demandas_timeline;
DROP POLICY IF EXISTS demandas_timeline_select ON public.demandas_timeline;

DROP POLICY IF EXISTS "juridico_rol_select_timeline" ON public.demandas_timeline;
CREATE POLICY "juridico_rol_select_timeline" ON public.demandas_timeline
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid() AND u.rol_id IN (1, 18, 26) AND u.activo = true
    )
  );

DROP POLICY IF EXISTS "juridico_rol_insert_timeline" ON public.demandas_timeline;
CREATE POLICY "juridico_rol_insert_timeline" ON public.demandas_timeline
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid() AND u.rol_id IN (1, 18, 26) AND u.activo = true
    )
  );
