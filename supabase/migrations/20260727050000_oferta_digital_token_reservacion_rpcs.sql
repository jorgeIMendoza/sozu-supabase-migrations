-- =============================================================================
-- Oferta digital + apartado provisional — token de reservación y RPCs públicas
--
--   1. reservaciones.token (uuid, único)         → credencial del link público
--   2. Cierre total del acceso de anon a reservaciones (REVOKE + DROP POLICY)
--   3. get_apartado_status(p_oferta_id, p_token) → estado del pago
--   4. update_lead_datos(..., p_token)           → datos del lead de la oferta
--   5. get_reservacion_publica(p_token)          → lectura del apartado provisional
--      guardar_datos_reservacion(p_token, ...)   → captura de datos del cliente
--   6. Guards de sobrecargas
--   7. Bloque self-verifying
--
-- Verificado read-only contra prod el 2026-07-27:
--   · Ninguna de las 4 funciones existe con ninguna firma.
--   · reservaciones: 178 filas, todas estatus='pendiente', activo=true,
--     fecha_expiracion NULL, 177 sin id_persona.
--   · PG 17.4 → gen_random_uuid() es nativa, no requiere pgcrypto.
--   · tipos_entidad.id = 7 es 'Prospecto'.
--   · tipo_persona vivo: 'pf' (1659) / 'pm' (1150).
--
-- Correcciones respecto al spec, contra el esquema real:
--   a) ofertas NO tiene id_proyecto. El proyecto se resuelve por
--      propiedades.id_edificio_modelo → edificios_modelos.id_edificio →
--      edificios.id_proyecto (resuelve 178/178 reservaciones actuales).
--      El spec habría fallado con 42703 en la primera ejecución.
--   b) entidades_relacionadas tiene índice único PARCIAL
--      (id_persona, id_tipo_entidad, id_proyecto, COALESCE(cuenta_madre_stp,''))
--      WHERE activo = true. Reactivar sin comprobar que no exista otra fila
--      activa produce 23505; el alta se hace en tres casos explícitos.
--   c) "pagado" con whitelist de estatus (4,5,7,8,9): el >= 4 del spec marcaba
--      pagado 6=Rentado, 10=Asignado, 11=En demanda, 12=Dación en pago.
--   d) RFC/CURP validados contra chk_personas_rfc_formato /
--      chk_personas_curp_formato y contra UNIQUE(rfc)/UNIQUE(curp): un valor
--      inválido o ya usado lanzaría excepción al rol anon (500), y la violación
--      de UNIQUE funciona como oráculo de existencia de un RFC.
--   e) telefono se escribe solo con 10-15 dígitos: chk_personas_telefono_formato
--      exige 5-20 caracteres y un input corto reventaría como error 500.
--   f) Tipos de retorno bigint: propiedades.id y cuentas_cobranza.id son bigint.
--   g) El gate del token excluye estatus 'expirado'/'cancelado': esos estatus no
--      apagan reservaciones.activo, así que activo por sí solo no basta.
--   h) guardar_datos_reservacion NO sobrescribe nombre_legal/telefono de una
--      persona consolidada (es_draft = false): hay 5 correos duplicados entre
--      personas activas y reservaciones.email puede ser de un comprador real.
--      Solo vincula la reservación en ese caso.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. DDL — reservaciones.token
--    Aditivo. El DEFAULT rellena las filas existentes en el mismo ALTER.
-- -----------------------------------------------------------------------------
ALTER TABLE public.reservaciones
  ADD COLUMN IF NOT EXISTS token uuid NOT NULL DEFAULT gen_random_uuid();

CREATE UNIQUE INDEX IF NOT EXISTS reservaciones_token_key
  ON public.reservaciones (token);

COMMENT ON COLUMN public.reservaciones.token IS
  'Token público (128 bits) usado en los links de la oferta digital y del '
  'apartado provisional: /oferta/O-XXXXXX/<token>, /reservar/<token>. '
  'Sustituye al id secuencial como credencial del cliente. anon no tiene '
  'ningún privilegio sobre esta tabla: solo se lee desde las funciones '
  'SECURITY DEFINER de esta migración, que filtran por token.';

-- -----------------------------------------------------------------------------
-- 2. Cierre del acceso directo de anon a reservaciones.
--
--    Sin esto el token no sirve de nada: la política public_read_by_id
--    (SELECT, rol public, USING true) + el GRANT de tabla a anon permitían
--      GET   /rest/v1/reservaciones?select=id_oferta,token
--      PATCH /rest/v1/reservaciones?id=eq.28  {"token":"..."}
--    es decir, leer los tokens de todos o inutilizar el de un cliente.
--
--    El front público ya usa las RPC de los bloques 3-5, así que anon no
--    necesita ningún privilegio sobre la tabla. authenticated no se toca: el
--    panel del asesor sigue leyendo token para armar el link.
-- -----------------------------------------------------------------------------
REVOKE ALL ON TABLE public.reservaciones FROM anon;

DROP POLICY IF EXISTS public_read_by_id ON public.reservaciones;
DROP POLICY IF EXISTS update_solo_pendiente ON public.reservaciones;

-- La política auth_insert se conserva: es como el panel crea las reservaciones
-- al generar la oferta digital. Tras el REVOKE, anon ya no puede usarla.

-- -----------------------------------------------------------------------------
-- 3. get_apartado_status(p_oferta_id, p_token)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_apartado_status(
  p_oferta_id integer,
  p_token     uuid DEFAULT NULL
)
RETURNS TABLE (
  pagado              boolean,
  estatus_id          integer,
  id_propiedad        bigint,
  id_cuenta_cobranza  bigint,
  clabe_stp           text,
  email_enmascarado   text,
  tiene_acceso        boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id_oferta      integer;
  v_id_propiedad   bigint;
  v_id_persona     integer;
  v_estatus        integer;
  v_id_cuenta      bigint;
  v_clabe          text;
  v_email          text;
  v_pagado         boolean := false;
  v_tiene_acceso   boolean := false;
BEGIN
  -- Fallo cerrado: sin token no se responde nada.
  IF p_token IS NULL THEN
    RETURN QUERY SELECT false, NULL::integer, NULL::bigint, NULL::bigint,
                        NULL::text, NULL::text, false;
    RETURN;
  END IF;

  -- El token es la credencial: de él se deriva la oferta. Debe estar vigente.
  -- 'expirado'/'cancelado' no apagan activo, hay que excluirlos explícitamente.
  SELECT r.id_oferta INTO v_id_oferta
  FROM reservaciones r
  WHERE r.token = p_token
    AND r.activo = true
    AND r.estatus NOT IN ('expirado', 'cancelado')
    AND (r.fecha_expiracion IS NULL OR r.fecha_expiracion > now());

  -- Token inválido/expirado, o que no corresponde a la oferta que dice el front.
  -- Mismo resultado vacío en ambos casos: no se filtra si la oferta existe.
  IF v_id_oferta IS NULL OR (p_oferta_id IS NOT NULL AND v_id_oferta <> p_oferta_id) THEN
    RETURN QUERY SELECT false, NULL::integer, NULL::bigint, NULL::bigint,
                        NULL::text, NULL::text, false;
    RETURN;
  END IF;

  SELECT o.id_propiedad, o.id_persona_lead
    INTO v_id_propiedad, v_id_persona
  FROM ofertas o
  WHERE o.id = v_id_oferta AND o.activo = true;

  IF v_id_propiedad IS NULL THEN
    RETURN QUERY SELECT false, NULL::integer, NULL::bigint, NULL::bigint,
                        NULL::text, NULL::text, false;
    RETURN;
  END IF;

  SELECT p.id_estatus_disponibilidad INTO v_estatus
  FROM propiedades p WHERE p.id = v_id_propiedad;

  -- Cuenta de cobranza de esta oferta (la crea n8n al aplicar el apartado).
  -- Su clabe_stp es la dedicada del cliente y sustituye a la temporal.
  SELECT cc.id, cc.clabe_stp INTO v_id_cuenta, v_clabe
  FROM cuentas_cobranza cc
  WHERE cc.id_oferta = v_id_oferta AND cc.activo = true
  ORDER BY cc.id
  LIMIT 1;

  -- Pagado si se cumple cualquiera: ya hay cuenta de cobranza, la propiedad
  -- pasó a un estatus posterior al apartado, o el acuerdo de apartado
  -- (concepto 1 = Apartado) quedó completado.
  -- Whitelist explícita: 4 Apartado, 5 Vendido, 7 Escrituración, 8 Entregado,
  -- 9 Pagada completamente. NO 6 Rentado / 10 Asignado / 11 En demanda /
  -- 12 Dación en pago, que no implican pago del apartado.
  -- COALESCE en el IN: con v_estatus NULL el operador daría NULL y el OR
  -- completo podría devolver NULL en lugar de false.
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

  RETURN QUERY SELECT
    v_pagado,
    v_estatus,
    v_id_propiedad,
    v_id_cuenta,
    v_clabe,
    -- Enmascarado aun con token válido: el link puede reenviarse o quedar en
    -- un historial.
    CASE
      WHEN v_email IS NULL OR position('@' in v_email) = 0 THEN NULL
      ELSE left(split_part(v_email, '@', 1), 1) || '***@' || split_part(v_email, '@', 2)
    END,
    COALESCE(v_tiene_acceso, false);
END;
$$;

REVOKE ALL ON FUNCTION public.get_apartado_status(integer, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_apartado_status(integer, uuid)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_apartado_status(integer, uuid) IS
  'Oferta digital pública: con el token de la reservación indica si el SPEI de '
  'apartado ya se reflejó, y devuelve la CLABE dedicada de la cuenta de cobranza, '
  'el email del lead enmascarado y si ya tiene usuario activo. Sin token válido '
  'devuelve fila vacía (fallo cerrado). Solo lectura.';

-- -----------------------------------------------------------------------------
-- 4. update_lead_datos(..., p_token)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_lead_datos(
  p_oferta_id integer,
  p_nombre    text,
  p_telefono  text,
  p_rfc       text DEFAULT NULL,
  p_curp      text DEFAULT NULL,
  p_token     uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id_oferta  integer;
  v_id_persona integer;
  v_nombre     text;
  v_telefono   text;
  v_rfc        text;
  v_curp       text;
BEGIN
  -- Fallo cerrado: sin token no se escribe nada.
  IF p_token IS NULL THEN
    RETURN false;
  END IF;

  SELECT r.id_oferta INTO v_id_oferta
  FROM reservaciones r
  WHERE r.token = p_token
    AND r.activo = true
    AND r.estatus NOT IN ('expirado', 'cancelado')
    AND (r.fecha_expiracion IS NULL OR r.fecha_expiracion > now());

  IF v_id_oferta IS NULL OR (p_oferta_id IS NOT NULL AND v_id_oferta <> p_oferta_id) THEN
    RETURN false;
  END IF;

  SELECT o.id_persona_lead INTO v_id_persona
  FROM ofertas o
  WHERE o.id = v_id_oferta AND o.activo = true;

  IF v_id_persona IS NULL THEN
    RETURN false;
  END IF;

  v_nombre := NULLIF(btrim(COALESCE(p_nombre, '')), '');

  -- Solo dígitos y largo plausible (ver nota (e) de la cabecera).
  v_telefono := NULLIF(regexp_replace(COALESCE(p_telefono, ''), '\D', '', 'g'), '');
  IF v_telefono IS NOT NULL AND length(v_telefono) NOT BETWEEN 10 AND 15 THEN
    v_telefono := NULL;
  END IF;

  -- RFC/CURP: se normalizan y se descartan si no cumplen el formato del CHECK
  -- o si ya pertenecen a otra persona (UNIQUE). Descartar en silencio evita
  -- tanto el 500 como usar la violación de UNIQUE como oráculo de existencia.
  v_rfc := NULLIF(upper(btrim(COALESCE(p_rfc, ''))), '');
  IF v_rfc IS NOT NULL
     AND (v_rfc !~ '^[A-Z&Ñ]{3,4}[0-9]{6}[A-Z0-9]{3}$'
          OR EXISTS (SELECT 1 FROM personas x
                     WHERE x.rfc = v_rfc AND x.id <> v_id_persona))
  THEN
    v_rfc := NULL;
  END IF;

  v_curp := NULLIF(upper(btrim(COALESCE(p_curp, ''))), '');
  IF v_curp IS NOT NULL
     AND (v_curp !~ '^[A-Z]{4}[0-9]{6}[HM][A-Z]{5}[A-Z0-9]{2}$'
          OR EXISTS (SELECT 1 FROM personas x
                     WHERE x.curp = v_curp AND x.id <> v_id_persona))
  THEN
    v_curp := NULL;
  END IF;

  UPDATE personas SET
    -- COALESCE: un input vacío o descartado conserva el valor previo.
    nombre_legal = COALESCE(v_nombre, nombre_legal),
    telefono     = COALESCE(v_telefono, telefono),
    -- RFC/CURP: solo se escriben si la columna está vacía. Nunca pisan un dato
    -- fiscal ya capturado o validado por el equipo.
    rfc  = CASE WHEN v_rfc  IS NOT NULL AND NULLIF(btrim(COALESCE(rfc,  '')), '') IS NULL
                THEN v_rfc  ELSE rfc  END,
    curp = CASE WHEN v_curp IS NOT NULL AND NULLIF(btrim(COALESCE(curp, '')), '') IS NULL
                THEN v_curp ELSE curp END,
    -- clave_pais_telefono NO se toca: guarda el ISO del país y es FK a
    -- paises(id), no la lada. Escribir '+52' rompería la FK.
    fecha_actualizacion = now()
  WHERE id = v_id_persona;

  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION public.update_lead_datos(integer, text, text, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_lead_datos(integer, text, text, text, text, uuid)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.update_lead_datos(integer, text, text, text, text, uuid) IS
  'Oferta digital pública: con el token de la reservación guarda nombre/telefono '
  'y, si están vacíos, RFC/CURP del lead de la oferta. Valida formato y unicidad '
  'antes de escribir. Sin token válido devuelve false sin tocar nada.';

-- -----------------------------------------------------------------------------
-- 5.1 get_reservacion_publica(p_token) — lectura del apartado provisional
--     Sustituye el SELECT directo que hacían /reservar/<token>, /hold y
--     /confirmacion con la anon key. Nunca devuelve token ni filas ajenas.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_reservacion_publica(p_token uuid DEFAULT NULL)
RETURNS TABLE (
  id                integer,
  id_oferta         integer,
  email             text,
  nombre            text,
  telefono          text,
  estatus           text,
  activo            boolean,
  fecha_activacion  timestamptz,
  fecha_expiracion  timestamptz,
  nombre_persona    text,
  telefono_persona  text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_token IS NULL THEN
    RETURN;  -- sin token, cero filas
  END IF;

  -- Sin filtro por activo/estatus a propósito: la página necesita poder
  -- distinguir "expirada" de "inexistente" para el cliente que sí trae el token.
  RETURN QUERY
  SELECT r.id, r.id_oferta, r.email, r.nombre, r.telefono, r.estatus, r.activo,
         r.fecha_activacion, r.fecha_expiracion,
         per.nombre_legal, per.telefono
  FROM reservaciones r
  LEFT JOIN personas per ON per.id = r.id_persona
  WHERE r.token = p_token;
END;
$$;

REVOKE ALL ON FUNCTION public.get_reservacion_publica(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_reservacion_publica(uuid)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_reservacion_publica(uuid) IS
  'Apartado provisional: datos de la reservación identificada por su token, '
  'para las páginas públicas /reservar. Nunca devuelve el token ni otras filas.';

-- -----------------------------------------------------------------------------
-- 5.2 guardar_datos_reservacion(p_token, p_nombre, p_telefono) — escritura
--     Reemplaza el upsert que la página pública hacía directo sobre personas,
--     reservaciones y entidades_relacionadas. El correo se toma de la
--     reservación del token, nunca del cliente: con el id en la URL se podía
--     apuntar a la reservación de otro.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guardar_datos_reservacion(
  p_token    uuid DEFAULT NULL,
  p_nombre   text DEFAULT NULL,
  p_telefono text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reserva     reservaciones%ROWTYPE;
  v_email       text;
  v_nombre      text := NULLIF(btrim(COALESCE(p_nombre, '')), '');
  v_telefono    text := NULLIF(regexp_replace(COALESCE(p_telefono, ''), '\D', '', 'g'), '');
  v_id_persona  integer;
  v_es_draft    boolean;
  v_id_proyecto integer;
BEGIN
  -- Fallo cerrado. El teléfono debe caber en chk_personas_telefono_formato.
  IF p_token IS NULL
     OR v_nombre IS NULL
     OR v_telefono IS NULL
     OR length(v_telefono) NOT BETWEEN 10 AND 15 THEN
    RETURN false;
  END IF;

  SELECT * INTO v_reserva
  FROM reservaciones r
  WHERE r.token = p_token
    AND r.activo = true
    AND r.estatus NOT IN ('expirado', 'cancelado');
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_email := NULLIF(lower(btrim(COALESCE(v_reserva.email, ''))), '');
  IF v_email IS NULL THEN
    RETURN false;
  END IF;

  -- Persona por el correo de la reservación (no por uno que mande el cliente).
  SELECT p.id, COALESCE(p.es_draft, false) INTO v_id_persona, v_es_draft
  FROM personas p
  WHERE lower(p.email) = v_email AND p.activo = true
  ORDER BY p.id
  LIMIT 1;

  IF v_id_persona IS NULL THEN
    INSERT INTO personas (email, nombre_legal, telefono, tipo_persona, es_draft, activo)
    VALUES (v_email, v_nombre, v_telefono, 'pf', true, true)
    RETURNING id INTO v_id_persona;
  ELSIF v_es_draft THEN
    -- Solo se sobrescribe a la persona creada por este mismo flujo público.
    UPDATE personas
       SET nombre_legal = v_nombre,
           telefono     = v_telefono,
           fecha_actualizacion = now()
     WHERE id = v_id_persona;
  ELSE
    -- Persona consolidada: no se pisan sus datos desde una página pública;
    -- solo se rellena el teléfono si estaba vacío.
    UPDATE personas
       SET telefono = COALESCE(NULLIF(btrim(COALESCE(telefono, '')), ''), v_telefono),
           fecha_actualizacion = now()
     WHERE id = v_id_persona;
  END IF;

  UPDATE reservaciones
     SET id_persona = v_id_persona,
         nombre     = v_nombre,
         telefono   = v_telefono,
         fecha_actualizacion = now()
   WHERE id = v_reserva.id;

  -- Proyecto de la oferta: ofertas NO tiene id_proyecto; se resuelve por la
  -- propiedad. Las ofertas de producto (id_producto) no resuelven proyecto y
  -- simplemente no generan alta de prospecto.
  SELECT e.id_proyecto INTO v_id_proyecto
  FROM ofertas o
  JOIN propiedades p          ON p.id  = o.id_propiedad
  JOIN edificios_modelos em   ON em.id = p.id_edificio_modelo
  JOIN edificios e            ON e.id  = em.id_edificio
  WHERE o.id = v_reserva.id_oferta;

  -- Alta/reactivación como Prospecto (tipos_entidad.id = 7) en el proyecto.
  -- El índice único es PARCIAL (WHERE activo = true): reactivar sin comprobar
  -- que no exista ya una fila activa produciría 23505.
  IF v_id_proyecto IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM entidades_relacionadas er
      WHERE er.id_persona = v_id_persona
        AND er.id_tipo_entidad = 7
        AND er.id_proyecto = v_id_proyecto
        AND er.activo = true
    ) THEN
      NULL;  -- ya está activo, nada que hacer
    ELSIF EXISTS (
      SELECT 1 FROM entidades_relacionadas er
      WHERE er.id_persona = v_id_persona
        AND er.id_tipo_entidad = 7
        AND er.id_proyecto = v_id_proyecto
        AND er.activo = false
    ) THEN
      UPDATE entidades_relacionadas
         SET activo = true
       WHERE id = (
         SELECT er.id FROM entidades_relacionadas er
         WHERE er.id_persona = v_id_persona
           AND er.id_tipo_entidad = 7
           AND er.id_proyecto = v_id_proyecto
           AND er.activo = false
         ORDER BY er.id
         LIMIT 1
       );
    ELSE
      INSERT INTO entidades_relacionadas (id_persona, id_tipo_entidad, id_proyecto, activo)
      VALUES (v_id_persona, 7, v_id_proyecto, true);
    END IF;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.guardar_datos_reservacion(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.guardar_datos_reservacion(uuid, text, text)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.guardar_datos_reservacion(uuid, text, text) IS
  'Apartado provisional: con el token de la reservación guarda nombre/telefono '
  'del cliente, vincula la persona (upsert por el correo de la reservación) y la '
  'da de alta como Prospecto en el proyecto de la oferta. No sobrescribe datos '
  'de personas consolidadas (es_draft = false).';

-- -----------------------------------------------------------------------------
-- 6. Guards de sobrecargas.
--    CREATE OR REPLACE no reemplaza una firma distinta: la agrega como
--    sobrecarga y PostgREST deja de resolver la llamada. En prod no existe
--    ninguna versión previa (verificado 2026-07-27); los DROP van guarded por
--    si hubiera drift en dev.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_sig text;
BEGIN
  FOREACH v_sig IN ARRAY ARRAY[
    'public.get_apartado_status(integer)',
    'public.update_lead_datos(integer, text, text)',
    'public.update_lead_datos(integer, text, text, text, text)',
    'public.get_reservacion_publica(integer)',
    'public.guardar_datos_reservacion(integer, text, text)'
  ]
  LOOP
    IF to_regprocedure(v_sig) IS NOT NULL THEN
      EXECUTE format('DROP FUNCTION %s', v_sig);
      RAISE NOTICE 'Eliminada sobrecarga previa %', v_sig;
    END IF;
  END LOOP;
END
$$;

-- -----------------------------------------------------------------------------
-- 7. Self-verifying: aborta el CI si algo no quedó como se espera.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_n integer;
BEGIN
  -- 7.1 Una sola firma por función, y las cuatro con SECURITY DEFINER.
  SELECT count(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('get_apartado_status', 'update_lead_datos',
                      'get_reservacion_publica', 'guardar_datos_reservacion');
  IF v_n <> 4 THEN
    RAISE EXCEPTION 'Se esperaban 4 funciones (una firma cada una), hay %', v_n;
  END IF;

  IF to_regprocedure('public.get_apartado_status(integer, uuid)') IS NULL
     OR to_regprocedure('public.update_lead_datos(integer, text, text, text, text, uuid)') IS NULL
     OR to_regprocedure('public.get_reservacion_publica(uuid)') IS NULL
     OR to_regprocedure('public.guardar_datos_reservacion(uuid, text, text)') IS NULL THEN
    RAISE EXCEPTION 'Falta alguna de las firmas nuevas';
  END IF;

  SELECT count(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('get_apartado_status', 'update_lead_datos',
                      'get_reservacion_publica', 'guardar_datos_reservacion')
    AND p.prosecdef = false;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'Hay % función(es) sin SECURITY DEFINER', v_n;
  END IF;

  -- 7.2 Token presente en todas las reservaciones (la unicidad la garantiza
  --     el índice único creado arriba).
  IF EXISTS (SELECT 1 FROM public.reservaciones WHERE token IS NULL) THEN
    RAISE EXCEPTION 'Hay reservaciones sin token';
  END IF;

  -- 7.3 anon sin NINGÚN privilegio sobre reservaciones (si esto falla, el
  --     token no sirve como credencial y la migración no debe darse por buena).
  IF has_table_privilege('anon', 'public.reservaciones', 'SELECT')
     OR has_table_privilege('anon', 'public.reservaciones', 'INSERT')
     OR has_table_privilege('anon', 'public.reservaciones', 'UPDATE')
     OR has_table_privilege('anon', 'public.reservaciones', 'DELETE') THEN
    RAISE EXCEPTION 'anon todavía tiene privilegios sobre reservaciones';
  END IF;

  IF has_column_privilege('anon', 'public.reservaciones', 'token', 'SELECT') THEN
    RAISE EXCEPTION 'anon todavía puede leer reservaciones.token';
  END IF;

  -- 7.4 Las políticas que exponían la tabla al público ya no existen.
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'reservaciones'
      AND policyname IN ('public_read_by_id', 'update_solo_pendiente')
  ) THEN
    RAISE EXCEPTION 'Siguen existiendo políticas públicas en reservaciones';
  END IF;

  -- 7.5 authenticated conserva su acceso (el panel arma el link con el token).
  IF NOT has_column_privilege('authenticated', 'public.reservaciones', 'token', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated perdió acceso a reservaciones.token';
  END IF;
END
$$;
