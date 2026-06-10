-- RLS de perfiles_juridicos: políticas pj_select / pj_insert / pj_update.
-- Fecha: 2026-06-10
--
-- Drift detectado: 20260527000003_app_juridico.sql sólo creó la policy SELECT
-- "todos_leen_perfiles_juridicos_activos". Las políticas pj_* se aplicaron después
-- fuera de banda en dev (donde existen las 3) pero producción quedó SIN pj_insert →
-- los INSERT de authenticated fallan por RLS. Esta migración recrea las 3 políticas
-- y elimina la policy vieja (dev ya no la tiene; pj_select USING(true) la supersede)
-- para que ambos ambientes converjan.
--
-- Idempotente: DROP POLICY IF EXISTS + CREATE. En dev queda igual (no-op efectivo).

ALTER TABLE public.perfiles_juridicos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "todos_leen_perfiles_juridicos_activos" ON public.perfiles_juridicos;
DROP POLICY IF EXISTS pj_select ON public.perfiles_juridicos;
DROP POLICY IF EXISTS pj_insert ON public.perfiles_juridicos;
DROP POLICY IF EXISTS pj_update ON public.perfiles_juridicos;

CREATE POLICY pj_select ON public.perfiles_juridicos
  FOR SELECT TO authenticated USING (true);

CREATE POLICY pj_insert ON public.perfiles_juridicos
  FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY pj_update ON public.perfiles_juridicos
  FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
