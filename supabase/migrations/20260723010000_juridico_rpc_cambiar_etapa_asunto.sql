-- Portal Jurídico Fase 2 · T2 · RPC cambiar_etapa_asunto (transición de etapa procesal)
-- Fecha: 2026-07-23
--
-- Transiciona la etapa de un asunto y registra la transición en la bitácora inmutable
-- actuaciones_procesales (tipo_actuacion='CAMBIO_ETAPA', reservado a este RPC). Valida:
-- usuario autenticado activo, descripción no vacía (≤5000), asunto existente/activo/con acceso
-- (FOR UPDATE → exclusión mutua anti-concurrencia), etapa nueva existente/activa, etapa nueva
-- del mismo id_tipo_asunto, transición no-op prohibida, y etapa actual no terminal.
-- etapa_al_momento = etapa ANTERIOR (documenta el origen de la transición; el destino queda
-- en asuntos_juridicos.id_etapa_actual). origen='INTERNO', tipo_fuente='MANUAL',
-- fecha_actuacion=CURRENT_DATE (fijos). IDs devueltos como text. SECURITY INVOKER (la RLS del
-- correctivo aplica al llamador; rol 26 solo ve asuntos donde es id_abogado_responsable).
--
-- Contrato v1: transiciones libres — cualquier etapa activa del mismo tipo puede ir a cualquier
-- otra del mismo tipo, sin validación de secuencia. Fase 3 introducirá cat_transiciones_procesales
-- (error JUR-0021 propuesto).
--
-- Catálogo de errores: JUR-0000/P0090 (sin usuario activo, heredado T1), JUR-0009/P0009 (desc
-- vacía), JUR-0011/P0011 (asunto no encontrado/sin acceso), JUR-0012/P0012 (asunto inactivo),
-- JUR-0016/P0016 (desc >5000), JUR-0017/P0017 (etapa nueva no encontrada/inactiva),
-- JUR-0018/P0018 (etapa de otro tipo_asunto), JUR-0019/P0019 (no-op misma etapa),
-- JUR-0020/P0020 (etapa actual terminal).
--
-- Depende de Fase 2 (20260721140000/150000) + correctivo (20260721170000) + T1
-- (20260722060000/070000). Idempotente: CREATE OR REPLACE + REVOKE/GRANT/COMMENT.
-- Sin BEGIN/COMMIT (CI/CD envuelve en tx).

CREATE OR REPLACE FUNCTION public.cambiar_etapa_asunto(
  p_id_asunto      BIGINT,
  p_id_etapa_nueva BIGINT,
  p_descripcion    TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_caller_email            TEXT;
  v_asunto_row              asuntos_juridicos%ROWTYPE;
  v_etapa_anterior          BIGINT;
  v_etapa_anterior_terminal BOOLEAN;
  v_etapa_row               cat_etapas_procesales%ROWTYPE;
  v_act_id                  BIGINT;
BEGIN

  -- 1. Resolver email del caller desde auth.uid()
  SELECT u.email INTO v_caller_email
  FROM public.usuarios u
  WHERE u.auth_user_id = auth.uid()
    AND u.activo = true
  LIMIT 1;

  IF v_caller_email IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado o inactivo. [JUR-0000]'
      USING ERRCODE = 'P0090';
  END IF;

  -- 2. Validar descripción no vacía
  IF btrim(coalesce(p_descripcion, '')) = '' THEN
    RAISE EXCEPTION 'La descripción no puede estar vacía. [JUR-0009]'
      USING ERRCODE = 'P0009';
  END IF;

  -- 3. Validar longitud de descripción
  IF char_length(p_descripcion) > 5000 THEN
    RAISE EXCEPTION 'La descripción supera el límite de 5 000 caracteres. [JUR-0016]'
      USING ERRCODE = 'P0016';
  END IF;

  -- 4. Obtener asunto con FOR UPDATE (RLS SELECT aplica al caller; lock anti-concurrencia)
  SELECT * INTO v_asunto_row
  FROM public.asuntos_juridicos
  WHERE id = p_id_asunto
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Asunto % no encontrado o sin acceso. [JUR-0011]', p_id_asunto
      USING ERRCODE = 'P0011';
  END IF;

  -- 5. Validar que el asunto esté activo
  IF NOT v_asunto_row.activo THEN
    RAISE EXCEPTION 'El asunto % no está activo. [JUR-0012]', p_id_asunto
      USING ERRCODE = 'P0012';
  END IF;

  -- 6. Capturar etapa anterior ANTES del UPDATE (etapa_al_momento = origen de la transición)
  v_etapa_anterior := v_asunto_row.id_etapa_actual;

  -- 7. Validar que la etapa nueva existe y está activa
  SELECT * INTO v_etapa_row
  FROM public.cat_etapas_procesales
  WHERE id = p_id_etapa_nueva
    AND activo = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Etapa % no encontrada o inactiva. [JUR-0017]', p_id_etapa_nueva
      USING ERRCODE = 'P0017';
  END IF;

  -- 8. Validar que la etapa nueva pertenece al mismo tipo de asunto
  --    (el trigger check_etapa_tipo_asunto repite esto como defensa en profundidad)
  IF v_etapa_row.id_tipo_asunto <> v_asunto_row.id_tipo_asunto THEN
    RAISE EXCEPTION
      'La etapa % pertenece al tipo_asunto % pero el asunto % es de tipo %. [JUR-0018]',
      p_id_etapa_nueva, v_etapa_row.id_tipo_asunto, p_id_asunto, v_asunto_row.id_tipo_asunto
      USING ERRCODE = 'P0018';
  END IF;

  -- 9. Validar transición no-op (mismo estado). IS NOT DISTINCT FROM maneja NULL.
  IF v_etapa_anterior IS NOT DISTINCT FROM p_id_etapa_nueva THEN
    RAISE EXCEPTION
      'El asunto % ya se encuentra en la etapa %. [JUR-0019]', p_id_asunto, p_id_etapa_nueva
      USING ERRCODE = 'P0019';
  END IF;

  -- 10. Validar que la etapa actual no es terminal (si existe etapa actual)
  IF v_etapa_anterior IS NOT NULL THEN
    SELECT ep.es_terminal INTO v_etapa_anterior_terminal
    FROM public.cat_etapas_procesales ep
    WHERE ep.id = v_etapa_anterior;

    IF v_etapa_anterior_terminal THEN
      RAISE EXCEPTION
        'El asunto % está en una etapa terminal (%) y no puede transicionar. [JUR-0020]',
        p_id_asunto, v_etapa_anterior
        USING ERRCODE = 'P0020';
    END IF;
  END IF;

  -- 11. UPDATE atómico: actualizar etapa en el asunto
  --     (triggers BEFORE UPDATE: enforce_audit_mutable, check_etapa_tipo_asunto, check_rol26)
  UPDATE public.asuntos_juridicos
  SET id_etapa_actual = p_id_etapa_nueva
  WHERE id = p_id_asunto;

  -- 12. INSERT en bitácora inmutable (creado_por lo sobrescribe enforce_audit_actuaciones)
  INSERT INTO public.actuaciones_procesales (
    id_asunto,
    tipo_actuacion,
    origen,
    tipo_fuente,
    etapa_al_momento,
    fecha_actuacion,
    descripcion,
    resultado,
    id_documento,
    creado_por
  ) VALUES (
    p_id_asunto,
    'CAMBIO_ETAPA',
    'INTERNO',
    'MANUAL',
    v_etapa_anterior,
    CURRENT_DATE,
    p_descripcion,
    NULL,
    NULL,
    v_caller_email
  )
  RETURNING id INTO v_act_id;

  -- 13. Envelope uniforme; IDs como text (BIGINT > Number.MAX_SAFE_INTEGER en JS)
  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'id',        v_act_id::text,
      'id_asunto', p_id_asunto::text
    )
  );

END;
$$;

-- Supabase self-hosted: ALTER DEFAULT PRIVILEGES otorga EXECUTE a anon/authenticated en toda
-- función nueva. REVOKE FROM PUBLIC no elimina los grants por-rol → REVOKE FROM anon explícito.
REVOKE ALL ON FUNCTION public.cambiar_etapa_asunto(BIGINT, BIGINT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cambiar_etapa_asunto(BIGINT, BIGINT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.cambiar_etapa_asunto(BIGINT, BIGINT, TEXT) TO authenticated;

COMMENT ON FUNCTION public.cambiar_etapa_asunto IS
  'T2 — Transición de etapa procesal. Contrato v1. Portal Jurídico Fase 2 v2.2. etapa_al_momento=anterior. FOR UPDATE anti-concurrencia. Transiciones libres sin cat_transiciones_procesales (Fase 3).';
