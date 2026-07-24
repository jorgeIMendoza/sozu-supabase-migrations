-- Portal Jurídico Fase 2 · T3 · RPC crear_expediente (transaccional)
-- Fecha: 2026-07-24
--
-- Crea de forma atómica: expediente jurídico + primer asunto + actuación APERTURA.
-- Decisiones (dictamen 2026-07-23):
--   · id_etapa_actual = NULL (la primera etapa se asigna vía T2 cambiar_etapa_asunto).
--   · Actuación APERTURA automática (descripcion fija 'Expediente creado').
--   · Unicidad: máx. 1 expediente ACTIVO por (propiedad + tipo_asunto).
--   · Advisory lock (hashtextextended sobre id_propiedad|id_tipo_asunto) serializa double-submit.
-- SQLSTATEs: P0021 propiedad/proyecto inválido (wrap de P0001 del trigger check_expediente_proyecto),
--   P0022 origen inválido, P0023 posición inválida, P0024 tipo asunto no encontrado/inactivo,
--   P0025 expediente ACTIVO ya existe. Rol autorizado {1,18,26}. SECURITY INVOKER.
--
-- Depende de Fase 2 (20260721140000/150000) + correctivo (20260721170000: triggers
-- enforce_audit_mutable, enforce_audit_actuaciones, check_expediente_proyecto, check_etapa_tipo_asunto).
-- Idempotente: CREATE OR REPLACE + REVOKE/GRANT/COMMENT. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

CREATE OR REPLACE FUNCTION public.crear_expediente(
  p_id_propiedad   BIGINT,
  p_id_proyecto    INTEGER,
  p_id_tipo_asunto BIGINT,
  p_origen         TEXT,
  p_posicion_sozu  TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_caller_uid      uuid;
  v_caller_email    text;
  v_id_exp          bigint;
  v_id_asu          bigint;
  v_folio_exp       text;
  v_folio_asu       text;
  v_valid_origenes  text[] := ARRAY['SOZU_ACTORA', 'COMPRADOR_ACTOR', 'PROFECO'];
  v_valid_posiciones text[] := ARRAY['ACTOR', 'DEMANDADO', 'PROMOVENTE', 'PROVEEDOR'];
BEGIN
  -- 1. Autenticación
  v_caller_uid := auth.uid();
  IF v_caller_uid IS NULL THEN
    RAISE EXCEPTION 'Autenticación requerida.' USING ERRCODE = 'P0090';
  END IF;

  SELECT email INTO v_caller_email FROM usuarios WHERE auth_user_id = v_caller_uid AND activo = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Usuario no encontrado o inactivo.' USING ERRCODE = 'P0011';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM usuarios WHERE auth_user_id = v_caller_uid AND rol_id = ANY(ARRAY[1, 18, 26]) AND activo = true
  ) THEN
    RAISE EXCEPTION 'Rol sin permisos para crear expedientes.' USING ERRCODE = 'P0012';
  END IF;

  -- 2. Validación de parámetros
  IF p_origen IS NULL OR NOT (p_origen = ANY(v_valid_origenes)) THEN
    RAISE EXCEPTION 'Origen inválido: %. Valores permitidos: SOZU_ACTORA, COMPRADOR_ACTOR, PROFECO.', p_origen USING ERRCODE = 'P0022';
  END IF;

  IF p_posicion_sozu IS NULL OR NOT (p_posicion_sozu = ANY(v_valid_posiciones)) THEN
    RAISE EXCEPTION 'Posición SOZU inválida: %. Valores permitidos: ACTOR, DEMANDADO, PROMOVENTE, PROVEEDOR.', p_posicion_sozu USING ERRCODE = 'P0023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM cat_tipos_asunto WHERE id = p_id_tipo_asunto AND activo = true) THEN
    RAISE EXCEPTION 'Tipo de asunto % no encontrado o inactivo.', p_id_tipo_asunto USING ERRCODE = 'P0024';
  END IF;

  -- 3. Advisory lock — serializa double-submit por propiedad + tipo_asunto
  PERFORM pg_advisory_xact_lock(hashtextextended(p_id_propiedad::text || '|' || p_id_tipo_asunto::text, 0));

  -- 4. Unicidad: máximo un expediente ACTIVO por propiedad + tipo_asunto
  IF EXISTS (
    SELECT 1 FROM expedientes_juridicos e
    JOIN asuntos_juridicos a ON a.id_expediente = e.id
    WHERE e.id_propiedad = p_id_propiedad
      AND a.id_tipo_asunto = p_id_tipo_asunto
      AND e.estado = 'ACTIVO'
      AND e.activo = true
  ) THEN
    RAISE EXCEPTION 'Ya existe un expediente ACTIVO para la propiedad % con tipo de asunto %.', p_id_propiedad, p_id_tipo_asunto USING ERRCODE = 'P0025';
  END IF;

  -- 5. INSERT expediente (enforce_audit_mutable fija creado_por/actualizado_por;
  --    check_expediente_proyecto valida la cadena propiedad→edificio→proyecto).
  BEGIN
    INSERT INTO expedientes_juridicos (id_propiedad, id_proyecto, creado_por, actualizado_por)
    VALUES (p_id_propiedad, p_id_proyecto, v_caller_email, v_caller_email)
    RETURNING id, folio_visible INTO v_id_exp, v_folio_exp;
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    RAISE EXCEPTION 'Propiedad % no encontrada o id_proyecto % no coincide con la cadena de edificio.', p_id_propiedad, p_id_proyecto USING ERRCODE = 'P0021';
  END;

  -- 6. INSERT asunto inicial (id_etapa_actual NULL; primera etapa vía T2)
  INSERT INTO asuntos_juridicos (id_expediente, id_tipo_asunto, origen, posicion_sozu, creado_por, actualizado_por)
  VALUES (v_id_exp, p_id_tipo_asunto, p_origen, p_posicion_sozu, v_caller_email, v_caller_email)
  RETURNING id, folio_visible INTO v_id_asu, v_folio_asu;

  -- 7. INSERT actuación APERTURA (primer evento inmutable; etapa_al_momento NULL)
  INSERT INTO actuaciones_procesales (id_asunto, tipo_actuacion, origen, tipo_fuente, fecha_actuacion, descripcion, creado_por)
  VALUES (v_id_asu, 'APERTURA', 'INTERNO', 'MANUAL', CURRENT_DATE, 'Expediente creado', v_caller_email);

  -- 8. Envelope
  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'id_expediente',    v_id_exp::text,
      'id_asunto',        v_id_asu::text,
      'folio_expediente', v_folio_exp,
      'folio_asunto',     v_folio_asu,
      'id_tipo_asunto',   p_id_tipo_asunto::text
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.crear_expediente(BIGINT, INTEGER, BIGINT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.crear_expediente(BIGINT, INTEGER, BIGINT, TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.crear_expediente(BIGINT, INTEGER, BIGINT, TEXT, TEXT) TO authenticated;

COMMENT ON FUNCTION public.crear_expediente(BIGINT, INTEGER, BIGINT, TEXT, TEXT) IS
  'T3 — Fase 2 Portal Jurídico. Crea expediente + asunto inicial + actuación APERTURA de forma atómica. Requiere rol {1,18,26}. Unicidad activa por (id_propiedad + id_tipo_asunto). SECURITY INVOKER.';
