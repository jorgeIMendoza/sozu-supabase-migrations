-- =============================================================================
-- Estado del apartado en vivo: qué pagó el cliente y cuánto le falta
-- =============================================================================
-- La pantalla de pago de la oferta digital es hoy un semáforo binario: `pagado` sí o no.
-- El cliente que manda $1 de prueba antes del monto completo no ve nada hasta que el
-- apartado queda liquidado, así que no sabe si su prueba llegó ni si puede mandar el resto.
-- Y si STP rechaza el depósito, tampoco se entera.
--
-- ─── Verificado read-only el 2026-08-14 en prod (tzmhgfjmddkfyffkkmto) ───────
-- · `get_apartado_pagos` no existe.
-- · `get_apartado_status(integer,uuid)` solo devuelve pagado/estatus/clabe/email: ni un
--   movimiento. Su regla de "pagado" es `COALESCE(v_estatus,0) IN (4,5,7,8,9)` — la nueva
--   RPC usa la MISMA, para no dar dos verdades.
-- · `pagos_stp_raw` tiene las 9 columnas que hacen falta (claverastreo, monto,
--   cuenta_beneficiario, nombre_ordenante, es_pago_aplicado, razon_rechazo,
--   fecha_operacion, fecha_creacion, id). Hoy: 12,707 filas, 118 no aplicadas. El rechazo
--   es un caso real y hoy es invisible para el cliente.
-- · `propiedades.clabe_stp_tmp_apartado` y `cuentas_cobranza.clabe_stp` existen: el dinero
--   del apartado puede entrar por cualquiera de las dos según el momento, y el $1 de prueba
--   suele caer en la temporal. Se cruzan las dos.
-- · `app_cliente_config` tiene RLS activa y su única policy es de `georgia_mcp_ro`: `anon`
--   no puede leer los links de tienda. Sus llaves hoy son min_version, force_update,
--   android_store_url, ios_store_url (vacía), update_message, animacion_campana y
--   latest_version.
--
-- ─── Decisiones ──────────────────────────────────────────────────────────────
-- · RPC NUEVA, no ampliar la existente: a `get_apartado_status` la llama el polling cada
--   minuto y devuelve `TABLE(...)`; cambiarle la forma rompería al front desplegado.
-- · Mismo gate: sin token válido y vigente responde `{"ok": false}` y nada más — sin
--   filtrar siquiera si la oferta existe.
-- · Qué se expone: montos, fecha, clave de rastreo, si se aplicó y la razón del rechazo.
--   Todos son datos del propio pago del cliente, los mismos que ya ve en su CEP.
--   `nombre_ordenante` se recorta a la primera palabra: el link puede reenviarse.
-- · Verdad del "aplicado": con cuenta de cobranza creada manda `pagos` (la fuente
--   contable); antes de que exista, `pagos_stp_raw` filtrando `es_pago_aplicado`. Así el
--   número nunca contradice a cobranza.
-- · `app_cliente_config` se abre a lectura pública SOLO en tres llaves de distribución
--   (urls de tienda y versión). El resto de la tabla sigue cerrada.
--
-- Orden: después de `20260813170000_oferta_apartado_de_la_propiedad.sql`, para que las dos
-- RPC resuelvan el apartado con la misma regla (COALESCE sobre propiedades.monto_apartado).
-- =============================================================================

BEGIN;

-- Guard: la regla del monto objetivo depende de esta columna.
DO $guard$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='propiedades' AND column_name='monto_apartado'
  ) THEN
    RAISE EXCEPTION 'No existe propiedades.monto_apartado';
  END IF;

  IF to_regclass('public.pagos_stp_raw') IS NULL THEN
    RAISE EXCEPTION 'No existe pagos_stp_raw';
  END IF;
END;
$guard$;

-- -----------------------------------------------------------------------------
-- §A. Estado del apartado con detalle de movimientos, para la pantalla pública
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_apartado_pagos(
  p_oferta_id integer,
  p_token     uuid DEFAULT NULL::uuid
)
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

-- La pantalla corre sin sesión: el token es la credencial. Se revoca PUBLIC primero para
-- no dejar el EXECUTE implícito con el que nace toda función nueva en `public`.
REVOKE ALL ON FUNCTION public.get_apartado_pagos(integer, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_apartado_pagos(integer, uuid) TO anon, authenticated;

COMMENT ON FUNCTION public.get_apartado_pagos(integer, uuid) IS
  'Estado del apartado con detalle de movimientos STP (aplicados y rechazados) para la '
  'pantalla pública de pago. Gate por reservaciones.token, igual que get_apartado_status. '
  'El monto objetivo sale de propiedades.monto_apartado con la misma regla que '
  'get_oferta_financials (COALESCE, porque 0 significa que no se cobra apartado).';

-- -----------------------------------------------------------------------------
-- §B. Links de la app para la pantalla de éxito, sin sesión
-- -----------------------------------------------------------------------------
-- Son urls de tienda y números de versión: config de distribución, no datos de nadie.
-- La policy lleva lista blanca de `key` para que el resto de la tabla siga cerrada.
DROP POLICY IF EXISTS "Public can read app store links" ON public.app_cliente_config;

CREATE POLICY "Public can read app store links"
  ON public.app_cliente_config
  FOR SELECT
  TO anon, authenticated
  USING (key IN ('android_store_url', 'ios_store_url', 'latest_version'));

-- -----------------------------------------------------------------------------
-- §C. Self-verifying
-- -----------------------------------------------------------------------------
DO $check$
BEGIN
  IF NOT has_function_privilege('anon', 'public.get_apartado_pagos(integer, uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon no puede ejecutar get_apartado_pagos; la pantalla pública quedaría rota';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='app_cliente_config'
      AND policyname='Public can read app store links'
  ) THEN
    RAISE EXCEPTION 'No quedó creada la policy de app_cliente_config';
  END IF;
END;
$check$;

COMMIT;

-- =============================================================================
-- Verificación (read-only, correr después del deploy)
-- =============================================================================
-- SELECT p.proname, pg_get_function_identity_arguments(p.oid) args, p.prosecdef,
--        has_function_privilege('anon', p.oid, 'execute')          AS anon_exec,
--        has_function_privilege('authenticated', p.oid, 'execute') AS auth_exec
-- FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname='get_apartado_pagos';
--
-- SELECT policyname, roles::text, cmd, qual FROM pg_policies
-- WHERE schemaname='public' AND tablename='app_cliente_config';
--
-- UAT (transacción desechable; sustituir <token> y 3010 por datos reales):
--   BEGIN;
--     SET LOCAL ROLE anon;
--     SELECT public.get_apartado_pagos(3010, NULL);                                  -- {"ok": false}
--     SELECT public.get_apartado_pagos(3010, '00000000-0000-0000-0000-000000000000');-- {"ok": false}
--     SELECT jsonb_pretty(public.get_apartado_pagos(3010, '<token>'));
--     SELECT key, value FROM public.app_cliente_config ORDER BY key;  -- solo las 3 llaves
--     RESET ROLE;
--   ROLLBACK;
-- =============================================================================
