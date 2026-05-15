-- ============================================================
-- BASELINE FUNCTIONS — generado 2026-05-14
-- Extraído de producción (proyecto: tzmhgfjmddkfyffkkmto)
-- Total de funciones: 95
-- ============================================================

-- actualizar_estatus_a_escrituracion
CREATE OR REPLACE FUNCTION public.actualizar_estatus_a_escrituracion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_id_propiedad BIGINT;
    v_estatus_actual INTEGER;
    v_saldo_pendiente NUMERIC;
    dato_actualizado BOOLEAN := FALSE;
BEGIN
    -- Detectar si se actualizó algún campo de escrituración
    IF (NEW.numero_escritura IS DISTINCT FROM OLD.numero_escritura) OR
       (NEW.libro IS DISTINCT FROM OLD.libro) OR
       (NEW.hoja IS DISTINCT FROM OLD.hoja) OR
       (NEW.numero_unidad_privativa IS DISTINCT FROM OLD.numero_unidad_privativa) OR
       (NEW.clave_catastral IS DISTINCT FROM OLD.clave_catastral) OR
       (NEW.fecha_escritura IS DISTINCT FROM OLD.fecha_escritura) THEN
        dato_actualizado := TRUE;
    END IF;

    IF NOT dato_actualizado THEN
        RETURN NEW;
    END IF;

    -- Obtener la propiedad relacionada y su estatus actual
    SELECT o.id_propiedad, p.id_estatus_disponibilidad
    INTO v_id_propiedad, v_estatus_actual
    FROM ofertas o
    JOIN propiedades p ON o.id_propiedad = p.id
    WHERE o.id = NEW.id_oferta
      AND o.id_producto IS NULL
      AND p.activo = TRUE;

    IF v_id_propiedad IS NULL OR v_estatus_actual IS NULL OR v_estatus_actual != 9 THEN
        RETURN NEW;
    END IF;

    -- NUEVA VALIDACIÓN: Verificar que la cuenta esté realmente pagada
    SELECT NEW.precio_final - COALESCE(SUM(p.monto), 0)
    INTO v_saldo_pendiente
    FROM pagos p
    WHERE p.id_cuenta_cobranza = NEW.id
      AND p.activo = true;

    -- Solo permitir el cambio si el saldo es <= $0.01
    IF v_saldo_pendiente > 0.01 THEN
        RAISE LOG 'Propiedad % NO actualizada a Escrituración: saldo pendiente $%', 
            v_id_propiedad, v_saldo_pendiente;
        RETURN NEW;
    END IF;

    -- Actualizar estatus a Escrituración
    UPDATE propiedades
    SET id_estatus_disponibilidad = 7,
        fecha_actualizacion = CURRENT_TIMESTAMP
    WHERE id = v_id_propiedad
      AND id_estatus_disponibilidad = 9;

    RAISE NOTICE 'Propiedad % actualizada de PAGADA COMPLETAMENTE (9) a ESCRITURACIÓN (7)', v_id_propiedad;

    RETURN NEW;
END;
$function$;

-- actualizar_estatus_propiedad_apartada
CREATE OR REPLACE FUNCTION public.actualizar_estatus_propiedad_apartada()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id_propiedad integer;
  v_estatus_actual integer;
BEGIN
  -- Solo cuando un acuerdo de "Apartado" pasa de no-completado a completado
  IF NEW.id_concepto <> 1 THEN
    RETURN NEW;
  END IF;

  IF NEW.pago_completado IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND COALESCE(OLD.pago_completado, false) = true THEN
    RETURN NEW;
  END IF;

  -- Resolver propiedad vía cuentas_cobranza -> ofertas
  SELECT o.id_propiedad
    INTO v_id_propiedad
  FROM cuentas_cobranza cc
  JOIN ofertas o ON o.id = cc.id_oferta
  WHERE cc.id = NEW.id_cuenta_cobranza
  LIMIT 1;

  IF v_id_propiedad IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT id_estatus_disponibilidad
    INTO v_estatus_actual
  FROM propiedades
  WHERE id = v_id_propiedad;

  -- Solo avanzar si está en Inventario (1) o Disponible (2). Nunca retroceder.
  IF v_estatus_actual IN (1, 2) THEN
    UPDATE propiedades
    SET id_estatus_disponibilidad = 4,
        clabe_stp_tmp_apartado = NULL,
        monto_apartado_pagando = 0
    WHERE id = v_id_propiedad;
  END IF;

  RETURN NEW;
END;
$function$;

-- actualizar_estatus_propiedad_pagada
CREATE OR REPLACE FUNCTION public.actualizar_estatus_propiedad_pagada()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id_cuenta_cobranza INTEGER;
  v_id_oferta INTEGER;
  v_id_propiedad BIGINT;
  v_total_acuerdos INTEGER;
  v_acuerdos_completados INTEGER;
  v_todos_completados BOOLEAN := FALSE;
BEGIN
  -- Obtener id_cuenta_cobranza desde el acuerdo de pago
  SELECT id_cuenta_cobranza INTO v_id_cuenta_cobranza
  FROM acuerdos_pago
  WHERE id = NEW.id_acuerdo_pago
    AND activo = true;

  IF v_id_cuenta_cobranza IS NULL THEN
    RETURN NEW;
  END IF;

  -- Obtener id_oferta de la cuenta de cobranza
  SELECT id_oferta INTO v_id_oferta
  FROM cuentas_cobranza
  WHERE id = v_id_cuenta_cobranza
    AND activo = true;

  -- Si no hay oferta, salir
  IF v_id_oferta IS NULL THEN
    RETURN NEW;
  END IF;

  -- Obtener id_propiedad desde la oferta
  SELECT id_propiedad INTO v_id_propiedad
  FROM ofertas
  WHERE id = v_id_oferta;

  -- Solo procesar si es una propiedad (no producto/servicio)
  IF v_id_propiedad IS NULL THEN
    RETURN NEW;
  END IF;

  -- 🔥 NUEVA LÓGICA: Verificar si TODOS los acuerdos están completados
  SELECT 
    COUNT(*) as total,
    COUNT(CASE WHEN pago_completado = true THEN 1 END) as completados
  INTO v_total_acuerdos, v_acuerdos_completados
  FROM acuerdos_pago
  WHERE id_cuenta_cobranza = v_id_cuenta_cobranza
    AND activo = true;

  -- Determinar si todos están completados
  v_todos_completados := (v_total_acuerdos > 0 AND v_total_acuerdos = v_acuerdos_completados);

  -- Solo actualizar a "Pagada completamente" si TODOS los acuerdos están completados
  IF v_todos_completados THEN
    UPDATE propiedades
    SET id_estatus_disponibilidad = 9  -- Pagada completamente
    WHERE id = v_id_propiedad
      AND id_estatus_disponibilidad != 9;  -- Solo si no está ya en ese estatus
    
    RAISE NOTICE 'Propiedad % actualizada a PAGADA COMPLETAMENTE (id_estatus_disponibilidad=9). Acuerdos completados: % de %', 
      v_id_propiedad, v_acuerdos_completados, v_total_acuerdos;
  ELSE
    RAISE LOG 'Propiedad %: Acuerdos completados: % de % - NO actualizar estatus', 
      v_id_propiedad, v_acuerdos_completados, v_total_acuerdos;
  END IF;

  RETURN NEW;
END;
$function$;

-- actualizar_estatus_reservas
CREATE OR REPLACE FUNCTION public.actualizar_estatus_reservas()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  -- Actualizar a "Pagado" (id=2) cuando el acuerdo de pago está completado
  UPDATE reservas r
  SET id_estatus_reserva = 2
  FROM acuerdos_pago ap
  WHERE r.id_acuerdo_pago = ap.id
    AND ap.pago_completado = true
    AND r.id_estatus_reserva = 1  -- Solo si está en "Agendada"
    AND r.activo = true;

  -- Actualizar a "En progreso" (id=3) cuando la fecha/hora actual está dentro de la duración de la reserva
  UPDATE reservas r
  SET id_estatus_reserva = 3
  FROM espacios_reservables_edificio ere
  WHERE r.id_espacio_reservable_edificio = ere.id
    AND r.id_estatus_reserva = 2  -- Solo si está en "Pagado"
    AND r.activo = true
    AND CONCAT(r.fecha_reserva::text, ' ', r.hora_reserva)::timestamp <= NOW()
    AND (CONCAT(r.fecha_reserva::text, ' ', r.hora_reserva)::timestamp + 
         COALESCE(ere.duracion_reserva, INTERVAL '1 hour')) > NOW();

  -- Actualizar a "Terminada" (id=4) cuando termina la duración de la reserva
  UPDATE reservas r
  SET id_estatus_reserva = 4
  FROM espacios_reservables_edificio ere
  WHERE r.id_espacio_reservable_edificio = ere.id
    AND r.id_estatus_reserva = 3  -- Solo si está en "En progreso"
    AND r.activo = true
    AND (CONCAT(r.fecha_reserva::text, ' ', r.hora_reserva)::timestamp + 
         COALESCE(ere.duracion_reserva, INTERVAL '1 hour')) <= NOW();
END;
$function$;

-- actualizar_precio_m2_proyecto
CREATE OR REPLACE FUNCTION public.actualizar_precio_m2_proyecto()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_precio_final NUMERIC;
    v_m2_total NUMERIC;
    v_precio_por_m2_actual NUMERIC;
    v_precio_m2_actual_proyecto NUMERIC;
    v_id_proyecto INTEGER;
BEGIN
    -- Solo ejecutar cuando el estatus cambia a "Vendido" (id=5)
    IF NEW.id_estatus_disponibilidad = 5 AND (OLD.id_estatus_disponibilidad IS NULL OR OLD.id_estatus_disponibilidad != 5) THEN
        
        -- Obtener la suma de m2_interiores + m2_exteriores de la propiedad
        SELECT (COALESCE(m2_interiores, 0) + COALESCE(m2_exteriores, 0)) INTO v_m2_total
        FROM propiedades
        WHERE id = NEW.id;
        
        -- Obtener precio_final de la cuenta de cobranza asociada
        SELECT cc.precio_final, er.id_proyecto
        INTO v_precio_final, v_id_proyecto
        FROM cuentas_cobranza cc
        JOIN ofertas o ON cc.id_oferta = o.id
        JOIN propiedades p ON o.id_propiedad = p.id
        JOIN entidades_relacionadas er ON p.id_entidad_relacionada_dueno = er.id
        WHERE o.id_propiedad = NEW.id
          AND cc.activo = true
        ORDER BY cc.fecha_creacion DESC
        LIMIT 1;
        
        -- Validar que tengamos los datos necesarios
        IF v_precio_final IS NOT NULL AND v_m2_total IS NOT NULL AND v_m2_total > 0 AND v_id_proyecto IS NOT NULL THEN
            
            -- Calcular precio por m2 actual y redondear a 2 decimales
            v_precio_por_m2_actual := ROUND(v_precio_final / v_m2_total, 2);
            
            -- Obtener el precio_m2_actual actual del proyecto
            SELECT precio_m2_actual INTO v_precio_m2_actual_proyecto
            FROM proyectos
            WHERE id = v_id_proyecto;
            
            -- Si el precio_m2_actual del proyecto es NULL o menor al recién calculado, actualizarlo
            IF v_precio_m2_actual_proyecto IS NULL OR v_precio_m2_actual_proyecto < v_precio_por_m2_actual THEN
                UPDATE proyectos
                SET precio_m2_actual = v_precio_por_m2_actual,
                    fecha_actualizacion = CURRENT_TIMESTAMP
                WHERE id = v_id_proyecto;
                
                RAISE NOTICE 'Actualizado precio_m2_actual del proyecto % a %', v_id_proyecto, v_precio_por_m2_actual;
            END IF;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$function$;

-- agent_claim_or_reactivate_prospect_project
CREATE OR REPLACE FUNCTION public.agent_claim_or_reactivate_prospect_project(_persona_id bigint, _proyecto_id bigint, _owner_persona_id bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _current_persona_id BIGINT;
  _effective_owner BIGINT;
  _relation_id BIGINT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  _current_persona_id := public.get_current_user_persona_id();

  IF NOT public.is_admin_user() AND _current_persona_id IS NULL THEN
    RAISE EXCEPTION 'User persona not found';
  END IF;

  -- Determine effective owner: admins can specify, others use their own
  IF _owner_persona_id IS NOT NULL AND public.is_admin_user() THEN
    _effective_owner := _owner_persona_id;
  ELSE
    _effective_owner := _current_persona_id;
  END IF;

  IF NOT public.is_admin_user() AND NOT EXISTS (
    SELECT 1
    FROM public.entidades_relacionadas
    WHERE id_persona = _persona_id
      AND id_tipo_entidad = 7
      AND activo = true
      AND id_persona_duena_lead = _current_persona_id
  ) THEN
    RAISE EXCEPTION 'No tienes acceso para reasignar este prospecto';
  END IF;

  SELECT id
  INTO _relation_id
  FROM public.entidades_relacionadas
  WHERE id_persona = _persona_id
    AND id_tipo_entidad = 7
    AND id_proyecto = _proyecto_id
  ORDER BY id DESC
  LIMIT 1;

  IF _relation_id IS NOT NULL THEN
    UPDATE public.entidades_relacionadas
    SET activo = true,
        id_persona_duena_lead = COALESCE(_effective_owner, id_persona_duena_lead)
    WHERE id = _relation_id;

    RETURN _relation_id;
  END IF;

  INSERT INTO public.entidades_relacionadas (
    id_persona,
    id_tipo_entidad,
    id_proyecto,
    id_persona_duena_lead,
    activo
  )
  VALUES (
    _persona_id,
    7,
    _proyecto_id,
    _effective_owner,
    true
  )
  RETURNING id INTO _relation_id;

  RETURN _relation_id;
END;
$function$;

-- agent_claim_or_reactivate_prospect_project
CREATE OR REPLACE FUNCTION public.agent_claim_or_reactivate_prospect_project(_persona_id bigint, _proyecto_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _current_persona_id BIGINT;
  _relation_id BIGINT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  _current_persona_id := public.get_current_user_persona_id();

  IF NOT public.is_admin_user() AND _current_persona_id IS NULL THEN
    RAISE EXCEPTION 'User persona not found';
  END IF;

  IF NOT public.is_admin_user() AND NOT EXISTS (
    SELECT 1
    FROM public.entidades_relacionadas
    WHERE id_persona = _persona_id
      AND id_tipo_entidad = 7
      AND activo = true
      AND id_persona_duena_lead = _current_persona_id
  ) THEN
    RAISE EXCEPTION 'No tienes acceso para reasignar este prospecto';
  END IF;

  SELECT id
  INTO _relation_id
  FROM public.entidades_relacionadas
  WHERE id_persona = _persona_id
    AND id_tipo_entidad = 7
    AND id_proyecto = _proyecto_id
  ORDER BY id DESC
  LIMIT 1;

  IF _relation_id IS NOT NULL THEN
    UPDATE public.entidades_relacionadas
    SET activo = true,
        id_persona_duena_lead = COALESCE(_current_persona_id, id_persona_duena_lead)
    WHERE id = _relation_id;

    RETURN _relation_id;
  END IF;

  INSERT INTO public.entidades_relacionadas (
    id_persona,
    id_tipo_entidad,
    id_proyecto,
    id_persona_duena_lead,
    activo
  )
  VALUES (
    _persona_id,
    7,
    _proyecto_id,
    _current_persona_id,
    true
  )
  RETURNING id INTO _relation_id;

  RETURN _relation_id;
END;
$function$;

-- agregar_conyuge_como_comprador
CREATE OR REPLACE FUNCTION public.agregar_conyuge_como_comprador()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_id_conyuge INTEGER;
    v_nuevo_porcentaje NUMERIC;
    v_existe_conyuge BOOLEAN;
    v_es_producto BOOLEAN;
BEGIN
    -- Solo ejecutar en el primer nivel del trigger
    IF pg_trigger_depth() > 0 THEN
        RETURN NEW;
    END IF;

    -- Solo proceder si el comprador está activo
    IF NEW.activo = false THEN
        RETURN NEW;
    END IF;

    -- Verificar si la cuenta de cobranza es de un producto
    SELECT EXISTS(
        SELECT 1
        FROM cuentas_cobranza cc
        JOIN ofertas o ON cc.id_oferta = o.id
        WHERE cc.id = NEW.id_cuenta_cobranza
          AND o.id_producto IS NOT NULL
    ) INTO v_es_producto;

    -- Si es un producto, no hacer nada
    IF v_es_producto THEN
        RETURN NEW;
    END IF;

    -- Obtener el id_conyuge de la persona
    SELECT id_conyuge INTO v_id_conyuge
    FROM personas
    WHERE id = NEW.id_persona
      AND id_conyuge IS NOT NULL
      AND activo = true;

    -- Si no tiene cónyuge, no hacer nada
    IF v_id_conyuge IS NULL THEN
        RETURN NEW;
    END IF;

    -- Calcular el nuevo porcentaje
    v_nuevo_porcentaje := NEW.porcentaje_copropiedad / 2;

    -- Actualizar el porcentaje del comprador original
    UPDATE compradores
    SET porcentaje_copropiedad = v_nuevo_porcentaje,
        fecha_actualizacion = CURRENT_TIMESTAMP
    WHERE id_persona = NEW.id_persona
      AND id_cuenta_cobranza = NEW.id_cuenta_cobranza
      AND activo = true;

    -- Verificar si el cónyuge ya existe como comprador
    SELECT EXISTS(
        SELECT 1 
        FROM compradores
        WHERE id_persona = v_id_conyuge
          AND id_cuenta_cobranza = NEW.id_cuenta_cobranza
          AND activo = true
    ) INTO v_existe_conyuge;

    -- Si el cónyuge no existe, agregarlo
    IF NOT v_existe_conyuge THEN
        INSERT INTO compradores (
            id_cuenta_cobranza,
            id_persona,
            porcentaje_copropiedad,
            activo,
            fecha_creacion,
            fecha_actualizacion
        ) VALUES (
            NEW.id_cuenta_cobranza,
            v_id_conyuge,
            v_nuevo_porcentaje,
            true,
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP
        );
    ELSE
        -- Si ya existe, actualizar su porcentaje
        UPDATE compradores
        SET porcentaje_copropiedad = v_nuevo_porcentaje,
            fecha_actualizacion = CURRENT_TIMESTAMP
        WHERE id_persona = v_id_conyuge
          AND id_cuenta_cobranza = NEW.id_cuenta_cobranza
          AND activo = true;
    END IF;

    RETURN NEW;
END;
$function$;

-- agregar_conyuge_en_todas_cuentas
CREATE OR REPLACE FUNCTION public.agregar_conyuge_en_todas_cuentas()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_cuenta_record RECORD;
    v_nuevo_porcentaje NUMERIC;
    v_existe_conyuge BOOLEAN;
    v_existe_persona_original BOOLEAN;
BEGIN
    -- Solo ejecutar en el primer nivel del trigger
    IF pg_trigger_depth() > 0 THEN
        RETURN NEW;
    END IF;

    -- Solo proceder si hay un nuevo cónyuge asignado
    IF NEW.id_conyuge IS NULL THEN
        RETURN NEW;
    END IF;

    -- Solo proceder si ambas personas están activas
    IF NEW.activo = false THEN
        RETURN NEW;
    END IF;

    -- Verificar que el cónyuge existe y está activo
    IF NOT EXISTS(
        SELECT 1 FROM personas 
        WHERE id = NEW.id_conyuge 
        AND activo = true
    ) THEN
        RETURN NEW;
    END IF;

    -- ====================================================================
    -- LOOP 1: Procesar cuentas donde la PERSONA ORIGINAL (NEW.id) es compradora
    -- ====================================================================
    FOR v_cuenta_record IN
        SELECT 
            c.id_cuenta_cobranza,
            c.porcentaje_copropiedad
        FROM compradores c
        JOIN cuentas_cobranza cc ON c.id_cuenta_cobranza = cc.id
        JOIN ofertas o ON cc.id_oferta = o.id
        WHERE c.id_persona = NEW.id
          AND c.activo = true
          AND cc.activo = true
          AND o.id_producto IS NULL  -- Solo propiedades
    LOOP
        -- Verificar si el cónyuge ya existe en esta cuenta
        SELECT EXISTS(
            SELECT 1 
            FROM compradores
            WHERE id_persona = NEW.id_conyuge
              AND id_cuenta_cobranza = v_cuenta_record.id_cuenta_cobranza
              AND activo = true
        ) INTO v_existe_conyuge;

        IF NOT v_existe_conyuge THEN
            -- Dividir el porcentaje actual
            v_nuevo_porcentaje := v_cuenta_record.porcentaje_copropiedad / 2;

            -- Actualizar el porcentaje de la persona original
            UPDATE compradores
            SET porcentaje_copropiedad = v_nuevo_porcentaje,
                fecha_actualizacion = CURRENT_TIMESTAMP
            WHERE id_persona = NEW.id
              AND id_cuenta_cobranza = v_cuenta_record.id_cuenta_cobranza
              AND activo = true;

            -- Insertar el cónyuge con el otro 50%
            INSERT INTO compradores (
                id_cuenta_cobranza,
                id_persona,
                porcentaje_copropiedad,
                activo,
                fecha_creacion,
                fecha_actualizacion
            ) VALUES (
                v_cuenta_record.id_cuenta_cobranza,
                NEW.id_conyuge,
                v_nuevo_porcentaje,
                true,
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP
            );
        END IF;
    END LOOP;

    -- ====================================================================
    -- LOOP 2: Procesar cuentas donde el CÓNYUGE (NEW.id_conyuge) es comprador
    -- ====================================================================
    FOR v_cuenta_record IN
        SELECT 
            c.id_cuenta_cobranza,
            c.porcentaje_copropiedad
        FROM compradores c
        JOIN cuentas_cobranza cc ON c.id_cuenta_cobranza = cc.id
        JOIN ofertas o ON cc.id_oferta = o.id
        WHERE c.id_persona = NEW.id_conyuge
          AND c.activo = true
          AND cc.activo = true
          AND o.id_producto IS NULL  -- Solo propiedades
    LOOP
        -- Verificar si la persona original ya existe en esta cuenta del cónyuge
        SELECT EXISTS(
            SELECT 1 
            FROM compradores
            WHERE id_persona = NEW.id
              AND id_cuenta_cobranza = v_cuenta_record.id_cuenta_cobranza
              AND activo = true
        ) INTO v_existe_persona_original;

        IF NOT v_existe_persona_original THEN
            -- Dividir el porcentaje del cónyuge
            v_nuevo_porcentaje := v_cuenta_record.porcentaje_copropiedad / 2;

            -- Actualizar el porcentaje del cónyuge
            UPDATE compradores
            SET porcentaje_copropiedad = v_nuevo_porcentaje,
                fecha_actualizacion = CURRENT_TIMESTAMP
            WHERE id_persona = NEW.id_conyuge
              AND id_cuenta_cobranza = v_cuenta_record.id_cuenta_cobranza
              AND activo = true;

            -- Insertar la persona original con el otro 50%
            INSERT INTO compradores (
                id_cuenta_cobranza,
                id_persona,
                porcentaje_copropiedad,
                activo,
                fecha_creacion,
                fecha_actualizacion
            ) VALUES (
                v_cuenta_record.id_cuenta_cobranza,
                NEW.id,
                v_nuevo_porcentaje,
                true,
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP
            );
        END IF;
    END LOOP;

    RETURN NEW;
END;
$function$;

-- ajustar_ultimo_acuerdo_pago
CREATE OR REPLACE FUNCTION public.ajustar_ultimo_acuerdo_pago()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_suma_acuerdos NUMERIC;
    v_precio_final NUMERIC;
    v_diferencia NUMERIC;
    v_id_ultimo_acuerdo INTEGER;
    v_monto_ultimo NUMERIC;
    v_orden_ultimo INTEGER;
    v_pago_completado BOOLEAN;
BEGIN
    -- Evitar recursión infinita
    IF pg_trigger_depth() > 1 THEN
        RETURN NEW;
    END IF;

    -- Solo proceder si el acuerdo está activo
    IF NEW.activo = FALSE THEN
        RETURN NEW;
    END IF;

    -- Obtener el precio final de la cuenta de cobranza
    SELECT precio_final
    INTO v_precio_final
    FROM cuentas_cobranza
    WHERE id = NEW.id_cuenta_cobranza
      AND activo = TRUE;

    -- Si no hay precio final, no hacer nada
    IF v_precio_final IS NULL OR v_precio_final <= 0 THEN
        RETURN NEW;
    END IF;

    -- Calcular la suma de todos los acuerdos activos
    SELECT COALESCE(SUM(monto), 0)
    INTO v_suma_acuerdos
    FROM acuerdos_pago
    WHERE id_cuenta_cobranza = NEW.id_cuenta_cobranza
      AND activo = TRUE;

    -- Calcular la diferencia
    v_diferencia := v_precio_final - v_suma_acuerdos;

    -- Solo ajustar si la diferencia es significativa (mayor a 1 centavo)
    IF ABS(v_diferencia) <= 0.01 THEN
        RETURN NEW;
    END IF;

    -- Identificar el último acuerdo (el de mayor orden)
    SELECT id, monto, orden, pago_completado
    INTO v_id_ultimo_acuerdo, v_monto_ultimo, v_orden_ultimo, v_pago_completado
    FROM acuerdos_pago
    WHERE id_cuenta_cobranza = NEW.id_cuenta_cobranza
      AND activo = TRUE
    ORDER BY orden DESC
    LIMIT 1;

    -- Si el último acuerdo no existe o ya está pagado, no hacer nada
    IF v_id_ultimo_acuerdo IS NULL OR v_pago_completado = TRUE THEN
        RETURN NEW;
    END IF;

    -- Ajustar el monto del último acuerdo
    UPDATE acuerdos_pago
    SET monto = v_monto_ultimo + v_diferencia,
        fecha_actualizacion = CURRENT_TIMESTAMP
    WHERE id = v_id_ultimo_acuerdo;

    RAISE NOTICE 'Ajustado acuerdo % (orden %): monto anterior %, nuevo monto %, diferencia %', 
        v_id_ultimo_acuerdo, v_orden_ultimo, v_monto_ultimo, v_monto_ultimo + v_diferencia, v_diferencia;

    RETURN NEW;
END;
$function$;

-- borrar_sp_cargar_amenidades_proyectos_desde_stagin
CREATE OR REPLACE FUNCTION public.borrar_sp_cargar_amenidades_proyectos_desde_stagin()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  INSERT INTO public.amenidades_proyectos (id_amenidad, id_proyecto)
  SELECT 
    a.id AS id_amenidad,
    p.id AS id_proyecto
  FROM public.borrar_amenidades_proyectos_stagin s
  JOIN public.amenidades a 
    ON TRIM(LOWER(a.nombre)) = TRIM(LOWER(s.amenidad))
  JOIN public.proyectos p 
    ON TRIM(LOWER(p.nombre)) = TRIM(LOWER(s.proyecto))
  WHERE NOT EXISTS (
    SELECT 1 
    FROM public.amenidades_proyectos ap
    WHERE ap.id_amenidad = a.id
      AND ap.id_proyecto = p.id
  );
END;
$function$;

-- borrar_sp_cargar_edificio_modelo
CREATE OR REPLACE FUNCTION public.borrar_sp_cargar_edificio_modelo()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  INSERT INTO public.edificios_modelos (
    id_edificio,
    id_modelo
  )
  select 
    e.id as id_edificio,
    m.id as id_modelo
  from edificios e
  join modelos m on e.id_proyecto=m.id_proyecto
  where e.id<>9
  order by 1;

  RAISE NOTICE '✅ Datos insertados correctamente desde el select edificios, modelos → edificio_modelo.';
END;
$function$;

-- borrar_sp_cargar_edificios_desde_stagin
CREATE OR REPLACE FUNCTION public.borrar_sp_cargar_edificios_desde_stagin()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  INSERT INTO public.edificios (id_proyecto, nombre, numero_pisos, fecha_lanzamiento)
  SELECT distinct
    p.id AS id_proyecto,
    s.nombre,
    s.numero_pisos,
    max(s.fecha_lanzamiento)
  FROM public.borrar_edificios_stagin s
  JOIN public.proyectos p ON TRIM(LOWER(p.nombre)) = TRIM(LOWER(s.proyecto))
 WHERE p.id<>2
 group by
  p.id,
  s.nombre,
  s.numero_pisos;

 
  RAISE NOTICE '✅ Datos insertados correctamente desde borrar_edificios_stagin → edificios.';
END;
$function$;

-- borrar_sp_cargar_modelos_caracteristicas_desde_stagin
CREATE OR REPLACE FUNCTION public.borrar_sp_cargar_modelos_caracteristicas_desde_stagin()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  INSERT INTO public.modelos_caracteristicas (id_modelo, id_caracteristica)
  SELECT 
    m.id AS id_modelo,
    c.id as id_caracteristica
  FROM public.borrar_modelos_caracteristicas_stagin s
  left outer JOIN public.caracteristicas c on TRIM(LOWER(s.caracteristica)) = TRIM(LOWER(c.nombre))
  left outer JOIN public.proyectos p ON TRIM(LOWER(s.proyecto)) = TRIM(LOWER(p.nombre))
  left outer JOIN public.modelos m ON TRIM(LOWER(s.modelo)) = TRIM(LOWER(m.nombre)) AND m.id_proyecto = p.id
  where c.id is not null
  group by
    s.proyecto,
    s.modelo,
    s.caracteristica,
    m.id,
    c.id
  ;

  RAISE NOTICE 'Datos insertados correctamente en modelos_caracteristicas.';
END;
$function$;

-- borrar_sp_cargar_modelos_desde_stagin
CREATE OR REPLACE FUNCTION public.borrar_sp_cargar_modelos_desde_stagin()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  INSERT INTO public.modelos (
    id_proyecto,
    nombre,
    descripcion,
    numero_medio_bano,
    numero_completo_banos,
    numero_recamaras
  )
  SELECT
    p.id AS id_proyecto,
    s.nombre,
    s.descripcion,
    NULLIF(s.numero_medio_bano, '')::integer as numero_medio_bano,
    NULLIF(s.numero_completo_banos, '')::integer as numero_completo_banos,
    NULLIF(s.numero_recamaras, '')::integer as numero_recamaras
  FROM public.borrar_modelos_stagin s
  left outer JOIN public.proyectos p
    ON TRIM(LOWER(p.nombre)) = TRIM(LOWER(s.proyecto));

  RAISE NOTICE '✅ Datos insertados correctamente desde borrar_modelos_stagin → modelos.';
END;
$function$;

-- borrar_sp_cargar_multimedias_modelo_desde_stagin
CREATE OR REPLACE FUNCTION public.borrar_sp_cargar_multimedias_modelo_desde_stagin()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  INSERT INTO public.multimedias_modelo (id_modelo, url, ver_como_ubicacion_en_oferta)
  SELECT 
    m.id AS id_modelo,
    s.url,
    ver_como_ubicacion_en_oferta
  FROM public.borrar_multimedias_modelo_stagin s
  JOIN public.proyectos p 
    ON TRIM(LOWER(s.proyecto)) = TRIM(LOWER(p.nombre))
  JOIN public.modelos m 
    ON TRIM(LOWER(s.modelo)) = TRIM(LOWER(m.nombre))
    AND m.id_proyecto = p.id
  WHERE s.url IS NOT NULL
  AND s.modelo IS NOT NULL
  AND s.proyecto IS NOT NULL;

  RAISE NOTICE 'Datos insertados correctamente en multimedias_modelo.';
END;
$function$;

-- borrar_sp_cargar_multimedias_proyecto
CREATE OR REPLACE FUNCTION public.borrar_sp_cargar_multimedias_proyecto()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  INSERT INTO public.multimedias_proyecto (
    id_proyecto,
    url
  )
   select 
    p.id as id_proyecto,
    m.url
  from borrar_multimedias_todo_stagin m
  left outer JOIN public.proyectos p ON TRIM(LOWER(p.nombre)) = TRIM(LOWER(m.proyecto))
    ;
 

  RAISE NOTICE '✅ Datos insertados correctamente desde el select borrar_multimedias_todo_stagin → multimedias_proyecto.';
END;
$function$;

-- borrar_sp_cargar_proyectos_desde_stagin
CREATE OR REPLACE FUNCTION public.borrar_sp_cargar_proyectos_desde_stagin()
 RETURNS void
 LANGUAGE plpgsql
AS $function$BEGIN
  -- 🔹 1. Actualizar id_tipo_uso con base en tipo_uso
  UPDATE public.borrar_proyectos_stagin ps
  SET id_tipo_uso = tu.id
  FROM public.tipos_uso tu
  WHERE ps.tipo_uso IS NOT NULL
    AND TRIM(LOWER(ps.tipo_uso)) = TRIM(LOWER(tu.nombre));

  -- 🔹 2. Actualizar id_pais 
  UPDATE public.borrar_proyectos_stagin ps
  SET id_pais = p.id::text
  FROM public.paises p
  WHERE ps.nombre_pais IS NOT NULL
    AND TRIM(LOWER(ps.nombre_pais)) = TRIM(LOWER(p.nombre));

  -- 🔹 3. Actualizar id_estado
  UPDATE public.borrar_proyectos_stagin ps
  SET id_estado = CAST(e.id AS bigint)
  FROM public.estados_mx e
  WHERE ps.nombre_estado IS NOT NULL
    AND TRIM(LOWER(ps.nombre_estado)) = TRIM(LOWER(e.nombre));

  -- 🔹 4. Actualizar id_municipio
  UPDATE public.borrar_proyectos_stagin ps
  SET id_municipio = CAST(m.id AS bigint)
  FROM public.municipios_mx m
  WHERE ps.nombre_municipio IS NOT NULL
    AND TRIM(LOWER(ps.nombre_municipio)) = TRIM(LOWER(m.nombre));

  -- 🔹 5. Insertar datos en proyectos (evitando duplicados por nombre)
  INSERT INTO public.proyectos (
    nombre,
    descripcion,
    direccion,
    fecha_inicio_construccion,
    id_tipo_uso,
    latitud,
    longitud,
    url_logo,
    url_firma_recibos,
    nombre_firmante_recibos,
    url_imagen_portada,
    costo_mantenimiento_m2,
    id_estatus_proyecto,
    fecha_lanzamiento,
    fecha_entrega,
    direccion_id_pais,
    direccion_id_estado,
    direccion_id_municipio
  )
  SELECT
    ps.nombre,
    ps.descripcion,
    ps.direccion,
    ps.fecha_inicio_construccion::date,
    ps.id_tipo_uso,
    ps.latitud,
    ps.longitud,
    ps.url_logo,
    ps.url_firma_recibos,
    ps.nombre_firmante_recibos,
    ps.url_imagen_portada,
    COALESCE(ps.costo_mantenimiento_m2::numeric, 0),
    ps.id_estatus_proyecto,
    ps.fecha_lanzamiento::timestamp,
    ps.fecha_entrega::timestamp,
    ps.id_pais,     -- ya debe tener el valor correcto ('MX', 'US', etc.)
    ps.id_estado::integer,
    ps.id_municipio::integer
  FROM public.borrar_proyectos_stagin ps
  WHERE ps.nombre IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.proyectos p
      WHERE TRIM(LOWER(p.nombre)) = TRIM(LOWER(ps.nombre))
    );

  RAISE NOTICE 'Datos insertados correctamente desde proyectos_stagin → proyectos.';
END;$function$;

-- borrar_sp_cargar_videos_youtube_proyecto
CREATE OR REPLACE FUNCTION public.borrar_sp_cargar_videos_youtube_proyecto()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  INSERT INTO public.videos_youtube (
    id_proyecto,
    nombre,
    link
  )
   select 
    p.id as id_proyecto,
    v.nombre,
    v.link
  from borrar_videos_youtube_stagin v
  left outer JOIN public.proyectos p ON TRIM(LOWER(p.nombre)) = TRIM(LOWER(v.proyecto))
    ;
 

  RAISE NOTICE '✅ Datos insertados correctamente desde el select borrar_videos_youtube_stagin → videos_youtube de proyectos.';
END;
$function$;

-- borrar_sp_esquemas_pago_proyecto
CREATE OR REPLACE FUNCTION public.borrar_sp_esquemas_pago_proyecto()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  INSERT INTO public.esquemas_pago (
    id_proyecto,
    nombre,
    porcentaje_descuento_aumento,
    porcentaje_enganche,
    porcentaje_mensualidades,
    numero_mensualidades,
    porcentaje_entrega
  )
   select 
    p.id as id_proyecto,
    e.nombre,
    coalesce(e.porcentaje_descuento_aumento::numeric,0) as porcentaje_descuento_aumento,
    coalesce(e.porcentaje_enganche::numeric,0) as porcentaje_enganche,
    coalesce(e.porcentaje_mensualidades::numeric,0) as porcentaje_mensualidades,
    coalesce(e.numero_mensualidades::numeric,0) as numero_mensualidades,
    coalesce(e.porcentaje_entrega::numeric,0) as porcentaje_entrega
  from borrar_esquemas_pago_stagin e
 JOIN public.proyectos p ON TRIM(LOWER(p.nombre)) = TRIM(LOWER(e.proyecto))
    ;
 

  RAISE NOTICE '✅ Datos insertados correctamente desde el select borrar_esquemas_pago_stagin → esquemas_pago de proyectos.';
END;
$function$;

-- borrar_sp_vistas
CREATE OR REPLACE FUNCTION public.borrar_sp_vistas()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  INSERT INTO public.vistas (
    id_proyecto,
    nombre,
    url
  )
   select 
    p.id as id_proyecto,
    v.nombre,
    v.url
  from borrar_vistas_stagin v
 JOIN public.proyectos p ON TRIM(LOWER(p.nombre)) = TRIM(LOWER(v.proyecto))
    ;
 

  RAISE NOTICE '✅ Datos insertados correctamente desde el select borrar_vistas_stagin → vistas de proyectos.';
END;
$function$;

-- can_access_agent_owned_lead
CREATE OR REPLACE FUNCTION public.can_access_agent_owned_lead(_owner_persona_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT (
    public.is_admin_user()
    OR public.can_view_all_prospects()
    OR (
      public.get_current_user_persona_id() IS NOT NULL
      AND _owner_persona_id IS NOT NULL
      AND _owner_persona_id = public.get_current_user_persona_id()
    )
    OR EXISTS (
      SELECT 1
      FROM public.entidades_relacionadas er_ag
      WHERE er_ag.id_tipo_entidad = 19
        AND er_ag.activo = true
        AND er_ag.id_persona = _owner_persona_id
        AND er_ag.id_persona_duena_lead = public.get_current_user_persona_id()
    )
    OR EXISTS (
      SELECT 1
      FROM public.usuarios u
      JOIN public.proyectos_acceso pa
        ON lower(pa.usuario_id) = lower(u.email)
       AND pa.activo = true
      JOIN public.entidades_relacionadas er_owner
        ON er_owner.id = pa.id_entidad_relacionada_dueno
       AND er_owner.activo = true
       AND er_owner.id_tipo_entidad = 5
      JOIN public.entidades_relacionadas er_agent
        ON er_agent.id_tipo_entidad = 19
       AND er_agent.activo = true
       AND er_agent.id_persona = _owner_persona_id
      WHERE u.auth_user_id = auth.uid()
        AND er_agent.id_persona_duena_lead = er_owner.id_persona
    )
  );
$function$;

-- can_view_all_prospects
CREATE OR REPLACE FUNCTION public.can_view_all_prospects()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    (SELECT ver_todos_prospectos_compradores 
     FROM roles 
     WHERE id = public.get_current_user_role()),
    FALSE
  )
$function$;

-- check_email_blocked_role
CREATE OR REPLACE FUNCTION public.check_email_blocked_role(p_email text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM usuarios u
    JOIN roles r ON u.rol_id = r.id
    WHERE u.email = lower(trim(p_email))
      AND u.activo = true
      AND r.nombre IN ('Cliente', 'Directores')
  );
$function$;

-- check_sat_notification_conditions
CREATE OR REPLACE FUNCTION public.check_sat_notification_conditions(p_cuenta_cobranza_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_propiedad_id INTEGER;
  v_estatus INTEGER;
  v_tiene_factura BOOLEAN;
  v_tiene_constancia BOOLEAN;
  v_tiene_archivo_sat BOOLEAN;
  v_supabase_url TEXT;
  v_service_role_key TEXT;
  v_edge_function_url TEXT;
BEGIN
  -- Get the property and its status through the offer
  SELECT o.id_propiedad, p.id_estatus_disponibilidad
  INTO v_propiedad_id, v_estatus
  FROM cuentas_cobranza cc
  JOIN ofertas o ON cc.id_oferta = o.id
  JOIN propiedades p ON o.id_propiedad = p.id
  WHERE cc.id = p_cuenta_cobranza_id
    AND cc.activo = true;

  -- If property not found or not in "Pagada completamente" status (9), exit
  IF v_propiedad_id IS NULL OR v_estatus != 9 THEN
    RETURN FALSE;
  END IF;

  -- Check if there's an active verified invoice (type 21 or 22)
  SELECT EXISTS (
    SELECT 1 FROM documentos
    WHERE id_cuenta_cobranza = p_cuenta_cobranza_id
      AND id_tipo_documento IN (21, 22)
      AND activo = true
      AND id_estatus_verificacion = 2
      AND es_draft = false
  ) INTO v_tiene_factura;

  -- Check if there's an active verified constancia fiscal (type 6)
  -- FIX: Changed 'compradores_cuenta_cobranza' to 'compradores'
  SELECT EXISTS (
    SELECT 1 FROM documentos d
    JOIN compradores ccc ON d.id_persona = ccc.id_persona
    WHERE ccc.id_cuenta_cobranza = p_cuenta_cobranza_id
      AND ccc.activo = true
      AND d.id_tipo_documento = 6
      AND d.activo = true
      AND d.id_estatus_verificacion = 2
  ) INTO v_tiene_constancia;

  -- Check if SAT notification file already exists (type 44)
  SELECT EXISTS (
    SELECT 1 FROM documentos
    WHERE id_cuenta_cobranza = p_cuenta_cobranza_id
      AND id_tipo_documento = 44
      AND activo = true
  ) INTO v_tiene_archivo_sat;

  -- If all conditions met and no SAT file exists, call the Edge Function
  IF v_tiene_factura AND v_tiene_constancia AND NOT v_tiene_archivo_sat THEN
    -- Get Supabase URL from environment (available in database functions)
    v_supabase_url := current_setting('app.settings.supabase_url', true);
    v_service_role_key := current_setting('app.settings.service_role_key', true);
    
    -- Fallback to direct URL if settings not available
    IF v_supabase_url IS NULL OR v_supabase_url = '' THEN
      v_supabase_url := 'https://tzmhgfjmddkfyffkkmto.supabase.co';
    END IF;
    
    v_edge_function_url := v_supabase_url || '/functions/v1/trigger-sat-notification';
    
    -- Call the Edge Function using http extension
    PERFORM extensions.http_post(
      url := v_edge_function_url,
      body := json_build_object('id_cuenta_cobranza', p_cuenta_cobranza_id)::jsonb,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || COALESCE(v_service_role_key, current_setting('request.jwt', true))
      )
    );
    
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$function$;

-- crear_referencia_bancaria
CREATE OR REPLACE FUNCTION public.crear_referencia_bancaria(id_er_dueno integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    contador_final INT;
    temp_bank_ref TEXT;
    suma INT := 0;
    digito_verificador INT;
    multiplicadores INT[] := ARRAY[3,7,1,3,7,1,3,7,1,3,7,1,3,7,1,3,7];
    ultima_cuenta TEXT;
    cuenta_madre_stp_dueno TEXT;
    clabe_existe BOOLEAN;
    temp_ref_sin_digito TEXT;
BEGIN
    -- Obtener la última cuenta considerando propiedades Y productos
    WITH todas_clabes AS (
        -- CLABEs de propiedades (apartado temporal)
        SELECT 
            p.clabe_stp_tmp_apartado as clabe,
            er.cuenta_madre_stp
        FROM propiedades p
        JOIN entidades_relacionadas er ON p.id_entidad_relacionada_dueno = er.id
        WHERE er.id = id_er_dueno
          AND p.clabe_stp_tmp_apartado IS NOT NULL
          AND p.clabe_stp_tmp_apartado NOT LIKE '%_TMP'
        
        UNION ALL
        
        -- CLABEs de cuentas de cobranza de propiedades
        SELECT 
            cc.clabe_stp as clabe,
            er.cuenta_madre_stp
        FROM propiedades p
        JOIN entidades_relacionadas er ON p.id_entidad_relacionada_dueno = er.id
        JOIN ofertas o ON o.id_propiedad = p.id
        JOIN cuentas_cobranza cc ON cc.id_oferta = o.id
        WHERE er.id = id_er_dueno
          AND cc.clabe_stp IS NOT NULL
          AND cc.clabe_stp NOT LIKE '%_TMP'
        
        UNION ALL
        
        -- CLABEs de productos (apartado temporal en ofertas)
        SELECT 
            o.clabe_stp_tmp_producto as clabe,
            er.cuenta_madre_stp
        FROM ofertas o
        JOIN productos_servicios ps ON o.id_producto = ps.id
        JOIN entidades_relacionadas er ON ps.id_entidad_relacionada_dueno = er.id
        WHERE er.id = id_er_dueno
          AND o.clabe_stp_tmp_producto IS NOT NULL
          AND o.clabe_stp_tmp_producto NOT LIKE '%_TMP'
        
        UNION ALL
        
        -- CLABEs de cuentas de cobranza de productos
        SELECT 
            cc.clabe_stp as clabe,
            er.cuenta_madre_stp
        FROM cuentas_cobranza cc
        JOIN ofertas o ON cc.id_oferta = o.id
        JOIN productos_servicios ps ON o.id_producto = ps.id
        JOIN entidades_relacionadas er ON ps.id_entidad_relacionada_dueno = er.id
        WHERE er.id = id_er_dueno
          AND cc.clabe_stp IS NOT NULL
          AND cc.clabe_stp NOT LIKE '%_TMP'
          AND o.id_producto IS NOT NULL

        UNION ALL

        -- CLABEs de cuentas de cobranza de mantenimientos
        SELECT 
        A.clabe,
        A.cuenta_madre_stp
        FROM
        (  
        SELECT 
            cc.clabe_stp as clabe,
            (SELECT 
                er.cuenta_madre_stp
            FROM entidades_relacionadas er
            WHERE 
                er.id = id_er_dueno) as cuenta_madre_stp
        FROM cuentas_cobranza cc
        WHERE 
            cc.id_oferta is null
        and
            cc.id_cuenta_cobranza_padre is not null  
        ) A
        WHERE 
        LEFT(A.clabe, LENGTH(A.clabe) - 4) = A.cuenta_madre_stp

        UNION ALL

        SELECT 
            er.cuenta_stp_comisiones as clabe,
            (SELECT cuenta_madre_stp FROM entidades_relacionadas where id = id_er_dueno) as cuenta_madre_stp
        FROM 
            entidades_relacionadas er
        WHERE 
        er.id_proyecto = (SELECT id_proyecto FROM entidades_relacionadas where id = id_er_dueno)
    )
    SELECT
        MAX(
            SUBSTRING(
                LEFT(clabe, LENGTH(clabe) - 1)
                FROM '.{3}$'
            )
        )::INT AS ultima_cuenta_num,
        cuenta_madre_stp
    INTO ultima_cuenta, cuenta_madre_stp_dueno
    FROM todas_clabes
    GROUP BY cuenta_madre_stp;

    -- Si no hay resultados, obtener solo la cuenta madre STP
    IF cuenta_madre_stp_dueno IS NULL THEN
        SELECT cuenta_madre_stp INTO cuenta_madre_stp_dueno
        FROM entidades_relacionadas
        WHERE id = id_er_dueno;
        
        IF cuenta_madre_stp_dueno IS NULL THEN
            RAISE EXCEPTION 'La entidad relacionada % no tiene cuenta_madre_stp configurada', id_er_dueno;
        END IF;
    END IF;

    -- Si no hay resultados o es NULL, poner contador en 0
    IF ultima_cuenta IS NULL THEN
        contador_final := 0;
    ELSE
        contador_final := CAST(SUBSTRING(ultima_cuenta FROM '[0-9]+') AS INT);
    END IF;

    -- Incrementar contador
    contador_final := contador_final + 1;

    -- Si contador llega a 1000, buscar huecos desde 001
    IF contador_final >= 1000 THEN
        -- Empezar búsqueda de huecos desde 001
        contador_final := 1;
        
        WHILE contador_final < 1000 LOOP
            -- Construir la referencia temporal sin dígito verificador
            temp_ref_sin_digito := cuenta_madre_stp_dueno || LPAD(contador_final::TEXT, 3, '0');
            
            -- Verificar si existe en alguna de las tablas
            SELECT EXISTS(
                WITH todas_clabes_check AS (
                    -- CLABEs de propiedades (apartado temporal)
                    SELECT p.clabe_stp_tmp_apartado as clabe
                    FROM propiedades p
                    JOIN entidades_relacionadas er ON p.id_entidad_relacionada_dueno = er.id
                    WHERE er.id = id_er_dueno
                      AND p.clabe_stp_tmp_apartado IS NOT NULL
                      AND p.clabe_stp_tmp_apartado NOT LIKE '%_TMP'
                    
                    UNION ALL
                    
                    -- CLABEs de cuentas de cobranza de propiedades
                    SELECT cc.clabe_stp as clabe
                    FROM propiedades p
                    JOIN entidades_relacionadas er ON p.id_entidad_relacionada_dueno = er.id
                    JOIN ofertas o ON o.id_propiedad = p.id
                    JOIN cuentas_cobranza cc ON cc.id_oferta = o.id
                    WHERE er.id = id_er_dueno
                      AND cc.clabe_stp IS NOT NULL
                      AND cc.clabe_stp NOT LIKE '%_TMP'
                    
                    UNION ALL
                    
                    -- CLABEs de productos (apartado temporal en ofertas)
                    SELECT o.clabe_stp_tmp_producto as clabe
                    FROM ofertas o
                    JOIN productos_servicios ps ON o.id_producto = ps.id
                    JOIN entidades_relacionadas er ON ps.id_entidad_relacionada_dueno = er.id
                    WHERE er.id = id_er_dueno
                      AND o.clabe_stp_tmp_producto IS NOT NULL
                      AND o.clabe_stp_tmp_producto NOT LIKE '%_TMP'
                    
                    UNION ALL
                    
                    -- CLABEs de cuentas de cobranza de productos
                    SELECT cc.clabe_stp as clabe
                    FROM cuentas_cobranza cc
                    JOIN ofertas o ON cc.id_oferta = o.id
                    JOIN productos_servicios ps ON o.id_producto = ps.id
                    JOIN entidades_relacionadas er ON ps.id_entidad_relacionada_dueno = er.id
                    WHERE er.id = id_er_dueno
                      AND cc.clabe_stp IS NOT NULL
                      AND cc.clabe_stp NOT LIKE '%_TMP'
                      AND o.id_producto IS NOT NULL

                    UNION ALL

                    -- CLABEs de cuentas de cobranza de mantenimientos
                    SELECT A.clabe
                    FROM (  
                        SELECT 
                            cc.clabe_stp as clabe,
                            (SELECT er.cuenta_madre_stp FROM entidades_relacionadas er WHERE er.id = id_er_dueno) as cuenta_madre_stp
                        FROM cuentas_cobranza cc
                        WHERE cc.id_oferta is null AND cc.id_cuenta_cobranza_padre is not null  
                    ) A
                    WHERE LEFT(A.clabe, LENGTH(A.clabe) - 4) = A.cuenta_madre_stp

                    UNION ALL

                    SELECT er.cuenta_stp_comisiones as clabe
                    FROM entidades_relacionadas er
                    WHERE er.id_proyecto = (SELECT id_proyecto FROM entidades_relacionadas where id = id_er_dueno)
                )
                SELECT 1 FROM todas_clabes_check WHERE clabe LIKE temp_ref_sin_digito || '%'
            ) INTO clabe_existe;
            
            -- Si no existe, encontramos un hueco
            IF NOT clabe_existe THEN
                EXIT; -- Salir del bucle
            END IF;
            
            contador_final := contador_final + 1;
        END LOOP;
        
        -- Si llegamos a 1000 y no encontramos hueco, error
        IF contador_final >= 1000 THEN
            RAISE EXCEPTION 'SIN_HUECOS_DISPONIBLES: Todos los números del 001 al 999 están ocupados para la cuenta madre %', cuenta_madre_stp_dueno;
        END IF;
    END IF;

    -- Formatear con ceros a la izquierda
    temp_bank_ref := cuenta_madre_stp_dueno || LPAD(contador_final::TEXT, 3, '0');

    -- Calcular dígito verificador
    FOR i IN 1..17 LOOP
        suma := suma + ((CAST(SUBSTRING(temp_bank_ref, i, 1) AS INT) * multiplicadores[i]) % 10);
    END LOOP;

    digito_verificador := (10 - (suma % 10)) % 10;

    RETURN temp_bank_ref || digito_verificador::TEXT;
END;
$function$;

-- create_client_user_on_comprador_insert
CREATE OR REPLACE FUNCTION public.create_client_user_on_comprador_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_persona RECORD;
  v_existing_user_email TEXT;
  v_cliente_rol_id INTEGER;
  v_edge_function_url TEXT;
  v_service_role_key TEXT;
BEGIN
  -- Obtener datos de la persona
  SELECT id, nombre_legal, email INTO v_persona
  FROM personas
  WHERE id = NEW.id_persona;
  
  -- Si no tiene email válido, no podemos crear usuario
  IF v_persona.email IS NULL OR v_persona.email = '' THEN
    RETURN NEW;
  END IF;
  
  -- Obtener el ID del rol Cliente
  SELECT id INTO v_cliente_rol_id
  FROM roles
  WHERE nombre = 'Cliente' AND activo = true
  LIMIT 1;
  
  -- Si no existe el rol Cliente, salir
  IF v_cliente_rol_id IS NULL THEN
    RAISE WARNING 'Rol Cliente no encontrado';
    RETURN NEW;
  END IF;
  
  -- Verificar si ya existe usuario con ese email (la tabla usuarios usa email como identificador, no tiene columna id)
  SELECT email INTO v_existing_user_email
  FROM usuarios
  WHERE email = v_persona.email;
  
  -- Si no existe, crear el registro en usuarios
  IF v_existing_user_email IS NULL THEN
    INSERT INTO usuarios (email, nombre, rol_id, activo, debe_cambiar_password, id_persona)
    VALUES (v_persona.email, v_persona.nombre_legal, v_cliente_rol_id, true, true, v_persona.id);
  END IF;
  
  -- URL de la edge function
  v_edge_function_url := 'https://tzmhgfjmddkfyffkkmto.supabase.co/functions/v1/create-client-user';
  
  -- Obtener el service role key desde Vault
  BEGIN
    SELECT decrypted_secret INTO v_service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'SUPABASE_SERVICE_ROLE_KEY'
    LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    v_service_role_key := NULL;
    RAISE WARNING 'No se pudo obtener SUPABASE_SERVICE_ROLE_KEY desde Vault: %', SQLERRM;
  END;
  
  -- Si tenemos el service role key, llamar a la edge function via pg_net
  IF v_service_role_key IS NOT NULL AND v_service_role_key != '' THEN
    PERFORM net.http_post(
      url := v_edge_function_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_service_role_key
      ),
      body := jsonb_build_object(
        'email', v_persona.email,
        'nombre', v_persona.nombre_legal,
        'id_persona', v_persona.id
      )
    );
  ELSE
    RAISE WARNING 'SUPABASE_SERVICE_ROLE_KEY no configurado en Vault - no se puede crear usuario en auth.users';
  END IF;
  
  RETURN NEW;
END;
$function$;

-- deactivate_user_on_agent_delete
CREATE OR REPLACE FUNCTION public.deactivate_user_on_agent_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    -- Si el agente se está desactivando (soft delete)
    IF OLD.activo = true AND NEW.activo = false THEN
        -- Buscar el usuario asociado a esta persona y desactivarlo
        UPDATE usuarios
        SET activo = false, fecha_actualizacion = now()
        WHERE id_persona = NEW.id
        AND activo = true;
    END IF;
    
    RETURN NEW;
END;
$function$;

-- enforce_single_ubicacion_oferta
CREATE OR REPLACE FUNCTION public.enforce_single_ubicacion_oferta()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  -- If the new/updated record has ver_como_ubicacion_en_oferta = true
  IF NEW.ver_como_ubicacion_en_oferta = true THEN
    -- Set all other multimedia for this model to false
    UPDATE public.multimedias_modelo 
    SET ver_como_ubicacion_en_oferta = false 
    WHERE id_modelo = NEW.id_modelo 
    AND id != NEW.id;
  END IF;
  
  RETURN NEW;
END;
$function$;

-- etl_bodegas
CREATE OR REPLACE FUNCTION public.etl_bodegas()
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$DECLARE
    rec RECORD;
    v_id_propiedad BIGINT;
    v_id_producto BIGINT;
    v_m2 NUMERIC;
    v_valido BOOLEAN := TRUE;
BEGIN
    FOR rec IN 
        SELECT * FROM bodegas_stagin
    LOOP
        -- Buscar id_propiedad
        SELECT p.id
        INTO v_id_propiedad
        FROM propiedades p
        JOIN entidades_relacionadas er ON p.id_entidad_relacionada_dueno = er.id
        JOIN proyectos proy ON er.id_proyecto = proy.id
        WHERE lower(proy.nombre) = lower(rec.nombre_proyecto)
          AND lower(p.numero_propiedad) = lower(rec.numero_departamento)
          AND p.activo = true
        LIMIT 1;

        -- Buscar id_producto
        SELECT ps.id
        INTO v_id_producto
        FROM productos_servicios ps
        WHERE lower(ps.nombre) = lower(rec.nombre_producto)
        AND ps.activo = true
        LIMIT 1;

        -- Validar m2_bodega como decimal
        IF rec.m2_bodega IS NULL OR rec.m2_bodega = '' OR rec.m2_bodega !~ '^[0-9]+(\.[0-9]+)?$' THEN
            v_m2 := NULL;
        ELSE
            v_m2 := rec.m2_bodega::NUMERIC;
        END IF;

        -- Actualizar la tabla staging con los resultados
        UPDATE bodegas_stagin
        SET id_propiedad = v_id_propiedad,
            id_producto  = v_id_producto,
            m2_bodega    = CASE WHEN v_m2 IS NOT NULL THEN v_m2::TEXT ELSE NULL END
        WHERE id = rec.id;

        -- Validar si hay algún NULL crítico
        IF v_id_propiedad IS NULL 
           OR v_id_producto IS NULL 
           OR v_m2 IS NULL
           OR rec.nombre_bodega IS NULL
           OR rec.ubicacion_bodega IS NULL THEN
            v_valido := FALSE;
        END IF;
    END LOOP;

    RETURN v_valido;
END;$function$;

-- etl_estacionamientos
CREATE OR REPLACE FUNCTION public.etl_estacionamientos()
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$DECLARE
    rec RECORD;
    v_id_propiedad BIGINT;
    v_id_producto BIGINT;
    v_num_est INT;
    v_tipos_array TEXT[];
    v_m2_array TEXT[];
    v_nombres_array TEXT[];
    v_ubicaciones_array TEXT[];
    v_ids_array TEXT[];
    v_tipo_id INT;
    v_result BOOLEAN := TRUE;
BEGIN
    FOR rec IN 
        SELECT *
        FROM estacionamientos_stagin
    LOOP
        -- Reiniciamos las variables por cada fila para asegurar que estén limpias
        v_id_propiedad := NULL;
        v_id_producto := NULL;
        v_num_est := NULL;
        v_ids_array := ARRAY[]::TEXT[];
        
        -- 1. Validar numero_estacionamientos (limpiando espacios)
        IF trim(rec.numero_estacionamientos) IS NOT NULL AND trim(rec.numero_estacionamientos) ~ '^[0-9]+$' THEN
            v_num_est := trim(rec.numero_estacionamientos)::INT;
        END IF;

        -- 2. Buscar id_propiedad (limpiando espacios)
        SELECT p.id INTO v_id_propiedad
        FROM propiedades p
        JOIN entidades_relacionadas er ON p.id_entidad_relacionada_dueno = er.id
        JOIN proyectos proy ON er.id_proyecto = proy.id
        WHERE lower(trim(proy.nombre)) = lower(trim(rec.nombre_proyecto))
          AND lower(trim(p.numero_propiedad)) = lower(trim(rec.numero_propiedad))
          AND p.activo = true
        LIMIT 1;

        -- 3. Buscar id_producto (limpiando espacios)
        SELECT ps.id INTO v_id_producto
        FROM productos_servicios ps
        WHERE lower(trim(ps.nombre)) = lower(trim(rec.nombre_producto))
          AND ps.activo = true
        LIMIT 1;

        -- 4. Validar Arrays (Solo si el número de estacionamientos es un número válido)
        IF v_num_est IS NOT NULL THEN
            v_tipos_array := string_to_array(COALESCE(trim(rec.tipos_estacionamientos),''), ',');
            v_m2_array := string_to_array(COALESCE(trim(rec.m2_estacionamientos),''), ',');
            v_nombres_array := string_to_array(COALESCE(trim(rec.nombres_estacionamientos),''), ',');
            v_ubicaciones_array := string_to_array(COALESCE(trim(rec.ubicaciones_estacionamientos),''), ',');

            -- A) Validar tipos_estacionamientos
            IF array_length(v_tipos_array, 1) <> v_num_est THEN
                v_ids_array := NULL; -- Falla por cantidad
            ELSE
                FOR i IN 1..v_num_est LOOP
                    SELECT id INTO v_tipo_id
                    FROM tipos_estacionamiento
                    WHERE lower(trim(nombre)) = lower(trim(v_tipos_array[i]))
                      AND activo = true
                    LIMIT 1;

                    IF v_tipo_id IS NULL THEN
                        v_ids_array := NULL; -- Falla porque no existe el tipo
                        EXIT;
                    ELSE
                        v_ids_array := v_ids_array || v_tipo_id::TEXT;
                    END IF;
                END LOOP;
            END IF;

            -- B) Validar m2_estacionamientos
            IF array_length(v_m2_array, 1) <> v_num_est THEN
                v_m2_array := NULL; -- Falla por cantidad
            ELSE
                FOR i IN 1..v_num_est LOOP
                    IF v_m2_array[i] IS NULL OR trim(v_m2_array[i]) = '' OR trim(v_m2_array[i]) !~ '^[0-9]+(\.[0-9]+)?$' THEN
                        v_m2_array := NULL; -- Falla por regex (no es número)
                        EXIT;
                    ELSE
                        v_m2_array[i] := trim(v_m2_array[i]); -- Limpiamos el espacio
                    END IF;
                END LOOP;
            END IF;

            -- C) Validar nombres_estacionamientos
            IF array_length(v_nombres_array, 1) <> v_num_est THEN
                v_nombres_array := NULL;
            ELSE
                FOR i IN 1..v_num_est LOOP
                    v_nombres_array[i] := trim(v_nombres_array[i]);
                END LOOP;
            END IF;

            -- D) Validar ubicaciones_estacionamientos
            IF array_length(v_ubicaciones_array, 1) <> v_num_est THEN
                v_ubicaciones_array := NULL;
            ELSE
                FOR i IN 1..v_num_est LOOP
                    v_ubicaciones_array[i] := trim(v_ubicaciones_array[i]);
                END LOOP;
            END IF;

        ELSE
            -- Si el número de estacionamientos es inválido, anulamos los arrays para evitar conflictos
            v_ids_array := NULL;
            v_m2_array := NULL;
            v_nombres_array := NULL;
            v_ubicaciones_array := NULL;
        END IF;

        -- Actualizar la tabla staging
        -- NOTA: Ahora SOLO el campo que falló se convierte en NULL
        UPDATE estacionamientos_stagin
        SET id_propiedad = v_id_propiedad,
            id_producto  = v_id_producto,
            numero_estacionamientos = v_num_est::TEXT,
            m2_estacionamientos = CASE WHEN v_m2_array IS NOT NULL THEN array_to_string(v_m2_array, ',') ELSE NULL END,
            nombres_estacionamientos = CASE WHEN v_nombres_array IS NOT NULL THEN array_to_string(v_nombres_array, ',') ELSE NULL END,
            ubicaciones_estacionamientos = CASE WHEN v_ubicaciones_array IS NOT NULL THEN array_to_string(v_ubicaciones_array, ',') ELSE NULL END,
            tipos_estacionamientos = CASE WHEN v_ids_array IS NOT NULL THEN array_to_string(v_ids_array, ',') ELSE NULL END
        WHERE id = rec.id;

        -- Evaluamos el resultado final: Si CUALQUIER campo vital terminó en NULL, hubo un error
        IF v_id_propiedad IS NULL OR v_id_producto IS NULL OR v_num_est IS NULL 
           OR v_m2_array IS NULL OR v_nombres_array IS NULL OR v_ubicaciones_array IS NULL OR v_ids_array IS NULL THEN
            v_result := FALSE;
        END IF;
        
    END LOOP;

    RETURN v_result;
END;$function$;

-- etl_propiedades
CREATE OR REPLACE FUNCTION public.etl_propiedades()
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$BEGIN
    SET statement_timeout TO '300s';

    UPDATE propiedades_stagin ps
    SET id_vista = (
        SELECT v.id::text FROM vistas v
        JOIN proyectos p ON v.id_proyecto = p.id
        WHERE v.activo = true AND p.activo = true
          AND upper(trim(p.nombre)) = upper(trim(ps.id_proyecto))
          AND upper(trim(v.nombre)) = upper(trim(ps.id_vista))
        LIMIT 1
    );

    UPDATE propiedades_stagin ps
    SET id_tipo_transaccion = (
        SELECT tt.id::text FROM tipos_transaccion tt
        WHERE tt.activo = true
          AND upper(trim(ps.id_tipo_transaccion)) = upper(trim(tt.nombre))
        LIMIT 1
    );

    UPDATE propiedades_stagin ps
    SET id_tipo_propiedad = (
        SELECT tp.id::text FROM tipos_propiedad tp
        WHERE tp.activo = true
          AND upper(trim(ps.id_tipo_propiedad)) = upper(trim(tp.nombre))
        LIMIT 1
    );

    UPDATE propiedades_stagin ps
    SET id_estatus_disponibilidad = (
        SELECT ed.id::text FROM estatus_disponibilidad ed
        WHERE ed.activo = true
          AND upper(trim(ps.id_estatus_disponibilidad)) = upper(trim(ed.nombre))
        LIMIT 1
    );

    UPDATE propiedades_stagin ps
    SET id_proyecto = (
        SELECT pr.id::text FROM proyectos pr
        WHERE pr.activo = true
          AND upper(trim(ps.id_proyecto)) = upper(trim(pr.nombre))
        LIMIT 1
    );

    UPDATE propiedades_stagin ps
    SET id_edificio = (
        SELECT e.id::text FROM edificios e
        JOIN proyectos p ON e.id_proyecto = p.id
        WHERE e.activo = true AND p.activo = true
          AND p.id = ps.id_proyecto::int
          AND upper(trim(e.nombre)) = upper(trim(ps.id_edificio))
        LIMIT 1
    );

    UPDATE propiedades_stagin ps
    SET id_modelo = (
        SELECT m.id::text FROM modelos m
        JOIN proyectos p ON m.id_proyecto = p.id
        WHERE m.activo = true AND p.activo = true
          AND p.id = ps.id_proyecto::int
          AND upper(trim(m.nombre)) = upper(trim(ps.id_modelo))
        LIMIT 1
    );

    UPDATE propiedades_stagin ps
    SET id_edificio_modelo = (
        SELECT em.id FROM edificios_modelos em
        WHERE em.activo = true
          AND em.id_edificio::text = ps.id_edificio
          AND em.id_modelo::text   = ps.id_modelo
        LIMIT 1
    );

    UPDATE propiedades_stagin ps
    SET nombre_propietario = (
        SELECT per.id::text FROM personas per
        WHERE per.activo = true
          AND upper(trim(ps.nombre_propietario)) = upper(trim(per.nombre_legal))
        LIMIT 1
    );

    UPDATE propiedades_stagin ps
    SET id_propietario = (
        SELECT er.id FROM entidades_relacionadas er
        WHERE er.activo = true
          AND er.id_proyecto::text = ps.id_proyecto
          AND er.id_persona::text  = ps.nombre_propietario
        LIMIT 1
    );

    /* 11. id_actual + clabe_stp — ENDURECIDO: _TMP NO se considera CLABE válida */
    UPDATE propiedades_stagin ps
    SET id_actual = p.id,
        clabe_stp = COALESCE(
            CASE 
              WHEN p.clabe_stp_tmp_apartado LIKE '%\_TMP' ESCAPE '\' THEN NULL
              ELSE p.clabe_stp_tmp_apartado
            END,
            cc.clabe_stp
        )
    FROM propiedades p
    JOIN entidades_relacionadas er 
         ON p.id_entidad_relacionada_dueno = er.id
    LEFT JOIN ofertas o ON o.id_propiedad = p.id
    LEFT JOIN cuentas_cobranza cc ON cc.id_oferta = o.id
    WHERE p.activo = true
      AND (
        (p.clabe_stp_tmp_apartado IS NOT NULL 
         AND p.clabe_stp_tmp_apartado NOT LIKE '%\_TMP' ESCAPE '\')
        OR cc.clabe_stp IS NOT NULL
      )
      AND upper(trim(ps.numero_propiedad)) = upper(trim(p.numero_propiedad))
      AND ps.id_proyecto::int = er.id_proyecto
      AND er.id_tipo_entidad IN (4, 15);

    UPDATE propiedades_stagin
    SET m2_interiores = CASE WHEN m2_interiores ~ '^[0-9]+(\.[0-9]+)?$' THEN m2_interiores ELSE NULL END;
    UPDATE propiedades_stagin
    SET m2_exteriores = CASE WHEN m2_exteriores ~ '^[0-9]+(\.[0-9]+)?$' THEN m2_exteriores ELSE NULL END;
    UPDATE propiedades_stagin
    SET m2_loft = CASE WHEN m2_loft ~ '^[0-9]+(\.[0-9]+)?$' THEN m2_loft ELSE NULL END;
    UPDATE propiedades_stagin
    SET precio_lista = CASE WHEN precio_lista ~ '^[0-9]+(\.[0-9]+)?$' THEN precio_lista ELSE NULL END;
    UPDATE propiedades_stagin
    SET monto_apartado = CASE WHEN monto_apartado ~ '^[0-9]+(\.[0-9]+)?$' THEN monto_apartado ELSE NULL END;

    IF EXISTS (
        SELECT 1 FROM propiedades_stagin
        WHERE id_vista IS NULL
           OR id_tipo_transaccion IS NULL
           OR id_edificio IS NULL
           OR id_tipo_propiedad IS NULL
           OR id_estatus_disponibilidad IS NULL
           OR numero_propiedad IS NULL
           OR numero_piso IS NULL
           OR m2_interiores IS NULL
           OR m2_exteriores IS NULL
           OR m2_loft IS NULL
           OR precio_lista IS NULL
           OR monto_apartado IS NULL
           OR id_modelo IS NULL
           OR id_edificio_modelo IS NULL
           OR id_propietario IS NULL
           OR id_proyecto IS NULL
    ) THEN
        RETURN false;
    ELSE
        RETURN true;
    END IF;
END;$function$;

-- execute_safe_query
CREATE OR REPLACE FUNCTION public.execute_safe_query(query_text text, max_rows integer DEFAULT 1000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    result JSONB;
    query_upper TEXT;
    query_clean TEXT;
    query_without_semicolon TEXT;
BEGIN
    -- Limpiar espacios en blanco
    query_clean := TRIM(BOTH FROM query_text);
    
    -- Convertir a mayúsculas para validación
    query_upper := UPPER(query_clean);
    
    -- Validar que CONTENGA SELECT o WITH (para permitir comentarios al inicio)
    IF NOT (query_upper ~ '\mSELECT\s' OR query_upper ~ '\mWITH\s') THEN
        RAISE EXCEPTION 'Solo se permiten consultas SELECT o WITH (CTEs). Query recibido: "%"', LEFT(query_clean, 150);
    END IF;
    
    -- Validar palabras clave peligrosas (excluyendo SELECT/WITH del match)
    IF query_upper ~ '\m(DROP|DELETE|UPDATE|INSERT|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|EXEC|EXECUTE)\M' THEN
        RAISE EXCEPTION 'Consulta contiene palabras clave no permitidas';
    END IF;
    
    -- Permitir punto y coma al final pero no múltiples consultas
    query_without_semicolon := REGEXP_REPLACE(query_clean, ';\s*$', '');
    IF query_without_semicolon LIKE '%;%' THEN
        RAISE EXCEPTION 'No se permiten múltiples consultas';
    END IF;
    
    -- Remover punto y coma final si existe
    query_clean := query_without_semicolon;
    
    -- Ejecutar query usando el query original con LIMIT
    IF NOT query_upper LIKE '%LIMIT%' THEN
        query_clean := query_clean || ' LIMIT ' || max_rows;
    END IF;
    
    -- Ejecutar query
    EXECUTE format('SELECT jsonb_agg(row_to_json(t)) FROM (%s) t', query_clean) INTO result;
    
    -- Si result es null, retornar array vacío
    IF result IS NULL THEN
        result := '[]'::JSONB;
    END IF;
    
    RETURN result;
    
EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error ejecutando consulta: %', SQLERRM;
END;
$function$;

-- fn_insert_datos_cep
CREATE OR REPLACE FUNCTION public.fn_insert_datos_cep()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id_tipo_cep INT;
    cadena_original TEXT;
    fecha_str TEXT;
BEGIN
    -- Construir la cadena original
    fecha_str := TO_CHAR(NEW.fecha_operacion::date, 'YYYY-MM-DD');
    cadena_original := fecha_str || ',' || NEW.claverastreo || ',' || NEW.institucion_ordenante
                        || ',' || NEW.institucion_beneficiaria || ',' || NEW.cuenta_beneficiario
                        || ',' || NEW.monto;

    -- Determinar id_tipo_cep según clabe STP (cuenta_beneficiario)
    SELECT pago_de
    INTO v_id_tipo_cep
    FROM (
        SELECT 1 AS pago_de
        FROM propiedades p
        WHERE p.clabe_stp_tmp_apartado = NEW.cuenta_beneficiario
          AND p.activo = TRUE

        UNION ALL

        SELECT CASE
                 WHEN o.id_propiedad IS NOT NULL THEN 1
                 ELSE 2
               END AS pago_de
        FROM cuentas_cobranza cc
        JOIN ofertas o ON cc.id_oferta = o.id
        WHERE cc.clabe_stp = NEW.cuenta_beneficiario
          AND cc.activo = TRUE

        UNION ALL

        SELECT 3 AS pago_de
        FROM cuentas_cobranza cc
        WHERE cc.clabe_stp = NEW.cuenta_beneficiario
          AND cc.id_cuenta_cobranza_padre IS NOT NULL
          AND cc.activo = TRUE
    ) sub
    LIMIT 1;

    -- Insertar en tabla_datos_cep CON MANEJO DE CONFLICTOS
    INSERT INTO tabla_datos_cep (
        claverastreo,
        fecha_operacion,
        cadena,
        id_tipo_cep,
        fecha_creacion
    )
    VALUES (
        NEW.claverastreo,
        NEW.fecha_operacion::date,
        CASE
            WHEN SPLIT_PART(cadena_original, ',', 1) = TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD') THEN
                cadena_original
            ELSE
                TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD') || ',' || SUBSTRING(cadena_original FROM POSITION(',' IN cadena_original)+1)
        END,
        COALESCE(v_id_tipo_cep, 4),
        CURRENT_DATE
    )
    ON CONFLICT (claverastreo) DO UPDATE SET
        fecha_operacion = EXCLUDED.fecha_operacion,
        cadena = EXCLUDED.cadena,
        id_tipo_cep = EXCLUDED.id_tipo_cep,
        fecha_creacion = EXCLUDED.fecha_creacion;

    RETURN NEW;
END;
$function$;

-- get_accessible_report_ids
CREATE OR REPLACE FUNCTION public.get_accessible_report_ids()
 RETURNS TABLE(reporte_id integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    _rol_id INTEGER;
    _rol_nombre TEXT;
BEGIN
    -- Get current user's role using auth_user_id
    SELECT u.rol_id, r.nombre INTO _rol_id, _rol_nombre
    FROM usuarios u
    JOIN roles r ON r.id = u.rol_id
    WHERE u.auth_user_id = auth.uid()
    AND u.activo = true;
    
    -- Fallback to email if auth_user_id not found
    IF _rol_id IS NULL THEN
        SELECT u.rol_id, r.nombre INTO _rol_id, _rol_nombre
        FROM usuarios u
        JOIN roles r ON r.id = u.rol_id
        WHERE u.email = auth.email()
        AND u.activo = true;
    END IF;
    
    -- Super Admin has access to all active reports
    IF _rol_nombre = 'Super Administrador' THEN
        RETURN QUERY SELECT rep.id FROM reportes rep WHERE rep.activo = true;
        RETURN;
    END IF;
    
    -- Return report IDs the role has access to
    RETURN QUERY
    SELECT rr.reporte_id
    FROM roles_reportes rr
    WHERE rr.rol_id = _rol_id
    AND rr.activo = true;
END;
$function$;

-- get_bandeja_operativa
CREATE OR REPLACE FUNCTION public.get_bandeja_operativa(p_proyecto_id integer DEFAULT NULL::integer, p_search text DEFAULT NULL::text, p_solo_vencidas boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  v_hoy date := current_date;
BEGIN
  SELECT COALESCE(jsonb_agg(row_to_json(r) ORDER BY 
    CASE r.prioridad
      WHEN 'gray' THEN 0
      WHEN 'blue' THEN 1
      WHEN 'purple' THEN 2
      WHEN 'red_dark' THEN 3
      WHEN 'red' THEN 4
      WHEN 'yellow' THEN 5
      ELSE 6
    END,
    r.dias_sin_pagar DESC NULLS LAST,
    r.monto_vencido DESC
  ), '[]'::jsonb)
  INTO result
  FROM (
    SELECT
      cc.id AS cuenta_id,
      cc.clabe_stp,
      cc.precio_final,
      cc.fecha_compra,
      p.nombre_legal AS cliente_nombre,
      p.email AS cliente_email,
      p.telefono AS cliente_telefono,
      pr.nombre AS proyecto,
      pr.id AS proyecto_id,
      ed.nombre AS edificio,
      prop.numero_propiedad,
      mod.nombre AS modelo,
      -- Mostrar nombre del producto si la oferta tiene id_producto (sin importar si también hay propiedad)
      CASE WHEN o.id_producto IS NOT NULL THEN ps.nombre ELSE NULL END AS producto_nombre,
      -- Tipo: si la oferta tiene id_producto es Producto (CCP-), sino Propiedad (CC-)
      CASE
        WHEN o.id_producto IS NOT NULL THEN 'Producto'
        WHEN cc.id_propiedad IS NOT NULL THEN 'Propiedad'
        ELSE 'Propiedad'
      END AS tipo_cuenta,
      COALESCE(vc.parcialidades_vencidas, 0) AS parcialidades_vencidas,
      COALESCE(vc.monto_vencido, 0) AS monto_vencido,
      COALESCE(vc.saldo_pendiente, 0) AS saldo_pendiente,
      vc.proximo_vencimiento,
      vc.ultima_fecha_pago,
      CASE
        WHEN vc.ultima_fecha_pago IS NOT NULL THEN GREATEST(0, (v_hoy - vc.ultima_fecha_pago)::int)
        WHEN cc.fecha_compra IS NOT NULL THEN GREATEST(0, (v_hoy - cc.fecha_compra)::int)
        ELSE 0
      END AS dias_sin_pagar,
      CASE
        WHEN COALESCE(vc.parcialidades_vencidas, 0) = 0 THEN 'green'
        ELSE
          CASE
            WHEN (CASE
                    WHEN vc.ultima_fecha_pago IS NOT NULL THEN (v_hoy - vc.ultima_fecha_pago)::int
                    WHEN cc.fecha_compra IS NOT NULL THEN (v_hoy - cc.fecha_compra)::int
                    ELSE 0
                  END) >= 90 THEN 'purple'
            WHEN (CASE
                    WHEN vc.ultima_fecha_pago IS NOT NULL THEN (v_hoy - vc.ultima_fecha_pago)::int
                    WHEN cc.fecha_compra IS NOT NULL THEN (v_hoy - cc.fecha_compra)::int
                    ELSE 0
                  END) >= 60 THEN 'red_dark'
            WHEN (CASE
                    WHEN vc.ultima_fecha_pago IS NOT NULL THEN (v_hoy - vc.ultima_fecha_pago)::int
                    WHEN cc.fecha_compra IS NOT NULL THEN (v_hoy - cc.fecha_compra)::int
                    ELSE 0
                  END) >= 30 THEN 'red'
            ELSE 'yellow'
          END
      END AS prioridad
    FROM cuentas_cobranza cc
    LEFT JOIN ofertas o ON o.id = cc.id_oferta
    LEFT JOIN personas p ON p.id = o.id_persona_lead
    LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
    LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
    LEFT JOIN edificios ed ON ed.id = em.id_edificio
    LEFT JOIN modelos mod ON mod.id = em.id_modelo
    LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
    LEFT JOIN proyectos pr ON pr.id = COALESCE(ed.id_proyecto, ps.id_proyecto)
    LEFT JOIN LATERAL (
      SELECT
        COUNT(CASE WHEN ap.pago_completado = false AND ap.fecha_pago < v_hoy THEN 1 END) AS parcialidades_vencidas,
        COALESCE(SUM(CASE WHEN ap.pago_completado = false AND ap.fecha_pago < v_hoy THEN GREATEST(ap.monto - COALESCE(apl.aplicado, 0), 0) END), 0) AS monto_vencido,
        COALESCE(SUM(CASE WHEN ap.pago_completado = false THEN GREATEST(ap.monto - COALESCE(apl.aplicado, 0), 0) END), 0) AS saldo_pendiente,
        MIN(CASE WHEN ap.pago_completado = false AND ap.fecha_pago >= v_hoy THEN ap.fecha_pago END) AS proximo_vencimiento,
        (
          SELECT MAX(pg.fecha_pago)
          FROM pagos pg
          WHERE pg.id_cuenta_cobranza = cc.id AND pg.activo = true
        ) AS ultima_fecha_pago
      FROM acuerdos_pago ap
      LEFT JOIN LATERAL (
        SELECT COALESCE(SUM(a.monto), 0) AS aplicado
        FROM aplicaciones_pago a
        WHERE a.id_acuerdo_pago = ap.id
          AND a.activo = true
          AND a.es_multa = false
      ) apl ON true
      WHERE ap.id_cuenta_cobranza = cc.id AND ap.activo = true
    ) vc ON true
    WHERE cc.activo = true
      AND (p_proyecto_id IS NULL OR pr.id = p_proyecto_id)
      AND (prop.id_estatus_disponibilidad IS NULL OR prop.id_estatus_disponibilidad NOT IN (8, 9))
      AND (
        p_search IS NULL OR p_search = '' OR
        cc.clabe_stp ILIKE '%' || p_search || '%' OR
        p.nombre_legal ILIKE '%' || p_search || '%' OR
        p.email ILIKE '%' || p_search || '%' OR
        prop.numero_propiedad ILIKE '%' || p_search || '%' OR
        ps.nombre ILIKE '%' || p_search || '%' OR
        ed.nombre ILIKE '%' || p_search || '%' OR
        pr.nombre ILIKE '%' || p_search || '%'
      )
      AND (
        p_solo_vencidas = false OR
        COALESCE(vc.parcialidades_vencidas, 0) > 0
      )
  ) r;

  RETURN result;
END;
$function$;

-- get_cuentas_cobranza_export
CREATE OR REPLACE FUNCTION public.get_cuentas_cobranza_export(p_id_cuenta text DEFAULT NULL::text, p_proyecto text DEFAULT NULL::text, p_clabe text DEFAULT NULL::text, p_no_propiedad text DEFAULT NULL::text, p_modelo text DEFAULT NULL::text, p_compradores text DEFAULT NULL::text, p_producto text DEFAULT NULL::text, p_estatus_ids integer[] DEFAULT NULL::integer[], p_tipos text[] DEFAULT NULL::text[], p_activo boolean DEFAULT true, p_proyecto_ids integer[] DEFAULT NULL::integer[], p_dueno_entity_ids integer[] DEFAULT NULL::integer[], p_limit integer DEFAULT 50000, p_offset integer DEFAULT 0)
 RETURNS TABLE(id integer, clabe_stp text, fecha_compra text, precio_final numeric, tipo text, proyecto text, modelo text, edificio text, numero_propiedad text, producto text, comprador text, estatus_disponibilidad_nombre text, vendedor text, dueno text, metraje numeric, precio_lista numeric, pagado numeric, restante numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET statement_timeout TO '120s'
AS $function$
BEGIN
  RETURN QUERY
  WITH pagos_sum AS (
    SELECT p.id_cuenta_cobranza, SUM(p.monto) as total_pagado
    FROM pagos p
    WHERE p.activo = true
    GROUP BY p.id_cuenta_cobranza
  ),
  primer_comprador AS (
    SELECT DISTINCT ON (comp.id_cuenta_cobranza)
      comp.id_cuenta_cobranza,
      pers.nombre_legal
    FROM compradores comp
    JOIN personas pers ON comp.id_persona = pers.id
    WHERE comp.activo = true
    ORDER BY comp.id_cuenta_cobranza, pers.id
  )
  SELECT
    cc.id::integer AS id,
    cc.clabe_stp,
    cc.fecha_compra::text,
    cc.precio_final,
    CASE
      WHEN o.id_producto IS NOT NULL THEN 'Producto'
      WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
      ELSE 'Servicio'
    END AS tipo,
    COALESCE(pr.nombre, pr2.nombre) AS proyecto,
    m.nombre AS modelo,
    edif.nombre AS edificio,
    prop.numero_propiedad,
    ps.nombre AS producto,
    pc.nombre_legal AS comprador,
    ed.nombre AS estatus_disponibilidad_nombre,
    vendedor_pers.nombre_legal AS vendedor,
    dueno_pers.nombre_legal AS dueno,
    COALESCE(prop.m2_interiores, 0) + COALESCE(prop.m2_exteriores, 0) AS metraje,
    prop.precio_lista,
    COALESCE(psum.total_pagado, 0) AS pagado,
    cc.precio_final - COALESCE(psum.total_pagado, 0) AS restante
  FROM cuentas_cobranza cc
  JOIN ofertas o ON cc.id_oferta = o.id
  LEFT JOIN propiedades prop ON o.id_propiedad = prop.id
  LEFT JOIN edificios_modelos em ON prop.id_edificio_modelo = em.id
  LEFT JOIN edificios edif ON em.id_edificio = edif.id
  LEFT JOIN proyectos pr ON edif.id_proyecto = pr.id
  LEFT JOIN modelos m ON em.id_modelo = m.id
  LEFT JOIN productos_servicios ps ON o.id_producto = ps.id
  LEFT JOIN proyectos pr2 ON ps.id_proyecto = pr2.id
  LEFT JOIN estatus_disponibilidad ed ON prop.id_estatus_disponibilidad = ed.id
  LEFT JOIN personas vendedor_pers ON vendedor_pers.id = o.id_persona_lead
  LEFT JOIN entidades_relacionadas er ON er.id = prop.id_entidad_relacionada_dueno AND er.activo = true
  LEFT JOIN personas dueno_pers ON dueno_pers.id = er.id_persona
  LEFT JOIN pagos_sum psum ON psum.id_cuenta_cobranza = cc.id
  LEFT JOIN primer_comprador pc ON pc.id_cuenta_cobranza = cc.id
  WHERE cc.activo = p_activo
    AND cc.id_cuenta_cobranza_padre IS NULL
    AND (p_id_cuenta IS NULL OR cc.id::text ILIKE '%' || p_id_cuenta || '%')
    AND (p_clabe IS NULL OR cc.clabe_stp ILIKE '%' || p_clabe || '%')
    AND (p_proyecto IS NULL OR COALESCE(pr.nombre, pr2.nombre) ILIKE '%' || p_proyecto || '%')
    AND (p_no_propiedad IS NULL OR prop.numero_propiedad ILIKE '%' || p_no_propiedad || '%')
    AND (p_modelo IS NULL OR m.nombre ILIKE '%' || p_modelo || '%')
    AND (p_compradores IS NULL OR pc.nombre_legal ILIKE '%' || p_compradores || '%')
    AND (p_producto IS NULL OR ps.nombre ILIKE '%' || p_producto || '%')
    AND (p_estatus_ids IS NULL OR prop.id_estatus_disponibilidad = ANY(p_estatus_ids))
    AND (p_tipos IS NULL OR (
      CASE
        WHEN o.id_producto IS NOT NULL THEN 'Producto'
        WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
        ELSE 'Servicio'
      END
    ) = ANY(p_tipos))
    AND (p_proyecto_ids IS NULL OR COALESCE(pr.id, pr2.id) = ANY(p_proyecto_ids))
    AND (p_dueno_entity_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_dueno_entity_ids))
  ORDER BY cc.id DESC
  LIMIT p_limit
  OFFSET p_offset;
END;
$function$;

-- get_cuentas_cobranza_export
CREATE OR REPLACE FUNCTION public.get_cuentas_cobranza_export(p_id_cuenta text DEFAULT NULL::text, p_proyecto text DEFAULT NULL::text, p_clabe text DEFAULT NULL::text, p_no_propiedad text DEFAULT NULL::text, p_modelo text DEFAULT NULL::text, p_compradores text DEFAULT NULL::text, p_producto text DEFAULT NULL::text, p_estatus_ids integer[] DEFAULT NULL::integer[], p_tipos text[] DEFAULT NULL::text[], p_activo boolean DEFAULT true, p_proyecto_ids integer[] DEFAULT NULL::integer[], p_dueno_entity_ids integer[] DEFAULT NULL::integer[], p_limit integer DEFAULT 50000)
 RETURNS TABLE(id integer, clabe_stp text, fecha_compra text, precio_final numeric, tipo text, proyecto text, modelo text, edificio text, numero_propiedad text, producto text, comprador text, estatus_disponibilidad_nombre text, vendedor text, dueno text, metraje numeric, precio_lista numeric, pagado numeric, restante numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET statement_timeout TO '120s'
AS $function$
BEGIN
  RETURN QUERY
  WITH pagos_sum AS (
    SELECT p.id_cuenta_cobranza, SUM(p.monto) as total_pagado
    FROM pagos p
    WHERE p.activo = true
    GROUP BY p.id_cuenta_cobranza
  ),
  primer_comprador AS (
    SELECT DISTINCT ON (comp.id_cuenta_cobranza)
      comp.id_cuenta_cobranza,
      pers.nombre_legal
    FROM compradores comp
    JOIN personas pers ON comp.id_persona = pers.id
    WHERE comp.activo = true
    ORDER BY comp.id_cuenta_cobranza, pers.id
  )
  SELECT
    cc.id::integer AS id,
    cc.clabe_stp,
    cc.fecha_compra::text,
    cc.precio_final,
    CASE
      WHEN o.id_producto IS NOT NULL THEN 'Producto'
      WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
      ELSE 'Servicio'
    END AS tipo,
    COALESCE(pr.nombre, pr2.nombre) AS proyecto,
    m.nombre AS modelo,
    edif.nombre AS edificio,
    prop.numero_propiedad,
    ps.nombre AS producto,
    pc.nombre_legal AS comprador,
    ed.nombre AS estatus_disponibilidad_nombre,
    vendedor_pers.nombre_legal AS vendedor,
    dueno_pers.nombre_legal AS dueno,
    COALESCE(prop.m2_interiores, 0) + COALESCE(prop.m2_exteriores, 0) AS metraje,
    prop.precio_lista,
    COALESCE(psum.total_pagado, 0) AS pagado,
    cc.precio_final - COALESCE(psum.total_pagado, 0) AS restante
  FROM cuentas_cobranza cc
  JOIN ofertas o ON cc.id_oferta = o.id
  LEFT JOIN propiedades prop ON o.id_propiedad = prop.id
  LEFT JOIN edificios_modelos em ON prop.id_edificio_modelo = em.id
  LEFT JOIN edificios edif ON em.id_edificio = edif.id
  LEFT JOIN proyectos pr ON edif.id_proyecto = pr.id
  LEFT JOIN modelos m ON em.id_modelo = m.id
  LEFT JOIN productos_servicios ps ON o.id_producto = ps.id
  LEFT JOIN proyectos pr2 ON ps.id_proyecto = pr2.id
  LEFT JOIN estatus_disponibilidad ed ON prop.id_estatus_disponibilidad = ed.id
  LEFT JOIN personas vendedor_pers ON vendedor_pers.id = o.id_persona_lead
  LEFT JOIN entidades_relacionadas er ON er.id = prop.id_entidad_relacionada_dueno AND er.activo = true
  LEFT JOIN personas dueno_pers ON dueno_pers.id = er.id_persona
  LEFT JOIN pagos_sum psum ON psum.id_cuenta_cobranza = cc.id
  LEFT JOIN primer_comprador pc ON pc.id_cuenta_cobranza = cc.id
  WHERE cc.activo = p_activo
    AND cc.id_cuenta_cobranza_padre IS NULL
    AND (p_id_cuenta IS NULL OR cc.id::text ILIKE '%' || p_id_cuenta || '%')
    AND (p_clabe IS NULL OR cc.clabe_stp ILIKE '%' || p_clabe || '%')
    AND (p_proyecto IS NULL OR COALESCE(pr.nombre, pr2.nombre) ILIKE '%' || p_proyecto || '%')
    AND (p_no_propiedad IS NULL OR prop.numero_propiedad ILIKE '%' || p_no_propiedad || '%')
    AND (p_modelo IS NULL OR m.nombre ILIKE '%' || p_modelo || '%')
    AND (p_compradores IS NULL OR pc.nombre_legal ILIKE '%' || p_compradores || '%')
    AND (p_producto IS NULL OR ps.nombre ILIKE '%' || p_producto || '%')
    AND (p_estatus_ids IS NULL OR prop.id_estatus_disponibilidad = ANY(p_estatus_ids))
    AND (p_tipos IS NULL OR (
      CASE
        WHEN o.id_producto IS NOT NULL THEN 'Producto'
        WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
        ELSE 'Servicio'
      END
    ) = ANY(p_tipos))
    AND (p_proyecto_ids IS NULL OR COALESCE(pr.id, pr2.id) = ANY(p_proyecto_ids))
    AND (p_dueno_entity_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_dueno_entity_ids))
  ORDER BY cc.id DESC
  LIMIT p_limit;
END;
$function$;

-- get_cuentas_cobranza_export
CREATE OR REPLACE FUNCTION public.get_cuentas_cobranza_export(p_id_cuenta text DEFAULT NULL::text, p_proyecto text DEFAULT NULL::text, p_clabe text DEFAULT NULL::text, p_no_propiedad text DEFAULT NULL::text, p_modelo text DEFAULT NULL::text, p_compradores text DEFAULT NULL::text, p_producto text DEFAULT NULL::text, p_estatus_ids integer[] DEFAULT NULL::integer[], p_tipos text[] DEFAULT NULL::text[], p_activo boolean DEFAULT true, p_proyecto_ids integer[] DEFAULT NULL::integer[], p_dueno_entity_ids integer[] DEFAULT NULL::integer[])
 RETURNS TABLE(id integer, clabe_stp text, fecha_compra text, precio_final numeric, tipo text, proyecto text, modelo text, edificio text, numero_propiedad text, producto text, comprador text, estatus_disponibilidad_nombre text, vendedor text, dueno text, metraje numeric, precio_lista numeric, pagado numeric, restante numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET statement_timeout TO '120s'
AS $function$
BEGIN
  RETURN QUERY
  WITH pagos_sum AS (
    SELECT p.id_cuenta_cobranza, SUM(p.monto) as total_pagado
    FROM pagos p
    WHERE p.activo = true
    GROUP BY p.id_cuenta_cobranza
  ),
  primer_comprador AS (
    SELECT DISTINCT ON (comp.id_cuenta_cobranza)
      comp.id_cuenta_cobranza,
      pers.nombre_legal
    FROM compradores comp
    JOIN personas pers ON comp.id_persona = pers.id
    WHERE comp.activo = true
    ORDER BY comp.id_cuenta_cobranza, pers.id
  )
  SELECT
    cc.id::integer AS id,
    cc.clabe_stp,
    cc.fecha_compra::text,
    cc.precio_final,
    CASE
      WHEN o.id_producto IS NOT NULL THEN 'Producto'
      WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
      ELSE 'Servicio'
    END AS tipo,
    COALESCE(pr.nombre, pr2.nombre) AS proyecto,
    m.nombre AS modelo,
    edif.nombre AS edificio,
    prop.numero_propiedad,
    ps.nombre AS producto,
    pc.nombre_legal AS comprador,
    ed.nombre AS estatus_disponibilidad_nombre,
    vendedor_pers.nombre_legal AS vendedor,
    dueno_pers.nombre_legal AS dueno,
    COALESCE(prop.m2_interiores, 0) + COALESCE(prop.m2_exteriores, 0) AS metraje,
    prop.precio_lista,
    COALESCE(psum.total_pagado, 0) AS pagado,
    cc.precio_final - COALESCE(psum.total_pagado, 0) AS restante
  FROM cuentas_cobranza cc
  JOIN ofertas o ON cc.id_oferta = o.id
  LEFT JOIN propiedades prop ON o.id_propiedad = prop.id
  LEFT JOIN edificios_modelos em ON prop.id_edificio_modelo = em.id
  LEFT JOIN edificios edif ON em.id_edificio = edif.id
  LEFT JOIN proyectos pr ON edif.id_proyecto = pr.id
  LEFT JOIN modelos m ON em.id_modelo = m.id
  LEFT JOIN productos_servicios ps ON o.id_producto = ps.id
  LEFT JOIN proyectos pr2 ON ps.id_proyecto = pr2.id
  LEFT JOIN estatus_disponibilidad ed ON prop.id_estatus_disponibilidad = ed.id
  LEFT JOIN personas vendedor_pers ON vendedor_pers.id = o.id_persona_lead
  LEFT JOIN entidades_relacionadas er ON er.id = prop.id_entidad_relacionada_dueno AND er.activo = true
  LEFT JOIN personas dueno_pers ON dueno_pers.id = er.id_persona
  LEFT JOIN pagos_sum psum ON psum.id_cuenta_cobranza = cc.id
  LEFT JOIN primer_comprador pc ON pc.id_cuenta_cobranza = cc.id
  WHERE cc.activo = p_activo
    AND cc.id_cuenta_cobranza_padre IS NULL
    AND (p_id_cuenta IS NULL OR cc.id::text ILIKE '%' || p_id_cuenta || '%')
    AND (p_clabe IS NULL OR cc.clabe_stp ILIKE '%' || p_clabe || '%')
    AND (p_proyecto IS NULL OR COALESCE(pr.nombre, pr2.nombre) ILIKE '%' || p_proyecto || '%')
    AND (p_no_propiedad IS NULL OR prop.numero_propiedad ILIKE '%' || p_no_propiedad || '%')
    AND (p_modelo IS NULL OR m.nombre ILIKE '%' || p_modelo || '%')
    AND (p_compradores IS NULL OR pc.nombre_legal ILIKE '%' || p_compradores || '%')
    AND (p_producto IS NULL OR ps.nombre ILIKE '%' || p_producto || '%')
    AND (p_estatus_ids IS NULL OR prop.id_estatus_disponibilidad = ANY(p_estatus_ids))
    AND (p_tipos IS NULL OR (
      CASE
        WHEN o.id_producto IS NOT NULL THEN 'Producto'
        WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
        ELSE 'Servicio'
      END
    ) = ANY(p_tipos))
    AND (p_proyecto_ids IS NULL OR COALESCE(pr.id, pr2.id) = ANY(p_proyecto_ids))
    AND (p_dueno_entity_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_dueno_entity_ids))
  ORDER BY cc.id DESC;
END;
$function$;

-- get_cuentas_cobranza_paginadas
CREATE OR REPLACE FUNCTION public.get_cuentas_cobranza_paginadas(p_page integer DEFAULT 1, p_per_page integer DEFAULT 50, p_id_cuenta text DEFAULT NULL::text, p_proyecto text DEFAULT NULL::text, p_clabe text DEFAULT NULL::text, p_no_propiedad text DEFAULT NULL::text, p_modelo text DEFAULT NULL::text, p_compradores text DEFAULT NULL::text, p_producto text DEFAULT NULL::text, p_estatus_ids integer[] DEFAULT NULL::integer[], p_tipos text[] DEFAULT NULL::text[], p_activo boolean DEFAULT true, p_proyecto_ids integer[] DEFAULT NULL::integer[], p_dueno_entity_ids integer[] DEFAULT NULL::integer[], p_search text DEFAULT NULL::text)
 RETURNS TABLE(id integer, clabe_stp text, fecha_compra text, precio_final numeric, activo boolean, id_oferta integer, tipo text, proyecto text, id_proyecto integer, modelo text, edificio text, numero_propiedad text, id_propiedad integer, producto text, id_producto integer, comprador text, compradores_json jsonb, id_estatus_disponibilidad integer, estatus_disponibilidad_nombre text, vendedor text, dueno text, id_entidad_relacionada_dueno integer, id_cuenta_cobranza_padre integer, metraje numeric, precio_lista numeric, pagado numeric, restante numeric, tiene_acuerdos boolean, apartado_pagado boolean, total_acuerdos numeric, discrepancia numeric, cash_limit numeric, cash_paid numeric, cash_payments jsonb, collection_id integer, total_count bigint, motivo_cancelacion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_offset integer;
  v_total bigint;
  v_id_padded text;
BEGIN
  v_offset := (p_page - 1) * p_per_page;
  v_id_padded := NULLIF(TRIM(COALESCE(p_id_cuenta, '')), '');

  SELECT COUNT(DISTINCT cc.id) INTO v_total
  FROM cuentas_cobranza cc
  LEFT JOIN ofertas o ON o.id = cc.id_oferta
  LEFT JOIN propiedades prop ON prop.id = o.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios e ON e.id = em.id_edificio
  LEFT JOIN proyectos proy ON proy.id = e.id_proyecto
  LEFT JOIN modelos m ON m.id = em.id_modelo
  LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
  LEFT JOIN compradores comp_filter ON comp_filter.id_cuenta_cobranza = cc.id AND comp_filter.activo = true
  LEFT JOIN personas per_filter ON per_filter.id = comp_filter.id_persona
  WHERE cc.activo = p_activo
    AND cc.id_cuenta_cobranza_padre IS NULL
    AND (
      v_id_padded IS NULL
      OR LPAD(cc.id::text, 6, '0') ILIKE '%' || v_id_padded || '%'
    )
    AND (p_clabe IS NULL OR cc.clabe_stp ILIKE '%' || p_clabe || '%')
    AND (p_proyecto IS NULL OR proy.nombre ILIKE '%' || p_proyecto || '%')
    AND (p_no_propiedad IS NULL OR prop.numero_propiedad ILIKE '%' || p_no_propiedad || '%')
    AND (p_modelo IS NULL OR m.nombre ILIKE '%' || p_modelo || '%')
    AND (p_producto IS NULL OR ps.nombre ILIKE '%' || p_producto || '%')
    AND (p_compradores IS NULL OR per_filter.nombre_legal ILIKE '%' || p_compradores || '%')
    AND (p_estatus_ids IS NULL OR prop.id_estatus_disponibilidad = ANY(p_estatus_ids))
    AND (p_tipos IS NULL OR 
         (CASE 
           WHEN o.id_producto IS NOT NULL THEN 'Producto'
           WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
           ELSE 'Servicio'
         END) = ANY(p_tipos))
    AND (p_proyecto_ids IS NULL OR e.id_proyecto = ANY(p_proyecto_ids))
    AND (p_dueno_entity_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_dueno_entity_ids))
    AND (p_search IS NULL OR (
      cc.id::text ILIKE '%' || p_search || '%'
      OR LPAD(cc.id::text, 6, '0') ILIKE '%' || p_search || '%'
      OR cc.clabe_stp ILIKE '%' || p_search || '%'
      OR proy.nombre ILIKE '%' || p_search || '%'
      OR prop.numero_propiedad ILIKE '%' || p_search || '%'
      OR ps.nombre ILIKE '%' || p_search || '%'
      OR per_filter.nombre_legal ILIKE '%' || p_search || '%'
    ));

  RETURN QUERY
  WITH acuerdos_info AS (
    SELECT 
      ap.id_cuenta_cobranza,
      SUM(ap.monto) AS suma_acuerdos,
      COUNT(*) > 0 AS tiene_acuerdos_flag
    FROM acuerdos_pago ap
    WHERE ap.activo = true
    GROUP BY ap.id_cuenta_cobranza
  ),
  apartado_info AS (
    SELECT
      ap.id_cuenta_cobranza,
      bool_and(ap.pago_completado) AS apartado_pagado_flag
    FROM acuerdos_pago ap
    WHERE ap.activo = true
      AND ap.id_concepto IN (1, 2)  -- 1=Apartado, 2=Enganche
    GROUP BY ap.id_cuenta_cobranza
  ),
  pagos_info AS (
    SELECT 
      p.id_cuenta_cobranza,
      SUM(p.monto) AS total_pagado
    FROM pagos p
    WHERE p.activo = true
    GROUP BY p.id_cuenta_cobranza
  ),
  cash_info AS (
    SELECT 
      p.id_cuenta_cobranza,
      SUM(p.monto) AS cash_paid,
      jsonb_agg(jsonb_build_object('fecha_pago', p.fecha_pago, 'monto', p.monto)) AS cash_payments
    FROM pagos p
    WHERE p.activo = true AND p.id_metodos_pago = 2
    GROUP BY p.id_cuenta_cobranza
  ),
  compradores_info AS (
    SELECT 
      comp.id_cuenta_cobranza,
      jsonb_agg(
        jsonb_build_object(
          'id_persona', per.id,
          'nombre_legal', per.nombre_legal,
          'rfc', per.rfc,
          'porcentaje_copropiedad', comp.porcentaje_copropiedad
        )
        ORDER BY per.nombre_legal
      ) AS compradores_data,
      STRING_AGG(per.nombre_legal, ', ' ORDER BY per.nombre_legal) AS compradores_str
    FROM compradores comp
    JOIN personas per ON per.id = comp.id_persona
    WHERE comp.activo = true
    GROUP BY comp.id_cuenta_cobranza
  )
  SELECT 
    cc.id::integer,
    cc.clabe_stp,
    cc.fecha_compra::text,
    cc.precio_final,
    cc.activo,
    cc.id_oferta,
    CASE 
      WHEN o.id_producto IS NOT NULL THEN 'Producto'
      WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
      ELSE 'Servicio'
    END AS tipo,
    proy.nombre AS proyecto,
    e.id_proyecto AS id_proyecto,
    m.nombre AS modelo,
    e.nombre AS edificio,
    prop.numero_propiedad,
    prop.id::integer AS id_propiedad,
    ps.nombre AS producto,
    ps.id AS id_producto,
    ci.compradores_str AS comprador,
    COALESCE(ci.compradores_data, '[]'::jsonb) AS compradores_json,
    prop.id_estatus_disponibilidad,
    ed.nombre AS estatus_disponibilidad_nombre,
    NULL::text AS vendedor,
    per_dueno.nombre_legal AS dueno,
    prop.id_entidad_relacionada_dueno::integer,
    cc.id_cuenta_cobranza_padre::integer,
    (COALESCE(prop.m2_interiores,0) + COALESCE(prop.m2_exteriores,0) + COALESCE(prop.m2_loft,0))::numeric AS metraje,
    prop.precio_lista::numeric,
    COALESCE(pi.total_pagado, 0) AS pagado,
    (cc.precio_final - COALESCE(pi.total_pagado, 0)) AS restante,
    COALESCE(ai.tiene_acuerdos_flag, false) AS tiene_acuerdos,
    COALESCE(api.apartado_pagado_flag, false) AS apartado_pagado,
    COALESCE(ai.suma_acuerdos, 0) AS total_acuerdos,
    (cc.precio_final - COALESCE(ai.suma_acuerdos, 0)) AS discrepancia,
    NULL::numeric AS cash_limit,
    COALESCE(chi.cash_paid, 0) AS cash_paid,
    COALESCE(chi.cash_payments, '[]'::jsonb) AS cash_payments,
    cc.collection_id::integer,
    v_total AS total_count,
    NULL::text AS motivo_cancelacion
  FROM cuentas_cobranza cc
  LEFT JOIN ofertas o ON o.id = cc.id_oferta
  LEFT JOIN propiedades prop ON prop.id = o.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios e ON e.id = em.id_edificio
  LEFT JOIN proyectos proy ON proy.id = e.id_proyecto
  LEFT JOIN modelos m ON m.id = em.id_modelo
  LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
  LEFT JOIN estatus_disponibilidad ed ON ed.id = prop.id_estatus_disponibilidad
  LEFT JOIN entidades_relacionadas er_dueno ON er_dueno.id = prop.id_entidad_relacionada_dueno
  LEFT JOIN personas per_dueno ON per_dueno.id = er_dueno.id_persona
  LEFT JOIN acuerdos_info ai ON ai.id_cuenta_cobranza = cc.id
  LEFT JOIN apartado_info api ON api.id_cuenta_cobranza = cc.id
  LEFT JOIN pagos_info pi ON pi.id_cuenta_cobranza = cc.id
  LEFT JOIN cash_info chi ON chi.id_cuenta_cobranza = cc.id
  LEFT JOIN compradores_info ci ON ci.id_cuenta_cobranza = cc.id
  WHERE cc.activo = p_activo
    AND cc.id_cuenta_cobranza_padre IS NULL
    AND (
      v_id_padded IS NULL
      OR LPAD(cc.id::text, 6, '0') ILIKE '%' || v_id_padded || '%'
    )
    AND (p_clabe IS NULL OR cc.clabe_stp ILIKE '%' || p_clabe || '%')
    AND (p_proyecto IS NULL OR proy.nombre ILIKE '%' || p_proyecto || '%')
    AND (p_no_propiedad IS NULL OR prop.numero_propiedad ILIKE '%' || p_no_propiedad || '%')
    AND (p_modelo IS NULL OR m.nombre ILIKE '%' || p_modelo || '%')
    AND (p_producto IS NULL OR ps.nombre ILIKE '%' || p_producto || '%')
    AND (p_compradores IS NULL OR EXISTS (
      SELECT 1 FROM compradores cf2
      JOIN personas pf2 ON pf2.id = cf2.id_persona
      WHERE cf2.id_cuenta_cobranza = cc.id
        AND cf2.activo = true
        AND pf2.nombre_legal ILIKE '%' || p_compradores || '%'
    ))
    AND (p_estatus_ids IS NULL OR prop.id_estatus_disponibilidad = ANY(p_estatus_ids))
    AND (p_tipos IS NULL OR 
         (CASE 
           WHEN o.id_producto IS NOT NULL THEN 'Producto'
           WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
           ELSE 'Servicio'
         END) = ANY(p_tipos))
    AND (p_proyecto_ids IS NULL OR e.id_proyecto = ANY(p_proyecto_ids))
    AND (p_dueno_entity_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_dueno_entity_ids))
    AND (p_search IS NULL OR (
      cc.id::text ILIKE '%' || p_search || '%'
      OR LPAD(cc.id::text, 6, '0') ILIKE '%' || p_search || '%'
      OR cc.clabe_stp ILIKE '%' || p_search || '%'
      OR proy.nombre ILIKE '%' || p_search || '%'
      OR prop.numero_propiedad ILIKE '%' || p_search || '%'
      OR ps.nombre ILIKE '%' || p_search || '%'
      OR EXISTS (
        SELECT 1 FROM compradores cf3
        JOIN personas pf3 ON pf3.id = cf3.id_persona
        WHERE cf3.id_cuenta_cobranza = cc.id
          AND cf3.activo = true
          AND pf3.nombre_legal ILIKE '%' || p_search || '%'
      )
    ))
  ORDER BY cc.id DESC
  LIMIT p_per_page
  OFFSET v_offset;
END;
$function$;

-- get_cuentas_cobranza_paginadas_backup
CREATE OR REPLACE FUNCTION public.get_cuentas_cobranza_paginadas_backup(p_page integer DEFAULT 1, p_per_page integer DEFAULT 50, p_id_cuenta text DEFAULT NULL::text, p_proyecto text DEFAULT NULL::text, p_clabe text DEFAULT NULL::text, p_no_propiedad text DEFAULT NULL::text, p_modelo text DEFAULT NULL::text, p_compradores text DEFAULT NULL::text, p_producto text DEFAULT NULL::text, p_estatus_ids integer[] DEFAULT NULL::integer[], p_tipos text[] DEFAULT NULL::text[], p_activo boolean DEFAULT true, p_proyecto_ids integer[] DEFAULT NULL::integer[], p_dueno_entity_ids integer[] DEFAULT NULL::integer[], p_search text DEFAULT NULL::text)
 RETURNS TABLE(id integer, clabe_stp text, fecha_compra text, precio_final numeric, activo boolean, id_oferta integer, tipo text, proyecto text, id_proyecto integer, modelo text, edificio text, numero_propiedad text, id_propiedad integer, producto text, id_producto integer, comprador text, compradores_json jsonb, id_estatus_disponibilidad integer, estatus_disponibilidad_nombre text, vendedor text, dueno text, id_entidad_relacionada_dueno integer, id_cuenta_cobranza_padre integer, metraje numeric, precio_lista numeric, pagado numeric, restante numeric, tiene_acuerdos boolean, apartado_pagado boolean, total_acuerdos numeric, discrepancia numeric, cash_limit numeric, cash_paid numeric, cash_payments jsonb, collection_id integer, total_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_offset integer;
  v_total bigint;
BEGIN
  v_offset := (p_page - 1) * p_per_page;

  SELECT COUNT(DISTINCT cc.id) INTO v_total
  FROM cuentas_cobranza cc
  LEFT JOIN ofertas o ON o.id = cc.id_oferta
  LEFT JOIN propiedades prop ON prop.id = o.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios e ON e.id = em.id_edificio
  LEFT JOIN proyectos proy ON proy.id = e.id_proyecto
  LEFT JOIN modelos m ON m.id = em.id_modelo
  LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
  WHERE cc.activo = p_activo
    AND (p_id_cuenta IS NULL OR cc.id::text ILIKE '%' || p_id_cuenta || '%')
    AND (p_clabe IS NULL OR cc.clabe_stp ILIKE '%' || p_clabe || '%')
    AND (p_proyecto IS NULL OR proy.nombre ILIKE '%' || p_proyecto || '%')
    AND (p_no_propiedad IS NULL OR prop.numero_propiedad ILIKE '%' || p_no_propiedad || '%')
    AND (p_modelo IS NULL OR m.nombre ILIKE '%' || p_modelo || '%')
    AND (p_producto IS NULL OR ps.nombre ILIKE '%' || p_producto || '%')
    AND (p_estatus_ids IS NULL OR prop.id_estatus_disponibilidad = ANY(p_estatus_ids))
    AND (p_tipos IS NULL OR 
         (CASE 
           WHEN o.id_producto IS NOT NULL THEN 'Producto'
           WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
           ELSE 'Servicio'
         END) = ANY(p_tipos))
    AND (p_proyecto_ids IS NULL OR e.id_proyecto = ANY(p_proyecto_ids))
    AND (p_dueno_entity_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_dueno_entity_ids))
    AND (p_search IS NULL OR (
      cc.id::text ILIKE '%' || p_search || '%'
      OR cc.clabe_stp ILIKE '%' || p_search || '%'
      OR proy.nombre ILIKE '%' || p_search || '%'
      OR prop.numero_propiedad ILIKE '%' || p_search || '%'
      OR ps.nombre ILIKE '%' || p_search || '%'
    ));

  RETURN QUERY
  WITH acuerdos_info AS (
    SELECT 
      ap.id_cuenta_cobranza,
      SUM(ap.monto) AS suma_acuerdos,
      COUNT(*) > 0 AS tiene_acuerdos_flag
    FROM acuerdos_pago ap
    WHERE ap.activo = true
    GROUP BY ap.id_cuenta_cobranza
  ),
  pagos_info AS (
    SELECT 
      p.id_cuenta_cobranza,
      SUM(p.monto) AS total_pagado
    FROM pagos p
    WHERE p.activo = true
    GROUP BY p.id_cuenta_cobranza
  ),
  cash_info AS (
    SELECT 
      p.id_cuenta_cobranza,
      SUM(p.monto) AS cash_paid,
      jsonb_agg(jsonb_build_object('fecha_pago', p.fecha_pago, 'monto', p.monto)) AS cash_payments
    FROM pagos p
    WHERE p.activo = true AND p.id_metodos_pago = 2
    GROUP BY p.id_cuenta_cobranza
  ),
  compradores_info AS (
    SELECT 
      comp.id_cuenta_cobranza,
      jsonb_agg(jsonb_build_object(
        'id_persona', per.id,
        'nombre_legal', per.nombre_legal,
        'rfc', per.rfc,
        'porcentaje_copropiedad', comp.porcentaje_copropiedad
      )) AS compradores_json,
      (array_agg(per.nombre_legal ORDER BY comp.porcentaje_copropiedad DESC))[1] AS comprador_principal
    FROM compradores comp
    JOIN personas per ON per.id = comp.id_persona
    WHERE comp.activo = true
    GROUP BY comp.id_cuenta_cobranza
  )
  SELECT 
    cc.id::integer,
    cc.clabe_stp::text,
    cc.fecha_compra::text,
    cc.precio_final::numeric,
    cc.activo,
    cc.id_oferta::integer,
    (CASE 
      WHEN o.id_producto IS NOT NULL THEN 'Producto'
      WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
      ELSE 'Servicio'
    END)::text AS tipo,
    proy.nombre::text AS proyecto,
    proy.id::integer AS id_proyecto,
    m.nombre::text AS modelo,
    e.nombre::text AS edificio,
    prop.numero_propiedad::text,
    prop.id::integer AS id_propiedad,
    ps.nombre::text AS producto,
    ps.id::integer AS id_producto,
    ci.comprador_principal::text AS comprador,
    COALESCE(ci.compradores_json, '[]'::jsonb) AS compradores_json,
    prop.id_estatus_disponibilidad::integer,
    ed.nombre::text AS estatus_disponibilidad_nombre,
    u.nombre::text AS vendedor,
    prop_dueno.nombre_legal::text AS dueno,
    prop.id_entidad_relacionada_dueno::integer,
    cc.id_cuenta_cobranza_padre::integer,
    prop.m2::numeric AS metraje,
    prop.precio_lista::numeric,
    COALESCE(pi.total_pagado, 0)::numeric AS pagado,
    (cc.precio_final - COALESCE(pi.total_pagado, 0))::numeric AS restante,
    COALESCE(ai.tiene_acuerdos_flag, false) AS tiene_acuerdos,
    false AS apartado_pagado,
    COALESCE(ai.suma_acuerdos, 0)::numeric AS total_acuerdos,
    (cc.precio_final - COALESCE(ai.suma_acuerdos, 0))::numeric AS discrepancia,
    NULL::numeric AS cash_limit,
    COALESCE(cashi.cash_paid, 0)::numeric AS cash_paid,
    COALESCE(cashi.cash_payments, '[]'::jsonb) AS cash_payments,
    cc.collection_id::integer,
    v_total AS total_count
  FROM cuentas_cobranza cc
  LEFT JOIN ofertas o ON o.id = cc.id_oferta
  LEFT JOIN propiedades prop ON prop.id = o.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios e ON e.id = em.id_edificio
  LEFT JOIN proyectos proy ON proy.id = e.id_proyecto
  LEFT JOIN modelos m ON m.id = em.id_modelo
  LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
  LEFT JOIN estatus_disponibilidad ed ON ed.id = prop.id_estatus_disponibilidad
  LEFT JOIN usuarios u ON u.email = o.email_creador
  LEFT JOIN acuerdos_info ai ON ai.id_cuenta_cobranza = cc.id
  LEFT JOIN pagos_info pi ON pi.id_cuenta_cobranza = cc.id
  LEFT JOIN cash_info cashi ON cashi.id_cuenta_cobranza = cc.id
  LEFT JOIN compradores_info ci ON ci.id_cuenta_cobranza = cc.id
  LEFT JOIN entidades_relacionadas er_prop ON er_prop.id = prop.id_entidad_relacionada_dueno
  LEFT JOIN personas prop_dueno ON prop_dueno.id = er_prop.id_persona
  WHERE cc.activo = p_activo
    AND (p_id_cuenta IS NULL OR cc.id::text ILIKE '%' || p_id_cuenta || '%')
    AND (p_clabe IS NULL OR cc.clabe_stp ILIKE '%' || p_clabe || '%')
    AND (p_proyecto IS NULL OR proy.nombre ILIKE '%' || p_proyecto || '%')
    AND (p_no_propiedad IS NULL OR prop.numero_propiedad ILIKE '%' || p_no_propiedad || '%')
    AND (p_modelo IS NULL OR m.nombre ILIKE '%' || p_modelo || '%')
    AND (p_producto IS NULL OR ps.nombre ILIKE '%' || p_producto || '%')
    AND (p_estatus_ids IS NULL OR prop.id_estatus_disponibilidad = ANY(p_estatus_ids))
    AND (p_tipos IS NULL OR 
         (CASE 
           WHEN o.id_producto IS NOT NULL THEN 'Producto'
           WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
           ELSE 'Servicio'
         END) = ANY(p_tipos))
    AND (p_proyecto_ids IS NULL OR e.id_proyecto = ANY(p_proyecto_ids))
    AND (p_dueno_entity_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_dueno_entity_ids))
    AND (p_search IS NULL OR (
      cc.id::text ILIKE '%' || p_search || '%'
      OR cc.clabe_stp ILIKE '%' || p_search || '%'
      OR proy.nombre ILIKE '%' || p_search || '%'
      OR prop.numero_propiedad ILIKE '%' || p_search || '%'
      OR ps.nombre ILIKE '%' || p_search || '%'
    ))
  ORDER BY cc.id DESC
  LIMIT p_per_page
  OFFSET v_offset;
END;
$function$;

-- get_cuentas_cobranza_paginadas_backup_20260127
CREATE OR REPLACE FUNCTION public.get_cuentas_cobranza_paginadas_backup_20260127()
 RETURNS TABLE(id integer, clabe_stp text, fecha_compra text, precio_final numeric, activo boolean, id_oferta integer, tipo text, proyecto text, id_proyecto integer, modelo text, edificio text, numero_propiedad text, id_propiedad integer, producto text, id_producto integer, comprador text, compradores_json jsonb, id_estatus_disponibilidad integer, estatus_disponibilidad_nombre text, vendedor text, dueno text, id_entidad_relacionada_dueno integer, id_cuenta_cobranza_padre integer, metraje numeric, precio_lista numeric, pagado numeric, restante numeric, tiene_acuerdos boolean, apartado_pagado boolean, total_acuerdos numeric, discrepancia numeric, cash_limit numeric, cash_paid numeric, cash_payments jsonb, collection_id integer, total_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_offset integer;
  v_total bigint;
BEGIN
  -- Esta es una copia de seguridad, no se usa activamente
  -- Parámetros hardcodeados para evitar error de sintaxis
  v_offset := 0;
  v_total := 0;
  
  RETURN QUERY SELECT 
    0::integer, ''::text, ''::text, 0::numeric, false, 0::integer, ''::text, 
    ''::text, 0::integer, ''::text, ''::text, ''::text, 0::integer, ''::text, 
    0::integer, ''::text, '[]'::jsonb, 0::integer, ''::text, ''::text, ''::text,
    0::integer, 0::integer, 0::numeric, 0::numeric, 0::numeric, 0::numeric,
    false, false, 0::numeric, 0::numeric, 0::numeric, 0::numeric, '[]'::jsonb,
    0::integer, 0::bigint
  WHERE false; -- No retorna nada, solo es backup
END;
$function$;

-- get_cuentas_cobranza_stats
CREATE OR REPLACE FUNCTION public.get_cuentas_cobranza_stats(p_proyecto_ids integer[] DEFAULT NULL::integer[], p_dueno_entity_ids integer[] DEFAULT NULL::integer[])
 RETURNS TABLE(total_cuentas_activas bigint, total_propiedades bigint, total_productos bigint, total_colocado_propiedades numeric, total_colocado_productos numeric, total_cobrado_propiedades numeric, total_cobrado_productos numeric, stats_por_proyecto jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_project_ids INT[];
  v_entity_ids INT[];
BEGIN
  -- Convert arrays
  v_project_ids := p_proyecto_ids;
  v_entity_ids := p_dueno_entity_ids;

  RETURN QUERY
  WITH cuenta_base AS (
    SELECT 
      cc.id,
      cc.precio_final,
      cc.id_oferta,
      cc.activo,
      o.id_propiedad,
      o.id_producto,
      prop.id_entidad_relacionada_dueno,
      CASE 
        WHEN o.id_producto IS NOT NULL THEN 
          CASE 
            WHEN proy_prod.id_tipo_uso = 9 THEN 'Producto'
            WHEN proy_prod.id_tipo_uso IN (10, 11) THEN 'Servicio'
            ELSE 'Producto'
          END
        ELSE 'Propiedad'
      END as tipo,
      er.id_proyecto
    FROM cuentas_cobranza cc
    JOIN ofertas o ON o.id = cc.id_oferta
    LEFT JOIN propiedades prop ON prop.id = o.id_propiedad
    LEFT JOIN entidades_relacionadas er ON er.id = prop.id_entidad_relacionada_dueno
    LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
    LEFT JOIN entidades_relacionadas er_prod ON er_prod.id = ps.id_entidad_relacionada_dueno
    LEFT JOIN proyectos proy_prod ON proy_prod.id = er_prod.id_proyecto
    WHERE cc.activo = true
      AND cc.id_cuenta_cobranza_padre IS NULL
      AND (v_project_ids IS NULL OR er.id_proyecto = ANY(v_project_ids))
      AND (v_entity_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(v_entity_ids))
  ),
  pagos_por_cuenta AS (
    SELECT 
      cb.id as cuenta_id,
      COALESCE(SUM(ap.monto), 0) as total_pagado
    FROM cuenta_base cb
    LEFT JOIN acuerdos_pago acu ON acu.id_cuenta_cobranza = cb.id AND acu.activo = true
    LEFT JOIN aplicaciones_pago ap ON ap.id_acuerdo_pago = acu.id AND ap.activo = true AND ap.es_multa = false
    GROUP BY cb.id
  ),
  cuenta_con_pagos AS (
    SELECT 
      cb.*,
      COALESCE(pc.total_pagado, 0) as pagado
    FROM cuenta_base cb
    LEFT JOIN pagos_por_cuenta pc ON pc.cuenta_id = cb.id
  ),
  stats AS (
    SELECT 
      COUNT(*) as total_activas,
      COUNT(*) FILTER (WHERE tipo = 'Propiedad') as count_propiedades,
      COUNT(*) FILTER (WHERE tipo IN ('Producto', 'Servicio')) as count_productos,
      COALESCE(SUM(precio_final) FILTER (WHERE tipo = 'Propiedad'), 0) as colocado_propiedades,
      COALESCE(SUM(precio_final) FILTER (WHERE tipo IN ('Producto', 'Servicio')), 0) as colocado_productos,
      COALESCE(SUM(pagado) FILTER (WHERE tipo = 'Propiedad'), 0) as cobrado_propiedades,
      COALESCE(SUM(pagado) FILTER (WHERE tipo IN ('Producto', 'Servicio')), 0) as cobrado_productos
    FROM cuenta_con_pagos
  ),
  proyecto_stats AS (
    SELECT 
      jsonb_agg(
        jsonb_build_object(
          'id_proyecto', proy.id_proyecto,
          'proyecto', proy.proyecto,
          'count', proy.count,
          'colocado', proy.colocado,
          'cobrado', proy.cobrado
        ) ORDER BY proy.count DESC
      ) as stats
    FROM (
      SELECT 
        cp.id_proyecto,
        COALESCE(p.nombre, 'Sin proyecto') as proyecto,
        COUNT(*) as count,
        SUM(cp.precio_final) as colocado,
        SUM(cp.pagado) as cobrado
      FROM cuenta_con_pagos cp
      LEFT JOIN proyectos p ON p.id = cp.id_proyecto
      WHERE cp.tipo = 'Propiedad'
      GROUP BY cp.id_proyecto, p.nombre
    ) proy
  )
  SELECT 
    s.total_activas,
    s.count_propiedades,
    s.count_productos,
    s.colocado_propiedades,
    s.colocado_productos,
    s.cobrado_propiedades,
    s.cobrado_productos,
    COALESCE(ps.stats, '[]'::jsonb)
  FROM stats s, proyecto_stats ps;
END;
$function$;

-- get_cuentas_mantenimiento_paginadas
CREATE OR REPLACE FUNCTION public.get_cuentas_mantenimiento_paginadas(p_page integer DEFAULT 1, p_per_page integer DEFAULT 50, p_id_cuenta text DEFAULT NULL::text, p_propietarios text DEFAULT NULL::text, p_clabe text DEFAULT NULL::text, p_proyecto text DEFAULT NULL::text, p_no_propiedad text DEFAULT NULL::text, p_modelo text DEFAULT NULL::text, p_clave_catastral text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_proyecto_ids integer[] DEFAULT NULL::integer[], p_dueno_entity_ids integer[] DEFAULT NULL::integer[])
 RETURNS TABLE(id bigint, clabe_stp text, activo boolean, id_oferta integer, id_cuenta_cobranza_padre bigint, numero_propiedad text, clave_catastral text, id_propiedad bigint, proyecto text, id_proyecto integer, edificio text, modelo text, dueno text, pago_acumulado numeric, total_pagado numeric, saldo_pendiente numeric, compradores_json jsonb, residentes_json jsonb, proxima_fecha_pago date, tiene_multas_pendientes boolean, bodegas_json jsonb, estacionamientos_json jsonb, productos_json jsonb, total_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_offset INTEGER;
  v_id_filter_text TEXT;
BEGIN
  v_offset := (p_page - 1) * p_per_page;

  IF p_id_cuenta IS NOT NULL AND p_id_cuenta <> '' THEN
    v_id_filter_text := TRIM(REPLACE(LOWER(p_id_cuenta), 'cm-', ''));
  END IF;

  RETURN QUERY
  WITH
  base_accounts AS (
    SELECT
      cc.id AS cuenta_id,
      cc.clabe_stp::TEXT AS cuenta_clabe_stp,
      cc.activo AS cuenta_activo,
      cc.id_oferta AS cuenta_id_oferta,
      cc.id_cuenta_cobranza_padre,
      pp.id AS prop_id,
      pp.numero_propiedad::TEXT AS prop_numero,
      parent_cc.clave_catastral::TEXT AS prop_clave_catastral,
      proy.nombre AS proyecto_nombre,
      proy.id AS proyecto_id,
      ed.nombre AS edificio_nombre,
      mod.nombre AS modelo_nombre,
      per_dueno.nombre_legal AS dueno_nombre,
      er.id AS entidad_id
    FROM cuentas_cobranza cc
    LEFT JOIN cuentas_cobranza parent_cc ON parent_cc.id = cc.id_cuenta_cobranza_padre
    LEFT JOIN ofertas parent_of ON parent_of.id = parent_cc.id_oferta
    LEFT JOIN propiedades pp ON pp.id = parent_of.id_propiedad
    LEFT JOIN entidades_relacionadas er ON er.id = pp.id_entidad_relacionada_dueno
    LEFT JOIN personas per_dueno ON per_dueno.id = er.id_persona
    LEFT JOIN proyectos proy ON proy.id = er.id_proyecto
    LEFT JOIN edificios_modelos em ON em.id = pp.id_edificio_modelo
    LEFT JOIN edificios ed ON ed.id = em.id_edificio
    LEFT JOIN modelos mod ON mod.id = em.id_modelo
    WHERE cc.id_cuenta_cobranza_padre IS NOT NULL
      AND cc.activo = true
      AND (p_proyecto_ids IS NULL OR proy.id = ANY(p_proyecto_ids))
      AND (p_dueno_entity_ids IS NULL OR er.id = ANY(p_dueno_entity_ids))
  ),
  acuerdos_info AS (
    SELECT ap.id_cuenta_cobranza, COALESCE(SUM(ap.monto), 0) AS total_acuerdos
    FROM acuerdos_pago ap
    WHERE ap.activo = true AND ap.id_cuenta_cobranza IN (SELECT cuenta_id FROM base_accounts)
    GROUP BY ap.id_cuenta_cobranza
  ),
  pagos_info AS (
    SELECT p.id_cuenta_cobranza, COALESCE(SUM(p.monto), 0) AS total_pagos_real
    FROM pagos p
    WHERE p.activo = true AND p.id_cuenta_cobranza IN (SELECT cuenta_id FROM base_accounts)
    GROUP BY p.id_cuenta_cobranza
  ),
  compradores_info AS (
    SELECT c.id_cuenta_cobranza,
      COALESCE(jsonb_agg(jsonb_build_object(
        'id_persona', per.id, 'nombre_legal', per.nombre_legal,
        'rfc', per.rfc, 'porcentaje_copropiedad', c.porcentaje_copropiedad
      )) FILTER (WHERE per.nombre_legal IS NOT NULL), '[]'::jsonb) AS compradores
    FROM compradores c LEFT JOIN personas per ON per.id = c.id_persona
    WHERE c.id_cuenta_cobranza IN (SELECT cuenta_id FROM base_accounts)
    GROUP BY c.id_cuenta_cobranza
  ),
  residentes_info AS (
    SELECT r.id_cuenta_cobranza,
      COALESCE(jsonb_agg(jsonb_build_object(
        'id_persona', r.id_persona, 'nombre_legal', per.nombre_legal, 'activo', r.activo
      )) FILTER (WHERE per.nombre_legal IS NOT NULL), '[]'::jsonb) AS residentes
    FROM residentes r LEFT JOIN personas per ON per.id = r.id_persona
    WHERE r.id_cuenta_cobranza IN (SELECT cuenta_id FROM base_accounts)
    GROUP BY r.id_cuenta_cobranza
  ),
  proxima_fecha AS (
    SELECT ap.id_cuenta_cobranza, MAX(ap.fecha_pago) AS fecha_maxima
    FROM acuerdos_pago ap
    WHERE ap.activo = true AND ap.pago_completado = false AND ap.fecha_pago IS NOT NULL
      AND ap.id_cuenta_cobranza IN (SELECT cuenta_id FROM base_accounts)
    GROUP BY ap.id_cuenta_cobranza
  ),
  multas_info AS (
    SELECT DISTINCT ap.id_cuenta_cobranza
    FROM acuerdos_pago ap INNER JOIN multas m ON m.id_acuerdo_pago = ap.id
    WHERE ap.activo = true AND m.activo = true AND m.es_pagada = false
      AND ap.id_cuenta_cobranza IN (SELECT cuenta_id FROM base_accounts)
  ),
  bodegas_info AS (
    SELECT ba.prop_id,
      COALESCE(jsonb_agg(jsonb_build_object(
        'nombre', b.nombre, 'm2', b.m2, 'ubicacion', b.ubicacion, 'es_incluido', b.es_incluido
      )), '[]'::jsonb) AS bodegas
    FROM (SELECT DISTINCT prop_id FROM base_accounts WHERE prop_id IS NOT NULL) ba
    INNER JOIN bodegas b ON b.id_propiedad = ba.prop_id AND b.activo = true
    GROUP BY ba.prop_id
  ),
  estacionamientos_info AS (
    SELECT ea.prop_id,
      COALESCE(jsonb_agg(jsonb_build_object(
        'nombre', e.nombre, 'tipo', COALESCE(te.nombre, 'Sin tipo'),
        'm2', e.m2, 'ubicacion', e.ubicacion, 'es_incluido', e.es_incluido
      )), '[]'::jsonb) AS estacionamientos
    FROM (SELECT DISTINCT prop_id FROM base_accounts WHERE prop_id IS NOT NULL) ea
    INNER JOIN estacionamientos e ON e.id_propiedad = ea.prop_id AND e.activo = true
    LEFT JOIN tipos_estacionamiento te ON te.id = e.id_tipo
    GROUP BY ea.prop_id
  ),
  productos_info AS (
    SELECT parent_of.id_propiedad AS prop_id,
      COALESCE(jsonb_agg(jsonb_build_object(
        'nombre', ps.nombre, 'categoria', COALESCE(cp.nombre, 'Sin categoría'),
        'precio', COALESCE(ps.precio_lista, 0)
      )), '[]'::jsonb) AS productos
    FROM base_accounts ba
    INNER JOIN cuentas_cobranza parent_cc ON parent_cc.id = ba.id_cuenta_cobranza_padre
    INNER JOIN ofertas parent_of ON parent_of.id = parent_cc.id_oferta AND parent_of.id_producto IS NOT NULL
    INNER JOIN productos_servicios ps ON ps.id = parent_of.id_producto
    LEFT JOIN categorias_producto cp ON cp.id = ps.id_categoria
    WHERE parent_of.id_propiedad IS NOT NULL
      AND (cp.nombre IS NULL OR cp.nombre NOT IN ('Bodega', 'Estacionamiento'))
    GROUP BY parent_of.id_propiedad
  ),
  filtered AS (
    SELECT ba.*,
      COALESCE(ai.total_acuerdos, 0) AS calc_pago_acumulado,
      COALESCE(pi.total_pagos_real, 0) AS calc_total_pagado,
      COALESCE(ai.total_acuerdos, 0) - COALESCE(pi.total_pagos_real, 0) AS calc_saldo,
      COALESCE(ci.compradores, '[]'::jsonb) AS calc_compradores,
      COALESCE(ri.residentes, '[]'::jsonb) AS calc_residentes,
      pf.fecha_maxima AS calc_proxima_fecha,
      (mi.id_cuenta_cobranza IS NOT NULL) AS calc_tiene_multas,
      COALESCE(bi.bodegas, '[]'::jsonb) AS calc_bodegas,
      COALESCE(ei.estacionamientos, '[]'::jsonb) AS calc_estacionamientos,
      COALESCE(pri.productos, '[]'::jsonb) AS calc_productos
    FROM base_accounts ba
    LEFT JOIN acuerdos_info ai ON ai.id_cuenta_cobranza = ba.cuenta_id
    LEFT JOIN pagos_info pi ON pi.id_cuenta_cobranza = ba.cuenta_id
    LEFT JOIN compradores_info ci ON ci.id_cuenta_cobranza = ba.cuenta_id
    LEFT JOIN residentes_info ri ON ri.id_cuenta_cobranza = ba.cuenta_id
    LEFT JOIN proxima_fecha pf ON pf.id_cuenta_cobranza = ba.cuenta_id
    LEFT JOIN multas_info mi ON mi.id_cuenta_cobranza = ba.cuenta_id
    LEFT JOIN bodegas_info bi ON bi.prop_id = ba.prop_id
    LEFT JOIN estacionamientos_info ei ON ei.prop_id = ba.prop_id
    LEFT JOIN productos_info pri ON pri.prop_id = ba.prop_id
    WHERE
      (v_id_filter_text IS NULL OR ba.cuenta_id::TEXT ILIKE '%' || v_id_filter_text || '%')
      AND (p_clabe IS NULL OR ba.cuenta_clabe_stp ILIKE '%' || p_clabe || '%')
      AND (p_proyecto IS NULL OR ba.proyecto_nombre ILIKE '%' || p_proyecto || '%')
      AND (p_no_propiedad IS NULL OR ba.prop_numero ILIKE '%' || p_no_propiedad || '%')
      AND (p_modelo IS NULL OR ba.modelo_nombre ILIKE '%' || p_modelo || '%')
      AND (p_clave_catastral IS NULL OR ba.prop_clave_catastral ILIKE '%' || p_clave_catastral || '%')
      AND (p_propietarios IS NULL OR EXISTS (
        SELECT 1 FROM jsonb_array_elements(COALESCE(ci.compradores, '[]'::jsonb)) AS elem
        WHERE elem->>'nombre_legal' ILIKE '%' || p_propietarios || '%'
           OR elem->>'rfc' ILIKE '%' || p_propietarios || '%'
      ))
      AND (p_search IS NULL OR (
        ba.cuenta_id::TEXT ILIKE '%' || p_search || '%'
        OR ba.cuenta_clabe_stp ILIKE '%' || p_search || '%'
        OR ba.proyecto_nombre ILIKE '%' || p_search || '%'
        OR ba.prop_numero ILIKE '%' || p_search || '%'
        OR ba.modelo_nombre ILIKE '%' || p_search || '%'
        OR ba.dueno_nombre ILIKE '%' || p_search || '%'
        OR EXISTS (
          SELECT 1 FROM jsonb_array_elements(COALESCE(ci.compradores, '[]'::jsonb)) AS elem
          WHERE elem->>'nombre_legal' ILIKE '%' || p_search || '%'
             OR elem->>'rfc' ILIKE '%' || p_search || '%'
        )
      ))
  )
  SELECT
    f.cuenta_id,
    f.cuenta_clabe_stp,
    f.cuenta_activo,
    f.cuenta_id_oferta,
    f.id_cuenta_cobranza_padre,
    f.prop_numero,
    f.prop_clave_catastral,
    f.prop_id,
    f.proyecto_nombre,
    f.proyecto_id,
    f.edificio_nombre,
    f.modelo_nombre,
    f.dueno_nombre,
    f.calc_pago_acumulado,
    f.calc_total_pagado,
    f.calc_saldo,
    f.calc_compradores,
    f.calc_residentes,
    f.calc_proxima_fecha,
    f.calc_tiene_multas,
    f.calc_bodegas,
    f.calc_estacionamientos,
    f.calc_productos,
    (SELECT COUNT(*) FROM filtered)::BIGINT
  FROM filtered f
  ORDER BY f.cuenta_id DESC
  OFFSET v_offset
  LIMIT p_per_page;
END;
$function$;

-- get_current_user_persona_id
CREATE OR REPLACE FUNCTION public.get_current_user_persona_id()
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT id_persona FROM usuarios WHERE auth_user_id = auth.uid()
$function$;

-- get_current_user_profile
CREATE OR REPLACE FUNCTION public.get_current_user_profile()
 RETURNS TABLE(email text, nombre text, rol_id integer, rol_nombre text, debe_cambiar_password boolean, id_persona integer, activo boolean, ver_todos_prospectos_compradores boolean, ver_filtros_avanzados_eliminados boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY SELECT 
    u.email, 
    u.nombre, 
    u.rol_id, 
    r.nombre as rol_nombre,
    u.debe_cambiar_password, 
    u.id_persona, 
    u.activo,
    COALESCE(r.ver_todos_prospectos_compradores, false) as ver_todos_prospectos_compradores,
    COALESCE(r.ver_filtros_avanzados_eliminados, true) as ver_filtros_avanzados_eliminados
  FROM usuarios u 
  JOIN roles r ON u.rol_id = r.id 
  WHERE u.auth_user_id = auth.uid();
END;
$function$;

-- get_current_user_role
CREATE OR REPLACE FUNCTION public.get_current_user_role()
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT rol_id FROM usuarios WHERE auth_user_id = auth.uid()
$function$;

-- get_dashboard_cobranza_kpis
CREATE OR REPLACE FUNCTION public.get_dashboard_cobranza_kpis(p_proyecto_id integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  v_cobrado_total numeric;
  v_vencido_total numeric;
  v_pendiente_total numeric;
  v_cobrado_mes numeric;
  v_programado_mes numeric;
  v_mes_inicio date;
  v_mes_fin date;
  v_hoy date;
BEGIN
  v_hoy := current_date;
  v_mes_inicio := date_trunc('month', v_hoy)::date;
  v_mes_fin := (date_trunc('month', v_hoy) + interval '1 month' - interval '1 day')::date;

  -- Cobrado total
  SELECT COALESCE(SUM(p.monto), 0) INTO v_cobrado_total
  FROM pagos p
  JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE p.activo = true AND cc.activo = true
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id);

  -- Vencido total
  SELECT COALESCE(SUM(ap.monto), 0) INTO v_vencido_total
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id);

  -- Pendiente futuro
  SELECT COALESCE(SUM(ap.monto), 0) INTO v_pendiente_total
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false AND ap.fecha_pago >= v_hoy
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id);

  -- Cobrado mes actual
  SELECT COALESCE(SUM(p.monto), 0) INTO v_cobrado_mes
  FROM pagos p
  JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE p.activo = true AND cc.activo = true
    AND p.fecha_pago >= v_mes_inicio AND p.fecha_pago <= v_mes_fin
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id);

  -- Programado mes actual
  SELECT COALESCE(SUM(ap.monto), 0) INTO v_programado_mes
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.fecha_pago >= v_mes_inicio AND ap.fecha_pago <= v_mes_fin
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id);

  result := jsonb_build_object(
    'cobrado_total', v_cobrado_total,
    'vencido_total', v_vencido_total,
    'pendiente_total', v_pendiente_total,
    'cobrado_mes', v_cobrado_mes,
    'programado_mes', v_programado_mes,
    'recovery_rate', CASE WHEN v_programado_mes > 0 THEN ROUND((v_cobrado_mes / v_programado_mes * 100)::numeric, 1) ELSE 0 END
  );

  -- Aging de cartera
  result := result || jsonb_build_object('aging', (
    SELECT COALESCE(jsonb_agg(row_to_json(a)), '[]'::jsonb)
    FROM (
      SELECT
        CASE
          WHEN v_hoy - ap.fecha_pago BETWEEN 1 AND 30 THEN '1-30'
          WHEN v_hoy - ap.fecha_pago BETWEEN 31 AND 60 THEN '31-60'
          WHEN v_hoy - ap.fecha_pago BETWEEN 61 AND 90 THEN '61-90'
          ELSE '90+'
        END AS rango,
        SUM(ap.monto) AS monto,
        COUNT(*) AS cantidad
      FROM acuerdos_pago ap
      JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
      LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
      LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      LEFT JOIN edificios ed ON ed.id = em.id_edificio
      WHERE ap.activo = true AND cc.activo = true
        AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
        AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
      GROUP BY 1 ORDER BY 1
    ) a
  ));

  -- Morosidad
  result := result || jsonb_build_object('morosidad', (
    SELECT COALESCE(jsonb_agg(row_to_json(m)), '[]'::jsonb)
    FROM (
      SELECT
        CASE WHEN cnt = 1 THEN '1_vencida' WHEN cnt = 2 THEN '2_vencidas' ELSE '3_plus' END AS grupo,
        SUM(total)::integer AS cuentas
      FROM (
        SELECT ap.id_cuenta_cobranza, LEAST(COUNT(*), 3) AS cnt, 1 AS total
        FROM acuerdos_pago ap
        JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
        LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
        LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
        LEFT JOIN edificios ed ON ed.id = em.id_edificio
        WHERE ap.activo = true AND cc.activo = true
          AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
          AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
        GROUP BY ap.id_cuenta_cobranza HAVING COUNT(*) >= 1
      ) sub
      GROUP BY 1 ORDER BY 1
    ) m
  ));

  -- Por proyecto
  result := result || jsonb_build_object('por_proyecto', (
    SELECT COALESCE(jsonb_agg(row_to_json(pp)), '[]'::jsonb)
    FROM (
      SELECT
        pr.nombre AS proyecto,
        pr.id AS proyecto_id,
        COALESCE((
          SELECT SUM(p2.monto) FROM pagos p2
          JOIN cuentas_cobranza cc2 ON cc2.id = p2.id_cuenta_cobranza
          LEFT JOIN propiedades prop2 ON prop2.id = cc2.id_propiedad
          LEFT JOIN edificios_modelos em2 ON em2.id = prop2.id_edificio_modelo
          LEFT JOIN edificios ed2 ON ed2.id = em2.id_edificio
          WHERE p2.activo = true AND cc2.activo = true AND ed2.id_proyecto = pr.id
        ), 0) AS cobrado,
        COALESCE((
          SELECT SUM(ap2.monto) FROM acuerdos_pago ap2
          JOIN cuentas_cobranza cc2 ON cc2.id = ap2.id_cuenta_cobranza
          LEFT JOIN propiedades prop2 ON prop2.id = cc2.id_propiedad
          LEFT JOIN edificios_modelos em2 ON em2.id = prop2.id_edificio_modelo
          LEFT JOIN edificios ed2 ON ed2.id = em2.id_edificio
          WHERE ap2.activo = true AND cc2.activo = true
            AND ap2.pago_completado = false AND ap2.fecha_pago < v_hoy AND ed2.id_proyecto = pr.id
        ), 0) AS vencido,
        COALESCE((
          SELECT SUM(ap2.monto) FROM acuerdos_pago ap2
          JOIN cuentas_cobranza cc2 ON cc2.id = ap2.id_cuenta_cobranza
          LEFT JOIN propiedades prop2 ON prop2.id = cc2.id_propiedad
          LEFT JOIN edificios_modelos em2 ON em2.id = prop2.id_edificio_modelo
          LEFT JOIN edificios ed2 ON ed2.id = em2.id_edificio
          WHERE ap2.activo = true AND cc2.activo = true
            AND ap2.pago_completado = false AND ap2.fecha_pago >= v_hoy AND ed2.id_proyecto = pr.id
        ), 0) AS pendiente
      FROM proyectos pr
      WHERE pr.activo = true
        AND (p_proyecto_id IS NULL OR pr.id = p_proyecto_id)
      ORDER BY pr.nombre
    ) pp
  ));

  -- Cobrado mensual (últimos 12 meses)
  result := result || jsonb_build_object('cobrado_mensual', (
    SELECT COALESCE(jsonb_agg(row_to_json(cm)), '[]'::jsonb)
    FROM (
      SELECT to_char(date_trunc('month', p.fecha_pago), 'YYYY-MM') AS mes, SUM(p.monto) AS cobrado
      FROM pagos p
      JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
      LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
      LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      LEFT JOIN edificios ed ON ed.id = em.id_edificio
      WHERE p.activo = true AND cc.activo = true
        AND p.fecha_pago >= (v_hoy - interval '12 months')
        AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
      GROUP BY 1 ORDER BY 1
    ) cm
  ));

  -- Programado mensual (últimos 12 meses)
  result := result || jsonb_build_object('programado_mensual', (
    SELECT COALESCE(jsonb_agg(row_to_json(pm)), '[]'::jsonb)
    FROM (
      SELECT to_char(date_trunc('month', ap.fecha_pago), 'YYYY-MM') AS mes, SUM(ap.monto) AS programado
      FROM acuerdos_pago ap
      JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
      LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
      LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      LEFT JOIN edificios ed ON ed.id = em.id_edificio
      WHERE ap.activo = true AND cc.activo = true
        AND ap.fecha_pago >= (v_hoy - interval '12 months')
        AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
      GROUP BY 1 ORDER BY 1
    ) pm
  ));

  RETURN result;
END;
$function$;

-- get_dashboard_cobranza_kpis
CREATE OR REPLACE FUNCTION public.get_dashboard_cobranza_kpis(p_proyecto_id integer DEFAULT NULL::integer, p_fecha_inicio date DEFAULT NULL::date, p_fecha_fin date DEFAULT NULL::date, p_entidad_ids integer[] DEFAULT NULL::integer[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  v_cobrado_total numeric;
  v_vencido_total numeric;
  v_vencido_total_sin_ce numeric;
  v_pendiente_total numeric;
  v_cobrado_mes numeric;
  v_programado_mes numeric;
  v_programado_mes_sin_ce numeric;
  v_por_cobrar_mes numeric;
  v_por_cobrar_mes_sin_ce numeric;
  v_mes_inicio date;
  v_mes_fin date;
  v_hoy date;
BEGIN
  v_hoy := current_date;
  v_mes_inicio := COALESCE(p_fecha_inicio, date_trunc('month', v_hoy)::date);
  v_mes_fin := COALESCE(p_fecha_fin, (date_trunc('month', v_hoy) + interval '1 month' - interval '1 day')::date);

  SELECT COALESCE(SUM(p.monto), 0) INTO v_cobrado_total
  FROM pagos p
  JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE p.activo = true AND cc.activo = true
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_vencido_total
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_vencido_total_sin_ce
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
    AND ap.id_concepto != 3
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(ap.monto), 0) INTO v_pendiente_total
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false AND ap.fecha_pago >= v_hoy
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(p.monto), 0) INTO v_cobrado_mes
  FROM pagos p
  JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE p.activo = true AND cc.activo = true
    AND p.fecha_pago >= v_mes_inicio AND p.fecha_pago <= v_mes_fin
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_programado_mes
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.fecha_pago >= v_mes_inicio AND ap.fecha_pago <= v_mes_fin
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_programado_mes_sin_ce
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.fecha_pago >= v_mes_inicio AND ap.fecha_pago <= v_mes_fin
    AND ap.id_concepto != 3
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_por_cobrar_mes
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false
    AND ap.fecha_pago >= v_mes_inicio AND ap.fecha_pago <= v_mes_fin
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_por_cobrar_mes_sin_ce
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false
    AND ap.fecha_pago >= v_mes_inicio AND ap.fecha_pago <= v_mes_fin
    AND ap.id_concepto != 3
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  result := jsonb_build_object(
    'cobrado_total', v_cobrado_total,
    'vencido_total', v_vencido_total,
    'vencido_total_sin_ce', v_vencido_total_sin_ce,
    'pendiente_total', v_pendiente_total,
    'cobrado_mes', v_cobrado_mes,
    'programado_mes', v_programado_mes,
    'programado_mes_sin_ce', v_programado_mes_sin_ce,
    'por_cobrar_mes', v_por_cobrar_mes,
    'por_cobrar_mes_sin_ce', v_por_cobrar_mes_sin_ce,
    'recovery_rate', CASE WHEN v_programado_mes > 0 THEN ROUND((v_cobrado_mes / v_programado_mes * 100)::numeric, 1) ELSE 0 END
  );

  result := result || jsonb_build_object('aging', (
    SELECT COALESCE(jsonb_agg(row_to_json(a)), '[]'::jsonb)
    FROM (
      SELECT
        CASE
          WHEN v_hoy - ap.fecha_pago BETWEEN 1 AND 30 THEN '1-30'
          WHEN v_hoy - ap.fecha_pago BETWEEN 31 AND 60 THEN '31-60'
          WHEN v_hoy - ap.fecha_pago BETWEEN 61 AND 90 THEN '61-90'
          ELSE '90+'
        END AS rango,
        SUM(GREATEST(ap.monto - COALESCE((
          SELECT SUM(apl.monto) FROM aplicaciones_pago apl
          WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
        ), 0), 0)) AS monto,
        SUM(CASE WHEN ap.id_concepto != 3 THEN GREATEST(ap.monto - COALESCE((
          SELECT SUM(apl.monto) FROM aplicaciones_pago apl
          WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
        ), 0), 0) ELSE 0 END) AS monto_sin_ce,
        COUNT(*) AS cantidad
      FROM acuerdos_pago ap
      JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
      LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
      LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      LEFT JOIN edificios ed ON ed.id = em.id_edificio
      WHERE ap.activo = true AND cc.activo = true
        AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
        AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
        AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
      GROUP BY 1 ORDER BY 1
    ) a
  ));

  result := result || jsonb_build_object('morosidad', (
    SELECT COALESCE(jsonb_agg(row_to_json(m)), '[]'::jsonb)
    FROM (
      SELECT
        CASE WHEN cnt = 1 THEN '1_vencida' WHEN cnt = 2 THEN '2_vencidas' ELSE '3_plus' END AS grupo,
        SUM(total)::integer AS cuentas
      FROM (
        SELECT ap.id_cuenta_cobranza, LEAST(COUNT(*), 3) AS cnt, 1 AS total
        FROM acuerdos_pago ap
        JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
        LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
        LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
        LEFT JOIN edificios ed ON ed.id = em.id_edificio
        WHERE ap.activo = true AND cc.activo = true
          AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
          AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
          AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
        GROUP BY ap.id_cuenta_cobranza HAVING COUNT(*) >= 1
      ) sub
      GROUP BY 1 ORDER BY 1
    ) m
  ));

  result := result || jsonb_build_object('por_proyecto', (
    SELECT COALESCE(jsonb_agg(row_to_json(pp)), '[]'::jsonb)
    FROM (
      SELECT
        pr.nombre AS proyecto,
        pr.id AS proyecto_id,
        COALESCE((
          SELECT SUM(p2.monto) FROM pagos p2
          JOIN cuentas_cobranza cc2 ON cc2.id = p2.id_cuenta_cobranza
          LEFT JOIN propiedades prop2 ON prop2.id = cc2.id_propiedad
          LEFT JOIN edificios_modelos em2 ON em2.id = prop2.id_edificio_modelo
          LEFT JOIN edificios ed2 ON ed2.id = em2.id_edificio
          WHERE p2.activo = true AND cc2.activo = true AND ed2.id_proyecto = pr.id
            AND (p_entidad_ids IS NULL OR prop2.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
        ), 0) AS cobrado,
        COALESCE((
          SELECT SUM(GREATEST(ap2.monto - COALESCE((
            SELECT SUM(apl2.monto) FROM aplicaciones_pago apl2
            WHERE apl2.id_acuerdo_pago = ap2.id AND apl2.activo = true AND apl2.es_multa = false
          ), 0), 0))
          FROM acuerdos_pago ap2
          JOIN cuentas_cobranza cc2 ON cc2.id = ap2.id_cuenta_cobranza
          LEFT JOIN propiedades prop2 ON prop2.id = cc2.id_propiedad
          LEFT JOIN edificios_modelos em2 ON em2.id = prop2.id_edificio_modelo
          LEFT JOIN edificios ed2 ON ed2.id = em2.id_edificio
          WHERE ap2.activo = true AND cc2.activo = true
            AND ap2.pago_completado = false AND ap2.fecha_pago < v_hoy AND ed2.id_proyecto = pr.id
            AND (p_entidad_ids IS NULL OR prop2.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
        ), 0) AS vencido,
        COALESCE((
          SELECT SUM(ap2.monto) FROM acuerdos_pago ap2
          JOIN cuentas_cobranza cc2 ON cc2.id = ap2.id_cuenta_cobranza
          LEFT JOIN propiedades prop2 ON prop2.id = cc2.id_propiedad
          LEFT JOIN edificios_modelos em2 ON em2.id = prop2.id_edificio_modelo
          LEFT JOIN edificios ed2 ON ed2.id = em2.id_edificio
          WHERE ap2.activo = true AND cc2.activo = true
            AND ap2.pago_completado = false AND ap2.fecha_pago >= v_hoy AND ed2.id_proyecto = pr.id
            AND (p_entidad_ids IS NULL OR prop2.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
        ), 0) AS pendiente
      FROM proyectos pr
      WHERE pr.activo = true
        AND (p_proyecto_id IS NULL OR pr.id = p_proyecto_id)
      ORDER BY pr.nombre
    ) pp
  ));

  result := result || jsonb_build_object('cobrado_mensual', (
    SELECT COALESCE(jsonb_agg(row_to_json(cm)), '[]'::jsonb)
    FROM (
      SELECT to_char(date_trunc('month', p.fecha_pago), 'YYYY-MM') AS mes, SUM(p.monto) AS cobrado
      FROM pagos p
      JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
      LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
      LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      LEFT JOIN edificios ed ON ed.id = em.id_edificio
      WHERE p.activo = true AND cc.activo = true
        AND p.fecha_pago >= (v_hoy - interval '12 months')
        AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
        AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
      GROUP BY 1 ORDER BY 1
    ) cm
  ));

  -- Programado mensual con y sin contraentrega (últimos 12 meses)
  result := result || jsonb_build_object('programado_mensual', (
    SELECT COALESCE(jsonb_agg(row_to_json(pm)), '[]'::jsonb)
    FROM (
      SELECT
        to_char(date_trunc('month', ap.fecha_pago), 'YYYY-MM') AS mes,
        SUM(ap.monto) AS programado,
        SUM(CASE WHEN ap.id_concepto != 3 THEN ap.monto ELSE 0 END) AS programado_sin_ce
      FROM acuerdos_pago ap
      JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
      LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
      LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      LEFT JOIN edificios ed ON ed.id = em.id_edificio
      WHERE ap.activo = true AND cc.activo = true
        AND ap.fecha_pago >= (v_hoy - interval '12 months')
        AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
        AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
      GROUP BY 1 ORDER BY 1
    ) pm
  ));

  RETURN result;
END;
$function$;

-- get_dashboard_cobranza_kpis
CREATE OR REPLACE FUNCTION public.get_dashboard_cobranza_kpis(p_proyecto_id integer DEFAULT NULL::integer, p_fecha_inicio date DEFAULT NULL::date, p_fecha_fin date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  v_cobrado_total numeric;
  v_vencido_total numeric;
  v_vencido_total_sin_ce numeric;
  v_pendiente_total numeric;
  v_cobrado_mes numeric;
  v_programado_mes numeric;
  v_programado_mes_sin_ce numeric;
  v_por_cobrar_mes numeric;
  v_por_cobrar_mes_sin_ce numeric;
  v_mes_inicio date;
  v_mes_fin date;
  v_hoy date;
BEGIN
  v_hoy := current_date;
  v_mes_inicio := COALESCE(p_fecha_inicio, date_trunc('month', v_hoy)::date);
  v_mes_fin := COALESCE(p_fecha_fin, (date_trunc('month', v_hoy) + interval '1 month' - interval '1 day')::date);

  -- Cobrado total
  SELECT COALESCE(SUM(p.monto), 0) INTO v_cobrado_total
  FROM pagos p
  JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE p.activo = true AND cc.activo = true
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id);

  -- Vencido total (restando pagos parciales aplicados)
  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_vencido_total
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id);

  -- Vencido total SIN contraentrega (id_concepto != 3), restando parciales
  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_vencido_total_sin_ce
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
    AND ap.id_concepto != 3
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id);

  -- Pendiente futuro
  SELECT COALESCE(SUM(ap.monto), 0) INTO v_pendiente_total
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false AND ap.fecha_pago >= v_hoy
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id);

  -- Cobrado en periodo
  SELECT COALESCE(SUM(p.monto), 0) INTO v_cobrado_mes
  FROM pagos p
  JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE p.activo = true AND cc.activo = true
    AND p.fecha_pago >= v_mes_inicio AND p.fecha_pago <= v_mes_fin
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id);

  -- Programado en periodo (con contraentrega) - restando parciales
  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_programado_mes
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.fecha_pago >= v_mes_inicio AND ap.fecha_pago <= v_mes_fin
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id);

  -- Programado en periodo SIN contraentrega - restando parciales
  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_programado_mes_sin_ce
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.fecha_pago >= v_mes_inicio AND ap.fecha_pago <= v_mes_fin
    AND ap.id_concepto != 3
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id);

  -- Por cobrar en periodo: saldo remanente de acuerdos no completados en el rango de fechas
  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_por_cobrar_mes
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false
    AND ap.fecha_pago >= v_mes_inicio AND ap.fecha_pago <= v_mes_fin
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id);

  -- Por cobrar en periodo SIN contraentrega
  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_por_cobrar_mes_sin_ce
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false
    AND ap.fecha_pago >= v_mes_inicio AND ap.fecha_pago <= v_mes_fin
    AND ap.id_concepto != 3
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id);

  result := jsonb_build_object(
    'cobrado_total', v_cobrado_total,
    'vencido_total', v_vencido_total,
    'vencido_total_sin_ce', v_vencido_total_sin_ce,
    'pendiente_total', v_pendiente_total,
    'cobrado_mes', v_cobrado_mes,
    'programado_mes', v_programado_mes,
    'programado_mes_sin_ce', v_programado_mes_sin_ce,
    'por_cobrar_mes', v_por_cobrar_mes,
    'por_cobrar_mes_sin_ce', v_por_cobrar_mes_sin_ce,
    'recovery_rate', CASE WHEN v_programado_mes > 0 THEN ROUND((v_cobrado_mes / v_programado_mes * 100)::numeric, 1) ELSE 0 END
  );

  -- Antigüedad de Cartera (con y sin contraentrega, montos netos)
  result := result || jsonb_build_object('aging', (
    SELECT COALESCE(jsonb_agg(row_to_json(a)), '[]'::jsonb)
    FROM (
      SELECT
        CASE
          WHEN v_hoy - ap.fecha_pago BETWEEN 1 AND 30 THEN '1-30'
          WHEN v_hoy - ap.fecha_pago BETWEEN 31 AND 60 THEN '31-60'
          WHEN v_hoy - ap.fecha_pago BETWEEN 61 AND 90 THEN '61-90'
          ELSE '90+'
        END AS rango,
        SUM(GREATEST(ap.monto - COALESCE((
          SELECT SUM(apl.monto) FROM aplicaciones_pago apl
          WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
        ), 0), 0)) AS monto,
        SUM(CASE WHEN ap.id_concepto != 3 THEN GREATEST(ap.monto - COALESCE((
          SELECT SUM(apl.monto) FROM aplicaciones_pago apl
          WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
        ), 0), 0) ELSE 0 END) AS monto_sin_ce,
        COUNT(*) AS cantidad
      FROM acuerdos_pago ap
      JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
      LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
      LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      LEFT JOIN edificios ed ON ed.id = em.id_edificio
      WHERE ap.activo = true AND cc.activo = true
        AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
        AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
      GROUP BY 1 ORDER BY 1
    ) a
  ));

  -- Morosidad (conteo por cuentas, sin cambios)
  result := result || jsonb_build_object('morosidad', (
    SELECT COALESCE(jsonb_agg(row_to_json(m)), '[]'::jsonb)
    FROM (
      SELECT
        CASE WHEN cnt = 1 THEN '1_vencida' WHEN cnt = 2 THEN '2_vencidas' ELSE '3_plus' END AS grupo,
        SUM(total)::integer AS cuentas
      FROM (
        SELECT ap.id_cuenta_cobranza, LEAST(COUNT(*), 3) AS cnt, 1 AS total
        FROM acuerdos_pago ap
        JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
        LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
        LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
        LEFT JOIN edificios ed ON ed.id = em.id_edificio
        WHERE ap.activo = true AND cc.activo = true
          AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
          AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
        GROUP BY ap.id_cuenta_cobranza HAVING COUNT(*) >= 1
      ) sub
      GROUP BY 1 ORDER BY 1
    ) m
  ));

  -- Por proyecto (restando pagos parciales en vencido)
  result := result || jsonb_build_object('por_proyecto', (
    SELECT COALESCE(jsonb_agg(row_to_json(pp)), '[]'::jsonb)
    FROM (
      SELECT
        pr.nombre AS proyecto,
        pr.id AS proyecto_id,
        COALESCE((
          SELECT SUM(p2.monto) FROM pagos p2
          JOIN cuentas_cobranza cc2 ON cc2.id = p2.id_cuenta_cobranza
          LEFT JOIN propiedades prop2 ON prop2.id = cc2.id_propiedad
          LEFT JOIN edificios_modelos em2 ON em2.id = prop2.id_edificio_modelo
          LEFT JOIN edificios ed2 ON ed2.id = em2.id_edificio
          WHERE p2.activo = true AND cc2.activo = true AND ed2.id_proyecto = pr.id
        ), 0) AS cobrado,
        COALESCE((
          SELECT SUM(GREATEST(ap2.monto - COALESCE((
            SELECT SUM(apl2.monto) FROM aplicaciones_pago apl2
            WHERE apl2.id_acuerdo_pago = ap2.id AND apl2.activo = true AND apl2.es_multa = false
          ), 0), 0))
          FROM acuerdos_pago ap2
          JOIN cuentas_cobranza cc2 ON cc2.id = ap2.id_cuenta_cobranza
          LEFT JOIN propiedades prop2 ON prop2.id = cc2.id_propiedad
          LEFT JOIN edificios_modelos em2 ON em2.id = prop2.id_edificio_modelo
          LEFT JOIN edificios ed2 ON ed2.id = em2.id_edificio
          WHERE ap2.activo = true AND cc2.activo = true
            AND ap2.pago_completado = false AND ap2.fecha_pago < v_hoy AND ed2.id_proyecto = pr.id
        ), 0) AS vencido,
        COALESCE((
          SELECT SUM(ap2.monto) FROM acuerdos_pago ap2
          JOIN cuentas_cobranza cc2 ON cc2.id = ap2.id_cuenta_cobranza
          LEFT JOIN propiedades prop2 ON prop2.id = cc2.id_propiedad
          LEFT JOIN edificios_modelos em2 ON em2.id = prop2.id_edificio_modelo
          LEFT JOIN edificios ed2 ON ed2.id = em2.id_edificio
          WHERE ap2.activo = true AND cc2.activo = true
            AND ap2.pago_completado = false AND ap2.fecha_pago >= v_hoy AND ed2.id_proyecto = pr.id
        ), 0) AS pendiente
      FROM proyectos pr
      WHERE pr.activo = true
        AND (p_proyecto_id IS NULL OR pr.id = p_proyecto_id)
      ORDER BY pr.nombre
    ) pp
  ));

  -- Cobrado mensual (últimos 12 meses)
  result := result || jsonb_build_object('cobrado_mensual', (
    SELECT COALESCE(jsonb_agg(row_to_json(cm)), '[]'::jsonb)
    FROM (
      SELECT to_char(date_trunc('month', p.fecha_pago), 'YYYY-MM') AS mes, SUM(p.monto) AS cobrado
      FROM pagos p
      JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
      LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
      LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      LEFT JOIN edificios ed ON ed.id = em.id_edificio
      WHERE p.activo = true AND cc.activo = true
        AND p.fecha_pago >= (v_hoy - interval '12 months')
        AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
      GROUP BY 1 ORDER BY 1
    ) cm
  ));

  -- Programado mensual (últimos 12 meses)
  result := result || jsonb_build_object('programado_mensual', (
    SELECT COALESCE(jsonb_agg(row_to_json(pm)), '[]'::jsonb)
    FROM (
      SELECT to_char(date_trunc('month', ap.fecha_pago), 'YYYY-MM') AS mes, SUM(ap.monto) AS programado
      FROM acuerdos_pago ap
      JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
      LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
      LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      LEFT JOIN edificios ed ON ed.id = em.id_edificio
      WHERE ap.activo = true AND cc.activo = true
        AND ap.fecha_pago >= (v_hoy - interval '12 months')
        AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
      GROUP BY 1 ORDER BY 1
    ) pm
  ));

  RETURN result;
END;
$function$;

-- get_expediente_cobranza
CREATE OR REPLACE FUNCTION public.get_expediente_cobranza(p_cuenta_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  v_hoy date := current_date;
BEGIN
  WITH cuenta AS (
    SELECT
      cc.id,
      cc.clabe_stp,
      cc.precio_final,
      cc.fecha_compra,
      cc.id_oferta,
      cc.activo,
      cc.collection_id,
      o.id_persona_lead,
      p.nombre_legal AS cliente_nombre,
      p.email AS cliente_email,
      p.telefono AS cliente_telefono,
      p.rfc AS cliente_rfc,
      p.tipo_persona AS cliente_tipo,
      pr.id AS proyecto_id,
      pr.nombre AS proyecto_nombre,
      ed.nombre AS edificio,
      mod.nombre AS modelo,
      prop.numero_propiedad,
      prop.id AS propiedad_id,
      (COALESCE(prop.m2_interiores,0) + COALESCE(prop.m2_exteriores,0) + COALESCE(prop.m2_loft,0))::numeric AS metraje
    FROM cuentas_cobranza cc
    LEFT JOIN ofertas o ON o.id = cc.id_oferta
    LEFT JOIN personas p ON p.id = o.id_persona_lead
    LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
    LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
    LEFT JOIN edificios ed ON ed.id = em.id_edificio
    LEFT JOIN proyectos pr ON pr.id = ed.id_proyecto
    LEFT JOIN modelos mod ON mod.id = em.id_modelo
    WHERE cc.id = p_cuenta_id
  ),
  acuerdos AS (
    SELECT
      ap.id,
      ap.orden,
      ap.fecha_pago,
      ap.monto,
      ap.pago_completado,
      cp.nombre AS concepto,
      COALESCE((
        SELECT SUM(a.monto) FROM aplicaciones_pago a
        WHERE a.id_acuerdo_pago = ap.id AND a.activo = true AND a.es_multa = false
      ), 0) AS aplicado
    FROM acuerdos_pago ap
    LEFT JOIN conceptos_pago cp ON cp.id = ap.id_concepto
    WHERE ap.id_cuenta_cobranza = p_cuenta_id AND ap.activo = true
  ),
  pagos_list AS (
    SELECT
      pg.id,
      pg.fecha_pago,
      pg.monto,
      pg.descripcion,
      pg.clave_rastreo,
      pg.url_recibo,
      pg.url_cep,
      mp.nombre AS metodo
    FROM pagos pg
    LEFT JOIN metodos_pago mp ON mp.id = pg.id_metodos_pago
    WHERE pg.id_cuenta_cobranza = p_cuenta_id AND pg.activo = true
  ),
  multas_list AS (
    SELECT
      m.id,
      m.monto,
      m.descripcion,
      m.fecha_creacion,
      m.es_pagada,
      m.id_acuerdo_pago,
      ap.orden AS acuerdo_orden,
      ap.fecha_pago AS fecha_acuerdo
    FROM multas m
    JOIN acuerdos_pago ap ON ap.id = m.id_acuerdo_pago
    WHERE ap.id_cuenta_cobranza = p_cuenta_id
      AND m.activo = true AND ap.activo = true
  ),
  finanzas AS (
    SELECT
      COALESCE(SUM(monto), 0) AS total_acuerdos,
      COALESCE(SUM(aplicado), 0) AS total_pagado,
      COUNT(*) FILTER (WHERE pago_completado = false AND fecha_pago < v_hoy) AS parcialidades_vencidas,
      COALESCE(SUM(GREATEST(monto - aplicado, 0)) FILTER (WHERE pago_completado = false AND fecha_pago < v_hoy), 0) AS monto_vencido,
      COALESCE(SUM(GREATEST(monto - aplicado, 0)) FILTER (WHERE pago_completado = false), 0) AS saldo_pendiente,
      MIN(fecha_pago) FILTER (WHERE pago_completado = false AND fecha_pago >= v_hoy) AS proximo_vencimiento,
      COUNT(*) AS total_parcialidades,
      COUNT(*) FILTER (WHERE pago_completado = true) AS parcialidades_pagadas
    FROM acuerdos
  ),
  multas_finanzas AS (
    SELECT
      COALESCE(SUM(monto), 0) AS total_multas,
      COALESCE(SUM(monto) FILTER (WHERE es_pagada = false), 0) AS multas_pendientes_monto,
      COUNT(*) FILTER (WHERE es_pagada = false) AS multas_pendientes_count,
      COUNT(*) AS multas_total_count
    FROM multas_list
  ),
  compradores_data AS (
    SELECT jsonb_agg(jsonb_build_object(
      'nombre_legal', per.nombre_legal,
      'rfc', per.rfc,
      'email', per.email,
      'telefono', per.telefono,
      'porcentaje_copropiedad', comp.porcentaje_copropiedad
    ) ORDER BY per.nombre_legal) AS data
    FROM compradores comp
    JOIN personas per ON per.id = comp.id_persona
    WHERE comp.id_cuenta_cobranza = p_cuenta_id AND comp.activo = true
  )
  SELECT jsonb_build_object(
    'cuenta', (SELECT row_to_json(c) FROM cuenta c),
    'compradores', COALESCE((SELECT data FROM compradores_data), '[]'::jsonb),
    'finanzas', (
      SELECT jsonb_build_object(
        'total_acuerdos', f.total_acuerdos,
        'total_pagado', f.total_pagado,
        'parcialidades_vencidas', f.parcialidades_vencidas,
        'monto_vencido', f.monto_vencido,
        'saldo_pendiente', f.saldo_pendiente,
        'proximo_vencimiento', f.proximo_vencimiento,
        'total_parcialidades', f.total_parcialidades,
        'parcialidades_pagadas', f.parcialidades_pagadas,
        'total_multas', mf.total_multas,
        'multas_pendientes_monto', mf.multas_pendientes_monto,
        'multas_pendientes_count', mf.multas_pendientes_count,
        'multas_total_count', mf.multas_total_count
      )
      FROM finanzas f, multas_finanzas mf
    ),
    'parcialidades', COALESCE((
      SELECT jsonb_agg(row_to_json(a) ORDER BY a.orden) FROM acuerdos a
    ), '[]'::jsonb),
    'pagos', COALESCE((
      SELECT jsonb_agg(row_to_json(p) ORDER BY p.fecha_pago DESC) FROM pagos_list p
    ), '[]'::jsonb),
    'multas', COALESCE((
      SELECT jsonb_agg(row_to_json(m) ORDER BY m.fecha_creacion) FROM multas_list m
    ), '[]'::jsonb)
  ) INTO result;

  RETURN result;
END;
$function$;

-- get_inventario_disponible
CREATE OR REPLACE FUNCTION public.get_inventario_disponible(p_accessible_project_ids integer[] DEFAULT NULL::integer[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN (
    SELECT jsonb_build_object(
      'propiedades', COALESCE((
        SELECT jsonb_agg(row_data ORDER BY (row_data->>'proyecto_nombre'), (row_data->>'edificio_nombre'), (row_data->>'numero_propiedad'))
        FROM (
          SELECT jsonb_build_object(
            'id', p.id,
            'numero_propiedad', p.numero_propiedad,
            'numero_piso', p.numero_piso,
            'precio_lista', p.precio_lista,
            'm2_interiores', p.m2_interiores,
            'm2_exteriores', p.m2_exteriores,
            'proyecto_id', pr.id,
            'proyecto_nombre', pr.nombre,
            'edificio_nombre', ed.nombre,
            'modelo_id', mo.id,
            'modelo_nombre', mo.nombre,
            'numero_recamaras', mo.numero_recamaras,
            'numero_completo_banos', mo.numero_completo_banos,
            'numero_medio_bano', mo.numero_medio_bano,
            'bodegas_count', COALESCE(bod.cnt, 0),
            'estacionamientos_count', COALESCE(est.cnt, 0),
            'estacionamientos_tipos', COALESCE(est.tipos, '[]'::jsonb),
            'propiedad_imagenes', COALESCE(pimg.imgs, '[]'::jsonb)
          ) AS row_data
          FROM propiedades p
          INNER JOIN edificios_modelos em ON em.id = p.id_edificio_modelo
          INNER JOIN edificios ed ON ed.id = em.id_edificio
          INNER JOIN proyectos pr ON pr.id = ed.id_proyecto
          INNER JOIN modelos mo ON mo.id = em.id_modelo
          LEFT JOIN LATERAL (
            SELECT count(*)::int AS cnt
            FROM bodegas b WHERE b.id_propiedad = p.id AND b.activo = true
          ) bod ON true
          LEFT JOIN LATERAL (
            SELECT count(*)::int AS cnt,
              jsonb_agg(DISTINCT te.nombre) FILTER (WHERE te.nombre IS NOT NULL) AS tipos
            FROM estacionamientos e
            LEFT JOIN tipos_estacionamiento te ON te.id = e.id_tipo
            WHERE e.id_propiedad = p.id AND e.activo = true
          ) est ON true
          LEFT JOIN LATERAL (
            SELECT jsonb_agg(jsonb_build_object('id', mp.id, 'url', mp.url) ORDER BY mp.id) AS imgs
            FROM multimedias_propiedad mp
            WHERE mp.id_propiedad = p.id AND mp.activo = true AND mp.es_imagen = true
          ) pimg ON true
          WHERE p.id_estatus_disponibilidad = 2
            AND pr.activo = true
            AND pr.publicar = true
            AND (p_accessible_project_ids IS NULL OR pr.id = ANY(p_accessible_project_ids))
        ) sub
      ), '[]'::jsonb),
      'modelo_imagenes', COALESCE((
        SELECT jsonb_object_agg(modelo_id::text, imgs)
        FROM (
          SELECT DISTINCT mo.id AS modelo_id,
            (SELECT jsonb_agg(jsonb_build_object('id', mm.id, 'url', mm.url) ORDER BY mm.id)
             FROM multimedias_modelo mm
             WHERE mm.id_modelo = mo.id AND mm.activo = true AND mm.es_imagen = true AND mm.ver_como_imagen_de_propiedad = true
            ) AS imgs
          FROM propiedades p
          INNER JOIN edificios_modelos em ON em.id = p.id_edificio_modelo
          INNER JOIN edificios ed ON ed.id = em.id_edificio
          INNER JOIN proyectos pr ON pr.id = ed.id_proyecto
          INNER JOIN modelos mo ON mo.id = em.id_modelo
          WHERE p.id_estatus_disponibilidad = 2
            AND pr.activo = true AND pr.publicar = true
            AND (p_accessible_project_ids IS NULL OR pr.id = ANY(p_accessible_project_ids))
        ) unique_models
        WHERE imgs IS NOT NULL
      ), '{}'::jsonb),
      'esquemas_pago_proyecto', COALESCE((
        SELECT jsonb_object_agg(proyecto_id::text, schemes)
        FROM (
          SELECT DISTINCT pr.id AS proyecto_id,
            (SELECT jsonb_agg(jsonb_build_object(
              'id', s.id, 'nombre', s.nombre, 'id_proyecto', s.id_proyecto,
              'porcentaje_enganche', s.porcentaje_enganche,
              'porcentaje_mensualidades', s.porcentaje_mensualidades,
              'porcentaje_entrega', s.porcentaje_entrega,
              'numero_mensualidades', s.numero_mensualidades,
              'porcentaje_descuento_aumento', s.porcentaje_descuento_aumento
            ) ORDER BY s.nombre)
            FROM esquemas_pago s
            WHERE s.id_proyecto = pr.id AND s.activo = true AND s.es_manual = false
            ) AS schemes
          FROM propiedades p
          INNER JOIN edificios_modelos em ON em.id = p.id_edificio_modelo
          INNER JOIN edificios ed ON ed.id = em.id_edificio
          INNER JOIN proyectos pr ON pr.id = ed.id_proyecto
          WHERE p.id_estatus_disponibilidad = 2
            AND pr.activo = true AND pr.publicar = true
            AND (p_accessible_project_ids IS NULL OR pr.id = ANY(p_accessible_project_ids))
        ) unique_projects
        WHERE schemes IS NOT NULL
      ), '{}'::jsonb)
    )
  );
END;
$function$;

-- get_inventario_disponible_v2
CREATE OR REPLACE FUNCTION public.get_inventario_disponible_v2(p_accessible_project_ids integer[] DEFAULT NULL::integer[], p_project_names text[] DEFAULT NULL::text[], p_model_names text[] DEFAULT NULL::text[], p_bedrooms integer[] DEFAULT NULL::integer[], p_levels text[] DEFAULT NULL::text[], p_has_bodega boolean DEFAULT NULL::boolean, p_has_estacionamiento boolean DEFAULT NULL::boolean, p_sort_price text DEFAULT NULL::text, p_page integer DEFAULT 0, p_page_size integer DEFAULT 30, p_min_price numeric DEFAULT NULL::numeric, p_max_price numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN (
    WITH base_props AS (
      -- First: cheap filter on propiedades + joins without laterals
      SELECT
        p.id, p.numero_propiedad, p.numero_piso, p.precio_lista,
        p.m2_interiores, p.m2_exteriores,
        pr.id AS proyecto_id, pr.nombre AS proyecto_nombre,
        ed.nombre AS edificio_nombre,
        mo.id AS modelo_id, mo.nombre AS modelo_nombre,
        mo.numero_recamaras, mo.numero_completo_banos, mo.numero_medio_bano
      FROM propiedades p
      INNER JOIN edificios_modelos em ON em.id = p.id_edificio_modelo
      INNER JOIN edificios ed ON ed.id = em.id_edificio
      INNER JOIN proyectos pr ON pr.id = ed.id_proyecto
      INNER JOIN modelos mo ON mo.id = em.id_modelo
      WHERE p.id_estatus_disponibilidad = 2
        AND p.es_aprobado = true
        AND pr.activo = true AND pr.publicar = true
        AND (p_accessible_project_ids IS NULL OR pr.id = ANY(p_accessible_project_ids))
        AND (p_project_names IS NULL OR pr.nombre = ANY(p_project_names))
        AND (p_model_names IS NULL OR mo.nombre = ANY(p_model_names))
        AND (p_bedrooms IS NULL OR mo.numero_recamaras = ANY(p_bedrooms))
        AND (p_levels IS NULL OR p.numero_piso = ANY(p_levels))
        AND (p_min_price IS NULL OR p.precio_lista >= p_min_price)
        AND (p_max_price IS NULL OR p.precio_lista <= p_max_price)
    ),
    -- Now apply bodega/estacionamiento filters via lateral joins only on filtered set
    inv_base AS (
      SELECT
        bp.*,
        COALESCE(bod.cnt, 0) AS bodegas_count,
        COALESCE(est.cnt, 0) AS estacionamientos_count,
        COALESCE(est.tipos, '[]'::jsonb) AS estacionamientos_tipos
      FROM base_props bp
      LEFT JOIN LATERAL (
        SELECT count(*)::int AS cnt FROM bodegas b WHERE b.id_propiedad = bp.id AND b.activo = true
      ) bod ON true
      LEFT JOIN LATERAL (
        SELECT count(*)::int AS cnt,
          jsonb_agg(DISTINCT te.nombre) FILTER (WHERE te.nombre IS NOT NULL) AS tipos
        FROM estacionamientos e
        LEFT JOIN tipos_estacionamiento te ON te.id = e.id_tipo
        WHERE e.id_propiedad = bp.id AND e.activo = true
      ) est ON true
      WHERE (p_has_bodega IS NULL OR (p_has_bodega = true AND COALESCE(bod.cnt, 0) > 0) OR (p_has_bodega = false AND COALESCE(bod.cnt, 0) = 0))
        AND (p_has_estacionamiento IS NULL OR (p_has_estacionamiento = true AND COALESCE(est.cnt, 0) > 0) OR (p_has_estacionamiento = false AND COALESCE(est.cnt, 0) = 0))
    ),
    inv_count AS (
      SELECT count(*)::int AS total FROM inv_base
    ),
    project_counts AS (
      SELECT jsonb_object_agg(proyecto_nombre, cnt) AS counts
      FROM (SELECT proyecto_nombre, count(*)::int AS cnt FROM inv_base GROUP BY proyecto_nombre) sub
    ),
    inv_page AS (
      SELECT * FROM inv_base
      ORDER BY
        CASE WHEN p_sort_price = 'asc' THEN precio_lista END ASC NULLS LAST,
        CASE WHEN p_sort_price = 'desc' THEN precio_lista END DESC NULLS LAST,
        CASE WHEN p_sort_price IS NULL OR p_sort_price NOT IN ('asc','desc') THEN random() END
      LIMIT p_page_size OFFSET p_page * p_page_size
    ),
    -- Images only for the page results
    page_with_imgs AS (
      SELECT ip.*,
        COALESCE(pimg.imgs, '[]'::jsonb) AS propiedad_imagenes
      FROM inv_page ip
      LEFT JOIN LATERAL (
        SELECT jsonb_agg(jsonb_build_object('id', mp.id, 'url', mp.url) ORDER BY mp.id) AS imgs
        FROM multimedias_propiedad mp
        WHERE mp.id_propiedad = ip.id AND mp.activo = true AND mp.es_imagen = true
      ) pimg ON true
    ),
    page_modelo_imgs AS (
      SELECT DISTINCT ON (mid) b.modelo_id AS mid,
        (SELECT jsonb_agg(jsonb_build_object('id', mm.id, 'url', mm.url) ORDER BY mm.id)
         FROM multimedias_modelo mm
         WHERE mm.id_modelo = b.modelo_id AND mm.activo = true AND mm.es_imagen = true AND mm.ver_como_imagen_de_propiedad = true
        ) AS imgs
      FROM inv_page b
    ),
    page_esquemas AS (
      SELECT DISTINCT ON (pid) b.proyecto_id AS pid,
        (SELECT jsonb_agg(jsonb_build_object(
          'id', s.id, 'nombre', s.nombre, 'id_proyecto', s.id_proyecto,
          'porcentaje_enganche', s.porcentaje_enganche,
          'porcentaje_mensualidades', s.porcentaje_mensualidades,
          'porcentaje_entrega', s.porcentaje_entrega,
          'numero_mensualidades', s.numero_mensualidades,
          'porcentaje_descuento_aumento', s.porcentaje_descuento_aumento
        ) ORDER BY s.nombre)
        FROM esquemas_pago s
        WHERE s.id_proyecto = b.proyecto_id AND s.activo = true AND s.es_manual = false
        ) AS schemes
      FROM inv_page b
    ),
    filter_options AS (
      SELECT jsonb_build_object(
        'proyectos', COALESCE((SELECT jsonb_agg(DISTINCT proyecto_nombre ORDER BY proyecto_nombre) FROM inv_base), '[]'::jsonb),
        'modelos', COALESCE((SELECT jsonb_agg(DISTINCT modelo_nombre ORDER BY modelo_nombre) FROM inv_base), '[]'::jsonb),
        'recamaras', COALESCE((SELECT jsonb_agg(DISTINCT numero_recamaras ORDER BY numero_recamaras) FROM inv_base WHERE numero_recamaras IS NOT NULL), '[]'::jsonb),
        'niveles', COALESCE((SELECT jsonb_agg(DISTINCT numero_piso ORDER BY numero_piso) FROM inv_base WHERE numero_piso IS NOT NULL), '[]'::jsonb)
      ) AS opts
    )
    SELECT jsonb_build_object(
      'total_count', (SELECT total FROM inv_count),
      'project_counts', COALESCE((SELECT counts FROM project_counts), '{}'::jsonb),
      'propiedades', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id', b.id, 'numero_propiedad', b.numero_propiedad, 'numero_piso', b.numero_piso,
        'precio_lista', b.precio_lista, 'm2_interiores', b.m2_interiores, 'm2_exteriores', b.m2_exteriores,
        'proyecto_id', b.proyecto_id, 'proyecto_nombre', b.proyecto_nombre,
        'edificio_nombre', b.edificio_nombre, 'modelo_id', b.modelo_id, 'modelo_nombre', b.modelo_nombre,
        'numero_recamaras', b.numero_recamaras, 'numero_completo_banos', b.numero_completo_banos,
        'numero_medio_bano', b.numero_medio_bano, 'bodegas_count', b.bodegas_count,
        'estacionamientos_count', b.estacionamientos_count, 'estacionamientos_tipos', b.estacionamientos_tipos,
        'propiedad_imagenes', b.propiedad_imagenes
      )) FROM page_with_imgs b), '[]'::jsonb),
      'modelo_imagenes', COALESCE((SELECT jsonb_object_agg(mid::text, COALESCE(imgs, '[]'::jsonb)) FROM page_modelo_imgs), '{}'::jsonb),
      'esquemas_pago_proyecto', COALESCE((SELECT jsonb_object_agg(pid::text, COALESCE(schemes, '[]'::jsonb)) FROM page_esquemas), '{}'::jsonb),
      'filter_options', (SELECT opts FROM filter_options)
    )
  );
END;
$function$;

-- get_offers_with_agent
CREATE OR REPLACE FUNCTION public.get_offers_with_agent(property_id integer)
 RETURNS TABLE(id integer, fecha_generacion timestamp without time zone, activo boolean, id_persona_lead integer, agent_name text, lead_name text, lead_email text, lead_telefono text, esquema_id integer, esquema_nombre text, esquema_enganche numeric, esquema_mensualidades numeric, esquema_entrega numeric, esquema_numero_meses integer, esquema_es_manual boolean, cuenta_precio_final numeric, cuenta_fecha_compra date, cuenta_es_aprobado boolean, cuenta_clabe_stp text, id_persona_duena_lead integer)
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  SELECT DISTINCT ON (o.id)
    o.id,
    o.fecha_generacion,
    o.activo,
    o.id_persona_lead,
    COALESCE(u.nombre, o.email_creador) as agent_name,
    p.nombre_legal as lead_name,
    p.email as lead_email,
    p.telefono as lead_telefono,
    ep.id as esquema_id,
    ep.nombre as esquema_nombre,
    ep.porcentaje_enganche as esquema_enganche,
    ep.porcentaje_mensualidades as esquema_mensualidades,
    ep.porcentaje_entrega as esquema_entrega,
    ep.numero_mensualidades as esquema_numero_meses,
    ep.es_manual as esquema_es_manual,
    cc.precio_final as cuenta_precio_final,
    cc.fecha_compra as cuenta_fecha_compra,
    cc.es_aprobado as cuenta_es_aprobado,
    cc.clabe_stp as cuenta_clabe_stp,
    er.id_persona_duena_lead::integer as id_persona_duena_lead
  FROM ofertas o
  LEFT JOIN usuarios u ON u.email = o.email_creador
  LEFT JOIN personas p ON p.id = o.id_persona_lead
  LEFT JOIN esquemas_pago ep ON ep.id = o.id_esquema_pago_seleccionado
  LEFT JOIN cuentas_cobranza cc ON cc.id_oferta = o.id
  LEFT JOIN entidades_relacionadas er ON er.id_persona = o.id_persona_lead AND er.id_tipo_entidad IN (2, 7) AND er.activo = true
  WHERE o.id_propiedad = property_id 
    AND o.activo = true
    AND o.id_producto IS NULL
  ORDER BY o.id, o.fecha_generacion DESC;
END;
$function$;

-- get_properties_with_details
CREATE OR REPLACE FUNCTION public.get_properties_with_details()
 RETURNS TABLE(id bigint, "dueño" text, numero_propiedad text, numero_piso integer, m2_reales numeric, precio_lista numeric, clabe_stp text, vista text, transaccion text, tipo_propiedad text, disponibilidad text, modelo text, activo boolean)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT 
        p.id,
        per.nombre_legal as dueño,
        p.numero_propiedad,
        p.numero_piso,
        p.m2_reales,
        p.precio_lista,
        COALESCE(p.clabe_stp_tmp_apartado, cc.clabe_stp) as clabe_stp,
        v.nombre as vista,
        tt.nombre as transaccion,
        tp.nombre as tipo_propiedad,
        ed.nombre as disponibilidad,
        m.nombre as modelo,
        p.activo
    FROM propiedades p
    JOIN entidades_relacionadas er ON p.id_entidad_relacionada_dueno = er.id
    JOIN personas per ON er.id_persona = per.id
    JOIN vistas v ON p.id_vista = v.id
    JOIN tipos_transaccion tt ON p.id_tipo_transaccion = tt.id
    JOIN tipos_propiedad tp ON p.id_tipo_propiedad = tp.id
    JOIN estatus_disponibilidad ed ON p.id_estatus_disponibilidad = ed.id
    JOIN edificios_modelos em ON p.id_edificio_modelo = em.id
    JOIN modelos m ON em.id_modelo = m.id
    LEFT JOIN ofertas o ON o.id_propiedad = p.id
    LEFT JOIN cuentas_cobranza cc ON cc.id_oferta = o.id
    ORDER BY p.numero_propiedad;
END;
$function$;

-- get_propiedades_paginadas
CREATE OR REPLACE FUNCTION public.get_propiedades_paginadas(p_page integer, p_per_page integer, p_search text DEFAULT NULL::text, p_proyecto_ids integer[] DEFAULT NULL::integer[], p_modelo_ids integer[] DEFAULT NULL::integer[], p_recamaras integer DEFAULT NULL::integer, p_banos integer DEFAULT NULL::integer, p_disponibilidad_ids integer[] DEFAULT NULL::integer[], p_tipo_transaccion_ids integer[] DEFAULT NULL::integer[], p_area_min numeric DEFAULT NULL::numeric, p_area_max numeric DEFAULT NULL::numeric, p_precio_min numeric DEFAULT NULL::numeric, p_precio_max numeric DEFAULT NULL::numeric, p_tiene_bodegas text DEFAULT NULL::text, p_tiene_estacionamientos text DEFAULT NULL::text, p_tiene_cuenta text DEFAULT NULL::text, p_activo boolean DEFAULT true, p_es_aprobado boolean DEFAULT true, p_orden_precio text DEFAULT NULL::text, p_accessible_project_ids integer[] DEFAULT NULL::integer[], p_ownership_entity_ids integer[] DEFAULT NULL::integer[])
 RETURNS TABLE(id integer, numero_propiedad text, numero_piso text, m2_interiores numeric, m2_exteriores numeric, m2_reales numeric, precio_lista numeric, monto_apartado numeric, monto_apartado_pagando numeric, clabe_stp_tmp_apartado text, activo boolean, es_aprobado boolean, id_entidad_relacionada_dueno integer, id_edificio_modelo integer, id_vista integer, id_estatus_disponibilidad integer, id_tipo_transaccion integer, proyecto text, proyecto_id integer, edificio text, modelo text, modelo_id integer, numero_recamaras integer, numero_completo_banos integer, numero_medio_bano integer, vista text, disponibilidad text, tipo_transaccion text, propietario text, cuenta_cobranza_id integer, clabe_stp text, precio_final numeric, es_comision_venta_efectivo boolean, porcentaje_comision_venta numeric, total_pagado numeric, restante numeric, apartado_pagado boolean, cuenta_sin_esquema boolean, tiene_cuenta_pagada boolean, estacionamientos_count integer, bodegas_count integer, tiene_ofertas boolean, tiene_ofertas_productos boolean, total_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_offset INTEGER;
BEGIN
  v_offset := (p_page - 1) * p_per_page;

  RETURN QUERY
  WITH cuenta_activa AS (
    SELECT DISTINCT ON (o.id_propiedad)
      o.id_propiedad,
      cc.id as cuenta_id,
      cc.clabe_stp,
      cc.precio_final,
      cc.es_comision_venta_efectivo,
      cc.porcentaje_comision_venta,
      o.id as oferta_id
    FROM ofertas o
    JOIN cuentas_cobranza cc ON cc.id_oferta = o.id AND cc.activo = true
    WHERE o.activo = true
      AND o.id_producto IS NULL
    ORDER BY o.id_propiedad, cc.fecha_creacion DESC
  ),
  pagos_info AS (
    SELECT 
      cc.id as cuenta_id,
      COALESCE(SUM(CASE WHEN p.activo = true THEN p.monto ELSE 0 END), 0) as total_pagado
    FROM cuentas_cobranza cc
    LEFT JOIN pagos p ON p.id_cuenta_cobranza = cc.id
    WHERE cc.activo = true
    GROUP BY cc.id
  ),
  acuerdos_info AS (
    SELECT 
      cc.id as cuenta_id,
      bool_or(CASE WHEN ap.id_concepto = 1 AND ap.pago_completado = true THEN true ELSE false END) as apartado_pagado,
      bool_and(ap.pago_completado) as cuenta_pagada,
      COUNT(ap.id) as total_acuerdos
    FROM cuentas_cobranza cc
    LEFT JOIN acuerdos_pago ap ON ap.id_cuenta_cobranza = cc.id AND ap.activo = true
    WHERE cc.activo = true
    GROUP BY cc.id
  ),
  prop_counts AS (
    SELECT 
      e.id_propiedad,
      COUNT(*) as estacionamientos_count
    FROM estacionamientos e
    WHERE e.activo = true
    GROUP BY e.id_propiedad
  ),
  bodega_counts AS (
    SELECT 
      b.id_propiedad,
      COUNT(*) as bodegas_count
    FROM bodegas b
    WHERE b.activo = true
    GROUP BY b.id_propiedad
  ),
  ofertas_prop AS (
    SELECT DISTINCT 
      o.id_propiedad,
      true as tiene_ofertas
    FROM ofertas o
    WHERE o.activo = true
      AND o.id_producto IS NULL
      AND o.id_propiedad IS NOT NULL
  ),
  ofertas_prod AS (
    SELECT DISTINCT 
      o.id_propiedad,
      true as tiene_ofertas_productos
    FROM ofertas o
    WHERE o.activo = true
      AND o.id_producto IS NOT NULL
      AND o.id_propiedad IS NOT NULL
  ),
  -- CTE para obtener el comprador principal de cada cuenta
  -- FIXED: compradores table doesn't have 'id' column, use fecha_creacion for ordering
  compradores_info AS (
    SELECT DISTINCT ON (cc.id)
      cc.id as cuenta_id,
      per.nombre_legal as comprador_principal
    FROM cuentas_cobranza cc
    JOIN compradores comp ON comp.id_cuenta_cobranza = cc.id AND comp.activo = true
    JOIN personas per ON per.id = comp.id_persona AND per.activo = true
    WHERE cc.activo = true
    ORDER BY cc.id, comp.porcentaje_copropiedad DESC, comp.fecha_creacion ASC
  ),
  filtered_props AS (
    SELECT 
      prop.id,
      prop.numero_propiedad,
      prop.numero_piso,
      prop.m2_interiores,
      prop.m2_exteriores,
      (prop.m2_interiores + prop.m2_exteriores) as m2_reales,
      prop.precio_lista,
      prop.monto_apartado,
      prop.monto_apartado_pagando,
      prop.clabe_stp_tmp_apartado,
      prop.activo,
      prop.es_aprobado,
      prop.id_entidad_relacionada_dueno,
      prop.id_edificio_modelo,
      prop.id_vista,
      prop.id_estatus_disponibilidad,
      prop.id_tipo_transaccion,
      proy.nombre as proyecto,
      proy.id as proyecto_id,
      edif.nombre as edificio,
      mod.nombre as modelo,
      mod.id as modelo_id,
      mod.numero_recamaras,
      mod.numero_completo_banos,
      mod.numero_medio_bano,
      vis.nombre as vista,
      ed.nombre as disponibilidad,
      tt.nombre as tipo_transaccion,
      -- Lógica de propietario: mostrar comprador solo si estatus es 9,7,8,10
      -- (Pagada completamente, Escrituración, Entregado, Asignado)
      (CASE 
        WHEN prop.id_estatus_disponibilidad IN (9, 7, 8, 10) 
             AND ci.comprador_principal IS NOT NULL 
        THEN ci.comprador_principal
        ELSE pers.nombre_legal
      END) as propietario,
      ca.cuenta_id as cuenta_cobranza_id,
      ca.clabe_stp,
      ca.precio_final,
      COALESCE(ca.es_comision_venta_efectivo, false) as es_comision_venta_efectivo,
      COALESCE(ca.porcentaje_comision_venta, 0) as porcentaje_comision_venta,
      COALESCE(pi.total_pagado, 0) as total_pagado,
      (COALESCE(ca.precio_final, 0) - COALESCE(pi.total_pagado, 0)) as restante,
      COALESCE(ai.apartado_pagado, false) as apartado_pagado,
      (ca.cuenta_id IS NOT NULL AND COALESCE(ai.total_acuerdos, 0) = 0) as cuenta_sin_esquema,
      COALESCE(ai.cuenta_pagada, false) as tiene_cuenta_pagada,
      COALESCE(pc.estacionamientos_count, 0)::INTEGER as estacionamientos_count,
      COALESCE(bc.bodegas_count, 0)::INTEGER as bodegas_count,
      COALESCE(op.tiene_ofertas, false) as tiene_ofertas,
      COALESCE(oprod.tiene_ofertas_productos, false) as tiene_ofertas_productos,
      COUNT(*) OVER() as total_count
    FROM propiedades prop
    JOIN edificios_modelos em ON prop.id_edificio_modelo = em.id
    JOIN edificios edif ON em.id_edificio = edif.id
    JOIN proyectos proy ON edif.id_proyecto = proy.id
    JOIN modelos mod ON em.id_modelo = mod.id
    LEFT JOIN estatus_disponibilidad ed ON prop.id_estatus_disponibilidad = ed.id
    LEFT JOIN vistas vis ON prop.id_vista = vis.id
    LEFT JOIN tipos_transaccion tt ON prop.id_tipo_transaccion = tt.id
    LEFT JOIN entidades_relacionadas er ON prop.id_entidad_relacionada_dueno = er.id
    LEFT JOIN personas pers ON er.id_persona = pers.id
    LEFT JOIN cuenta_activa ca ON ca.id_propiedad = prop.id
    LEFT JOIN pagos_info pi ON pi.cuenta_id = ca.cuenta_id
    LEFT JOIN acuerdos_info ai ON ai.cuenta_id = ca.cuenta_id
    LEFT JOIN compradores_info ci ON ci.cuenta_id = ca.cuenta_id
    LEFT JOIN prop_counts pc ON pc.id_propiedad = prop.id
    LEFT JOIN bodega_counts bc ON bc.id_propiedad = prop.id
    LEFT JOIN ofertas_prop op ON op.id_propiedad = prop.id
    LEFT JOIN ofertas_prod oprod ON oprod.id_propiedad = prop.id
    WHERE prop.activo = p_activo
      AND prop.es_aprobado = p_es_aprobado
      AND (p_search IS NULL OR (
        prop.numero_propiedad ILIKE '%' || p_search || '%'
        OR proy.nombre ILIKE '%' || p_search || '%'
        OR edif.nombre ILIKE '%' || p_search || '%'
        OR mod.nombre ILIKE '%' || p_search || '%'
        OR pers.nombre_legal ILIKE '%' || p_search || '%'
        OR ci.comprador_principal ILIKE '%' || p_search || '%'
      ))
      AND (p_proyecto_ids IS NULL OR proy.id = ANY(p_proyecto_ids))
      AND (p_modelo_ids IS NULL OR mod.id = ANY(p_modelo_ids))
      AND (p_recamaras IS NULL OR mod.numero_recamaras = p_recamaras)
      AND (p_banos IS NULL OR mod.numero_completo_banos = p_banos)
      AND (p_disponibilidad_ids IS NULL OR prop.id_estatus_disponibilidad = ANY(p_disponibilidad_ids))
      AND (p_tipo_transaccion_ids IS NULL OR prop.id_tipo_transaccion = ANY(p_tipo_transaccion_ids))
      AND (p_area_min IS NULL OR (prop.m2_interiores + prop.m2_exteriores) >= p_area_min)
      AND (p_area_max IS NULL OR (prop.m2_interiores + prop.m2_exteriores) <= p_area_max)
      AND (p_precio_min IS NULL OR prop.precio_lista >= p_precio_min)
      AND (p_precio_max IS NULL OR prop.precio_lista <= p_precio_max)
      AND (p_tiene_bodegas IS NULL 
           OR (p_tiene_bodegas = 'si' AND EXISTS (SELECT 1 FROM bodegas b WHERE b.id_propiedad = prop.id AND b.activo = true))
           OR (p_tiene_bodegas = 'no' AND NOT EXISTS (SELECT 1 FROM bodegas b WHERE b.id_propiedad = prop.id AND b.activo = true)))
      AND (p_tiene_estacionamientos IS NULL 
           OR (p_tiene_estacionamientos = 'si' AND EXISTS (SELECT 1 FROM estacionamientos e WHERE e.id_propiedad = prop.id AND e.activo = true))
           OR (p_tiene_estacionamientos = 'no' AND NOT EXISTS (SELECT 1 FROM estacionamientos e WHERE e.id_propiedad = prop.id AND e.activo = true)))
      AND (p_tiene_cuenta IS NULL
           OR (p_tiene_cuenta = 'si' AND ca.cuenta_id IS NOT NULL)
           OR (p_tiene_cuenta = 'no' AND ca.cuenta_id IS NULL))
      AND (p_accessible_project_ids IS NULL OR proy.id = ANY(p_accessible_project_ids))
      AND (p_ownership_entity_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_ownership_entity_ids))
    ORDER BY 
      CASE WHEN p_orden_precio = 'asc' THEN prop.precio_lista END ASC NULLS LAST,
      CASE WHEN p_orden_precio = 'desc' THEN prop.precio_lista END DESC NULLS LAST,
      proy.nombre ASC,
      edif.nombre ASC,
      prop.numero_propiedad ASC
    LIMIT p_per_page
    OFFSET v_offset
  )
  SELECT 
    fp.id::INTEGER,
    fp.numero_propiedad::TEXT,
    fp.numero_piso::TEXT,
    fp.m2_interiores::NUMERIC,
    fp.m2_exteriores::NUMERIC,
    fp.m2_reales::NUMERIC,
    fp.precio_lista::NUMERIC,
    fp.monto_apartado::NUMERIC,
    fp.monto_apartado_pagando::NUMERIC,
    fp.clabe_stp_tmp_apartado::TEXT,
    fp.activo::BOOLEAN,
    fp.es_aprobado::BOOLEAN,
    fp.id_entidad_relacionada_dueno::INTEGER,
    fp.id_edificio_modelo::INTEGER,
    fp.id_vista::INTEGER,
    fp.id_estatus_disponibilidad::INTEGER,
    fp.id_tipo_transaccion::INTEGER,
    fp.proyecto::TEXT,
    fp.proyecto_id::INTEGER,
    fp.edificio::TEXT,
    fp.modelo::TEXT,
    fp.modelo_id::INTEGER,
    fp.numero_recamaras::INTEGER,
    fp.numero_completo_banos::INTEGER,
    fp.numero_medio_bano::INTEGER,
    fp.vista::TEXT,
    fp.disponibilidad::TEXT,
    fp.tipo_transaccion::TEXT,
    fp.propietario::TEXT,
    fp.cuenta_cobranza_id::INTEGER,
    fp.clabe_stp::TEXT,
    fp.precio_final::NUMERIC,
    fp.es_comision_venta_efectivo::BOOLEAN,
    fp.porcentaje_comision_venta::NUMERIC,
    fp.total_pagado::NUMERIC,
    fp.restante::NUMERIC,
    fp.apartado_pagado::BOOLEAN,
    fp.cuenta_sin_esquema::BOOLEAN,
    fp.tiene_cuenta_pagada::BOOLEAN,
    fp.estacionamientos_count::INTEGER,
    fp.bodegas_count::INTEGER,
    fp.tiene_ofertas::BOOLEAN,
    fp.tiene_ofertas_productos::BOOLEAN,
    fp.total_count::BIGINT
  FROM filtered_props fp;
END;
$function$;

-- get_relacion_pagos
CREATE OR REPLACE FUNCTION public.get_relacion_pagos(p_proyecto_id integer DEFAULT NULL::integer, p_metodo_pago text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_has_cep boolean DEFAULT NULL::boolean, p_tipo_cuenta text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  WITH base AS (
    SELECT
      p.id AS pago_id,
      p.monto,
      p.fecha_pago,
      p.clave_rastreo,
      p.url_cep,
      p.url_recibo,
      p.descripcion,
      p.id_cuenta_cobranza,
      mp.nombre AS metodo_pago,
      cc.clabe_stp,
      cc.id_propiedad,
      cc.id_oferta,
      o.id_producto AS oferta_id_producto,
      o.id_persona_lead,
      per.nombre_legal AS cliente,
      pr.numero_propiedad AS num_propiedad,
      ps.nombre AS producto,
      CASE 
        WHEN cc.id_propiedad IS NOT NULL THEN 'propiedad'
        WHEN o.id_producto IS NOT NULL THEN 'producto'
        ELSE NULL
      END AS tipo_cuenta,
      proy.nombre AS proyecto,
      proy.id AS proyecto_id,
      (p.url_cep IS NOT NULL AND length(trim(p.url_cep)) > 0) AS tiene_cep
    FROM pagos p
    LEFT JOIN metodos_pago mp ON mp.id = p.id_metodos_pago
    LEFT JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
    LEFT JOIN ofertas o ON o.id = cc.id_oferta
    LEFT JOIN personas per ON per.id = o.id_persona_lead
    LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
    LEFT JOIN propiedades pr ON pr.id = cc.id_propiedad
    LEFT JOIN edificios_modelos em ON em.id = pr.id_edificio_modelo
    LEFT JOIN edificios ed ON ed.id = em.id_edificio
    LEFT JOIN proyectos proy ON proy.id = COALESCE(ed.id_proyecto, ps.id_proyecto)
    WHERE p.activo = true
      -- Excluir cuentas de mantenimiento: solo cuentas con propiedad o producto
      AND (cc.id_propiedad IS NOT NULL OR o.id_producto IS NOT NULL)
  ),
  filtered AS (
    SELECT * FROM base
    WHERE (p_proyecto_id IS NULL OR proyecto_id = p_proyecto_id)
      AND (p_metodo_pago IS NULL OR metodo_pago = p_metodo_pago)
      AND (p_has_cep IS NULL OR tiene_cep = p_has_cep)
      AND (p_tipo_cuenta IS NULL OR tipo_cuenta = p_tipo_cuenta)
      AND (
        p_search IS NULL OR p_search = '' OR
        clave_rastreo ILIKE '%' || p_search || '%' OR
        descripcion ILIKE '%' || p_search || '%' OR
        cliente ILIKE '%' || p_search || '%' OR
        num_propiedad ILIKE '%' || p_search || '%' OR
        producto ILIKE '%' || p_search || '%' OR
        clabe_stp ILIKE '%' || p_search || '%'
      )
  ),
  with_apps AS (
    SELECT f.*,
      COALESCE(SUM(ap.monto), 0) AS monto_aplicado,
      COUNT(ap.id) AS num_aplicaciones,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'concepto', cp.nombre,
            'orden', acp.orden,
            'monto', ap.monto
          ) ORDER BY acp.orden
        ) FILTER (WHERE ap.id IS NOT NULL),
        '[]'::jsonb
      ) AS aplicaciones_detalle
    FROM filtered f
    LEFT JOIN aplicaciones_pago ap ON ap.id_pago = f.pago_id AND ap.activo = true
    LEFT JOIN acuerdos_pago acp ON acp.id = ap.id_acuerdo_pago
    LEFT JOIN conceptos_pago cp ON cp.id = acp.id_concepto
    GROUP BY f.pago_id, f.monto, f.fecha_pago, f.clave_rastreo, f.url_cep, f.url_recibo,
             f.descripcion, f.id_cuenta_cobranza, f.metodo_pago, f.clabe_stp,
             f.id_propiedad, f.id_oferta, f.oferta_id_producto, f.id_persona_lead,
             f.cliente, f.num_propiedad, f.producto, f.tipo_cuenta,
             f.proyecto, f.proyecto_id, f.tiene_cep
  ),
  totals AS (
    SELECT
      COUNT(*) AS total,
      COALESCE(SUM(monto), 0) AS total_monto,
      COUNT(*) FILTER (WHERE tiene_cep) AS total_con_cep,
      COUNT(*) FILTER (WHERE NOT tiene_cep) AS total_sin_cep,
      COUNT(*) FILTER (WHERE monto_aplicado >= monto AND monto > 0) AS total_aplicados,
      COUNT(*) FILTER (WHERE monto_aplicado < monto OR monto_aplicado = 0) AS total_sin_aplicar
    FROM with_apps
  ),
  paginated AS (
    SELECT * FROM with_apps
    ORDER BY fecha_pago DESC, pago_id DESC
    LIMIT p_limit OFFSET p_offset
  )
  SELECT jsonb_build_object(
    'total', (SELECT total FROM totals),
    'total_monto', (SELECT total_monto FROM totals),
    'total_con_cep', (SELECT total_con_cep FROM totals),
    'total_sin_cep', (SELECT total_sin_cep FROM totals),
    'total_aplicados', (SELECT total_aplicados FROM totals),
    'total_sin_aplicar', (SELECT total_sin_aplicar FROM totals),
    'pagos', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'pago_id', pago_id,
          'monto', monto,
          'fecha_pago', fecha_pago,
          'clave_rastreo', clave_rastreo,
          'url_cep', url_cep,
          'url_recibo', url_recibo,
          'descripcion', descripcion,
          'id_cuenta_cobranza', id_cuenta_cobranza,
          'metodo_pago', metodo_pago,
          'clabe_stp', clabe_stp,
          'cliente', cliente,
          'num_propiedad', num_propiedad,
          'producto', producto,
          'tipo_cuenta', tipo_cuenta,
          'proyecto', proyecto,
          'proyecto_id', proyecto_id,
          'tiene_cep', tiene_cep,
          'monto_aplicado', monto_aplicado,
          'num_aplicaciones', num_aplicaciones,
          'aplicaciones_detalle', aplicaciones_detalle
        )
      ) FROM paginated
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- get_relacion_pagos
CREATE OR REPLACE FUNCTION public.get_relacion_pagos(p_proyecto_id integer DEFAULT NULL::integer, p_metodo_pago text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_has_cep boolean DEFAULT NULL::boolean, p_tipo_cuenta text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_metodos_permitidos text[] DEFAULT NULL::text[], p_has_aplicaciones boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  WITH base AS (
    SELECT
      p.id AS pago_id,
      p.monto,
      p.fecha_pago,
      p.clave_rastreo,
      p.url_cep,
      p.url_recibo,
      p.descripcion,
      p.id_cuenta_cobranza,
      mp.nombre AS metodo_pago,
      cc.clabe_stp,
      cc.id_propiedad,
      cc.id_oferta,
      o.id_producto AS oferta_id_producto,
      o.id_persona_lead,
      per.nombre_legal AS cliente,
      pr.numero_propiedad AS num_propiedad,
      ps.nombre AS producto,
      CASE 
        WHEN cc.id_propiedad IS NOT NULL THEN 'propiedad'
        WHEN o.id_producto IS NOT NULL THEN 'producto'
        ELSE NULL
      END AS tipo_cuenta,
      proy.nombre AS proyecto,
      proy.id AS proyecto_id,
      (p.url_cep IS NOT NULL AND length(trim(p.url_cep)) > 0) AS tiene_cep
    FROM pagos p
    LEFT JOIN metodos_pago mp ON mp.id = p.id_metodos_pago
    LEFT JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
    LEFT JOIN ofertas o ON o.id = cc.id_oferta
    LEFT JOIN personas per ON per.id = o.id_persona_lead
    LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
    LEFT JOIN propiedades pr ON pr.id = cc.id_propiedad
    LEFT JOIN edificios_modelos em ON em.id = pr.id_edificio_modelo
    LEFT JOIN edificios ed ON ed.id = em.id_edificio
    LEFT JOIN proyectos proy ON proy.id = COALESCE(ed.id_proyecto, ps.id_proyecto)
    WHERE p.activo = true
      AND (cc.id_propiedad IS NOT NULL OR o.id_producto IS NOT NULL)
  ),
  filtered AS (
    SELECT * FROM base
    WHERE (p_proyecto_id IS NULL OR proyecto_id = p_proyecto_id)
      AND (p_metodo_pago IS NULL OR metodo_pago = p_metodo_pago)
      AND (p_metodos_permitidos IS NULL OR metodo_pago = ANY(p_metodos_permitidos))
      AND (p_has_cep IS NULL OR tiene_cep = p_has_cep)
      AND (p_tipo_cuenta IS NULL OR tipo_cuenta = p_tipo_cuenta)
      AND (
        p_search IS NULL OR p_search = '' OR
        clave_rastreo ILIKE '%' || p_search || '%' OR
        descripcion ILIKE '%' || p_search || '%' OR
        cliente ILIKE '%' || p_search || '%' OR
        num_propiedad ILIKE '%' || p_search || '%' OR
        producto ILIKE '%' || p_search || '%' OR
        clabe_stp ILIKE '%' || p_search || '%'
      )
  ),
  with_apps AS (
    SELECT f.*,
      COALESCE(SUM(ap.monto), 0) AS monto_aplicado,
      COUNT(ap.id) AS num_aplicaciones,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'concepto', cp.nombre,
            'orden', acp.orden,
            'monto', ap.monto
          ) ORDER BY acp.orden
        ) FILTER (WHERE ap.id IS NOT NULL),
        '[]'::jsonb
      ) AS aplicaciones_detalle
    FROM filtered f
    LEFT JOIN aplicaciones_pago ap ON ap.id_pago = f.pago_id AND ap.activo = true
    LEFT JOIN acuerdos_pago acp ON acp.id = ap.id_acuerdo_pago
    LEFT JOIN conceptos_pago cp ON cp.id = acp.id_concepto
    GROUP BY f.pago_id, f.monto, f.fecha_pago, f.clave_rastreo, f.url_cep, f.url_recibo,
             f.descripcion, f.id_cuenta_cobranza, f.metodo_pago, f.clabe_stp,
             f.id_propiedad, f.id_oferta, f.oferta_id_producto, f.id_persona_lead,
             f.cliente, f.num_propiedad, f.producto, f.tipo_cuenta,
             f.proyecto, f.proyecto_id, f.tiene_cep
  ),
  with_apps_filtered AS (
    SELECT * FROM with_apps
    WHERE (
      p_has_aplicaciones IS NULL
      OR (p_has_aplicaciones = true AND num_aplicaciones > 0)
      OR (p_has_aplicaciones = false AND num_aplicaciones = 0)
    )
  ),
  totals AS (
    SELECT
      COUNT(*) AS total,
      COALESCE(SUM(monto), 0) AS total_monto,
      COUNT(*) FILTER (WHERE tiene_cep) AS total_con_cep,
      COUNT(*) FILTER (WHERE NOT tiene_cep) AS total_sin_cep,
      COUNT(*) FILTER (WHERE num_aplicaciones > 0) AS total_aplicados,
      COUNT(*) FILTER (WHERE num_aplicaciones = 0) AS total_sin_aplicar
    FROM with_apps_filtered
  ),
  paginated AS (
    SELECT * FROM with_apps_filtered
    ORDER BY fecha_pago DESC, pago_id DESC
    LIMIT p_limit OFFSET p_offset
  )
  SELECT jsonb_build_object(
    'total', (SELECT total FROM totals),
    'total_monto', (SELECT total_monto FROM totals),
    'total_con_cep', (SELECT total_con_cep FROM totals),
    'total_sin_cep', (SELECT total_sin_cep FROM totals),
    'total_aplicados', (SELECT total_aplicados FROM totals),
    'total_sin_aplicar', (SELECT total_sin_aplicar FROM totals),
    'pagos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'pago_id', pago_id,
        'monto', monto,
        'fecha_pago', fecha_pago,
        'clave_rastreo', clave_rastreo,
        'url_cep', url_cep,
        'url_recibo', url_recibo,
        'descripcion', descripcion,
        'id_cuenta_cobranza', id_cuenta_cobranza,
        'metodo_pago', metodo_pago,
        'clabe_stp', clabe_stp,
        'cliente', cliente,
        'num_propiedad', num_propiedad,
        'producto', producto,
        'tipo_cuenta', tipo_cuenta,
        'proyecto', proyecto,
        'proyecto_id', proyecto_id,
        'tiene_cep', tiene_cep,
        'monto_aplicado', monto_aplicado,
        'num_aplicaciones', num_aplicaciones,
        'aplicaciones_detalle', aplicaciones_detalle
      )) FROM paginated
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- get_relacion_pagos
CREATE OR REPLACE FUNCTION public.get_relacion_pagos(p_proyecto_id integer DEFAULT NULL::integer, p_metodo_pago text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_has_cep boolean DEFAULT NULL::boolean, p_tipo_cuenta text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_metodos_permitidos text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  WITH base AS (
    SELECT
      p.id AS pago_id,
      p.monto,
      p.fecha_pago,
      p.clave_rastreo,
      p.url_cep,
      p.url_recibo,
      p.descripcion,
      p.id_cuenta_cobranza,
      mp.nombre AS metodo_pago,
      cc.clabe_stp,
      cc.id_propiedad,
      cc.id_oferta,
      o.id_producto AS oferta_id_producto,
      o.id_persona_lead,
      per.nombre_legal AS cliente,
      pr.numero_propiedad AS num_propiedad,
      ps.nombre AS producto,
      CASE 
        WHEN cc.id_propiedad IS NOT NULL THEN 'propiedad'
        WHEN o.id_producto IS NOT NULL THEN 'producto'
        ELSE NULL
      END AS tipo_cuenta,
      proy.nombre AS proyecto,
      proy.id AS proyecto_id,
      (p.url_cep IS NOT NULL AND length(trim(p.url_cep)) > 0) AS tiene_cep
    FROM pagos p
    LEFT JOIN metodos_pago mp ON mp.id = p.id_metodos_pago
    LEFT JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
    LEFT JOIN ofertas o ON o.id = cc.id_oferta
    LEFT JOIN personas per ON per.id = o.id_persona_lead
    LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
    LEFT JOIN propiedades pr ON pr.id = cc.id_propiedad
    LEFT JOIN edificios_modelos em ON em.id = pr.id_edificio_modelo
    LEFT JOIN edificios ed ON ed.id = em.id_edificio
    LEFT JOIN proyectos proy ON proy.id = COALESCE(ed.id_proyecto, ps.id_proyecto)
    WHERE p.activo = true
      AND (cc.id_propiedad IS NOT NULL OR o.id_producto IS NOT NULL)
  ),
  filtered AS (
    SELECT * FROM base
    WHERE (p_proyecto_id IS NULL OR proyecto_id = p_proyecto_id)
      AND (p_metodo_pago IS NULL OR metodo_pago = p_metodo_pago)
      AND (p_metodos_permitidos IS NULL OR metodo_pago = ANY(p_metodos_permitidos))
      AND (p_has_cep IS NULL OR tiene_cep = p_has_cep)
      AND (p_tipo_cuenta IS NULL OR tipo_cuenta = p_tipo_cuenta)
      AND (
        p_search IS NULL OR p_search = '' OR
        clave_rastreo ILIKE '%' || p_search || '%' OR
        descripcion ILIKE '%' || p_search || '%' OR
        cliente ILIKE '%' || p_search || '%' OR
        num_propiedad ILIKE '%' || p_search || '%' OR
        producto ILIKE '%' || p_search || '%' OR
        clabe_stp ILIKE '%' || p_search || '%'
      )
  ),
  with_apps AS (
    SELECT f.*,
      COALESCE(SUM(ap.monto), 0) AS monto_aplicado,
      COUNT(ap.id) AS num_aplicaciones,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'concepto', cp.nombre,
            'orden', acp.orden,
            'monto', ap.monto
          ) ORDER BY acp.orden
        ) FILTER (WHERE ap.id IS NOT NULL),
        '[]'::jsonb
      ) AS aplicaciones_detalle
    FROM filtered f
    LEFT JOIN aplicaciones_pago ap ON ap.id_pago = f.pago_id AND ap.activo = true
    LEFT JOIN acuerdos_pago acp ON acp.id = ap.id_acuerdo_pago
    LEFT JOIN conceptos_pago cp ON cp.id = acp.id_concepto
    GROUP BY f.pago_id, f.monto, f.fecha_pago, f.clave_rastreo, f.url_cep, f.url_recibo,
             f.descripcion, f.id_cuenta_cobranza, f.metodo_pago, f.clabe_stp,
             f.id_propiedad, f.id_oferta, f.oferta_id_producto, f.id_persona_lead,
             f.cliente, f.num_propiedad, f.producto, f.tipo_cuenta,
             f.proyecto, f.proyecto_id, f.tiene_cep
  ),
  totals AS (
    SELECT
      COUNT(*) AS total,
      COALESCE(SUM(monto), 0) AS total_monto,
      COUNT(*) FILTER (WHERE tiene_cep) AS total_con_cep,
      COUNT(*) FILTER (WHERE NOT tiene_cep) AS total_sin_cep,
      COUNT(*) FILTER (WHERE monto_aplicado >= monto AND monto > 0) AS total_aplicados,
      COUNT(*) FILTER (WHERE monto_aplicado < monto OR monto_aplicado = 0) AS total_sin_aplicar
    FROM with_apps
  ),
  paginated AS (
    SELECT * FROM with_apps
    ORDER BY fecha_pago DESC, pago_id DESC
    LIMIT p_limit OFFSET p_offset
  )
  SELECT jsonb_build_object(
    'total', (SELECT total FROM totals),
    'total_monto', (SELECT total_monto FROM totals),
    'total_con_cep', (SELECT total_con_cep FROM totals),
    'total_sin_cep', (SELECT total_sin_cep FROM totals),
    'total_aplicados', (SELECT total_aplicados FROM totals),
    'total_sin_aplicar', (SELECT total_sin_aplicar FROM totals),
    'pagos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'pago_id', pago_id,
        'monto', monto,
        'fecha_pago', fecha_pago,
        'clave_rastreo', clave_rastreo,
        'url_cep', url_cep,
        'url_recibo', url_recibo,
        'descripcion', descripcion,
        'id_cuenta_cobranza', id_cuenta_cobranza,
        'metodo_pago', metodo_pago,
        'clabe_stp', clabe_stp,
        'cliente', cliente,
        'num_propiedad', num_propiedad,
        'producto', producto,
        'tipo_cuenta', tipo_cuenta,
        'proyecto', proyecto,
        'proyecto_id', proyecto_id,
        'tiene_cep', tiene_cep,
        'monto_aplicado', monto_aplicado,
        'num_aplicaciones', num_aplicaciones,
        'aplicaciones_detalle', aplicaciones_detalle
      )) FROM paginated
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- get_totales_comisiones_sozu
CREATE OR REPLACE FUNCTION public.get_totales_comisiones_sozu()
 RETURNS TABLE(monto_total_sozu numeric, monto_ya_cobrado numeric, monto_por_cobrar numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  SELECT 
    COALESCE(SUM(cc.precio_final * cc.porcentaje_comision_venta / 100), 0) as monto_total_sozu,
    COALESCE(SUM(CASE WHEN cc.es_pagada_comision_venta = true THEN cc.precio_final * cc.porcentaje_comision_venta / 100 ELSE 0 END), 0) as monto_ya_cobrado,
    COALESCE(SUM(CASE WHEN cc.es_pagada_comision_venta = false OR cc.es_pagada_comision_venta IS NULL THEN cc.precio_final * cc.porcentaje_comision_venta / 100 ELSE 0 END), 0) as monto_por_cobrar
  FROM cuentas_cobranza cc
  WHERE cc.activo = true AND cc.porcentaje_comision_venta > 0;
END;
$function$;

-- get_totales_comisionistas
CREATE OR REPLACE FUNCTION public.get_totales_comisionistas()
 RETURNS TABLE(monto_total numeric, monto_dispersado numeric, monto_pendiente numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  SELECT 
    COALESCE(SUM(cc.precio_final * c.porcentaje_comision / 100), 0) as monto_total,
    COALESCE(SUM(CASE WHEN c.pagada = true THEN cc.precio_final * c.porcentaje_comision / 100 ELSE 0 END), 0) as monto_dispersado,
    COALESCE(SUM(CASE WHEN c.pagada = false OR c.pagada IS NULL THEN cc.precio_final * c.porcentaje_comision / 100 ELSE 0 END), 0) as monto_pendiente
  FROM comisionistas c
  INNER JOIN cuentas_cobranza cc ON cc.id = c.id_cuenta_cobranza
  WHERE c.activo = true AND c.aprobada = true;
END;
$function$;

-- get_user_menus
CREATE OR REPLACE FUNCTION public.get_user_menus()
 RETURNS TABLE(menu_id integer, menu_nombre text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY SELECT DISTINCT m.id, m.nombre FROM usuarios u
  JOIN menus_roles mr ON u.rol_id = mr.rol_id AND mr.activo = true
  JOIN menus m ON m.id = mr.menu_id
  WHERE u.auth_user_id = auth.uid() AND u.activo = true ORDER BY m.id;
END; $function$;

-- get_user_role
CREATE OR REPLACE FUNCTION public.get_user_role()
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _role_name TEXT;
BEGIN
  SELECT r.nombre INTO _role_name FROM usuarios u
  JOIN roles r ON u.rol_id = r.id WHERE u.auth_user_id = auth.uid() AND u.activo = true;
  RETURN _role_name;
END; $function$;

-- get_usuarios_by_emails
CREATE OR REPLACE FUNCTION public.get_usuarios_by_emails(_emails text[])
 RETURNS TABLE(email text, nombre text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT u.email, u.nombre
  FROM usuarios u
  WHERE u.email = ANY(_emails);
$function$;

-- handle_email_confirmation
CREATE OR REPLACE FUNCTION public.handle_email_confirmation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _usuario_nombre TEXT;
  _supabase_url TEXT;
  _anon_key TEXT;
BEGIN
  -- Only proceed if email_confirmed_at changed from NULL to a value
  IF OLD.email_confirmed_at IS NULL AND NEW.email_confirmed_at IS NOT NULL THEN
    -- 1. Update email_confirmado in usuarios table
    UPDATE public.usuarios
    SET email_confirmado = true
    WHERE LOWER(email) = LOWER(NEW.email);

    -- 2. Try to call the notification edge function (non-blocking)
    BEGIN
      SELECT nombre INTO _usuario_nombre
      FROM public.usuarios
      WHERE LOWER(email) = LOWER(NEW.email)
      LIMIT 1;

      _supabase_url := 'https://tzmhgfjmddkfyffkkmto.supabase.co';
      _anon_key := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR6bWhnZmptZGRrZnlmZmtrbXRvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTczNTU0NDUsImV4cCI6MjA3MjkzMTQ0NX0.8DaFtWO6zyJg14jFo_Zm2idYKwI-mvfmUtlixG2JDSE';

      PERFORM net.http_post(
        url := _supabase_url || '/functions/v1/notificar-confirmacion-email',
        body := jsonb_build_object('email', NEW.email, 'nombre', COALESCE(_usuario_nombre, 'Usuario')),
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || _anon_key)
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE LOG 'handle_email_confirmation: Could not call notification edge function: %', SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$function$;

-- incrementar_precio_m2_mensual
CREATE OR REPLACE FUNCTION public.incrementar_precio_m2_mensual()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_proyecto RECORD;
    v_nuevo_precio NUMERIC;
    v_todas_vendidas BOOLEAN;
BEGIN
    -- Iterar sobre proyectos activos que tienen precio_m2_actual
    FOR v_proyecto IN 
        SELECT id, precio_m2_actual
        FROM proyectos
        WHERE activo = true 
          AND precio_m2_actual IS NOT NULL
          AND precio_m2_actual > 0
    LOOP
        -- Verificar si TODAS las propiedades del proyecto están en estatus >= 5
        SELECT NOT EXISTS(
            SELECT 1
            FROM propiedades p
            JOIN entidades_relacionadas er ON p.id_entidad_relacionada_dueno = er.id
            WHERE er.id_proyecto = v_proyecto.id
              AND p.activo = true
              AND p.id_estatus_disponibilidad < 5
        ) INTO v_todas_vendidas;
        
        -- Si todas están vendidas/apartadas, incrementar el precio
        IF v_todas_vendidas THEN
            -- Incrementar 10/12 = 0.833333% y redondear a 2 decimales
            v_nuevo_precio := ROUND(v_proyecto.precio_m2_actual * 1.00833333, 2);
            
            UPDATE proyectos
            SET precio_m2_actual = v_nuevo_precio,
                fecha_actualizacion = CURRENT_TIMESTAMP
            WHERE id = v_proyecto.id;
            
            RAISE NOTICE 'Proyecto %: precio_m2_actual actualizado de % a %', 
                v_proyecto.id, v_proyecto.precio_m2_actual, v_nuevo_precio;
        END IF;
    END LOOP;
END;
$function$;

-- insertar_pago_stp
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

-- is_admin_user
CREATE OR REPLACE FUNCTION public.is_admin_user()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM usuarios 
    WHERE auth_user_id = auth.uid() 
    AND rol_id IN (1, 2)
  )
$function$;

-- is_inmob_agent_owner
CREATE OR REPLACE FUNCTION public.is_inmob_agent_owner(target_email text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH actor AS (
    SELECT u.id_persona, u.rol_id, u.email
    FROM public.usuarios u
    WHERE u.activo = true
      AND (
        u.auth_user_id = auth.uid()
        OR lower(u.email) = lower(auth.jwt() ->> 'email')
      )
    ORDER BY CASE WHEN u.auth_user_id = auth.uid() THEN 0 ELSE 1 END
    LIMIT 1
  ),
  owner_candidates AS (
    -- Super Admin y Admin Proyecto: acceso total
    SELECT -1::bigint AS owner_persona
    FROM actor a
    WHERE a.rol_id IN (1, 2)

    UNION

    -- Agentes: resolver inmobiliaria dueña por relación tipo 19
    SELECT er.id_persona_duena_lead::bigint AS owner_persona
    FROM actor a
    JOIN public.entidades_relacionadas er
      ON er.id_persona = a.id_persona
     AND er.id_tipo_entidad = 19
     AND er.activo = true
    WHERE a.rol_id IN (3, 9)
      AND er.id_persona_duena_lead IS NOT NULL

    UNION

    -- Usuario inmobiliaria: usar su id_persona SOLO si realmente tiene agentes vinculados
    SELECT a.id_persona::bigint AS owner_persona
    FROM actor a
    WHERE a.rol_id = 4
      AND a.id_persona IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM public.entidades_relacionadas er_check
        WHERE er_check.id_tipo_entidad = 19
          AND er_check.activo = true
          AND er_check.id_persona_duena_lead = a.id_persona
      )

    UNION

    -- Fallback por proyectos_acceso para contextos de inmobiliaria secundaria
    SELECT er_owner.id_persona::bigint AS owner_persona
    FROM actor a
    JOIN public.proyectos_acceso pa
      ON lower(pa.usuario_id) = lower(a.email)
     AND pa.activo = true
     AND pa.id_entidad_relacionada_dueno IS NOT NULL
    JOIN public.entidades_relacionadas er_owner
      ON er_owner.id = pa.id_entidad_relacionada_dueno
     AND er_owner.id_tipo_entidad = 5
     AND er_owner.activo = true
  )
  SELECT EXISTS (
    SELECT 1
    FROM owner_candidates oc
    WHERE oc.owner_persona IS NOT NULL
      AND (
        oc.owner_persona = -1
        OR EXISTS (
          SELECT 1
          FROM public.entidades_relacionadas er_agent
          JOIN public.usuarios u_agent ON u_agent.id_persona = er_agent.id_persona
          WHERE er_agent.id_tipo_entidad = 19
            AND er_agent.activo = true
            AND er_agent.id_persona_duena_lead = oc.owner_persona
            AND lower(u_agent.email) = lower(trim(target_email))
        )
      )
  );
$function$;

-- is_super_admin
CREATE OR REPLACE FUNCTION public.is_super_admin(user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM usuarios u
    JOIN roles r ON u.rol_id = r.id
    WHERE u.auth_user_id = user_id
      AND r.nombre = 'Super Administrador'
  )
$function$;

-- is_super_admin
CREATE OR REPLACE FUNCTION public.is_super_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM usuarios u
    JOIN roles r ON r.id = u.rol_id
    WHERE u.email = auth.email()
    AND r.nombre = 'Super Administrador'
  )
$function$;

-- mark_email_confirmed
CREATE OR REPLACE FUNCTION public.mark_email_confirmed()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  user_email text;
BEGIN
  -- Get email from JWT claim directly (more reliable than querying auth.users)
  user_email := current_setting('request.jwt.claims', true)::json->>'email';
  
  IF user_email IS NOT NULL THEN
    UPDATE usuarios
    SET email_confirmado = true, fecha_actualizacion = now()
    WHERE LOWER(email) = LOWER(user_email)
      AND email_confirmado = false;
  END IF;
END;
$function$;

-- mark_password_changed
CREATE OR REPLACE FUNCTION public.mark_password_changed()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  UPDATE usuarios SET debe_cambiar_password = false,
    ultimo_cambio_password = NOW(), fecha_actualizacion = NOW()
  WHERE auth_user_id = auth.uid();
END; $function$;

-- recalcular_pago_completado_acuerdos
CREATE OR REPLACE FUNCTION public.recalcular_pago_completado_acuerdos(p_id_cuenta_cobranza integer DEFAULT NULL::integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  n_actualizados integer := 0;
BEGIN
  WITH totales AS (
    SELECT
      ap.id AS id_acuerdo,
      ap.monto AS monto_requerido,
      ap.pago_completado AS flag_actual,
      COALESCE((
        SELECT SUM(apl.monto)
        FROM public.aplicaciones_pago apl
        WHERE apl.id_acuerdo_pago = ap.id
          AND apl.activo = true
          AND apl.es_multa = false
      ), 0) AS total_aplicado
    FROM public.acuerdos_pago ap
    WHERE ap.activo = true
      AND (p_id_cuenta_cobranza IS NULL OR ap.id_cuenta_cobranza = p_id_cuenta_cobranza)
  ),
  cambios AS (
    UPDATE public.acuerdos_pago ap
    SET pago_completado = (t.total_aplicado >= t.monto_requerido - 0.01)
    FROM totales t
    WHERE ap.id = t.id_acuerdo
      AND ap.pago_completado IS DISTINCT FROM (t.total_aplicado >= t.monto_requerido - 0.01)
    RETURNING 1
  )
  SELECT COUNT(*) INTO n_actualizados FROM cambios;

  RETURN n_actualizados;
END;
$function$;

-- regenerar_clabes_faltantes
CREATE OR REPLACE FUNCTION public.regenerar_clabes_faltantes(p_id_proyecto integer DEFAULT NULL::integer, p_id_entidad integer DEFAULT NULL::integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE 
  r RECORD; 
  n INT := 0;
BEGIN
  FOR r IN 
    SELECT p.id, p.id_entidad_relacionada_dueno::int AS id_er
    FROM propiedades p
    JOIN entidades_relacionadas er ON er.id = p.id_entidad_relacionada_dueno
    WHERE p.activo = true
      AND (p.clabe_stp_tmp_apartado IS NULL 
           OR p.clabe_stp_tmp_apartado LIKE '%\_TMP' ESCAPE '\')
      AND er.cuenta_madre_stp IS NOT NULL
      AND (p_id_proyecto IS NULL OR er.id_proyecto = p_id_proyecto)
      AND (p_id_entidad IS NULL OR p.id_entidad_relacionada_dueno = p_id_entidad)
    ORDER BY p.id
  LOOP
    UPDATE propiedades 
    SET clabe_stp_tmp_apartado = crear_referencia_bancaria(r.id_er)
    WHERE id = r.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END $function$;

-- scan_legacy_urls
CREATE OR REPLACE FUNCTION public.scan_legacy_urls()
 RETURNS TABLE(tabla text, columna text, pendientes bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET statement_timeout TO '300s'
AS $function$
DECLARE
  r record;
  cnt bigint;
BEGIN
  FOR r IN
    SELECT c.table_name, c.column_name
    FROM information_schema.columns c
    JOIN information_schema.tables t
      ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE c.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
      AND c.data_type IN ('text','character varying')
      AND (
        c.column_name ILIKE '%url%' OR c.column_name ILIKE '%logo%'
        OR c.column_name ILIKE '%foto%' OR c.column_name ILIKE '%imagen%'
        OR c.column_name ILIKE '%image%' OR c.column_name ILIKE '%portada%'
        OR c.column_name ILIKE '%brochure%' OR c.column_name ILIKE '%plano%'
        OR c.column_name ILIKE '%archivo%' OR c.column_name ILIKE '%documento%'
        OR c.column_name ILIKE '%file%' OR c.column_name ILIKE '%avatar%'
        OR c.column_name ILIKE '%pdf%' OR c.column_name ILIKE '%video%'
        OR c.column_name ILIKE '%media%' OR c.column_name ILIKE '%adjunto%'
        OR c.column_name ILIKE '%comprobante%' OR c.column_name ILIKE '%evidencia%'
        OR c.column_name ILIKE '%firma%' OR c.column_name ILIKE '%ine%'
        OR c.column_name ILIKE '%path%' OR c.column_name ILIKE '%link%'
      )
  LOOP
    BEGIN
      EXECUTE format(
        'SELECT count(*) FROM public.%I WHERE %I LIKE %L',
        r.table_name, r.column_name, '%api.sozu.com%'
      ) INTO cnt;
      IF cnt > 0 THEN
        tabla := r.table_name; columna := r.column_name; pendientes := cnt;
        RETURN NEXT;
      END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
END;
$function$;

-- set_avisos_proyectos_updated_at
CREATE OR REPLACE FUNCTION public.set_avisos_proyectos_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  new.fecha_actualizacion = now();
  return new;
end;
$function$;

-- sync_conyuge_compradores
CREATE OR REPLACE FUNCTION public.sync_conyuge_compradores(p_id_persona integer)
 RETURNS TABLE(mensaje text, cuentas_procesadas integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_id_conyuge INTEGER;
    v_cuenta_record RECORD;
    v_nuevo_porcentaje NUMERIC;
    v_existe_conyuge BOOLEAN;
    v_existe_persona_original BOOLEAN;
    v_contador INTEGER := 0;
BEGIN
    -- Obtener id_conyuge de la persona
    SELECT id_conyuge INTO v_id_conyuge
    FROM personas
    WHERE id = p_id_persona
      AND activo = true;

    -- Si no tiene cónyuge, retornar mensaje
    IF v_id_conyuge IS NULL THEN
        RETURN QUERY SELECT 
            'La persona no tiene cónyuge asignado'::TEXT,
            0::INTEGER;
        RETURN;
    END IF;

    -- Verificar que el cónyuge existe y está activo
    IF NOT EXISTS(
        SELECT 1 FROM personas 
        WHERE id = v_id_conyuge 
        AND activo = true
    ) THEN
        RETURN QUERY SELECT 
            'El cónyuge no existe o no está activo'::TEXT,
            0::INTEGER;
        RETURN;
    END IF;

    -- ====================================================================
    -- LOOP 1: Procesar cuentas donde la PERSONA ORIGINAL es compradora
    -- ====================================================================
    FOR v_cuenta_record IN
        SELECT 
            c.id_cuenta_cobranza,
            c.porcentaje_copropiedad
        FROM compradores c
        JOIN cuentas_cobranza cc ON c.id_cuenta_cobranza = cc.id
        JOIN ofertas o ON cc.id_oferta = o.id
        WHERE c.id_persona = p_id_persona
          AND c.activo = true
          AND cc.activo = true
          AND o.id_producto IS NULL  -- Solo propiedades
    LOOP
        -- Verificar si el cónyuge ya existe en esta cuenta
        SELECT EXISTS(
            SELECT 1 
            FROM compradores
            WHERE id_persona = v_id_conyuge
              AND id_cuenta_cobranza = v_cuenta_record.id_cuenta_cobranza
              AND activo = true
        ) INTO v_existe_conyuge;

        IF NOT v_existe_conyuge THEN
            -- Dividir el porcentaje actual
            v_nuevo_porcentaje := v_cuenta_record.porcentaje_copropiedad / 2;

            -- Actualizar el porcentaje de la persona original
            UPDATE compradores
            SET porcentaje_copropiedad = v_nuevo_porcentaje,
                fecha_actualizacion = CURRENT_TIMESTAMP
            WHERE id_persona = p_id_persona
              AND id_cuenta_cobranza = v_cuenta_record.id_cuenta_cobranza
              AND activo = true;

            -- Insertar el cónyuge con el otro 50%
            INSERT INTO compradores (
                id_cuenta_cobranza,
                id_persona,
                porcentaje_copropiedad,
                activo,
                fecha_creacion,
                fecha_actualizacion
            ) VALUES (
                v_cuenta_record.id_cuenta_cobranza,
                v_id_conyuge,
                v_nuevo_porcentaje,
                true,
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP
            );
            
            v_contador := v_contador + 1;
        END IF;
    END LOOP;

    -- ====================================================================
    -- LOOP 2: Procesar cuentas donde el CÓNYUGE es comprador
    -- ====================================================================
    FOR v_cuenta_record IN
        SELECT 
            c.id_cuenta_cobranza,
            c.porcentaje_copropiedad
        FROM compradores c
        JOIN cuentas_cobranza cc ON c.id_cuenta_cobranza = cc.id
        JOIN ofertas o ON cc.id_oferta = o.id
        WHERE c.id_persona = v_id_conyuge
          AND c.activo = true
          AND cc.activo = true
          AND o.id_producto IS NULL  -- Solo propiedades
    LOOP
        -- Verificar si la persona original ya existe en esta cuenta del cónyuge
        SELECT EXISTS(
            SELECT 1 
            FROM compradores
            WHERE id_persona = p_id_persona
              AND id_cuenta_cobranza = v_cuenta_record.id_cuenta_cobranza
              AND activo = true
        ) INTO v_existe_persona_original;

        IF NOT v_existe_persona_original THEN
            -- Dividir el porcentaje del cónyuge
            v_nuevo_porcentaje := v_cuenta_record.porcentaje_copropiedad / 2;

            -- Actualizar el porcentaje del cónyuge
            UPDATE compradores
            SET porcentaje_copropiedad = v_nuevo_porcentaje,
                fecha_actualizacion = CURRENT_TIMESTAMP
            WHERE id_persona = v_id_conyuge
              AND id_cuenta_cobranza = v_cuenta_record.id_cuenta_cobranza
              AND activo = true;

            -- Insertar la persona original con el otro 50%
            INSERT INTO compradores (
                id_cuenta_cobranza,
                id_persona,
                porcentaje_copropiedad,
                activo,
                fecha_creacion,
                fecha_actualizacion
            ) VALUES (
                v_cuenta_record.id_cuenta_cobranza,
                p_id_persona,
                v_nuevo_porcentaje,
                true,
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP
            );
            
            v_contador := v_contador + 1;
        END IF;
    END LOOP;

    -- Retornar resultado
    RETURN QUERY SELECT 
        format('Sincronización completada. %s cuentas procesadas.', v_contador)::TEXT,
        v_contador::INTEGER;
END;
$function$;

-- sync_inmobiliaria_project_access
CREATE OR REPLACE FUNCTION public.sync_inmobiliaria_project_access()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  inmobiliaria_persona_id INT;
  agent_email TEXT;
  target_usuario_id TEXT;
  target_proyecto_id INT;
  target_activo BOOLEAN;
  target_dueno_id INT;
BEGIN
  -- Determine which record to use
  IF TG_OP = 'DELETE' THEN
    target_usuario_id := OLD.usuario_id;
    target_proyecto_id := OLD.proyecto_id;
  ELSE
    target_usuario_id := NEW.usuario_id;
    target_proyecto_id := NEW.proyecto_id;
    target_activo := NEW.activo;
    target_dueno_id := NEW.id_entidad_relacionada_dueno;
  END IF;

  -- Check if the user is an Inmobiliaria (rol_id = 4)
  SELECT p.id INTO inmobiliaria_persona_id
  FROM usuarios u
  JOIN personas p ON p.email = u.email
  WHERE u.email = target_usuario_id
  AND u.rol_id = 4
  AND u.activo = true;

  -- Only proceed if this is an inmobiliaria user
  IF inmobiliaria_persona_id IS NOT NULL THEN
    
    -- Handle INSERT or UPDATE
    IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
      -- Find ALL agents linked to this inmobiliaria via entidades_relacionadas
      FOR agent_email IN
        SELECT u.email
        FROM entidades_relacionadas er
        JOIN personas p ON p.id = er.id_persona
        JOIN usuarios u ON u.email = p.email
        WHERE er.id_persona_duena_lead = inmobiliaria_persona_id
        AND er.id_tipo_entidad = 19 -- Agente entity type
        AND er.activo = true
        AND u.rol_id IN (3, 9) -- Agente Inmobiliario AND Agente Interno
        AND u.activo = true
      LOOP
        -- Upsert the agent's project access with same values as inmobiliaria
        INSERT INTO proyectos_acceso (usuario_id, proyecto_id, id_entidad_relacionada_dueno, activo)
        VALUES (agent_email, target_proyecto_id, target_dueno_id, target_activo)
        ON CONFLICT (usuario_id, proyecto_id) 
        DO UPDATE SET 
          id_entidad_relacionada_dueno = EXCLUDED.id_entidad_relacionada_dueno,
          activo = EXCLUDED.activo,
          fecha_actualizacion = now();
      END LOOP;
    END IF;

    -- Handle DELETE - also delete from agents
    IF TG_OP = 'DELETE' THEN
      FOR agent_email IN
        SELECT u.email
        FROM entidades_relacionadas er
        JOIN personas p ON p.id = er.id_persona
        JOIN usuarios u ON u.email = p.email
        WHERE er.id_persona_duena_lead = inmobiliaria_persona_id
        AND er.id_tipo_entidad = 19
        AND er.activo = true
        AND u.rol_id IN (3, 9)
        AND u.activo = true
      LOOP
        DELETE FROM proyectos_acceso 
        WHERE usuario_id = agent_email 
        AND proyecto_id = target_proyecto_id;
      END LOOP;
    END IF;
  END IF;

  -- Return appropriate value
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$function$;

-- tg_set_aviso_evento_updated
CREATE OR REPLACE FUNCTION public.tg_set_aviso_evento_updated()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.fecha_actualizacion = now();
  RETURN NEW;
END;
$function$;

-- trigger_check_escrituracion
CREATE OR REPLACE FUNCTION public.trigger_check_escrituracion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id_cuenta_cobranza INTEGER;
  v_request_id BIGINT;
  v_supabase_url TEXT := 'https://tzmhgfjmddkfyffkkmto.supabase.co';
  v_anon_key TEXT := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR6bWhnZmptZGRrZnlmZmtrbXRvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTczNTU0NDUsImV4cCI6MjA3MjkzMTQ0NX0.8DaFtWO6zyJg14jFo_Zm2idYKwI-mvfmUtlixG2JDSE';
BEGIN
  -- Solo procesar cuando el estatus cambia a Validado (2)
  IF NEW.id_estatus_verificacion = 2 AND (OLD.id_estatus_verificacion IS NULL OR OLD.id_estatus_verificacion != 2) THEN
    
    -- CASO 1: Documento asociado directamente a una cuenta de cobranza
    IF NEW.id_cuenta_cobranza IS NOT NULL THEN
      RAISE LOG '[TRIGGER] Documento % verificado para cuenta_cobranza %', NEW.id, NEW.id_cuenta_cobranza;
      
      SELECT net.http_post(
        url := v_supabase_url || '/functions/v1/check-property-escrituracion-status',
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_anon_key),
        body := jsonb_build_object('id_cuenta_cobranza', NEW.id_cuenta_cobranza)
      ) INTO v_request_id;
      
      RAISE LOG '[TRIGGER] HTTP request enviado para cuenta %: request_id=%', NEW.id_cuenta_cobranza, v_request_id;
    
    -- CASO 2: Documento asociado a una persona (buscar sus cuentas como comprador)
    ELSIF NEW.id_persona IS NOT NULL THEN
      RAISE LOG '[TRIGGER] Documento % verificado para persona %', NEW.id, NEW.id_persona;
      
      FOR v_id_cuenta_cobranza IN 
        SELECT DISTINCT comp.id_cuenta_cobranza
        FROM compradores comp
        WHERE comp.id_persona = NEW.id_persona AND comp.activo = true
      LOOP
        SELECT net.http_post(
          url := v_supabase_url || '/functions/v1/check-property-escrituracion-status',
          headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_anon_key),
          body := jsonb_build_object('id_cuenta_cobranza', v_id_cuenta_cobranza)
        ) INTO v_request_id;
        
        RAISE LOG '[TRIGGER] HTTP request enviado para cuenta %: request_id=%', v_id_cuenta_cobranza, v_request_id;
      END LOOP;
    END IF;
  END IF;
  
  RETURN NEW;
END;
$function$;

-- trigger_check_property_sold_status
CREATE OR REPLACE FUNCTION public.trigger_check_property_sold_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id_propiedad INTEGER;
  v_cuenta_cobranza_id INTEGER;
  v_request_id BIGINT;
  v_supabase_url TEXT := 'https://tzmhgfjmddkfyffkkmto.supabase.co';
  v_anon_key TEXT := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR6bWhnZmptZGRrZnlmZmtrbXRvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTczNTU0NDUsImV4cCI6MjA3MjkzMTQ0NX0.8DaFtWO6zyJg14jFo_Zm2idYKwI-mvfmUtlixG2JDSE';
BEGIN
  -- Solo ejecutar cuando pago_completado cambia a TRUE
  IF NEW.pago_completado = TRUE AND (OLD.pago_completado = FALSE OR OLD.pago_completado IS NULL) THEN
    
    v_cuenta_cobranza_id := NEW.id_cuenta_cobranza;
    
    -- Verificar si la cuenta de cobranza está relacionada con una propiedad
    SELECT o.id_propiedad INTO v_id_propiedad
    FROM cuentas_cobranza cc
    JOIN ofertas o ON cc.id_oferta = o.id
    WHERE cc.id = v_cuenta_cobranza_id
      AND o.id_propiedad IS NOT NULL
      AND cc.activo = TRUE;
    
    -- Solo llamar al Edge Function si es una cuenta de propiedad
    IF v_id_propiedad IS NOT NULL THEN
      RAISE LOG '[TRIGGER] Llamando a check-property-sold-status para cuenta % (propiedad %)', 
        v_cuenta_cobranza_id, v_id_propiedad;
      
      -- Hacer HTTP POST request al Edge Function usando pg_net
      SELECT net.http_post(
        url := v_supabase_url || '/functions/v1/check-property-sold-status',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || v_anon_key
        ),
        body := jsonb_build_object(
          'id_cuenta_cobranza', v_cuenta_cobranza_id
        )
      ) INTO v_request_id;
      
      RAISE LOG '[TRIGGER] HTTP request enviado con ID: %', v_request_id;
    ELSE
      RAISE LOG '[TRIGGER] Cuenta % no es de propiedad, omitiendo llamada a Edge Function', 
        v_cuenta_cobranza_id;
    END IF;
  END IF;
  
  RETURN NEW;
END;
$function$;

-- trigger_document_insert_sat
CREATE OR REPLACE FUNCTION public.trigger_document_insert_sat()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cuenta_id INTEGER;
BEGIN
  -- Solo procesar documentos relevantes (constancia fiscal o facturas)
  IF NEW.id_tipo_documento NOT IN (6, 21, 22) THEN
    RETURN NEW;
  END IF;
  
  -- Para UPDATE, solo procesar si cambió algo relevante
  IF TG_OP = 'UPDATE' THEN
    -- Ignorar si no cambió nada importante
    IF OLD.id_persona = NEW.id_persona 
       AND OLD.id_estatus_verificacion = NEW.id_estatus_verificacion 
       AND OLD.activo = NEW.activo 
       AND OLD.id_cuenta_cobranza = NEW.id_cuenta_cobranza THEN
      RETURN NEW;
    END IF;
  END IF;
  
  -- Solo procesar si el documento está activo
  IF NEW.activo = false THEN
    RETURN NEW;
  END IF;
  
  -- Determinar la cuenta de cobranza
  IF NEW.id_cuenta_cobranza IS NOT NULL THEN
    v_cuenta_id := NEW.id_cuenta_cobranza;
  ELSIF NEW.id_persona IS NOT NULL THEN
    -- Buscar cuenta del comprador por persona
    SELECT c.id_cuenta_cobranza INTO v_cuenta_id
    FROM public.compradores c
    WHERE c.id_persona = NEW.id_persona AND c.activo = true
    LIMIT 1;
  END IF;
  
  IF v_cuenta_id IS NOT NULL THEN
    PERFORM public.check_sat_notification_conditions(v_cuenta_id);
  END IF;
  
  RETURN NEW;
END;
$function$;

-- trigger_property_status_sat
CREATE OR REPLACE FUNCTION public.trigger_property_status_sat()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cuenta_id INTEGER;
BEGIN
  -- Solo procesar si el nuevo estatus es 9 (Pagada completamente)
  -- y el anterior era diferente de 9
  IF NEW.id_estatus_disponibilidad = 9 AND 
     (OLD.id_estatus_disponibilidad IS NULL OR OLD.id_estatus_disponibilidad <> 9) THEN
    
    -- Buscar la cuenta de cobranza activa de esta propiedad
    SELECT cc.id INTO v_cuenta_id
    FROM public.cuentas_cobranza cc
    JOIN public.ofertas o ON cc.id_oferta = o.id
    WHERE o.id_propiedad = NEW.id AND cc.activo = true
    LIMIT 1;
    
    IF v_cuenta_id IS NOT NULL THEN
      PERFORM public.check_sat_notification_conditions(v_cuenta_id);
    END IF;
  END IF;
  
  RETURN NEW;
END;
$function$;

-- update_citas_capacitacion_timestamp
CREATE OR REPLACE FUNCTION public.update_citas_capacitacion_timestamp()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.fecha_actualizacion = now();
  RETURN NEW;
END;
$function$;

-- update_modelos_planos_arquitectonicos_updated_at
CREATE OR REPLACE FUNCTION public.update_modelos_planos_arquitectonicos_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$;

-- update_updated_at_column
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF to_jsonb(NEW) ? 'fecha_actualizacion' THEN
    NEW := jsonb_populate_record(NEW, jsonb_build_object('fecha_actualizacion', CURRENT_TIMESTAMP));
  ELSIF to_jsonb(NEW) ? 'updated_at' THEN
    NEW := jsonb_populate_record(NEW, jsonb_build_object('updated_at', CURRENT_TIMESTAMP));
  END IF;
  RETURN NEW;
END;
$function$;

-- user_can_access_report
CREATE OR REPLACE FUNCTION public.user_can_access_report(_reporte_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    _rol_id INTEGER;
    _rol_nombre TEXT;
    _has_access BOOLEAN;
BEGIN
    -- Get current user's role using auth_user_id (más confiable que email)
    SELECT u.rol_id, r.nombre INTO _rol_id, _rol_nombre
    FROM usuarios u
    JOIN roles r ON r.id = u.rol_id
    WHERE u.auth_user_id = auth.uid()
    AND u.activo = true;
    
    -- Si no encontró el usuario, intentar con email como fallback
    IF _rol_id IS NULL THEN
        SELECT u.rol_id, r.nombre INTO _rol_id, _rol_nombre
        FROM usuarios u
        JOIN roles r ON r.id = u.rol_id
        WHERE u.email = auth.email()
        AND u.activo = true;
    END IF;
    
    -- Super Admin has access to everything
    IF _rol_nombre = 'Super Administrador' THEN
        RETURN TRUE;
    END IF;
    
    -- Check if role has access to this specific report
    SELECT EXISTS (
        SELECT 1
        FROM roles_reportes
        WHERE rol_id = _rol_id
        AND reporte_id = _reporte_id
        AND activo = true
    ) INTO _has_access;
    
    RETURN COALESCE(_has_access, FALSE);
END;
$function$;

-- user_has_internal_role
CREATE OR REPLACE FUNCTION public.user_has_internal_role(_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM usuarios u
    JOIN roles r ON r.id = u.rol_id
    WHERE u.auth_user_id = _user_id
    AND r.es_rol_interno = true
  );
$function$;

-- user_has_permission
CREATE OR REPLACE FUNCTION public.user_has_permission(_submenu_path text, _permission_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM usuarios u
    JOIN menus_roles mr ON u.rol_id = mr.rol_id AND mr.activo = true
    JOIN submenus s ON s.menu_id = mr.menu_id
    JOIN submenus_permisos sp ON sp.submenu_id = s.id AND sp.rol_id = u.rol_id AND sp.activo = true
    JOIN permisos perm ON perm.id = sp.permiso_id
    WHERE u.auth_user_id = auth.uid() AND s.vista_front_end = _submenu_path
    AND perm.nombre = _permission_name AND u.activo = true
  );
END; $function$;

-- user_has_role
CREATE OR REPLACE FUNCTION public.user_has_role(_email text, _rol_id integer)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE lower(email) = lower(btrim(_email))
      AND rol_id = _rol_id
      AND activo = true
  );
$function$;

-- user_roles_normalize_email
CREATE OR REPLACE FUNCTION public.user_roles_normalize_email()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.email := lower(btrim(NEW.email));
  NEW.fecha_actualizacion := now();
  RETURN NEW;
END;
$function$;

-- validar_mensajes_whatsapp
CREATE OR REPLACE FUNCTION public.validar_mensajes_whatsapp(_mensajes jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
declare
  total_count integer;
  distinct_count integer;
begin
  if _mensajes is null then
    return true;
  end if;

  if jsonb_typeof(_mensajes) <> 'array' then
    return false;
  end if;

  total_count := jsonb_array_length(_mensajes);
  if total_count <> 3 then
    return false;
  end if;

  if exists (
    select 1
    from jsonb_array_elements_text(_mensajes) as item(value)
    where btrim(value) = ''
  ) then
    return false;
  end if;

  select count(distinct lower(btrim(value)))
  into distinct_count
  from jsonb_array_elements_text(_mensajes) as item(value);

  return distinct_count = 3;
end;
$function$;

-- verificar_multa_completada
CREATE OR REPLACE FUNCTION public.verificar_multa_completada()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_monto_multa NUMERIC;
    v_suma_aplicaciones NUMERIC;
    v_id_multa INTEGER;
BEGIN
    -- Solo proceder si es una aplicación de pago de multa y está activa
    IF NEW.es_multa = FALSE OR NEW.activo = FALSE THEN
        RETURN NEW;
    END IF;

    -- Obtener el monto total de la multa y su ID
    SELECT m.monto, m.id
    INTO v_monto_multa, v_id_multa
    FROM multas m
    WHERE m.id_acuerdo_pago = NEW.id_acuerdo_pago
      AND m.activo = TRUE
    LIMIT 1;

    -- Si no existe la multa, salir
    IF v_monto_multa IS NULL THEN
        RAISE NOTICE 'No se encontró multa activa para id_acuerdo_pago=%', NEW.id_acuerdo_pago;
        RETURN NEW;
    END IF;

    -- Calcular la suma de todas las aplicaciones de pago para esta multa
    SELECT COALESCE(SUM(ap.monto), 0)
    INTO v_suma_aplicaciones
    FROM aplicaciones_pago ap
    WHERE ap.id_acuerdo_pago = NEW.id_acuerdo_pago
      AND ap.es_multa = TRUE
      AND ap.activo = TRUE;

    RAISE NOTICE 'Multa ID=%: Monto total=$%, Suma aplicaciones=$%', 
        v_id_multa, v_monto_multa, v_suma_aplicaciones;

    -- Si la suma de aplicaciones es mayor o igual al monto de la multa
    IF v_suma_aplicaciones >= v_monto_multa THEN
        -- Actualizar multas.es_pagada = TRUE
        UPDATE multas
        SET es_pagada = TRUE,
            fecha_actualizacion = CURRENT_TIMESTAMP
        WHERE id_acuerdo_pago = NEW.id_acuerdo_pago
          AND activo = TRUE;

        -- Actualizar acuerdos_pago.pago_completado = TRUE
        UPDATE acuerdos_pago
        SET pago_completado = TRUE,
            fecha_actualizacion = CURRENT_TIMESTAMP
        WHERE id = NEW.id_acuerdo_pago
          AND activo = TRUE;

        RAISE NOTICE 'Multa ID=% completamente pagada. Actualizado es_pagada y pago_completado a TRUE', 
            v_id_multa;
    ELSE
        RAISE NOTICE 'Multa ID=% aún no está completamente pagada. Falta: $%', 
            v_id_multa, v_monto_multa - v_suma_aplicaciones;
    END IF;

    RETURN NEW;
END;
$function$;

-- verificar_propiedad_vendida
CREATE OR REPLACE FUNCTION public.verificar_propiedad_vendida()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_propiedad_id INTEGER;
    tiene_contrato_verificado BOOLEAN := FALSE;
    tiene_enganche_pagado BOOLEAN := FALSE;
    v_id_edificio_modelo INTEGER;
BEGIN
    IF TG_TABLE_NAME = 'documentos' THEN
        v_propiedad_id := NEW.id_propiedad;
    ELSIF TG_TABLE_NAME = 'acuerdos_pago' THEN
        SELECT o.id_propiedad INTO v_propiedad_id
        FROM acuerdos_pago ap
        JOIN cuentas_cobranza cc ON ap.id_cuenta_cobranza = cc.id
        JOIN ofertas o ON cc.id_oferta = o.id
        WHERE ap.id = NEW.id;
    END IF;

    SELECT id_edificio_modelo INTO v_id_edificio_modelo FROM propiedades WHERE id = v_propiedad_id;
    IF v_id_edificio_modelo IS NULL THEN RETURN NEW; END IF;

    SELECT EXISTS(
        SELECT 1 FROM documentos 
        WHERE id_propiedad = v_propiedad_id AND id_tipo_documento = 18 
        AND id_estatus_verificacion = 2 AND activo = TRUE
    ) INTO tiene_contrato_verificado;

    SELECT EXISTS(
        SELECT 1 FROM acuerdos_pago ap
        JOIN cuentas_cobranza cc ON ap.id_cuenta_cobranza = cc.id
        JOIN ofertas o ON cc.id_oferta = o.id
        WHERE o.id_propiedad = v_propiedad_id AND ap.id_concepto = 2 
        AND ap.pago_completado = TRUE AND ap.activo = TRUE
    ) INTO tiene_enganche_pagado;

    IF tiene_contrato_verificado AND tiene_enganche_pagado THEN
        UPDATE propiedades SET id_estatus_disponibilidad = 5 WHERE id = v_propiedad_id;
        UPDATE cuentas_cobranza SET fecha_compra = CURRENT_DATE
        WHERE id IN (SELECT cc.id FROM cuentas_cobranza cc JOIN ofertas o ON cc.id_oferta = o.id WHERE o.id_propiedad = v_propiedad_id AND cc.activo = TRUE);
    END IF;
    RETURN NEW;
END;
$function$;
