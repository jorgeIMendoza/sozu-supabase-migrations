-- Portal Jurídico Fase 1 · DDL-4B · Función crear_expediente_demanda
-- Fecha: 2026-07-21
--
-- Crea un expediente (demanda + entrada de timeline) y marca la propiedad como "En demanda"
-- (estatus 11) en una sola transacción. SECURITY DEFINER: la identidad del ejecutor se deriva
-- de auth.uid() → public.usuarios (no de parámetros del frontend). Solo roles 1/18/26.
-- Devuelve JSONB {success:true,...} o, ante error, {success:false, code, hint, detail} para
-- que PostgREST responda HTTP 200 y el front maneje el fallo.
--
-- Idempotente: CREATE OR REPLACE + REVOKE/GRANT. Sin BEGIN/COMMIT (CI/CD envuelve en tx).
-- Depende de: índice único demandas_cuenta_uidx, CHECK tipo_evento con 'CREACION',
-- estatus_disponibilidad id=11.

CREATE OR REPLACE FUNCTION public.crear_expediente_demanda(
  p_id_cuenta_cobranza BIGINT,
  p_id_propiedad       BIGINT,
  p_estatus_demanda    TEXT DEFAULT 'NOTIFICADO',
  p_observaciones      TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_auth_uid           UUID;
  v_usuario_id         BIGINT;
  v_rol_id             BIGINT;
  v_email_ejecutor     TEXT;
  v_demanda_id         BIGINT;
  v_timeline_id        BIGINT;
  v_propiedad_estatus  INTEGER;
  v_cuenta_es_principal BOOLEAN;
BEGIN
  -- 1. Validar sesión activa
  v_auth_uid := auth.uid();
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'usuario_no_autenticado'
      USING DETAIL  = 'auth.uid() retornó NULL. Se requiere JWT válido.',
            ERRCODE = 'P0001';
  END IF;

  -- 2. Verificar usuario activo en public.usuarios (identidad derivada de la BD)
  SELECT u.id, u.rol_id, u.email
  INTO v_usuario_id, v_rol_id, v_email_ejecutor
  FROM public.usuarios u
  WHERE u.auth_user_id = v_auth_uid AND u.activo = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'usuario_no_registrado'
      USING DETAIL  = format('auth.uid() %s no corresponde a usuario activo.', v_auth_uid),
            HINT    = 'Verificar que el usuario existe en public.usuarios con activo=true.',
            ERRCODE = 'P0002';
  END IF;

  -- 3. Validar rol autorizado (1 Super Admin, 18 Admin Legal, 26 Jurídico)
  IF v_rol_id NOT IN (1, 18, 26) THEN
    RAISE EXCEPTION 'rol_no_autorizado'
      USING DETAIL  = format('rol_id=%s no tiene permiso para crear expedientes.', v_rol_id),
            HINT    = 'Roles autorizados: 1 (Super Administrador), 18 (Admin Legal), 26 (Jurídico).',
            ERRCODE = 'P0003';
  END IF;

  -- 4. Validar parámetros obligatorios
  IF p_id_cuenta_cobranza IS NULL THEN
    RAISE EXCEPTION 'parametro_nulo: p_id_cuenta_cobranza' USING ERRCODE = 'P0004';
  END IF;
  IF p_id_propiedad IS NULL THEN
    RAISE EXCEPTION 'parametro_nulo: p_id_propiedad' USING ERRCODE = 'P0004';
  END IF;

  -- 5. Validar estatus_demanda inicial
  IF p_estatus_demanda NOT IN (
    'SIN_DEMANDA','NOTIFICADO','EN_PROCESO','ACUERDO','LITIGIO','RESUELTO'
  ) THEN
    RAISE EXCEPTION 'estatus_demanda_invalido'
      USING DETAIL  = format('"%s" no es un valor válido para apertura de expediente.', p_estatus_demanda),
            HINT    = 'Valores permitidos: SIN_DEMANDA, NOTIFICADO, EN_PROCESO, ACUERDO, LITIGIO, RESUELTO.',
            ERRCODE = 'P0005';
  END IF;

  -- 6. Bloquear la propiedad para prevenir condición de carrera
  SELECT id_estatus_disponibilidad
  INTO v_propiedad_estatus
  FROM public.propiedades
  WHERE id = p_id_propiedad
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'propiedad_no_encontrada'
      USING DETAIL  = format('No existe propiedad con id=%s.', p_id_propiedad),
            ERRCODE = 'P0006';
  END IF;

  -- 7. Validar que la cuenta pertenece a la propiedad, es principal y está activa
  SELECT EXISTS (
    SELECT 1 FROM public.cuentas_cobranza cc
    WHERE cc.id = p_id_cuenta_cobranza
      AND cc.id_propiedad = p_id_propiedad
      AND cc.id_cuenta_cobranza_padre IS NULL
      AND cc.activo = true
  ) INTO v_cuenta_es_principal;

  IF NOT v_cuenta_es_principal THEN
    RAISE EXCEPTION 'cuenta_invalida_o_no_principal'
      USING DETAIL  = format(
              'La cuenta %s no es principal de la propiedad %s, no le pertenece, o no está activa.',
              p_id_cuenta_cobranza, p_id_propiedad),
            HINT    = 'La cuenta principal se identifica por id_cuenta_cobranza_padre IS NULL.',
            ERRCODE = 'P0007';
  END IF;

  -- 8. Validar que no existe demanda activa para esta cuenta
  IF EXISTS (
    SELECT 1 FROM public.demandas d
    WHERE d.id_cuenta_cobranza = p_id_cuenta_cobranza AND d.activo = true
  ) THEN
    RAISE EXCEPTION 'demanda_activa_existente'
      USING DETAIL  = format('La cuenta %s ya tiene una demanda activa.', p_id_cuenta_cobranza),
            HINT    = 'Solo puede existir una demanda activa por cuenta de cobranza.',
            ERRCODE = 'P0008';
  END IF;

  -- 9. INSERT en public.demandas
  INSERT INTO public.demandas (
    id_cuenta_cobranza, id_propiedad, estatus_demanda, observaciones, activo
  )
  VALUES (p_id_cuenta_cobranza, p_id_propiedad, p_estatus_demanda, p_observaciones, true)
  RETURNING id INTO v_demanda_id;

  -- 10. INSERT en public.demandas_timeline (tipo_evento = 'CREACION')
  INSERT INTO public.demandas_timeline (id_demanda, tipo_evento, descripcion, creado_por)
  VALUES (
    v_demanda_id,
    'CREACION',
    format('Expediente creado. Estatus inicial: %s. Usuario: %s (rol_id=%s).',
           p_estatus_demanda, v_email_ejecutor, v_rol_id),
    v_email_ejecutor
  )
  RETURNING id INTO v_timeline_id;

  -- 11. UPDATE propiedades → "En demanda" (id=11)
  UPDATE public.propiedades
  SET id_estatus_disponibilidad = 11, fecha_actualizacion = now()
  WHERE id = p_id_propiedad;

  -- 12. Resultado exitoso
  RETURN jsonb_build_object(
    'success',       true,
    'demanda_id',    v_demanda_id,
    'timeline_id',   v_timeline_id,
    'propiedad_id',  p_id_propiedad,
    'cuenta_id',     p_id_cuenta_cobranza,
    'estatus',       p_estatus_demanda,
    'ejecutado_por', v_email_ejecutor,
    'rol_id',        v_rol_id
  );

EXCEPTION WHEN OTHERS THEN
  -- Los DML de los pasos 9-11 se revierten automáticamente.
  RETURN jsonb_build_object(
    'success', false,
    'error',   SQLERRM,
    'code',    SQLSTATE,
    'hint',    COALESCE(PG_EXCEPTION_HINT, ''),
    'detail',  COALESCE(PG_EXCEPTION_DETAIL, '')
  );
END;
$$;

-- Permisos: solo authenticated puede ejecutar.
REVOKE ALL ON FUNCTION public.crear_expediente_demanda(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.crear_expediente_demanda(BIGINT, BIGINT, TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.crear_expediente_demanda(BIGINT, BIGINT, TEXT, TEXT) TO authenticated;
