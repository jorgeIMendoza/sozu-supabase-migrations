-- Fix: crear_referencia_bancaria numeraba el consecutivo POR PROYECTO, no por
-- cuenta madre STP. Como una misma cuenta_madre_stp (p.ej. la de SOZU,
-- 64618028740005) se comparte entre varios proyectos (Productos, Bottura,
-- Daiku...), cada proyecto reiniciaba la numeración y podía generar CLABEs
-- DUPLICADAS. Ejemplo real detectado: dos entidades Tallwood (proyectos Daiku y
-- Bottura) comparten la CLABE 646180287400050045.
--
-- Solución: contar el consecutivo de forma GLOBAL por cuenta madre, reuniendo
-- TODAS las CLABEs existentes bajo esa madre sin importar proyecto/entidad ni la
-- fuente (comisiones, apartados de propiedad/producto, cuentas de cobranza y
-- mantenimientos). Así el número resultante es único dentro de la cuenta madre.
--
-- Nota: NO modifica datos existentes (la CLABE duplicada 004 se deja como está,
-- por indicación). Solo corrige la generación futura.
--
-- El consecutivo son los 3 dígitos previos al dígito verificador; una CLABE STP
-- válida es cuenta_madre (14) + consecutivo (3) + dígito verificador (1) = 18.

CREATE OR REPLACE FUNCTION public.crear_referencia_bancaria(id_er_dueno integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_madre TEXT;
    v_len INT;
    contador_final INT;
    temp_bank_ref TEXT;
    suma INT := 0;
    digito_verificador INT;
    multiplicadores INT[] := ARRAY[3,7,1,3,7,1,3,7,1,3,7,1,3,7,1,3,7];
    ultimo_consec INT;
    clabe_existe BOOLEAN;
    temp_ref_sin_digito TEXT;
BEGIN
    -- Cuenta madre STP del dueño (id_er_dueno = normalmente la Inmobiliaria del proyecto)
    SELECT NULLIF(TRIM(cuenta_madre_stp), '') INTO v_madre
    FROM entidades_relacionadas
    WHERE id = id_er_dueno;

    IF v_madre IS NULL THEN
        RAISE EXCEPTION 'La entidad relacionada % no tiene cuenta_madre_stp configurada', id_er_dueno;
    END IF;

    v_len := length(v_madre);  -- normalmente 14

    -- Máximo consecutivo YA usado bajo esta cuenta madre, GLOBAL (todos los
    -- proyectos/entidades/fuentes). El filtro por regex asegura que solo se
    -- consideren CLABEs válidas de forma "madre + 3 consecutivo + 1 verificador",
    -- descartando placeholders tipo '..._TMP'.
    WITH todas_clabes AS (
        SELECT cuenta_stp_comisiones AS clabe FROM entidades_relacionadas WHERE cuenta_stp_comisiones IS NOT NULL
        UNION ALL
        SELECT clabe_stp FROM cuentas_cobranza WHERE clabe_stp IS NOT NULL
        UNION ALL
        SELECT clabe_stp_tmp_apartado FROM propiedades WHERE clabe_stp_tmp_apartado IS NOT NULL
        UNION ALL
        SELECT clabe_stp_tmp_producto FROM ofertas WHERE clabe_stp_tmp_producto IS NOT NULL
    )
    SELECT MAX(SUBSTRING(clabe FROM v_len + 1 FOR 3)::INT)
    INTO ultimo_consec
    FROM todas_clabes
    WHERE clabe ~ ('^' || v_madre || '[0-9]{4}$');

    contador_final := COALESCE(ultimo_consec, 0) + 1;

    -- Si se llenó (>=1000), buscar el primer hueco disponible desde 001
    IF contador_final >= 1000 THEN
        contador_final := 1;
        WHILE contador_final < 1000 LOOP
            temp_ref_sin_digito := v_madre || LPAD(contador_final::TEXT, 3, '0');

            SELECT EXISTS(
                WITH todas_clabes_check AS (
                    SELECT cuenta_stp_comisiones AS clabe FROM entidades_relacionadas WHERE cuenta_stp_comisiones IS NOT NULL
                    UNION ALL
                    SELECT clabe_stp FROM cuentas_cobranza WHERE clabe_stp IS NOT NULL
                    UNION ALL
                    SELECT clabe_stp_tmp_apartado FROM propiedades WHERE clabe_stp_tmp_apartado IS NOT NULL
                    UNION ALL
                    SELECT clabe_stp_tmp_producto FROM ofertas WHERE clabe_stp_tmp_producto IS NOT NULL
                )
                SELECT 1 FROM todas_clabes_check WHERE clabe LIKE temp_ref_sin_digito || '%'
            ) INTO clabe_existe;

            IF NOT clabe_existe THEN
                EXIT;
            END IF;

            contador_final := contador_final + 1;
        END LOOP;

        IF contador_final >= 1000 THEN
            RAISE EXCEPTION 'SIN_HUECOS_DISPONIBLES: Todos los números del 001 al 999 están ocupados para la cuenta madre %', v_madre;
        END IF;
    END IF;

    -- Referencia sin dígito verificador
    temp_bank_ref := v_madre || LPAD(contador_final::TEXT, 3, '0');

    -- Dígito verificador (mismo algoritmo que la versión previa)
    FOR i IN 1..17 LOOP
        suma := suma + ((CAST(SUBSTRING(temp_bank_ref, i, 1) AS INT) * multiplicadores[i]) % 10);
    END LOOP;

    digito_verificador := (10 - (suma % 10)) % 10;

    RETURN temp_bank_ref || digito_verificador::TEXT;
END;
$function$;
