-- Portal Jurídico Fase 2 · T1 · RPC registrar_actuacion (bitácora inmutable)
-- Fecha: 2026-07-22
--
-- Inserta una actuación en actuaciones_procesales validando: usuario autenticado activo,
-- descripción no vacía (≤5000), CAMBIO_ETAPA prohibido (uso interno de cambiar_etapa_asunto),
-- tipo_fuente=IA reservado (Fase 4/5), fecha no futura, asunto existente y activo, y documento
-- (si se pasa) perteneciente al asunto. etapa_al_momento se toma del asunto. IDs devueltos como
-- text. SECURITY INVOKER (la RLS del correctivo aplica al llamador).
--
-- Depende de Fase 2 (20260721140000/150000) + correctivo (20260721170000). Idempotente:
-- CREATE OR REPLACE + REVOKE/GRANT/COMMENT. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

CREATE OR REPLACE FUNCTION public.registrar_actuacion(
  p_id_asunto       BIGINT,
  p_tipo_actuacion  TEXT,
  p_origen          TEXT,
  p_fecha_actuacion DATE,
  p_descripcion     TEXT,
  p_resultado       TEXT    DEFAULT NULL,
  p_tipo_fuente     TEXT    DEFAULT 'MANUAL',
  p_id_documento    BIGINT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_caller_email  TEXT;
  v_asunto_row    asuntos_juridicos%ROWTYPE;
  v_act_id        BIGINT;
BEGIN
  SELECT u.email INTO v_caller_email
  FROM public.usuarios u
  WHERE u.auth_user_id = auth.uid()
    AND u.activo = true
  LIMIT 1;

  IF v_caller_email IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado o inactivo. [JUR-0000]' USING ERRCODE = 'P0090';
  END IF;

  IF btrim(coalesce(p_descripcion, '')) = '' THEN
    RAISE EXCEPTION 'La descripción no puede estar vacía. [JUR-0009]' USING ERRCODE = 'P0009';
  END IF;

  IF char_length(p_descripcion) > 5000 THEN
    RAISE EXCEPTION 'La descripción supera el límite de 5 000 caracteres. [JUR-0016]' USING ERRCODE = 'P0016';
  END IF;

  IF p_tipo_actuacion = 'CAMBIO_ETAPA' THEN
    RAISE EXCEPTION
      'CAMBIO_ETAPA es de uso interno del RPC cambiar_etapa_asunto. Usa ese RPC directamente. [JUR-0010]'
      USING ERRCODE = 'P0010';
  END IF;

  IF p_tipo_fuente = 'IA' THEN
    RAISE EXCEPTION
      'tipo_fuente=IA está reservado para Fase 4/5 y no está habilitado en esta versión. [JUR-0015]'
      USING ERRCODE = 'P0015';
  END IF;

  IF p_fecha_actuacion > CURRENT_DATE THEN
    RAISE EXCEPTION 'La fecha de actuación no puede ser futura. [JUR-0013]' USING ERRCODE = 'P0013';
  END IF;

  SELECT * INTO v_asunto_row
  FROM public.asuntos_juridicos
  WHERE id = p_id_asunto;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Asunto % no encontrado o sin acceso. [JUR-0011]', p_id_asunto USING ERRCODE = 'P0011';
  END IF;

  IF NOT v_asunto_row.activo THEN
    RAISE EXCEPTION 'El asunto % no está activo. [JUR-0012]', p_id_asunto USING ERRCODE = 'P0012';
  END IF;

  IF p_id_documento IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.app_juridico_documentos
      WHERE id = p_id_documento
        AND id_asunto = p_id_asunto
    ) THEN
      RAISE EXCEPTION
        'El documento % no existe, no es accesible o no pertenece al asunto %. [JUR-0014]',
        p_id_documento, p_id_asunto
        USING ERRCODE = 'P0014';
    END IF;
  END IF;

  INSERT INTO public.actuaciones_procesales (
    id_asunto, tipo_actuacion, origen, tipo_fuente,
    etapa_al_momento, fecha_actuacion, descripcion,
    resultado, id_documento, creado_por
  ) VALUES (
    p_id_asunto, p_tipo_actuacion, p_origen, p_tipo_fuente,
    v_asunto_row.id_etapa_actual,
    p_fecha_actuacion, p_descripcion, p_resultado,
    p_id_documento, v_caller_email
  )
  RETURNING id INTO v_act_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'id',        v_act_id::text,
      'id_asunto', p_id_asunto::text
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_actuacion(
  BIGINT, TEXT, TEXT, DATE, TEXT, TEXT, TEXT, BIGINT
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.registrar_actuacion(
  BIGINT, TEXT, TEXT, DATE, TEXT, TEXT, TEXT, BIGINT
) TO authenticated;

COMMENT ON FUNCTION public.registrar_actuacion IS
  'T1 — Bitácora inmutable. Contract v1. Portal Jurídico Fase 2 v2.2. CAMBIO_ETAPA y tipo_fuente=IA reservados. IDs devueltos como text. v1.1 post-auditoría.';
