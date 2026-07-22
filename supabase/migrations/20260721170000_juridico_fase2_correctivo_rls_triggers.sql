-- Portal Jurídico · Fase 2 v2.2.1 · Correctivo RLS/Triggers
-- Fecha: 2026-07-21
--
-- Depende de la Fase 2 (20260721140000 estructura + 20260721150000 RLS). Corrige, según
-- auditoría post-ejecución, los hallazgos P-01..P-12:
--   A) 5 políticas UPDATE: ownership real para rol 26 (solo filas donde es
--      id_abogado_responsable, directo o vía expediente).
--   B) 3 políticas INSERT (tablas inmutables): ownership en WITH CHECK.
--   C) 11 funciones de trigger SECURITY DEFINER (auditoría derivada de auth.uid();
--      aprobación de estrategias solo roles 1/18; rol 26 no reasigna abogado ni cambia
--      prioridad/cierre; etapa∈tipo; detalle_demanda solo DEMANDA_*; profeco solo QUEJA_PROFECO;
--      id_proyecto == proyecto real de la propiedad). Guard IF auth.uid() IS NOT NULL para
--      no romper acceso directo/migraciones.
--   D) 12 triggers de auditoría + 7 de integridad.
--   E) FK actuaciones_procesales→asuntos: CASCADE→RESTRICT; UNIQUE (id_asunto, numero_version)
--      en estrategias_juridicas.
--
-- NO incluye la Sección C del DDL principal (migración de datos). Idempotente: DROP POLICY
-- IF EXISTS + CREATE, CREATE OR REPLACE (funciones y triggers, PG 15.8), DO-blocks para FK/UNIQUE.
-- Sin BEGIN/COMMIT (CI/CD envuelve en tx).

-- ================================================================
-- SECCIÓN A — Políticas UPDATE con ownership (P-01, P-02)
-- ================================================================
DROP POLICY IF EXISTS asuntos_upd ON public.asuntos_juridicos;
CREATE POLICY asuntos_upd ON public.asuntos_juridicos FOR UPDATE TO authenticated
  USING (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.perfiles_juridicos pj JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND pj.id = asuntos_juridicos.id_abogado_responsable AND u.activo = true))
  )
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));

DROP POLICY IF EXISTS expedientes_upd ON public.expedientes_juridicos;
CREATE POLICY expedientes_upd ON public.expedientes_juridicos FOR UPDATE TO authenticated
  USING (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.asuntos_juridicos aj JOIN public.perfiles_juridicos pj ON pj.id = aj.id_abogado_responsable
                JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND aj.id_expediente = expedientes_juridicos.id AND u.activo = true))
  )
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));

DROP POLICY IF EXISTS detalle_demanda_upd ON public.asuntos_detalle_demanda;
CREATE POLICY detalle_demanda_upd ON public.asuntos_detalle_demanda FOR UPDATE TO authenticated
  USING (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.asuntos_juridicos aj JOIN public.perfiles_juridicos pj ON pj.id = aj.id_abogado_responsable
                JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND aj.id = asuntos_detalle_demanda.id_asunto AND u.activo = true))
  )
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));

DROP POLICY IF EXISTS profeco_upd ON public.profeco_expedientes;
CREATE POLICY profeco_upd ON public.profeco_expedientes FOR UPDATE TO authenticated
  USING (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.asuntos_juridicos aj JOIN public.perfiles_juridicos pj ON pj.id = aj.id_abogado_responsable
                JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND aj.id = profeco_expedientes.id_asunto AND u.activo = true))
  )
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));

DROP POLICY IF EXISTS estrategias_upd ON public.estrategias_juridicas;
CREATE POLICY estrategias_upd ON public.estrategias_juridicas FOR UPDATE TO authenticated
  USING (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.asuntos_juridicos aj JOIN public.perfiles_juridicos pj ON pj.id = aj.id_abogado_responsable
                JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND aj.id = estrategias_juridicas.id_asunto AND u.activo = true))
  )
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18,26]) AND u.activo = true));

-- ================================================================
-- SECCIÓN B — Políticas INSERT con ownership (tablas inmutables, P-03)
-- ================================================================
DROP POLICY IF EXISTS actuaciones_ins ON public.actuaciones_procesales;
CREATE POLICY actuaciones_ins ON public.actuaciones_procesales FOR INSERT TO authenticated
  WITH CHECK (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.asuntos_juridicos aj JOIN public.perfiles_juridicos pj ON pj.id = aj.id_abogado_responsable
                JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND aj.id = actuaciones_procesales.id_asunto AND u.activo = true))
  );

DROP POLICY IF EXISTS hist_riesgo_ins ON public.historial_riesgo_asunto;
CREATE POLICY hist_riesgo_ins ON public.historial_riesgo_asunto FOR INSERT TO authenticated
  WITH CHECK (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.asuntos_juridicos aj JOIN public.perfiles_juridicos pj ON pj.id = aj.id_abogado_responsable
                JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND aj.id = historial_riesgo_asunto.id_asunto AND u.activo = true))
  );

DROP POLICY IF EXISTS hist_asig_ins ON public.historial_asignaciones_juridicas;
CREATE POLICY hist_asig_ins ON public.historial_asignaciones_juridicas FOR INSERT TO authenticated
  WITH CHECK (
    (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true))
    OR (EXISTS (SELECT 1 FROM public.asuntos_juridicos aj JOIN public.perfiles_juridicos pj ON pj.id = aj.id_abogado_responsable
                JOIN public.usuarios u ON u.email = pj.email
                WHERE u.auth_user_id = auth.uid() AND aj.id = historial_asignaciones_juridicas.id_asunto AND u.activo = true))
  );

-- ================================================================
-- SECCIÓN C — Funciones de trigger (SECURITY DEFINER)
-- ================================================================
CREATE OR REPLACE FUNCTION public.enforce_audit_mutable() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_email TEXT;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    SELECT email INTO v_email FROM public.usuarios WHERE auth_user_id = auth.uid() AND activo = true;
    IF v_email IS NULL THEN
      RAISE EXCEPTION 'Usuario autenticado sin perfil activo en tabla usuarios.' USING ERRCODE = 'P0002';
    END IF;
    IF TG_OP = 'INSERT' THEN
      NEW.creado_por := v_email; NEW.actualizado_por := v_email;
    ELSE
      NEW.creado_por := OLD.creado_por; NEW.actualizado_por := v_email;
    END IF;
  ELSE
    IF TG_OP = 'INSERT' AND (NEW.creado_por IS NULL OR NEW.creado_por = '') THEN
      RAISE EXCEPTION 'creado_por no puede ser vacío (acceso directo).' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.enforce_audit_actuaciones() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_email TEXT;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    SELECT email INTO v_email FROM public.usuarios WHERE auth_user_id = auth.uid() AND activo = true;
    IF v_email IS NULL THEN
      RAISE EXCEPTION 'Usuario autenticado sin perfil activo.' USING ERRCODE = 'P0002';
    END IF;
    NEW.creado_por := v_email;
  ELSE
    IF NEW.creado_por IS NULL OR NEW.creado_por = '' THEN
      RAISE EXCEPTION 'creado_por no puede ser vacío (acceso directo).' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.enforce_audit_hist_riesgo() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_email TEXT;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    SELECT email INTO v_email FROM public.usuarios WHERE auth_user_id = auth.uid() AND activo = true;
    IF v_email IS NULL THEN
      RAISE EXCEPTION 'Usuario autenticado sin perfil activo.' USING ERRCODE = 'P0002';
    END IF;
    NEW.evaluado_por := v_email;
  ELSE
    IF NEW.evaluado_por IS NULL OR NEW.evaluado_por = '' THEN
      RAISE EXCEPTION 'evaluado_por no puede ser vacío (acceso directo).' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.enforce_audit_hist_asig() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_email TEXT;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    SELECT email INTO v_email FROM public.usuarios WHERE auth_user_id = auth.uid() AND activo = true;
    IF v_email IS NULL THEN
      RAISE EXCEPTION 'Usuario autenticado sin perfil activo.' USING ERRCODE = 'P0002';
    END IF;
    NEW.asignado_por := v_email;
  ELSE
    IF NEW.asignado_por IS NULL OR NEW.asignado_por = '' THEN
      RAISE EXCEPTION 'asignado_por no puede ser vacío (acceso directo).' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.check_estrategia_aprobacion() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF NEW.estado = 'APROBADA' AND OLD.estado <> 'APROBADA' THEN
    IF NOT EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true) THEN
      RAISE EXCEPTION 'Solo roles 1 y 18 pueden aprobar estrategias jurídicas.' USING ERRCODE = 'P0003';
    END IF;
  END IF;
  IF OLD.estado = 'DESCARTADA' AND NEW.estado <> 'DESCARTADA' THEN
    IF NOT EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true) THEN
      RAISE EXCEPTION 'Solo roles 1 y 18 pueden reactivar estrategias descartadas.' USING ERRCODE = 'P0003';
    END IF;
  END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.check_rol26_asunto_updates() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true) THEN RETURN NEW; END IF;
  IF NEW.id_abogado_responsable IS DISTINCT FROM OLD.id_abogado_responsable THEN
    RAISE EXCEPTION 'Rol 26 no puede reasignar el abogado responsable del asunto.' USING ERRCODE = 'P0004';
  END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.check_rol26_expediente_updates() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM public.usuarios u WHERE u.auth_user_id = auth.uid() AND u.rol_id = ANY(ARRAY[1,18]) AND u.activo = true) THEN RETURN NEW; END IF;
  IF NEW.prioridad IS DISTINCT FROM OLD.prioridad THEN
    RAISE EXCEPTION 'Rol 26 no puede modificar la prioridad del expediente.' USING ERRCODE = 'P0004';
  END IF;
  IF NEW.estado IN ('CERRADO','ARCHIVADO') AND OLD.estado <> NEW.estado THEN
    RAISE EXCEPTION 'Rol 26 no puede cerrar ni archivar expedientes.' USING ERRCODE = 'P0004';
  END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.check_etapa_tipo_asunto() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.id_etapa_actual IS NULL THEN RETURN NEW; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.cat_etapas_procesales ep WHERE ep.id = NEW.id_etapa_actual AND ep.id_tipo_asunto = NEW.id_tipo_asunto) THEN
    RAISE EXCEPTION 'id_etapa_actual (%) no pertenece al tipo de asunto (id_tipo_asunto=%).', NEW.id_etapa_actual, NEW.id_tipo_asunto USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.check_detalle_demanda_tipo() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_codigo TEXT;
BEGIN
  SELECT ta.codigo INTO v_codigo FROM public.asuntos_juridicos aj JOIN public.cat_tipos_asunto ta ON ta.id = aj.id_tipo_asunto WHERE aj.id = NEW.id_asunto;
  IF v_codigo IS NULL OR v_codigo NOT LIKE 'DEMANDA_%' THEN
    RAISE EXCEPTION 'asuntos_detalle_demanda solo aplica a asuntos DEMANDA_*. Tipo actual: %.', COALESCE(v_codigo, 'no encontrado') USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.check_profeco_tipo() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_codigo TEXT;
BEGIN
  SELECT ta.codigo INTO v_codigo FROM public.asuntos_juridicos aj JOIN public.cat_tipos_asunto ta ON ta.id = aj.id_tipo_asunto WHERE aj.id = NEW.id_asunto;
  IF v_codigo IS DISTINCT FROM 'QUEJA_PROFECO' THEN
    RAISE EXCEPTION 'profeco_expedientes solo aplica a asuntos QUEJA_PROFECO. Tipo actual: %.', COALESCE(v_codigo, 'no encontrado') USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.check_expediente_proyecto() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_proyecto INTEGER;
BEGIN
  SELECT e.id_proyecto INTO v_proyecto
  FROM public.propiedades pr
  JOIN public.edificios_modelos em ON em.id = pr.id_edificio_modelo
  JOIN public.edificios e ON e.id = em.id_edificio
  WHERE pr.id = NEW.id_propiedad;
  IF v_proyecto IS NULL THEN
    RAISE EXCEPTION 'No se encontró el proyecto para la propiedad %. Verificar cadena edificios_modelos→edificios.', NEW.id_propiedad USING ERRCODE = 'P0001';
  END IF;
  IF v_proyecto <> NEW.id_proyecto THEN
    RAISE EXCEPTION 'id_proyecto % no corresponde al proyecto real de la propiedad % (proyecto real: %).', NEW.id_proyecto, NEW.id_propiedad, v_proyecto USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END; $$;

-- ================================================================
-- SECCIÓN D — Triggers
-- ================================================================
-- D1 Auditoría tablas mutables (BEFORE INSERT OR UPDATE)
CREATE OR REPLACE TRIGGER trg_cat_etapas_procesales_audit    BEFORE INSERT OR UPDATE ON public.cat_etapas_procesales    FOR EACH ROW EXECUTE FUNCTION public.enforce_audit_mutable();
CREATE OR REPLACE TRIGGER trg_cat_niveles_riesgo_audit       BEFORE INSERT OR UPDATE ON public.cat_niveles_riesgo       FOR EACH ROW EXECUTE FUNCTION public.enforce_audit_mutable();
CREATE OR REPLACE TRIGGER trg_cat_tipos_asunto_audit         BEFORE INSERT OR UPDATE ON public.cat_tipos_asunto         FOR EACH ROW EXECUTE FUNCTION public.enforce_audit_mutable();
CREATE OR REPLACE TRIGGER trg_contrapartes_audit             BEFORE INSERT OR UPDATE ON public.contrapartes             FOR EACH ROW EXECUTE FUNCTION public.enforce_audit_mutable();
CREATE OR REPLACE TRIGGER trg_asuntos_detalle_demanda_audit  BEFORE INSERT OR UPDATE ON public.asuntos_detalle_demanda  FOR EACH ROW EXECUTE FUNCTION public.enforce_audit_mutable();
CREATE OR REPLACE TRIGGER trg_asuntos_juridicos_audit        BEFORE INSERT OR UPDATE ON public.asuntos_juridicos        FOR EACH ROW EXECUTE FUNCTION public.enforce_audit_mutable();
CREATE OR REPLACE TRIGGER trg_estrategias_juridicas_audit    BEFORE INSERT OR UPDATE ON public.estrategias_juridicas    FOR EACH ROW EXECUTE FUNCTION public.enforce_audit_mutable();
CREATE OR REPLACE TRIGGER trg_expedientes_juridicos_audit    BEFORE INSERT OR UPDATE ON public.expedientes_juridicos    FOR EACH ROW EXECUTE FUNCTION public.enforce_audit_mutable();
CREATE OR REPLACE TRIGGER trg_profeco_expedientes_audit      BEFORE INSERT OR UPDATE ON public.profeco_expedientes      FOR EACH ROW EXECUTE FUNCTION public.enforce_audit_mutable();

-- D2 Auditoría tablas inmutables (BEFORE INSERT)
CREATE OR REPLACE TRIGGER trg_actuaciones_procesales_audit   BEFORE INSERT ON public.actuaciones_procesales           FOR EACH ROW EXECUTE FUNCTION public.enforce_audit_actuaciones();
CREATE OR REPLACE TRIGGER trg_historial_asignaciones_audit   BEFORE INSERT ON public.historial_asignaciones_juridicas FOR EACH ROW EXECUTE FUNCTION public.enforce_audit_hist_asig();
CREATE OR REPLACE TRIGGER trg_historial_riesgo_asunto_audit  BEFORE INSERT ON public.historial_riesgo_asunto          FOR EACH ROW EXECUTE FUNCTION public.enforce_audit_hist_riesgo();

-- D3-D9 Integridad
CREATE OR REPLACE TRIGGER trg_estrategias_juridicas_aprobacion BEFORE UPDATE ON public.estrategias_juridicas FOR EACH ROW EXECUTE FUNCTION public.check_estrategia_aprobacion();
CREATE OR REPLACE TRIGGER trg_asuntos_juridicos_rol26         BEFORE UPDATE ON public.asuntos_juridicos      FOR EACH ROW EXECUTE FUNCTION public.check_rol26_asunto_updates();
CREATE OR REPLACE TRIGGER trg_expedientes_juridicos_rol26     BEFORE UPDATE ON public.expedientes_juridicos  FOR EACH ROW EXECUTE FUNCTION public.check_rol26_expediente_updates();
CREATE OR REPLACE TRIGGER trg_asuntos_juridicos_etapa         BEFORE INSERT OR UPDATE ON public.asuntos_juridicos FOR EACH ROW EXECUTE FUNCTION public.check_etapa_tipo_asunto();
CREATE OR REPLACE TRIGGER trg_asuntos_detalle_demanda_tipo    BEFORE INSERT ON public.asuntos_detalle_demanda FOR EACH ROW EXECUTE FUNCTION public.check_detalle_demanda_tipo();
CREATE OR REPLACE TRIGGER trg_profeco_expedientes_tipo        BEFORE INSERT ON public.profeco_expedientes     FOR EACH ROW EXECUTE FUNCTION public.check_profeco_tipo();
CREATE OR REPLACE TRIGGER trg_expedientes_juridicos_proyecto  BEFORE INSERT OR UPDATE ON public.expedientes_juridicos FOR EACH ROW EXECUTE FUNCTION public.check_expediente_proyecto();

-- ================================================================
-- SECCIÓN E — Cambios estructurales (P-10, P-11)
-- ================================================================
-- E1 actuaciones_procesales → asuntos_juridicos: CASCADE → RESTRICT
DO $$
DECLARE v_conname TEXT;
BEGIN
  SELECT conname INTO v_conname FROM pg_constraint
  WHERE conrelid = 'public.actuaciones_procesales'::regclass AND contype = 'f'
    AND confrelid = 'public.asuntos_juridicos'::regclass;
  IF v_conname IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.actuaciones_procesales DROP CONSTRAINT ' || quote_ident(v_conname);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'actuaciones_id_asunto_fk' AND conrelid = 'public.actuaciones_procesales'::regclass) THEN
    ALTER TABLE public.actuaciones_procesales
      ADD CONSTRAINT actuaciones_id_asunto_fk FOREIGN KEY (id_asunto) REFERENCES public.asuntos_juridicos(id) ON DELETE RESTRICT;
  END IF;
END $$;

-- E2 estrategias_juridicas: UNIQUE (id_asunto, numero_version)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'estrategias_version_uq' AND conrelid = 'public.estrategias_juridicas'::regclass) THEN
    ALTER TABLE public.estrategias_juridicas ADD CONSTRAINT estrategias_version_uq UNIQUE (id_asunto, numero_version);
  END IF;
END $$;
