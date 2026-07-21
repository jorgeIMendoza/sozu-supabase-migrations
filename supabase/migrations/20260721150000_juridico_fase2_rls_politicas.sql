-- Portal Jurídico · Fase 2 v2.2 · Sección B — Políticas RLS
-- Fecha: 2026-07-21
--
-- Depende de 20260721140000 (tablas + ENABLE RLS). Patrón:
--   · Rol 1 (Super Admin) y 18 (Admin Legal): acceso total.
--   · Rol 26 (Jurídico): SELECT solo donde es id_abogado_responsable (o el expediente/asunto
--     asociado); INSERT donde aplica; sin acceso de administración de catálogos.
--   Lookup: usuarios.auth_user_id = auth.uid(); own: perfiles_juridicos.email = usuarios.email.
--
-- Tablas inmutables (actuaciones_procesales, historial_riesgo_asunto,
-- historial_asignaciones_juridicas): solo SELECT + INSERT.
-- Idempotente: DROP POLICY IF EXISTS antes de cada CREATE. Sin BEGIN/COMMIT.

-- ─── cat_tipos_asunto ──────────────────────────────────
DROP POLICY IF EXISTS cat_tipos_asunto_sel ON public.cat_tipos_asunto;
CREATE POLICY cat_tipos_asunto_sel ON public.cat_tipos_asunto FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));
DROP POLICY IF EXISTS cat_tipos_asunto_ins ON public.cat_tipos_asunto;
CREATE POLICY cat_tipos_asunto_ins ON public.cat_tipos_asunto FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true));
DROP POLICY IF EXISTS cat_tipos_asunto_upd ON public.cat_tipos_asunto;
CREATE POLICY cat_tipos_asunto_upd ON public.cat_tipos_asunto FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true));
DROP POLICY IF EXISTS cat_tipos_asunto_del ON public.cat_tipos_asunto;
CREATE POLICY cat_tipos_asunto_del ON public.cat_tipos_asunto FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true));

-- ─── cat_niveles_riesgo ────────────────────────────────
DROP POLICY IF EXISTS cat_niveles_riesgo_sel ON public.cat_niveles_riesgo;
CREATE POLICY cat_niveles_riesgo_sel ON public.cat_niveles_riesgo FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));
DROP POLICY IF EXISTS cat_niveles_riesgo_ins ON public.cat_niveles_riesgo;
CREATE POLICY cat_niveles_riesgo_ins ON public.cat_niveles_riesgo FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true));
DROP POLICY IF EXISTS cat_niveles_riesgo_upd ON public.cat_niveles_riesgo;
CREATE POLICY cat_niveles_riesgo_upd ON public.cat_niveles_riesgo FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true));
DROP POLICY IF EXISTS cat_niveles_riesgo_del ON public.cat_niveles_riesgo;
CREATE POLICY cat_niveles_riesgo_del ON public.cat_niveles_riesgo FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true));

-- ─── cat_etapas_procesales ─────────────────────────────
DROP POLICY IF EXISTS cat_etapas_sel ON public.cat_etapas_procesales;
CREATE POLICY cat_etapas_sel ON public.cat_etapas_procesales FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));
DROP POLICY IF EXISTS cat_etapas_ins ON public.cat_etapas_procesales;
CREATE POLICY cat_etapas_ins ON public.cat_etapas_procesales FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true));
DROP POLICY IF EXISTS cat_etapas_upd ON public.cat_etapas_procesales;
CREATE POLICY cat_etapas_upd ON public.cat_etapas_procesales FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true));
DROP POLICY IF EXISTS cat_etapas_del ON public.cat_etapas_procesales;
CREATE POLICY cat_etapas_del ON public.cat_etapas_procesales FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true));

-- ─── contrapartes ─────────────────────────────────────
DROP POLICY IF EXISTS contrapartes_sel ON public.contrapartes;
CREATE POLICY contrapartes_sel ON public.contrapartes FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));
DROP POLICY IF EXISTS contrapartes_ins ON public.contrapartes;
CREATE POLICY contrapartes_ins ON public.contrapartes FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));
DROP POLICY IF EXISTS contrapartes_upd ON public.contrapartes;
CREATE POLICY contrapartes_upd ON public.contrapartes FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true));

-- ─── expedientes_juridicos (rol 26: expedientes con asunto asignado) ─────
DROP POLICY IF EXISTS expedientes_sel ON public.expedientes_juridicos;
CREATE POLICY expedientes_sel ON public.expedientes_juridicos FOR SELECT TO authenticated
  USING (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.asuntos_juridicos aj JOIN public.perfiles_juridicos pj ON pj.id = aj.id_abogado_responsable
                JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND aj.id_expediente = expedientes_juridicos.id AND u.activo = true))
  );
DROP POLICY IF EXISTS expedientes_ins ON public.expedientes_juridicos;
CREATE POLICY expedientes_ins ON public.expedientes_juridicos FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));
DROP POLICY IF EXISTS expedientes_upd ON public.expedientes_juridicos;
CREATE POLICY expedientes_upd ON public.expedientes_juridicos FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true))
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));

-- ─── asuntos_juridicos (rol 26: solo donde es responsable) ─────
DROP POLICY IF EXISTS asuntos_sel ON public.asuntos_juridicos;
CREATE POLICY asuntos_sel ON public.asuntos_juridicos FOR SELECT TO authenticated
  USING (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.perfiles_juridicos pj JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND pj.id = asuntos_juridicos.id_abogado_responsable AND u.activo = true))
  );
DROP POLICY IF EXISTS asuntos_ins ON public.asuntos_juridicos;
CREATE POLICY asuntos_ins ON public.asuntos_juridicos FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));
DROP POLICY IF EXISTS asuntos_upd ON public.asuntos_juridicos;
CREATE POLICY asuntos_upd ON public.asuntos_juridicos FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true))
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));

-- ─── asuntos_detalle_demanda ──────────────────────────
DROP POLICY IF EXISTS detalle_demanda_sel ON public.asuntos_detalle_demanda;
CREATE POLICY detalle_demanda_sel ON public.asuntos_detalle_demanda FOR SELECT TO authenticated
  USING (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.asuntos_juridicos aj JOIN public.perfiles_juridicos pj ON pj.id = aj.id_abogado_responsable
                JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND aj.id = asuntos_detalle_demanda.id_asunto AND u.activo = true))
  );
DROP POLICY IF EXISTS detalle_demanda_ins ON public.asuntos_detalle_demanda;
CREATE POLICY detalle_demanda_ins ON public.asuntos_detalle_demanda FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));
DROP POLICY IF EXISTS detalle_demanda_upd ON public.asuntos_detalle_demanda;
CREATE POLICY detalle_demanda_upd ON public.asuntos_detalle_demanda FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true))
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));

-- ─── profeco_expedientes ──────────────────────────────
DROP POLICY IF EXISTS profeco_sel ON public.profeco_expedientes;
CREATE POLICY profeco_sel ON public.profeco_expedientes FOR SELECT TO authenticated
  USING (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.asuntos_juridicos aj JOIN public.perfiles_juridicos pj ON pj.id = aj.id_abogado_responsable
                JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND aj.id = profeco_expedientes.id_asunto AND u.activo = true))
  );
DROP POLICY IF EXISTS profeco_ins ON public.profeco_expedientes;
CREATE POLICY profeco_ins ON public.profeco_expedientes FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));
DROP POLICY IF EXISTS profeco_upd ON public.profeco_expedientes;
CREATE POLICY profeco_upd ON public.profeco_expedientes FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true))
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));

-- ─── actuaciones_procesales (INMUTABLE: solo SELECT + INSERT) ─
DROP POLICY IF EXISTS actuaciones_sel ON public.actuaciones_procesales;
CREATE POLICY actuaciones_sel ON public.actuaciones_procesales FOR SELECT TO authenticated
  USING (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.asuntos_juridicos aj JOIN public.perfiles_juridicos pj ON pj.id = aj.id_abogado_responsable
                JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND aj.id = actuaciones_procesales.id_asunto AND u.activo = true))
  );
DROP POLICY IF EXISTS actuaciones_ins ON public.actuaciones_procesales;
CREATE POLICY actuaciones_ins ON public.actuaciones_procesales FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));

-- ─── estrategias_juridicas ────────────────────────────
DROP POLICY IF EXISTS estrategias_sel ON public.estrategias_juridicas;
CREATE POLICY estrategias_sel ON public.estrategias_juridicas FOR SELECT TO authenticated
  USING (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.asuntos_juridicos aj JOIN public.perfiles_juridicos pj ON pj.id = aj.id_abogado_responsable
                JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND aj.id = estrategias_juridicas.id_asunto AND u.activo = true))
  );
DROP POLICY IF EXISTS estrategias_ins ON public.estrategias_juridicas;
CREATE POLICY estrategias_ins ON public.estrategias_juridicas FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));
DROP POLICY IF EXISTS estrategias_upd ON public.estrategias_juridicas;
CREATE POLICY estrategias_upd ON public.estrategias_juridicas FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true))
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));

-- ─── historial_riesgo_asunto (INMUTABLE) ──────────────
DROP POLICY IF EXISTS hist_riesgo_sel ON public.historial_riesgo_asunto;
CREATE POLICY hist_riesgo_sel ON public.historial_riesgo_asunto FOR SELECT TO authenticated
  USING (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.asuntos_juridicos aj JOIN public.perfiles_juridicos pj ON pj.id = aj.id_abogado_responsable
                JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND aj.id = historial_riesgo_asunto.id_asunto AND u.activo = true))
  );
DROP POLICY IF EXISTS hist_riesgo_ins ON public.historial_riesgo_asunto;
CREATE POLICY hist_riesgo_ins ON public.historial_riesgo_asunto FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));

-- ─── historial_asignaciones_juridicas (INMUTABLE) ─────
DROP POLICY IF EXISTS hist_asig_sel ON public.historial_asignaciones_juridicas;
CREATE POLICY hist_asig_sel ON public.historial_asignaciones_juridicas FOR SELECT TO authenticated
  USING (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.asuntos_juridicos aj JOIN public.perfiles_juridicos pj ON pj.id = aj.id_abogado_responsable
                JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND aj.id = historial_asignaciones_juridicas.id_asunto AND u.activo = true))
  );
DROP POLICY IF EXISTS hist_asig_ins ON public.historial_asignaciones_juridicas;
CREATE POLICY hist_asig_ins ON public.historial_asignaciones_juridicas FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));
