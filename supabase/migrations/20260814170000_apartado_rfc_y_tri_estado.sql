-- =============================================================================
-- Apartado: la identidad fiscal se valida solo por RFC, y el pago tiene tri-estado
-- =============================================================================
-- 1. FISCAL. `insertar_pago_stp` —la puerta de entrada de STP— acepta hoy que el ordenante
--    se identifique con RFC **o CURP**. El CURP no es un identificador fiscal y no viaja en
--    la factura; casar dinero con él nunca fue correcto. Queda solo el RFC.
--
-- 2. CLIENTE. `pagos_stp_raw.es_pago_aplicado` nace en NULL: el INSERT no lo setea y quien
--    lo pone en TRUE es el motor de aplicacion, despues. La v1 de `get_apartado_pagos`
--    colapsa ese NULL con `COALESCE(..., false)`, o sea pinta como RECHAZADO el hueco de
--    segundos entre que STP entrega el pago y el motor lo aplica. Ahora hay `estado` de
--    tres valores y la pantalla puede decir "lo estamos aplicando".
--
-- --- Verificado read-only el 2026-08-14 en prod y dev -------------------------
-- * Las dos funciones son byte por byte identicas en los dos entornos:
--     insertar_pago_stp   md5 639efa85a5e09b96765e0c5b35cd2751  (475 lineas)
--     get_apartado_pagos  md5 1cc5ca1c9f4a1b0c967987b38fcdf13f
--   Los cuerpos de abajo se extrajeron con pg_get_functiondef de la definicion viva y se
--   les aplicaron SOLO los reemplazos marcados. El diff es de 4 lineas en la primera y 7
--   agregadas en la segunda; nada mas cambio.
-- * `insertar_pago_stp` es SECURITY INVOKER (prosecdef = false). Se conserva asi.
-- * `pagos_stp_raw`: 12,590 en TRUE, 118 en FALSE, 0 en NULL. El hueco existe pero dura
--   segundos, por eso no hay filas atrapadas ahi ahora mismo.
--
-- --- Correccion al documento -------------------------------------------------
-- El doc justifica el upper/btrim diciendo que `personas.rfc` es CHAR(n) y llega con
-- relleno. Es falso: `rfc` y `curp` son `text`. La normalizacion se conserva igual, pero
-- por otra razon: el RFC llega del conector de STP y puede traer mayusculas o espacios
-- distintos a los capturados.
--
-- --- PENDIENTE, no se toca aqui ----------------------------------------------
-- `insertar_pago_stp` tiene EXECUTE para PUBLIC (`=X/postgres`), o sea `anon`. Siendo
-- SECURITY INVOKER y con `pagos_stp_raw` sin RLS y con INSERT para anon, cualquiera con la
-- anon key puede fabricar un deposito de STP en el ledger que despues leen la conciliacion
-- y el motor de aplicacion. Cerrarlo es un REVOKE, pero antes hay que confirmar con que
-- credencial lo invoca el conector de STP: si usa la anon key, revocarlo tumba el cobro.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Guards: se reemplazan cuerpos completos, asi que hay que abortar si la definicion
-- viva ya no es la auditada; recrear encima de un cambio ajeno lo borraria.
-- -----------------------------------------------------------------------------
DO $guard$
DECLARE
  v_ips text;
  v_gap text;
BEGIN
  IF to_regprocedure('public.insertar_pago_stp(text,numeric,text,text,text,text,text,text,text,text,text,text,text,text,text,date,text,text,text,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'insertar_pago_stp no existe con la firma auditada';
  END IF;

  IF to_regproc('public.get_apartado_pagos') IS NULL THEN
    RAISE EXCEPTION 'get_apartado_pagos no existe; aplicar 20260814030000 antes que esta';
  END IF;

  SELECT pg_get_functiondef('public.insertar_pago_stp'::regproc) INTO v_ips;
  SELECT pg_get_functiondef('public.get_apartado_pagos'::regproc) INTO v_gap;

  -- Anchor semantico: o trae lo que venimos a quitar, o ya esta migrada (re-ejecucion).
  IF v_ips NOT LIKE '%per.curp = p_rfc_curp_ordenante%'
     AND v_ips NOT LIKE '%upper(btrim(per.rfc))%' THEN
    RAISE EXCEPTION 'Drift en insertar_pago_stp: no trae ni la comparacion contra CURP ni la normalizacion por RFC. Reconciliar el cuerpo vivo antes de aplicar.';
  END IF;

  IF v_gap NOT LIKE '%es_pago_aplicado%' THEN
    RAISE EXCEPTION 'Drift en get_apartado_pagos: no lee es_pago_aplicado';
  END IF;

  IF md5(v_ips) <> '639efa85a5e09b96765e0c5b35cd2751' THEN
    RAISE WARNING 'insertar_pago_stp cambio respecto al cuerpo auditado (md5 vivo=%). Esta migracion lo reemplaza con la version del repo.', md5(v_ips);
  END IF;

  IF md5(v_gap) <> '1cc5ca1c9f4a1b0c967987b38fcdf13f' THEN
    RAISE WARNING 'get_apartado_pagos cambio respecto al cuerpo auditado (md5 vivo=%).', md5(v_gap);
  END IF;
END;
$guard$;

-- -----------------------------------------------------------------------------
-- A. insertar_pago_stp: identidad del ordenante solo por RFC, normalizado.
--    Rama 'apartado'        -> AND (upper(btrim(per.rfc)) = upper(btrim(p_rfc_curp_ordenante)))
--    Rama 'pago propiedad'  -> ... OR cb.cuenta_clabe = p_cuenta_ordenante   (se conserva:
--    la CLABE registrada es un segundo factor legitimo, no un identificador fiscal)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.insertar_pago_stp(p_stp_id text, p_monto numeric, p_nombre_ordenante text, p_concepto_pago text, p_institucion_beneficiaria text, p_nombre_beneficiario text, p_ts_liquidacion text, p_cuenta_beneficiario text, p_tipo_pago text, p_tipo_cuenta_beneficiario text, p_cuenta_ordenante text, p_claverastreo text, p_institucion_ordenante text, p_rfc_curp_beneficiario text, p_tipo_cuenta_ordenante text, p_fecha_operacion date, p_empresa text, p_referencia_numerica text, p_rfc_curp_ordenante text, p_nombre_beneficiario2 text DEFAULT NULL::text, p_tipo_cuenta_beneficiario2 text DEFAULT NULL::text, p_cuenta_beneficiario2 text DEFAULT NULL::text, p_folio_codi text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
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
          AND (upper(btrim(per.rfc)) = upper(btrim(p_rfc_curp_ordenante)))
          AND o.id_producto is null
        ORDER BY o.id DESC
        LIMIT 1;

        IF NOT FOUND THEN
            v_success := FALSE;
            v_razon_rechazo := 'RFC del ordenante no coincide con el del cliente';
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
            AND (upper(btrim(per.rfc)) = upper(btrim(p_rfc_curp_ordenante)) OR cb.cuenta_clabe = p_cuenta_ordenante)
            LIMIT 1;

            IF FOUND THEN
                v_success := TRUE;
                v_siguiente_accion := 'aplicar_pago';
                v_message := 'Pago aplicado';
            ELSE
                v_success := FALSE;
                v_razon_rechazo := 'El RFC o la cuenta del ordenante no coinciden con los registrados';
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


-- -----------------------------------------------------------------------------
-- B. get_apartado_pagos v2: `estado` de tres valores por movimiento.
--    Se conserva `aplicado` por compatibilidad con el front ya desplegado.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_apartado_pagos(p_oferta_id integer, p_token uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id_oferta     integer;
  v_id_propiedad  bigint;
  v_id_persona    integer;
  v_estatus       integer;
  v_id_cuenta     bigint;
  v_clabe_cuenta  text;
  v_clabe_tmp     text;
  v_clabes        text[];
  v_email         text;
  v_objetivo      numeric := 0;
  v_aplicado      numeric := 0;
  v_pagado        boolean := false;
  v_tiene_acceso  boolean := false;
  v_movs          jsonb   := '[]'::jsonb;
BEGIN
  -- Fallo cerrado: sin token no se responde nada (igual que get_apartado_status).
  IF p_token IS NULL THEN
    RETURN jsonb_build_object('ok', false);
  END IF;

  SELECT r.id_oferta INTO v_id_oferta
  FROM reservaciones r
  WHERE r.token = p_token
    AND r.activo = true
    AND r.estatus NOT IN ('expirado', 'cancelado')
    AND (r.fecha_expiracion IS NULL OR r.fecha_expiracion > now());

  IF v_id_oferta IS NULL OR (p_oferta_id IS NOT NULL AND v_id_oferta <> p_oferta_id) THEN
    RETURN jsonb_build_object('ok', false);
  END IF;

  SELECT o.id_propiedad, o.id_persona_lead
    INTO v_id_propiedad, v_id_persona
  FROM ofertas o
  WHERE o.id = v_id_oferta AND o.activo = true;

  IF v_id_propiedad IS NULL THEN
    RETURN jsonb_build_object('ok', false);
  END IF;

  SELECT p.id_estatus_disponibilidad, p.clabe_stp_tmp_apartado,
         COALESCE(p.monto_apartado, 20000)
    INTO v_estatus, v_clabe_tmp, v_objetivo
  FROM propiedades p WHERE p.id = v_id_propiedad;

  v_objetivo := COALESCE(v_objetivo, 20000);

  SELECT cc.id, cc.clabe_stp INTO v_id_cuenta, v_clabe_cuenta
  FROM cuentas_cobranza cc
  WHERE cc.id_oferta = v_id_oferta AND cc.activo = true
  ORDER BY cc.id
  LIMIT 1;

  -- Las dos CLABEs por las que puede entrar el dinero del apartado.
  v_clabes := ARRAY(
    SELECT DISTINCT c FROM unnest(ARRAY[v_clabe_cuenta, v_clabe_tmp]) AS c
    WHERE NULLIF(btrim(COALESCE(c, '')), '') IS NOT NULL
  );

  -- Movimientos vistos por STP. Se listan también los NO aplicados: son justo los que el
  -- cliente necesita ver para saber que tiene que reintentar.
  IF array_length(v_clabes, 1) IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(m ORDER BY m->>'fecha_hora' DESC), '[]'::jsonb) INTO v_movs
    FROM (
      SELECT jsonb_build_object(
               'clave_rastreo', r.claverastreo,
               'monto',         round(COALESCE(r.monto, 0), 2),
               'aplicado',      COALESCE(r.es_pago_aplicado, false),
               -- Tri-estado: NULL es el hueco entre que STP entrega el pago y el motor
               -- lo aplica. Colapsarlo a false lo pintaba como rechazado.
               'estado',        CASE
                                  WHEN r.es_pago_aplicado IS TRUE  THEN 'aplicado'
                                  WHEN r.es_pago_aplicado IS FALSE THEN 'rechazado'
                                  ELSE 'en_proceso'
                                END,
               'razon_rechazo', r.razon_rechazo,
               -- Solo el primer nombre del ordenante: el link puede reenviarse.
               'ordenante',     split_part(btrim(COALESCE(r.nombre_ordenante, '')), ' ', 1),
               'fecha',         COALESCE(
                                  NULLIF(r.fecha_operacion, ''),
                                  to_char(r.fecha_creacion, 'YYYY-MM-DD')
                                ),
               'fecha_hora',    to_char(r.fecha_creacion, 'YYYY-MM-DD"T"HH24:MI:SS')
             ) AS m
      FROM pagos_stp_raw r
      WHERE r.cuenta_beneficiario = ANY (v_clabes)
      ORDER BY r.id DESC
      LIMIT 50
    ) s;
  END IF;

  -- Total aplicado: con cuenta creada manda la contabilidad; antes de eso, lo que STP marcó.
  IF v_id_cuenta IS NOT NULL THEN
    SELECT COALESCE(SUM(pg.monto), 0) INTO v_aplicado
    FROM pagos pg
    WHERE pg.id_cuenta_cobranza = v_id_cuenta AND pg.activo = true;
  ELSE
    SELECT COALESCE(SUM(r.monto), 0) INTO v_aplicado
    FROM pagos_stp_raw r
    WHERE r.cuenta_beneficiario = ANY (COALESCE(v_clabes, ARRAY[]::text[]))
      AND COALESCE(r.es_pago_aplicado, false) = true;
  END IF;

  -- Misma regla de "pagado" que get_apartado_status, para no dar dos verdades.
  v_pagado := v_id_cuenta IS NOT NULL
           OR COALESCE(v_estatus, 0) IN (4, 5, 7, 8, 9)
           OR EXISTS (
                SELECT 1
                FROM cuentas_cobranza cc
                JOIN acuerdos_pago ap ON ap.id_cuenta_cobranza = cc.id
                WHERE cc.id_oferta = v_id_oferta
                  AND cc.activo = true
                  AND ap.activo = true
                  AND ap.id_concepto = 1
                  AND ap.pago_completado = true
              );

  SELECT per.email INTO v_email FROM personas per WHERE per.id = v_id_persona;

  SELECT EXISTS (
    SELECT 1 FROM usuarios u
    WHERE lower(u.email) = lower(v_email) AND u.activo = true
  ) INTO v_tiene_acceso;

  RETURN jsonb_build_object(
    'ok',                 true,
    'pagado',             v_pagado,
    'estatus_id',         v_estatus,
    'id_cuenta_cobranza', v_id_cuenta,
    'clabe',              COALESCE(v_clabe_cuenta, v_clabe_tmp),
    'monto_objetivo',     round(v_objetivo, 2),
    'total_aplicado',     round(v_aplicado, 2),
    'restante',           round(GREATEST(0, v_objetivo - v_aplicado), 2),
    'movimientos',        v_movs,
    'email_enmascarado',  CASE
                            WHEN v_email IS NULL OR position('@' in v_email) = 0 THEN NULL
                            ELSE left(split_part(v_email, '@', 1), 1) || '***@' || split_part(v_email, '@', 2)
                          END,
    'tiene_acceso',       COALESCE(v_tiene_acceso, false)
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- Post-checks
-- -----------------------------------------------------------------------------
DO $post$
DECLARE
  v_ips text := pg_get_functiondef('public.insertar_pago_stp'::regproc);
  v_gap text := pg_get_functiondef('public.get_apartado_pagos'::regproc);
BEGIN
  IF v_ips LIKE '%per.curp = p_rfc_curp_ordenante%' THEN
    RAISE EXCEPTION 'insertar_pago_stp sigue comparando contra CURP';
  END IF;

  IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.insertar_pago_stp'::regproc) THEN
    RAISE EXCEPTION 'insertar_pago_stp quedo como SECURITY DEFINER; era INVOKER';
  END IF;

  IF v_gap NOT LIKE '%en_proceso%' THEN
    RAISE EXCEPTION 'get_apartado_pagos no quedo con el tri-estado';
  END IF;

  IF NOT has_function_privilege('anon', 'public.get_apartado_pagos(integer, uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'get_apartado_pagos perdio el EXECUTE de anon; la pantalla publica quedaria rota';
  END IF;
END;
$post$;

COMMIT;

-- =============================================================================
-- Validacion (read-only, correr despues del deploy)
-- =============================================================================
-- SELECT pg_get_functiondef(oid) ILIKE '%per.curp = p_rfc_curp_ordenante%' AS sigue_usando_curp
-- FROM pg_proc WHERE proname='insertar_pago_stp' AND pronamespace='public'::regnamespace;
-- -- esperado: false
--
-- SELECT pg_get_functiondef(oid) ILIKE '%en_proceso%' AS tiene_estado
-- FROM pg_proc WHERE proname='get_apartado_pagos' AND pronamespace='public'::regnamespace;
-- -- esperado: true
--
-- SELECT p.proname, pg_get_function_identity_arguments(p.oid) args, p.prosecdef,
--        has_function_privilege('anon', p.oid, 'execute') anon_exec
-- FROM pg_proc p WHERE p.pronamespace='public'::regnamespace
--   AND p.proname IN ('insertar_pago_stp','get_apartado_pagos');
--
-- UAT: ver el documento. El caso B (mandar el CURP del lead) debe devolver
-- siguiente_accion = "rechazo_pago" con 'RFC del ordenante no coincide con el del cliente'.
-- Correr SIEMPRE dentro de BEGIN ... ROLLBACK: el caso A inserta en pagos_stp_raw.
-- =============================================================================
