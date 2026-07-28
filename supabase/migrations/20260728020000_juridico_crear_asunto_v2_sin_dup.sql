-- Portal Jurídico Fase 2 · T4 crear_asunto v2 — retirar bloqueo de duplicado por tipo
-- Fecha: 2026-07-28
--
-- Reemplaza (CREATE OR REPLACE) la versión de 20260728000000. Cambio (reconsiderado 2026-07-28):
-- se RETIRA la validación P0031 (no 2 asuntos activos del mismo tipo por expediente). Motivo:
-- una propiedad puede tener varias cuentas de cobranza (bodega/estacionamiento con cuenta propia)
-- y el expediente es por PROPIEDAD, no por cuenta → es legítimo tener 2 asuntos del mismo tipo
-- activos a la vez. La protección contra doble-submit accidental la dan el botón deshabilitado
-- (isPending) en front + el FOR UPDATE sobre el expediente.
--
-- Resto igual: SECURITY INVOKER, validaciones auth/rol {1,18,26}/origen/posición/tipo,
-- FOR UPDATE sobre expedientes_juridicos, P0029 (no encontrado) / P0030 (no ACTIVO),
-- id_etapa_actual NULL + actuación APERTURA. Firma sin cambios. Idempotente. Sin BEGIN/COMMIT.

CREATE OR REPLACE FUNCTION public.crear_asunto(
  p_id_expediente   BIGINT,
  p_id_tipo_asunto  BIGINT,
  p_origen          TEXT,
  p_posicion_sozu   TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_caller_uid       uuid;
  v_caller_email     text;
  v_expediente_row   expedientes_juridicos%ROWTYPE;
  v_id_asu           bigint;
  v_folio_asu        text;
  v_valid_origenes   text[] := ARRAY['SOZU_ACTORA', 'COMPRADOR_ACTOR', 'PROFECO'];
  v_valid_posiciones text[] := ARRAY['ACTOR', 'DEMANDADO', 'PROMOVENTE', 'PROVEEDOR'];
BEGIN
  -- 1. Autenticación
  v_caller_uid := auth.uid();
  IF v_caller_uid IS NULL THEN
    RAISE EXCEPTION 'Autenticación requerida.' USING ERRCODE = 'P0090';
  END IF;

  SELECT email INTO v_caller_email FROM usuarios WHERE auth_user_id = v_caller_uid AND activo = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Usuario no encontrado o inactivo.' USING ERRCODE = 'P0026';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM usuarios WHERE auth_user_id = v_caller_uid AND rol_id = ANY(ARRAY[1, 18, 26]) AND activo = true
  ) THEN
    RAISE EXCEPTION 'Rol sin permisos para crear asuntos.' USING ERRCODE = 'P0027';
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

  -- 3. Expediente debe existir y estar ACTIVO — FOR UPDATE serializa altas concurrentes
  SELECT * INTO v_expediente_row
  FROM expedientes_juridicos
  WHERE id = p_id_expediente
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Expediente % no encontrado.', p_id_expediente USING ERRCODE = 'P0029';
  END IF;

  IF v_expediente_row.estado <> 'ACTIVO' OR NOT v_expediente_row.activo THEN
    RAISE EXCEPTION 'El expediente % no está activo (estado=%).', p_id_expediente, v_expediente_row.estado USING ERRCODE = 'P0030';
  END IF;

  -- 4. INSERT asunto nuevo (id_etapa_actual NULL; primera etapa vía T2).
  --    Sin validación de duplicado por tipo: una propiedad puede tener varias cuentas de
  --    cobranza y por tanto varios asuntos legítimos del mismo tipo.
  INSERT INTO asuntos_juridicos (id_expediente, id_tipo_asunto, origen, posicion_sozu, creado_por, actualizado_por)
  VALUES (p_id_expediente, p_id_tipo_asunto, p_origen, p_posicion_sozu, v_caller_email, v_caller_email)
  RETURNING id, folio_visible INTO v_id_asu, v_folio_asu;

  -- 5. INSERT actuación APERTURA
  INSERT INTO actuaciones_procesales (id_asunto, tipo_actuacion, origen, tipo_fuente, fecha_actuacion, descripcion, creado_por)
  VALUES (v_id_asu, 'APERTURA', 'INTERNO', 'MANUAL', CURRENT_DATE, 'Asunto adicional creado en expediente existente', v_caller_email);

  -- 6. Envelope
  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'id_expediente',    p_id_expediente::text,
      'id_asunto',        v_id_asu::text,
      'folio_expediente', v_expediente_row.folio_visible,
      'folio_asunto',     v_folio_asu,
      'id_tipo_asunto',   p_id_tipo_asunto::text
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.crear_asunto(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.crear_asunto(BIGINT, BIGINT, TEXT, TEXT) FROM anon;
GRANT  EXECUTE ON FUNCTION public.crear_asunto(BIGINT, BIGINT, TEXT, TEXT) TO authenticated;

COMMENT ON FUNCTION public.crear_asunto(BIGINT, BIGINT, TEXT, TEXT) IS
  'T4 Fase 2 — agrega un asunto adicional a un expediente jurídico ACTIVO existente (multiasunto por propiedad). Permite varios asuntos del mismo tipo (una propiedad puede tener varias cuentas). No crea expediente, no bloquea cobranza. SECURITY INVOKER.';
