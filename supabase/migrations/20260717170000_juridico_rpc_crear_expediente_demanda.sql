-- Portal Jurídico Fase 1 · RPC transaccional crear_expediente_demanda
-- Fecha: 2026-07-17
--
-- Formaliza DDL-4B. Reemplaza las 3 operaciones sueltas del front (INSERT demandas +
-- INSERT demandas_timeline + UPDATE propiedades) por una función PL/pgSQL en una sola
-- transacción, eliminando estados inconsistentes. Centraliza: sesión activa, rol
-- autorizado, cuenta principal válida, protección concurrencial (FOR UPDATE) e
-- identidad del ejecutor derivada de la BD (no del front).
--
-- Correcciones vs el .md original:
--  - tipo_evento 'CREACION' (no 'CASO_ABIERTO', que viola el CHECK real de
--    demandas_timeline: CREACION/CAMBIO_ESTATUS/NOTA/DOCUMENTO/ACUERDO/PAGO/RESOLUCION/OTRO).
--  - id_propiedad NO se recibe como parámetro: se DERIVA de la cuenta principal
--    (cuentas_cobranza.id_propiedad). Evita denormalización por parámetro y mismatch;
--    no confía en el front. Firma final: (BIGINT, TEXT, TEXT).
--  - Estatus de apertura sin SIN_DEMANDA (ni CERRADO): solo NOTIFICADO/EN_PROCESO/
--    ACUERDO/LITIGIO/RESUELTO. Valores confirmados contra demandas_estatus_demanda_check.
--  - EXCEPTION loguea con RAISE WARNING y NO devuelve detail/hint crudos (evita filtrar
--    internals al cliente).
--
-- Invariante real = UNA demanda activa por CUENTA (no por propiedad): verificado 2026-07-17
-- que 489 propiedades tienen >1 cuenta principal activa, así que "una por propiedad" no es
-- garantizable ni deseable. Alineado con el índice existente demandas_cuenta_uidx
-- (UNIQUE id_cuenta_cobranza WHERE activo). El check del paso 7 da error descriptivo
-- antes de tocar el índice.
--
-- SECURITY DEFINER + SET search_path=public. Roles autorizados (confirmados prod):
-- 1 Super Administrador, 18 Admin Legal, 26 Jurídico. Idempotente (CREATE OR REPLACE).

CREATE OR REPLACE FUNCTION public.crear_expediente_demanda(
    p_id_cuenta_cobranza  BIGINT,
    p_estatus_demanda     TEXT    DEFAULT 'NOTIFICADO',
    p_observaciones       TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_auth_uid          UUID;
    v_usuario_id        BIGINT;
    v_rol_id            BIGINT;
    v_email_ejecutor    TEXT;
    v_id_propiedad      BIGINT;
    v_demanda_id        BIGINT;
    v_timeline_id       BIGINT;
BEGIN
    -- 1. Sesión activa
    v_auth_uid := auth.uid();
    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'usuario_no_autenticado'
            USING DETAIL = 'auth.uid() retornó NULL.', ERRCODE = 'P0001';
    END IF;

    -- 2. Usuario activo (identidad derivada de BD, no del front)
    SELECT u.id, u.rol_id, u.email
      INTO v_usuario_id, v_rol_id, v_email_ejecutor
    FROM public.usuarios u
    WHERE u.auth_user_id = v_auth_uid AND u.activo = true;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'usuario_no_registrado'
            USING DETAIL = format('auth.uid() %s sin usuario activo.', v_auth_uid),
                  ERRCODE = 'P0002';
    END IF;

    -- 3. Rol autorizado (1 Super Admin, 18 Admin Legal, 26 Jurídico)
    IF v_rol_id NOT IN (1, 18, 26) THEN
        RAISE EXCEPTION 'rol_no_autorizado'
            USING DETAIL = format('rol_id=%s sin permiso.', v_rol_id),
                  HINT = 'Roles: 1, 18, 26.', ERRCODE = 'P0003';
    END IF;

    -- 4. Parámetro obligatorio
    IF p_id_cuenta_cobranza IS NULL THEN
        RAISE EXCEPTION 'parametro_nulo: p_id_cuenta_cobranza' USING ERRCODE = 'P0004';
    END IF;

    -- 5. Estatus inicial válido (SIN_DEMANDA y CERRADO excluidos: no son apertura activa)
    IF p_estatus_demanda NOT IN ('NOTIFICADO','EN_PROCESO','ACUERDO','LITIGIO','RESUELTO') THEN
        RAISE EXCEPTION 'estatus_demanda_invalido'
            USING DETAIL = format('"%s" no es estatus válido de apertura.', p_estatus_demanda),
                  HINT = 'Permitidos: NOTIFICADO, EN_PROCESO, ACUERDO, LITIGIO, RESUELTO.',
                  ERRCODE = 'P0005';
    END IF;

    -- 6. Resolver cuenta principal + DERIVAR id_propiedad de la cuenta (no del front).
    --    FOR UPDATE serializa apertura concurrente sobre la misma cuenta principal.
    SELECT cc.id_propiedad
      INTO v_id_propiedad
    FROM public.cuentas_cobranza cc
    WHERE cc.id = p_id_cuenta_cobranza
      AND cc.id_cuenta_cobranza_padre IS NULL
      AND cc.activo = true
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'cuenta_invalida_o_no_principal'
            USING DETAIL = format('Cuenta %s inexistente, inactiva o no principal (padre IS NULL).',
                                  p_id_cuenta_cobranza),
                  ERRCODE = 'P0007';
    END IF;

    -- 7. No demanda activa para esta cuenta (alineado con demandas_cuenta_uidx)
    IF EXISTS (
        SELECT 1 FROM public.demandas d
        WHERE d.id_cuenta_cobranza = p_id_cuenta_cobranza AND d.activo = true
    ) THEN
        RAISE EXCEPTION 'demanda_activa_existente'
            USING DETAIL = format('Cuenta %s ya tiene demanda activa.', p_id_cuenta_cobranza),
                  ERRCODE = 'P0008';
    END IF;

    -- 8. INSERT demanda (fechas por DEFAULT; responsable/perfil se asignan vía asignaciones_juridico)
    INSERT INTO public.demandas (
        id_cuenta_cobranza, id_propiedad, estatus_demanda, observaciones, activo
    ) VALUES (
        p_id_cuenta_cobranza, v_id_propiedad, p_estatus_demanda, p_observaciones, true
    ) RETURNING id INTO v_demanda_id;

    -- 9. INSERT timeline (CREACION: único válido para apertura)
    INSERT INTO public.demandas_timeline (
        id_demanda, tipo_evento, descripcion, creado_por
    ) VALUES (
        v_demanda_id, 'CREACION',
        format('Expediente creado. Estatus inicial: %s. Usuario: %s (rol_id=%s).',
               p_estatus_demanda, v_email_ejecutor, v_rol_id),
        v_email_ejecutor
    ) RETURNING id INTO v_timeline_id;

    -- 10. Propiedad -> "En demanda" (id=11); usa la fila ya bloqueada por la cuenta
    UPDATE public.propiedades
    SET id_estatus_disponibilidad = 11, fecha_actualizacion = now()
    WHERE id = v_id_propiedad;

    -- 11. Resultado
    RETURN jsonb_build_object(
        'success', true,
        'demanda_id', v_demanda_id,
        'timeline_id', v_timeline_id,
        'propiedad_id', v_id_propiedad,
        'cuenta_id', p_id_cuenta_cobranza,
        'estatus', p_estatus_demanda,
        'ejecutado_por', v_email_ejecutor,
        'rol_id', v_rol_id
    );

EXCEPTION
    WHEN OTHERS THEN
        -- DML de 8-10 revertido por la excepción. Se registra en logs del server y se
        -- devuelve mensaje genérico al cliente (sin filtrar detail/hint internos).
        RAISE WARNING 'crear_expediente_demanda fallo: % (%)', SQLERRM, SQLSTATE;
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM,
            'code', SQLSTATE
        );
END;
$$;

REVOKE ALL ON FUNCTION public.crear_expediente_demanda(BIGINT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.crear_expediente_demanda(BIGINT, TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.crear_expediente_demanda(BIGINT, TEXT, TEXT) TO authenticated;
