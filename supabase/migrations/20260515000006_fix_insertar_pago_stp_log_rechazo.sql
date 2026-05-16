-- Fix: insertar_pago_stp — registrar rechazo por adminte_pago en pagos_stp_raw
-- Cuando el monto entrante supera el precio_final, la función ahora inserta el pago
-- en pagos_stp_raw con es_pago_aplicado=false antes de retornar 'rechazo_pago',
-- para que sea visible en la UI y N8N pueda disparar la notificación.

CREATE OR REPLACE FUNCTION public.insertar_pago_stp(p_stp_id text, p_monto numeric, p_nombre_ordenante text, p_concepto_pago text, p_institucion_beneficiaria text, p_nombre_beneficiario text, p_ts_liquidacion text, p_cuenta_beneficiario text, p_tipo_pago text, p_tipo_cuenta_beneficiario text, p_cuenta_ordenante text, p_claverastreo text, p_institucion_ordenante text, p_rfc_curp_beneficiario text, p_tipo_cuenta_ordenante text, p_fecha_operacion date, p_empresa text, p_referencia_numerica text, p_rfc_curp_ordenante text, p_nombre_beneficiario2 text DEFAULT NULL::text, p_tipo_cuenta_beneficiario2 text DEFAULT NULL::text, p_cuenta_beneficiario2 text DEFAULT NULL::text, p_folio_codi text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
AS $function$DECLARE
    existe_pago BOOLEAN;
    es_propiedad_demandada BOOLEAN;
    es_comision BOOLEAN;
    es_comision_completa BOOLEAN;
    adminte_pago BOOLEAN;
    v_id_cuenta_con_comision_ya_pagada INT := NULL;
    v_pago_tipo TEXT := NULL;
    v_id_propiedad INT := NULL;
    v_id_oferta INT := NULL;
    v_id_persona_lead INT := NULL;
    v_id_esquema_pago INT := NULL;
    v_id_cuenta_cobranza INT := NULL;
    v_success BOOLEAN := FALSE;
    v_razon_rechazo TEXT := NULL;
    v_siguiente_accion TEXT := NULL;
    v_message TEXT := NULL;
    v_id_tipo_pago INT := 1;
    v_count_tipos INTEGER;

    -- variables usadas para cuando el pago es de comision
    v_pos  INT := 1;
    v_match text[] := NULL;
    v_num text := NULL;
BEGIN
    -- Verificar si ya existe antes de insertar
    SELECT TRUE INTO existe_pago
    FROM pagos_stp_raw
    WHERE claverastreo = p_claverastreo
    LIMIT 1;

    IF existe_pago THEN
        RETURN json_build_object(
            'success', FALSE,
            'siguiente_accion', 'rechazo_pago',
            'message', 'El pago con esta claverastreo ya existe',
            'claverastreo', p_claverastreo
        );
    END IF;

    SELECT
        TRUE
    INTO es_comision
    FROM
        entidades_relacionadas er
    WHERE
        cuenta_stp_comisiones=p_cuenta_beneficiario;


    IF es_comision THEN
       v_id_tipo_pago := 5;
    ELSE  -- no es pago de comision
        -- Verificar si la cuenta aun puede recibir pagos (cuando el precio_final < sum(pagos))
        SELECT
        CASE
            WHEN cc.precio_final >= SUM(coalesce(pag.monto,0))+p_monto THEN TRUE
            ELSE FALSE
        END INTO adminte_pago
        FROM cuentas_cobranza cc
        JOIN ofertas o ON cc.id_oferta = o.id
        JOIN propiedades p ON o.id_propiedad = p.id
        LEFT OUTER JOIN pagos pag ON pag.id_cuenta_cobranza = cc.id
        WHERE cc.clabe_stp = p_cuenta_beneficiario
        AND cc.activo = TRUE
        AND o.activo = TRUE
        AND p.activo = TRUE
        AND (pag.activo = TRUE OR pag.activo is null)
        GROUP BY cc.precio_final
        LIMIT 1;

        IF NOT adminte_pago THEN
            -- Registrar el rechazo en pagos_stp_raw para trazabilidad y notificación
            INSERT INTO pagos_stp_raw (
                stp_id, monto, nombre_ordenante, concepto_pago, institucion_beneficiaria,
                nombre_beneficiario, ts_liquidacion, cuenta_beneficiario, tipo_pago,
                tipo_cuenta_beneficiario, cuenta_ordenante, claverastreo,
                institucion_ordenante, rfc_curp_beneficiario, tipo_cuenta_ordenante,
                fecha_operacion, empresa, referencia_numerica, rfc_curp_ordenante,
                nombre_beneficiario2, tipo_cuenta_beneficiario2, cuenta_beneficiario2, folio_codi,
                id_tipo_pago, es_pago_aplicado, razon_rechazo
            ) VALUES (
                p_stp_id, p_monto, p_nombre_ordenante, p_concepto_pago, p_institucion_beneficiaria,
                p_nombre_beneficiario, p_ts_liquidacion, p_cuenta_beneficiario, p_tipo_pago,
                p_tipo_cuenta_beneficiario, p_cuenta_ordenante, p_claverastreo,
                p_institucion_ordenante, p_rfc_curp_beneficiario, p_tipo_cuenta_ordenante,
                p_fecha_operacion, p_empresa, p_referencia_numerica, p_rfc_curp_ordenante,
                p_nombre_beneficiario2, p_tipo_cuenta_beneficiario2, p_cuenta_beneficiario2, p_folio_codi,
                v_id_tipo_pago, FALSE, 'La cuenta no admite más pagos: monto supera el precio final'
            );
            RETURN json_build_object(
                'success', FALSE,
                'siguiente_accion', 'rechazo_pago',
                'message', 'La cuenta ya esta pagada completamente',
                'claverastreo', p_claverastreo
            );
        END IF;

-- 🔹 Calcular v_id_tipo_pago según la cuenta madre STP
-- 🔹 1. Consultar cuántos tipos de pago potenciales existen
    SELECT COUNT(DISTINCT CASE
                    WHEN tu.nombre IN ('Productos','Servicios') THEN 2
                    WHEN tu.nombre = 'Mantenimientos' THEN 3
                    ELSE 1
                END)
    INTO v_count_tipos
    FROM entidades_relacionadas er
    JOIN proyectos pr ON er.id_proyecto = pr.id
    JOIN tipos_uso tu ON pr.id_tipo_uso = tu.id
    WHERE tu.id IN (9,10,11)
    AND er.cuenta_madre_stp IS NOT NULL
    AND er.cuenta_madre_stp = LEFT(p_cuenta_beneficiario, LENGTH(p_cuenta_beneficiario) - 4);

        -- 🔹 2. Si solo hay uno, lo asignamos directamente
        IF v_count_tipos = 1 THEN
            SELECT DISTINCT
                CASE
                    WHEN tu.nombre IN ('Productos','Servicios') THEN 2
                    WHEN tu.nombre = 'Mantenimientos' THEN 3
                    ELSE 1
                END
            INTO v_id_tipo_pago
            FROM entidades_relacionadas er
            JOIN proyectos pr ON er.id_proyecto = pr.id
            JOIN tipos_uso tu ON pr.id_tipo_uso = tu.id
            WHERE tu.id IN (9,10,11)
            AND er.cuenta_madre_stp IS NOT NULL
            AND er.cuenta_madre_stp = LEFT(p_cuenta_beneficiario, LENGTH(p_cuenta_beneficiario) - 4)
            LIMIT 1;

        -- 🔹 3. Si hay más de uno (o cero), aplicamos tu validación de desempate
        ELSE
            -- Intentamos determinar si es Propiedad (1)
            SELECT 1 INTO v_id_tipo_pago
            FROM propiedades p
            WHERE p.clabe_stp_tmp_apartado = p_cuenta_beneficiario
            AND p.activo = TRUE
            AND p.id_estatus_disponibilidad = 2
            LIMIT 1;

            IF NOT FOUND THEN
                -- Si no fue propiedad, intentamos determinar si es Producto (2)
                SELECT 2 INTO v_id_tipo_pago
                FROM ofertas o
                WHERE o.clabe_stp_tmp_producto = p_cuenta_beneficiario
                AND o.activo = TRUE
                LIMIT 1;
            END IF;

            -- Valor por defecto si ninguna validación de desempate encuentra nada
            v_id_tipo_pago := COALESCE(v_id_tipo_pago, 1);
        END IF;
    END IF;

    -- 1. Insertamos el pago en pagos_stp_raw con TODOS los campos originales + id_tipo_pago
    INSERT INTO pagos_stp_raw (
        stp_id, monto, nombre_ordenante, concepto_pago, institucion_beneficiaria,
        nombre_beneficiario, ts_liquidacion, cuenta_beneficiario, tipo_pago,
        tipo_cuenta_beneficiario, cuenta_ordenante, claverastreo,
        institucion_ordenante, rfc_curp_beneficiario, tipo_cuenta_ordenante,
        fecha_operacion, empresa, referencia_numerica, rfc_curp_ordenante,
        nombre_beneficiario2, tipo_cuenta_beneficiario2, cuenta_beneficiario2, folio_codi,
        id_tipo_pago -- 🔹 ya guardamos desde el inicio
    ) VALUES (
        p_stp_id, p_monto, p_nombre_ordenante, p_concepto_pago, p_institucion_beneficiaria,
        p_nombre_beneficiario, p_ts_liquidacion, p_cuenta_beneficiario, p_tipo_pago,
        p_tipo_cuenta_beneficiario, p_cuenta_ordenante, p_claverastreo,
        p_institucion_ordenante, p_rfc_curp_beneficiario, p_tipo_cuenta_ordenante,
        p_fecha_operacion, p_empresa, p_referencia_numerica, p_rfc_curp_ordenante,
        p_nombre_beneficiario2, p_tipo_cuenta_beneficiario2, p_cuenta_beneficiario2, p_folio_codi,
        v_id_tipo_pago
    );

    -- 🔹 VALIDACIÓN DE PROPIEDAD DEMANDADA 🚨
    SELECT
        TRUE
    INTO es_propiedad_demandada
    FROM cuentas_cobranza cc
    JOIN ofertas o ON cc.id_oferta = o.id
    JOIN propiedades p ON o.id_propiedad = p.id
    WHERE cc.clabe_stp = p_cuenta_beneficiario
    AND p.id_estatus_disponibilidad=11
    LIMIT 1;

    IF es_propiedad_demandada THEN
        v_success := FALSE;
        v_razon_rechazo := 'La propiedad está demandada y no puede recibir pagos';
        v_siguiente_accion := 'rechazo_pago';
        v_message := v_razon_rechazo;

        -- Si la propiedad está demandada, **se registra el pago como rechazado** y se retorna inmediatamente.
        UPDATE pagos_stp_raw
        SET es_pago_aplicado = FALSE,
            razon_rechazo = v_razon_rechazo
        WHERE claverastreo = p_claverastreo;

        RETURN json_build_object(
            'success', FALSE,
            'siguiente_accion', v_siguiente_accion,
            'message', v_message,
            'claverastreo', p_claverastreo
        );
    END IF;

    -- 2. Verificamos si la CLABE existe en propiedades o cuentas_cobranza o en ofertas
    -- primero checo en propiedades
    SELECT id, 'apartado'
    INTO v_id_propiedad, v_pago_tipo
    FROM propiedades p
    WHERE p.clabe_stp_tmp_apartado = p_cuenta_beneficiario
      AND p.activo = TRUE
      AND p.id_estatus_disponibilidad=2 -- solo las que estan disponibles se les puede apartar
    LIMIT 1;

    IF NOT FOUND THEN  -- voy a checar en la oferta
        SELECT o.id, 'apartado producto',o.id_persona_lead
        INTO v_id_oferta, v_pago_tipo,v_id_persona_lead
        FROM ofertas o
        WHERE o.clabe_stp_tmp_producto = p_cuenta_beneficiario
          AND o.activo = TRUE
        LIMIT 1;
    END IF;

    IF NOT FOUND THEN  -- voy a diferenciar entre pago de propiedad y de producto checando en la oferta si es de producto o propiedad
        SELECT cc.id,
            CASE
                WHEN o.id_producto is null THEN 'pago propiedad'
                ELSE 'pago producto'
            END
        INTO v_id_cuenta_cobranza, v_pago_tipo
        FROM cuentas_cobranza cc
        join ofertas o on cc.id_oferta=o.id
        WHERE cc.clabe_stp = p_cuenta_beneficiario
          AND cc.activo = TRUE
        LIMIT 1;
    END IF;

    IF NOT FOUND THEN  -- busco en las cuentas de cobranza de mantenimientos, es decir donde tienen un id_cuenta_padre
        SELECT cc.id,
            CASE
                WHEN cc.id_cuenta_cobranza_padre is not null THEN 'pago mantenimiento'
            END
        INTO v_id_cuenta_cobranza, v_pago_tipo
        FROM cuentas_cobranza cc
        WHERE cc.clabe_stp = p_cuenta_beneficiario
          AND cc.activo = TRUE
        LIMIT 1;
    END IF;

    IF NOT FOUND THEN  -- busco en las cuentas de comision, es decir  en la tabla de entidades_relacionadas para los tipos Dueño y Aportante (4,15)
        SELECT
            'pago comisiones'
        INTO v_pago_tipo
        FROM
            entidades_relacionadas er
        WHERE
            er.cuenta_stp_comisiones = p_cuenta_beneficiario
        AND er.id_tipo_entidad in (4,15)
        AND er.activo=true;
    END IF;

    IF NOT FOUND THEN  -- busco en las cuentas de comision, es decir  en la tabla de entidades_relacionadas para los Proveedores (8)
        SELECT
            'pago proveedores'
        INTO v_pago_tipo
        FROM
            entidades_relacionadas er
        WHERE
            er.cuenta_stp_comisiones = p_cuenta_beneficiario
        AND er.id_tipo_entidad in (8)
        AND er.activo=true;
    END IF;

    IF v_pago_tipo IS NULL THEN
        -- CLABE no encontrada
        v_razon_rechazo := 'Cuenta STP no existe';
        v_siguiente_accion := 'rechazo_pago';
        v_message := v_razon_rechazo;

        UPDATE pagos_stp_raw
        SET es_pago_aplicado = FALSE,
            razon_rechazo = v_razon_rechazo
        WHERE claverastreo = p_claverastreo;

        RETURN json_build_object(
            'success', FALSE,
            'siguiente_accion', v_siguiente_accion,
            'message', v_message,
            'claverastreo', p_claverastreo
        );
    END IF;

    -- 3. Validación según tipo de pago
    IF v_pago_tipo = 'apartado' THEN
        -- v_success := TRUE; -- siempre TRUE para apartado

        -- Buscamos oferta y esquema
        SELECT o.id, o.id_persona_lead, p.id as id_propiedad, o.id_esquema_pago_seleccionado
        INTO v_id_oferta, v_id_persona_lead, v_id_propiedad, v_id_esquema_pago
        FROM ofertas o
        JOIN propiedades p ON o.id_propiedad = p.id
        JOIN personas per ON o.id_persona_lead = per.id
        WHERE p.clabe_stp_tmp_apartado = p_cuenta_beneficiario
          AND p.id_estatus_disponibilidad = 2
          AND (per.rfc = p_rfc_curp_ordenante OR per.curp = p_rfc_curp_ordenante)
          AND o.id_producto is null
        ORDER BY o.id DESC
        LIMIT 1;

        IF NOT FOUND THEN
            v_success := FALSE;
            v_razon_rechazo := 'RFC o CURP no registrados en cliente';
            v_siguiente_accion := 'rechazo_pago';
            v_message := v_razon_rechazo;
        ELSE
            IF  v_id_esquema_pago IS NULL THEN
                v_success := TRUE;
                v_razon_rechazo := null;
                v_siguiente_accion := 'genera_cuenta_cobranza_sin_acuerdo';
                v_message := v_razon_rechazo;
            ELSE
                v_success := TRUE;
                v_siguiente_accion := 'genera_cuenta_cobranza_completa';
                v_message := 'Pago aplicado';
            END IF;
        END IF;
    ELSE
        IF v_pago_tipo = 'pago propiedad' THEN -- v_pago_tipo = 'pago propiedad'
            SELECT cc.id
            INTO v_id_cuenta_cobranza
            FROM cuentas_cobranza cc
            JOIN compradores co ON co.id_cuenta_cobranza = cc.id
            JOIN personas per ON co.id_persona = per.id
            left outer JOIN cuentas_bancarias cb ON cb.id_persona = per.id
            WHERE cc.clabe_stp = p_cuenta_beneficiario
            AND (per.rfc = p_rfc_curp_ordenante OR per.curp = p_rfc_curp_ordenante OR cb.cuenta_clabe = p_cuenta_ordenante)
            LIMIT 1;

            IF FOUND THEN
                v_success := TRUE;
                v_siguiente_accion := 'aplicar_pago';
                v_message := 'Pago aplicado';
            ELSE
                v_success := FALSE;
                v_razon_rechazo := 'RFC o CURP o cuentas registradas no coinciden con STP';
                v_siguiente_accion := 'rechazo_pago';
                v_message := v_razon_rechazo;
            END IF;
        ELSE
            IF v_pago_tipo = 'apartado producto' THEN -- v_pago_tipo = 'apartado producto'
                v_success := TRUE;
                v_siguiente_accion := 'aplicar_apartado_producto';
                v_message := 'Pago de apartado producto aplicado';
            ELSE
                IF v_pago_tipo = 'pago producto' THEN -- v_pago_tipo = 'pago producto'
                    v_success := TRUE;
                    v_siguiente_accion := 'aplicar_pago_producto';
                    v_message := 'Pago de producto aplicado';
                ELSE
                    IF v_pago_tipo = 'pago mantenimiento' THEN
                        v_success := TRUE;
                        v_siguiente_accion := 'aplicar_pago_automatico_mantenimiento';
                        v_message := 'Pago de mantenimiento aplicado';
                    ELSE
                        IF v_pago_tipo = 'pago comisiones' THEN
                        -- Funcion para obtener el numero de cuenta del concepto de pago
                        -- ----------------------------------------------
                        -- Extrae todos los números (de 2 a 8 dígitos)
                        v_match := regexp_matches(p_concepto_pago, '[0-9]{1,6}', 'g');

                        -- Si encuentra coincidencias, iteramos sobre ellas
                        IF v_match IS NOT NULL THEN
                            FOREACH v_num IN ARRAY v_match LOOP
                                SELECT cc.id
                                INTO v_id_cuenta_cobranza
                                FROM cuentas_cobranza cc
                                WHERE cc.id = CAST(v_num AS INTEGER)
                                LIMIT 1;

                                -- Si encontramos una cuenta válida, salimos del bucle
                                IF v_id_cuenta_cobranza IS NOT NULL THEN
                                    EXIT;
                                END IF;
                            END LOOP;
                        END IF;

                        -- ----------------------------------------------
                        IF FOUND THEN
                            -- checo si la comision ya esta pagada
                            SELECT cc.id
                            INTO v_id_cuenta_con_comision_ya_pagada
                            FROM cuentas_cobranza cc
                            WHERE cc.id = CAST(v_num AS INTEGER)
                            AND cc.es_pagada_comision_venta=true
                            LIMIT 1;

                            IF FOUND THEN  -- ya esta pagada, rechazo pago
                                v_success := FALSE;
                                v_razon_rechazo := 'La cuenta de cobranza ya tiene la comisión pagada';
                                v_siguiente_accion := 'rechazo_pago';
                                v_message := v_razon_rechazo;
                            ELSE  -- no esta pagada aun
                                -- checo si el monto que se esta pagando es igual al requerido para comision
                                SELECT
                                    case
                                        when p_monto >= round(coalesce(cc.porcentaje_comision_venta/100*cc.precio_final),2) then true
                                        else  false
                                    end
                                INTO es_comision_completa
                                FROM cuentas_cobranza cc
                                WHERE cc.id = CAST(v_num AS INTEGER)
                                LIMIT 1;

                                IF es_comision_completa THEN  -- el monto esta completo
                                    v_success := TRUE;
                                    v_siguiente_accion := 'aplicar_pago_comision';
                                    v_message := 'Pago de comision aplicado';
                                ELSE
                                    v_success := FALSE;
                                    v_razon_rechazo := 'El monto de la comisión no esta completo';
                                    v_siguiente_accion := 'rechazo_pago';
                                    v_message := v_razon_rechazo;
                                END IF;
                            END IF;
                        ELSE
                            v_success := FALSE;
                            v_razon_rechazo := 'La cuenta de cobranza no se encontro para pagar comision';
                            v_siguiente_accion := 'rechazo_pago';
                            v_message := v_razon_rechazo;
                        END IF;
                    ELSE -- else pago proveedores
                        IF v_pago_tipo = 'pago proveedores' THEN
                            v_success := TRUE;
                            v_siguiente_accion := 'aplicar_pago_proveedores';
                            v_message := 'Pago de proveedores aplicado';
                        ELSE
                            v_success := FALSE;
                            v_razon_rechazo := 'Error en pago';
                            v_siguiente_accion := 'rechazo_pago';
                            v_message := v_razon_rechazo;
                        END IF;
                    END IF;
                END IF;
            END IF;
        END IF;
    END IF;
END IF;

    -- 4. Actualizamos pagos_stp_raw con resultados finales
    UPDATE pagos_stp_raw
    SET
        razon_rechazo = v_razon_rechazo
    WHERE claverastreo = p_claverastreo;

    -- 5. Retornamos JSON final
    RETURN json_build_object(
        'success', COALESCE(v_success, FALSE),
        'siguiente_accion', v_siguiente_accion,
        'message', v_message,
        'claverastreo', p_claverastreo,
        'rfc_curp_ordenante', p_rfc_curp_ordenante,
        'id_oferta', v_id_oferta,
        'id_persona_lead', v_id_persona_lead,
        'id_propiedad', v_id_propiedad,
        'id_cuenta_cobranza', v_id_cuenta_cobranza,
        'clabe_stp', p_cuenta_beneficiario,
        'monto', p_monto,
        'id_metodo_pago', 6,
        'fecha_pago', CURRENT_DATE
    );
END;$function$;
