-- Paso 1: Habilitar pg_net (extensión para HTTP desde PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Paso 2: Tabla de configuración para guardar el service_role_key
-- No requiere permisos especiales. Solo el rol postgres puede leerla (SECURITY DEFINER).
CREATE TABLE IF NOT EXISTS private.sozu_config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Ejecutar esto UNA SOLA VEZ para guardar el key
-- (reemplazar con el valor real de Dashboard → Settings → API → "service_role")
-- INSERT INTO private.sozu_config (key, value) VALUES ('edge_function_key', '<SERVICE_ROLE_KEY>');

-- Paso 3: Función auxiliar para leer el key de forma segura
CREATE OR REPLACE FUNCTION private.get_edge_function_key()
RETURNS TEXT AS $$
    SELECT value FROM private.sozu_config WHERE key = 'edge_function_key' LIMIT 1;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- Paso 4: Modificar verificar_propiedad_vendida para llamar a la edge function
CREATE OR REPLACE FUNCTION public.verificar_propiedad_vendida()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_propiedad_id INTEGER;
    tiene_contrato_verificado BOOLEAN := FALSE;
    tiene_enganche_pagado BOOLEAN := FALSE;
    v_id_edificio_modelo INTEGER;
    v_cuenta_id INTEGER;
    v_key TEXT;
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
        WHERE id IN (
            SELECT cc.id FROM cuentas_cobranza cc
            JOIN ofertas o ON cc.id_oferta = o.id
            WHERE o.id_propiedad = v_propiedad_id AND cc.activo = TRUE
        );

        -- Obtener la cuenta de cobranza principal
        SELECT cc.id INTO v_cuenta_id
        FROM cuentas_cobranza cc
        JOIN ofertas o ON cc.id_oferta = o.id
        WHERE o.id_propiedad = v_propiedad_id
          AND cc.activo = TRUE
          AND cc.id_cuenta_cobranza_padre IS NULL
        ORDER BY cc.id DESC
        LIMIT 1;

        -- Llamar a la edge function (fire and forget)
        IF v_cuenta_id IS NOT NULL THEN
            v_key := private.get_edge_function_key();
            IF v_key IS NOT NULL THEN
                PERFORM net.http_post(
                    url     := 'https://tzmhgfjmddkfyffkkmto.supabase.co/functions/v1/generar-factura-comision-sozu',
                    headers := jsonb_build_object(
                        'Content-Type',  'application/json',
                        'Authorization', 'Bearer ' || v_key
                    ),
                    body    := jsonb_build_object('id_cuenta_cobranza', v_cuenta_id)
                );
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;
