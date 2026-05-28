-- =============================================================
-- RPC get_workflow_evaluation
-- Fecha: 2026-05-27
-- Fuente: sozu-edge-functions/Ejecuciones/ejecutar.md
--
-- Consolida en una sola llamada server-side la evaluación del
-- workflow de escrituración que WorkflowDashboard.tsx resuelve
-- actualmente con 15+ queries paralelas client-side.
-- =============================================================

CREATE OR REPLACE FUNCTION public.get_workflow_evaluation(p_cuenta_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result         jsonb;
  v_cuenta         record;
  v_propiedad      record;
  v_notario        record;
  v_credito        record;
  v_proceso        record;
  v_demanda        record;
  v_pld_status     text := 'PENDIENTE';
  v_pld_bloqueado  boolean := false;
  v_total_pagado   numeric := 0;
  v_sin_cr         integer := 0;
  v_sin_cep        integer := 0;
  v_docs_completos integer := 0;
  v_docs_total     integer := 0;
  v_cita_firma     record;
  v_compradores    jsonb;
  v_steps          jsonb;
  v_step_array     jsonb[] := '{}';
  v_pct_progreso   numeric := 0;
  v_overall_status text := 'PENDIENTE';
  v_blocking       text[] := '{}';
  v_metodo_pago    text := 'RECURSOS_PROPIOS';
BEGIN

  -- 1. Cuenta principal
  SELECT cc.*, p.id AS prop_id, p.numero_propiedad, p.id_estatus_disponibilidad,
         proy.id AS proyecto_id, proy.nombre AS proyecto_nombre,
         n.id AS notario_id, n.notaria AS notaria_nombre
  INTO v_cuenta
  FROM cuentas_cobranza cc
  JOIN propiedades p      ON p.id = cc.id_propiedad
  JOIN edificios_modelos em ON em.id = p.id_edificio_modelo
  JOIN edificios e         ON e.id = em.id_edificio
  JOIN proyectos proy      ON proy.id = e.id_proyecto
  LEFT JOIN notarios n     ON n.id = cc.id_notario
  WHERE cc.id = p_cuenta_id AND cc.activo = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Cuenta no encontrada', 'account_id', p_cuenta_id);
  END IF;

  -- 2. Compradores
  SELECT jsonb_agg(jsonb_build_object(
    'nombre', COALESCE(pe.nombre_legal, pe.nombre_comercial, '—'),
    'email',  pe.email,
    'rfc',    pe.rfc
  ))
  INTO v_compradores
  FROM compradores c
  JOIN personas pe ON pe.id = c.id_persona
  WHERE c.id_cuenta_cobranza = p_cuenta_id AND c.activo = true;

  -- 3. Pagos y motor PLD
  SELECT
    COALESCE(SUM(monto), 0),
    COUNT(*) FILTER (WHERE clave_rastreo IS NULL OR clave_rastreo = ''),
    COUNT(*) FILTER (WHERE (clave_rastreo IS NOT NULL AND clave_rastreo != '') AND (url_cep IS NULL OR url_cep = ''))
  INTO v_total_pagado, v_sin_cr, v_sin_cep
  FROM pagos
  WHERE id_cuenta_cobranza = p_cuenta_id AND activo = true;

  -- Evaluar PLD (misma lógica que PldDashboard.tsx)
  IF v_sin_cr > 0 THEN
    v_pld_status    := 'BLOQUEADO';
    v_pld_bloqueado := true;
    v_blocking      := array_append(v_blocking, 'Hay pagos sin clave de rastreo (PLD BLOQUEADO)');
  ELSIF v_sin_cep > 0 THEN
    v_pld_status := 'EN_REVISION';
    v_blocking   := array_append(v_blocking, 'Hay pagos sin CEP (PLD EN REVISIÓN)');
  ELSIF v_total_pagado > v_cuenta.precio_final * 1.01 THEN
    v_pld_status    := 'OBSERVADO';
    v_pld_bloqueado := true;
    v_blocking      := array_append(v_blocking, 'Sobrepago detectado — revisar con PLD');
  ELSIF v_total_pagado >= v_cuenta.precio_final * 0.99 THEN
    v_pld_status := 'APROBADO';
  END IF;

  -- 4. Documentos (expediente)
  SELECT
    COUNT(*) FILTER (WHERE id_estatus_verificacion >= 2),
    COUNT(*)
  INTO v_docs_completos, v_docs_total
  FROM documentos
  WHERE id_cuenta_cobranza = p_cuenta_id AND activo = true;

  -- 5. Crédito hipotecario (graceful — tabla puede no existir aún)
  BEGIN
    SELECT * INTO v_credito
    FROM creditos_hipotecarios
    WHERE id_cuenta_cobranza = p_cuenta_id AND activo = true
    LIMIT 1;

    IF FOUND THEN
      v_metodo_pago := 'CREDITO_HIPOTECARIO';
    END IF;
  EXCEPTION WHEN undefined_table THEN
    v_credito := NULL;
  END;

  -- 6. app_notaria_proceso (graceful — tabla puede no existir aún)
  BEGIN
    SELECT * INTO v_proceso
    FROM app_notaria_proceso
    WHERE id_cuenta_cobranza = p_cuenta_id AND activo = true
    LIMIT 1;
  EXCEPTION WHEN undefined_table THEN
    v_proceso := NULL;
  END;

  -- 7. Cita de firma
  SELECT rc.* INTO v_cita_firma
  FROM reservas_citas rc
  JOIN tipos_cita tc ON tc.id = rc.id_tipo_cita
  JOIN compradores c ON c.id_persona = rc.id_persona
  WHERE c.id_cuenta_cobranza = p_cuenta_id
    AND rc.activo = true
    AND (LOWER(tc.nombre) LIKE '%firma%' OR LOWER(tc.nombre) LIKE '%escritur%' OR LOWER(tc.nombre) LIKE '%notari%')
  ORDER BY rc.fecha DESC
  LIMIT 1;

  -- 8. Demandas (graceful — tabla puede no existir aún)
  BEGIN
    SELECT * INTO v_demanda
    FROM demandas
    WHERE id_cuenta_cobranza = p_cuenta_id AND activo = true
    LIMIT 1;
  EXCEPTION WHEN undefined_table THEN
    v_demanda := NULL;
  END;

  -- 9. Construir pasos del workflow

  -- Paso 1: Expediente documental
  v_step_array := array_append(v_step_array, jsonb_build_object(
    'id', 'expediente',
    'order', 1,
    'branch', 'GENERAL',
    'title', 'Expediente documental',
    'description', 'Documentos KYC completos y verificados',
    'status', CASE
      WHEN v_docs_total = 0                       THEN 'PENDIENTE'
      WHEN v_docs_completos = v_docs_total         THEN 'COMPLETO'
      WHEN v_docs_completos > 0                    THEN 'EN_PROCESO'
      ELSE 'PENDIENTE'
    END,
    'sourceModule', 'EXPEDIENTES',
    'responsibleRole', 'COMPRADOR',
    'evidence', jsonb_build_array(jsonb_build_object(
      'label', format('%s / %s documentos completos', v_docs_completos, v_docs_total),
      'type', 'DOCUMENT'
    )),
    'missingValidations', CASE
      WHEN v_docs_completos < v_docs_total
      THEN jsonb_build_array(format('%s documentos pendientes de validación', v_docs_total - v_docs_completos))
      ELSE '[]'::jsonb
    END
  ));

  -- Paso 2: PLD
  v_step_array := array_append(v_step_array, jsonb_build_object(
    'id', 'pld',
    'order', 2,
    'branch', 'GENERAL',
    'title', 'Prevención de Lavado de Dinero',
    'description', 'Pagos con clave de rastreo y CEP validados',
    'status', CASE v_pld_status
      WHEN 'APROBADO'    THEN 'COMPLETO'
      WHEN 'BLOQUEADO'   THEN 'BLOQUEADO'
      WHEN 'EN_REVISION' THEN 'EN_PROCESO'
      WHEN 'OBSERVADO'   THEN 'BLOQUEADO'
      ELSE 'PENDIENTE'
    END,
    'sourceModule', 'PLD',
    'responsibleRole', 'SISTEMA',
    'evidence', jsonb_build_array(jsonb_build_object(
      'label', format('PLD: %s', v_pld_status),
      'type', 'STATUS',
      'status', v_pld_status
    ))
  ));

  -- Paso 3: Notaría asignada
  v_step_array := array_append(v_step_array, jsonb_build_object(
    'id', 'notaria',
    'order', 3,
    'branch', 'GENERAL',
    'title', 'Asignación de notaría',
    'description', 'Notaría asignada al expediente',
    'status', CASE WHEN v_cuenta.notario_id IS NOT NULL THEN 'COMPLETO' ELSE 'PENDIENTE' END,
    'sourceModule', 'NOTARIAS',
    'responsibleRole', 'DESARROLLADOR',
    'evidence', CASE
      WHEN v_cuenta.notario_id IS NOT NULL
      THEN jsonb_build_array(jsonb_build_object('label', v_cuenta.notaria_nombre, 'type', 'STATUS'))
      ELSE '[]'::jsonb
    END
  ));

  -- Paso 4: VoBo banco (solo crédito hipotecario; NO_APLICA para recursos propios)
  IF v_metodo_pago = 'CREDITO_HIPOTECARIO' THEN
    v_step_array := array_append(v_step_array, jsonb_build_object(
      'id', 'vobo_banco',
      'order', 4,
      'branch', 'CREDITO_HIPOTECARIO',
      'title', 'VoBo del banco hipotecario',
      'description', 'Proyecto de escritura aprobado por el banco',
      'status', CASE
        WHEN v_credito IS NOT NULL AND v_credito.vobo_banco = 'APROBADO'  THEN 'COMPLETO'
        WHEN v_credito IS NOT NULL AND v_credito.vobo_banco = 'PENDIENTE' THEN 'EN_PROCESO'
        WHEN v_credito IS NOT NULL AND v_credito.vobo_banco = 'RECHAZADO' THEN 'RECHAZADO'
        ELSE 'PENDIENTE'
      END,
      'sourceModule', 'CREDITOS_HIPOTECARIOS',
      'responsibleRole', 'BANCO'
    ));
  ELSE
    v_step_array := array_append(v_step_array, jsonb_build_object(
      'id', 'vobo_banco',
      'order', 4,
      'branch', 'RECURSOS_PROPIOS',
      'title', 'VoBo banco',
      'status', 'NO_APLICA',
      'sourceModule', 'CREDITOS_HIPOTECARIOS',
      'responsibleRole', 'BANCO'
    ));
  END IF;

  -- Paso 5: Cita de firma
  v_step_array := array_append(v_step_array, jsonb_build_object(
    'id', 'cita_firma',
    'order', 5,
    'branch', 'FINAL',
    'title', 'Cita de firma de escritura',
    'description', 'Fecha de firma programada con la notaría',
    'status', CASE
      WHEN v_cita_firma IS NOT NULL AND v_cita_firma.estatus = 'REALIZADA' THEN 'COMPLETO'
      WHEN v_cita_firma IS NOT NULL                                         THEN 'EN_PROCESO'
      ELSE 'PENDIENTE'
    END,
    'sourceModule', 'PROGRAMAR_CITAS',
    'responsibleRole', 'NOTARIA',
    'evidence', CASE
      WHEN v_cita_firma IS NOT NULL
      THEN jsonb_build_array(jsonb_build_object(
        'label', format('Cita: %s', v_cita_firma.fecha),
        'type', 'APPOINTMENT'
      ))
      ELSE '[]'::jsonb
    END
  ));

  -- Paso 6: Escritura firmada
  v_step_array := array_append(v_step_array, jsonb_build_object(
    'id', 'escritura_firmada',
    'order', 6,
    'branch', 'FINAL',
    'title', 'Escritura firmada',
    'description', 'Número de escritura registrado en el sistema',
    'status', CASE
      WHEN v_cuenta.numero_escritura IS NOT NULL AND v_cuenta.numero_escritura != ''        THEN 'COMPLETO'
      WHEN v_proceso IS NOT NULL AND v_proceso.estatus IN ('FIRMADO','EN_REGISTRO_RPP','CONCLUIDO') THEN 'COMPLETO'
      ELSE 'PENDIENTE'
    END,
    'sourceModule', 'NOTARIAS',
    'responsibleRole', 'NOTARIA'
  ));

  -- 10. Calcular porcentaje de progreso (excluye pasos NO_APLICA)
  SELECT
    ROUND(
      100.0 * COUNT(*) FILTER (WHERE (s->>'status') = 'COMPLETO') /
      NULLIF(COUNT(*) FILTER (WHERE (s->>'status') != 'NO_APLICA'), 0)
    )
  INTO v_pct_progreso
  FROM unnest(v_step_array) s;

  -- 11. Overall status
  IF EXISTS (SELECT 1 FROM unnest(v_step_array) s WHERE (s->>'status') = 'BLOQUEADO') THEN
    v_overall_status := 'BLOQUEADO';
  ELSIF v_pct_progreso = 100 THEN
    v_overall_status := 'COMPLETO';
  ELSIF v_pct_progreso > 0 THEN
    v_overall_status := 'EN_PROCESO';
  ELSE
    v_overall_status := 'PENDIENTE';
  END IF;

  -- 12. Resultado final
  v_result := jsonb_build_object(
    'accountId',          p_cuenta_id,
    'projectId',          v_cuenta.proyecto_id,
    'unitCode',           v_cuenta.numero_propiedad,
    'clientName',         COALESCE(v_compradores->0->>'nombre', '—'),
    'compradores',        v_compradores,
    'paymentMethod',      v_metodo_pago,
    'precioFinal',        v_cuenta.precio_final,
    'totalPagado',        v_total_pagado,
    'overallStatus',      v_overall_status,
    'progressPercentage', COALESCE(v_pct_progreso, 0),
    'blockingReasons',    to_jsonb(v_blocking),
    'notariaName',        v_cuenta.notaria_nombre,
    'pldStatus',          v_pld_status,
    'pldBloqueado',       v_pld_bloqueado,
    'docsCompletos',      v_docs_completos,
    'docsTotal',          v_docs_total,
    'numeroEscritura',    v_cuenta.numero_escritura,
    'fechaEscritura',     v_cuenta.fecha_escritura,
    'estatusPropiedad',   v_cuenta.id_estatus_disponibilidad,
    'steps',              to_jsonb(v_step_array)
  );

  RETURN v_result;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('error', SQLERRM, 'account_id', p_cuenta_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_workflow_evaluation(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_workflow_evaluation(bigint) TO service_role;

COMMENT ON FUNCTION public.get_workflow_evaluation(bigint) IS
  'Evalúa el estado completo del workflow de escrituración para una cuenta de cobranza. Reemplaza las 15+ queries paralelas del WorkflowDashboard.tsx.';
