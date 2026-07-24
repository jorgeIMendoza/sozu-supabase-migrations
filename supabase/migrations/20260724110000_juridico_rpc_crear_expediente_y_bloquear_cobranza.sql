-- Portal Jurídico Fase 2 · RPC orquestador crear_expediente_y_bloquear_cobranza
-- Fecha: 2026-07-24
--
-- Punto de creación desde Portal Cobranza (reemplaza la llamada directa a
-- crear_expediente_demanda de EnDemandaDialog.tsx — sustitución de front pendiente).
-- Envuelve T3 (crear_expediente, SECURITY INVOKER) + el efecto institucional de bloqueo de
-- propiedad (id_estatus_disponibilidad=11 "En Demanda") en una sola transacción.
--
-- Decisiones:
--   · SECURITY DEFINER: requerido para el UPDATE propiedades (excede lo que RLS permite al
--     rol jurídico bajo INVOKER). La lógica de auth/rol/validación/D-3/advisory lock la hace
--     crear_expediente() — no se duplica; si T3 lanza, ROLLBACK total.
--   · NO replica el bookkeeping legacy (demandas/demandas_timeline): la actuación APERTURA
--     que crea T3 lo reemplaza. Sin dual-write.
--   · Lock: SELECT ... FOR UPDATE sobre la cuenta principal (padre IS NULL, activa) antes de
--     resolver id_propiedad. Errores como RAISE EXCEPTION (no envelope), consumible por
--     normalizeJuridicoError. Nuevo SQLSTATE P0028 (JUR-0028) cuenta inválida/inactiva/no principal.
--
-- Depende de crear_expediente (20260724000000) + Fase 2/correctivo. Idempotente:
-- CREATE OR REPLACE + REVOKE/GRANT/COMMENT. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

CREATE OR REPLACE FUNCTION public.crear_expediente_y_bloquear_cobranza(
  p_id_cuenta_cobranza BIGINT,
  p_id_proyecto        INTEGER,
  p_id_tipo_asunto     BIGINT,
  p_origen             TEXT,
  p_posicion_sozu      TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id_propiedad  BIGINT;
  v_resultado_t3  JSONB;
BEGIN
  -- 1. Resolver y bloquear la cuenta principal (padre IS NULL, activa). FOR UPDATE serializa.
  SELECT cc.id_propiedad INTO v_id_propiedad
  FROM cuentas_cobranza cc
  WHERE cc.id = p_id_cuenta_cobranza
    AND cc.id_cuenta_cobranza_padre IS NULL
    AND cc.activo = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cuenta % inexistente, inactiva o no principal (padre IS NULL).', p_id_cuenta_cobranza USING ERRCODE = 'P0028';
  END IF;

  -- 2. Delegar a T3 (auth, rol {1,18,26}, validación, D-3, advisory lock). Si lanza, ROLLBACK total.
  v_resultado_t3 := crear_expediente(v_id_propiedad, p_id_proyecto, p_id_tipo_asunto, p_origen, p_posicion_sozu);

  -- 3. Efecto institucional: propiedad → "En Demanda" (id=11)
  UPDATE propiedades SET id_estatus_disponibilidad = 11, fecha_actualizacion = now()
  WHERE id = v_id_propiedad;

  -- 4. Envelope combinado
  RETURN jsonb_build_object(
    'success', true,
    'data', v_resultado_t3->'data' || jsonb_build_object('idPropiedadBloqueada', v_id_propiedad::text)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.crear_expediente_y_bloquear_cobranza(BIGINT, INTEGER, BIGINT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.crear_expediente_y_bloquear_cobranza(BIGINT, INTEGER, BIGINT, TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.crear_expediente_y_bloquear_cobranza(BIGINT, INTEGER, BIGINT, TEXT, TEXT) TO authenticated;

COMMENT ON FUNCTION public.crear_expediente_y_bloquear_cobranza(BIGINT, INTEGER, BIGINT, TEXT, TEXT) IS
  'Orquestador — envuelve T3 crear_expediente + bloqueo institucional de propiedad (id_estatus_disponibilidad=11), preservando el efecto de crear_expediente_demanda sin duplicar su bookkeeping legacy (demandas/demandas_timeline). SECURITY DEFINER (requerido para UPDATE propiedades). Rollback total si T3 falla.';
