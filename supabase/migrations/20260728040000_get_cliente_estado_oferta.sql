-- =============================================================================
-- Oferta digital — get_cliente_estado_oferta(p_token)
--
-- Al cierre de la oferta digital el flujo se bifurca:
--   · Cliente nuevo      → confirma datos, sube Constancia, se crea la cuenta.
--   · Cliente de SOZU    → usuario activo + al menos una propiedad: se manda
--                          directo al portal a iniciar sesión.
-- El front necesita saberlo antes de pintar la pantalla y sin exponer el padrón:
-- la consulta va por el token de la reservación, igual que el resto del flujo
-- público (misma credencial que get_apartado_status / get_reservacion_publica).
--
-- Verificado read-only contra prod el 2026-07-28:
--   · get_cliente_estado_oferta no existe con ninguna firma.
--   · Tipos: ofertas.id / ofertas.id_persona_lead / personas.id /
--     compradores.id_persona / compradores.id_cuenta_cobranza / reservaciones.id_oferta
--     son integer; cuentas_cobranza.id es bigint (el join int = bigint es válido).
--   · 189 reservaciones activas con oferta activa; 0 leads sin correo.
--   · 34 leads son comprador activo de una cuenta de cobranza activa.
--   · 84 leads tienen usuario activo; 50 de ellos SIN propiedad.
--
-- Correcciones respecto al spec, contra los datos reales:
--   a) El EXISTS de propiedades excluye la cuenta de cobranza de la PROPIA
--      oferta (cc.id_oferta IS DISTINCT FROM v_id_oferta). n8n crea cuenta +
--      comprador para la oferta en curso al aplicar el apartado, así que el
--      spec marcaba "ya es cliente" a quien acaba de pagar su primera
--      propiedad y lo mandaba a iniciar sesión a una cuenta inexistente.
--      Hoy en prod: 6 reservaciones con propiedad de su propia oferta, 4 de
--      ellas exclusivamente por esa vía.
--   b) La propiedad se busca por id_persona O por correo igual: 14 leads
--      activos tienen más de una fila en personas con el mismo correo (el
--      flujo público inserta drafts), y el comprador real puede ser la otra
--      fila. Hoy ambos criterios coinciden en 34/34, así que no cambia nada
--      en los datos actuales y cierra el caso latente.
--   c) Correo normalizado con lower(btrim(...)) en los dos lados.
--   d) STABLE: la función solo lee.
--
-- Nota para el front (no es cosa del SQL): tiene_acceso = true con
-- tiene_propiedades = false son 50 reservaciones activas hoy. Ahí
-- es_cliente_existente sale false, pero intentar el alta choca con el usuario
-- que ya existe en auth: esa rama debe ir a login / recuperar contraseña,
-- no al registro. Por eso la función devuelve las tres banderas y no solo una.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_cliente_estado_oferta(p_token uuid DEFAULT NULL)
RETURNS TABLE (
  tiene_acceso         boolean,
  tiene_propiedades    boolean,
  es_cliente_existente boolean,
  email_enmascarado    text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id_oferta   integer;
  v_id_persona  integer;
  v_email       text;
  v_acceso      boolean := false;
  v_propiedades boolean := false;
BEGIN
  -- Fallo cerrado: sin token no se responde nada y el front trata al visitante
  -- como cliente nuevo.
  IF p_token IS NULL THEN
    RETURN QUERY SELECT false, false, false, NULL::text;
    RETURN;
  END IF;

  -- El token es la credencial: de él se deriva la oferta. 'expirado'/'cancelado'
  -- no apagan reservaciones.activo, hay que excluirlos explícitamente.
  SELECT r.id_oferta INTO v_id_oferta
  FROM reservaciones r
  WHERE r.token = p_token
    AND r.activo = true
    AND r.estatus NOT IN ('expirado', 'cancelado')
    AND (r.fecha_expiracion IS NULL OR r.fecha_expiracion > now());

  IF v_id_oferta IS NULL THEN
    RETURN QUERY SELECT false, false, false, NULL::text;
    RETURN;
  END IF;

  SELECT o.id_persona_lead INTO v_id_persona
  FROM ofertas o WHERE o.id = v_id_oferta AND o.activo = true;

  IF v_id_persona IS NULL THEN
    RETURN QUERY SELECT false, false, false, NULL::text;
    RETURN;
  END IF;

  SELECT NULLIF(lower(btrim(COALESCE(per.email, ''))), '') INTO v_email
  FROM personas per WHERE per.id = v_id_persona;

  SELECT EXISTS (
    SELECT 1 FROM usuarios u
    WHERE lower(btrim(u.email)) = v_email
      AND v_email IS NOT NULL
      AND u.activo = true
  ) INTO v_acceso;

  -- Al menos una propiedad: comprador activo de una cuenta de cobranza activa
  -- que NO sea la de esta misma oferta (ver nota (a) de la cabecera).
  -- Se acepta el match por id_persona o por correo igual, porque el mismo
  -- cliente puede tener una fila draft en personas además de la consolidada
  -- (nota (b)).
  SELECT EXISTS (
    SELECT 1
    FROM compradores c
    JOIN cuentas_cobranza cc ON cc.id = c.id_cuenta_cobranza
    LEFT JOIN personas p2    ON p2.id = c.id_persona
    WHERE c.activo = true
      AND cc.activo = true
      AND cc.id_oferta IS DISTINCT FROM v_id_oferta
      AND (
            c.id_persona = v_id_persona
         OR (v_email IS NOT NULL
             AND p2.activo = true
             AND lower(btrim(COALESCE(p2.email, ''))) = v_email)
          )
  ) INTO v_propiedades;

  RETURN QUERY SELECT
    COALESCE(v_acceso, false),
    COALESCE(v_propiedades, false),
    COALESCE(v_acceso, false) AND COALESCE(v_propiedades, false),
    -- Enmascarado aun con token válido: el link puede reenviarse o quedar en
    -- un historial.
    CASE
      WHEN v_email IS NULL OR position('@' in v_email) = 0 THEN NULL
      ELSE left(split_part(v_email, '@', 1), 1) || '***@' || split_part(v_email, '@', 2)
    END;
END;
$$;

REVOKE ALL ON FUNCTION public.get_cliente_estado_oferta(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_cliente_estado_oferta(uuid)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_cliente_estado_oferta(uuid) IS
  'Oferta digital pública: indica si el lead de la reservación ya es cliente de SOZU '
  '(usuario activo + al menos una propiedad como comprador, sin contar la cuenta de '
  'cobranza de la propia oferta) para saltarse el alta de cuenta y mandarlo a iniciar '
  'sesión. Sin token válido devuelve todo en false. Solo lectura.';

-- -----------------------------------------------------------------------------
-- Guard de sobrecargas. CREATE OR REPLACE no reemplaza una firma distinta: la
-- agrega y PostgREST deja de resolver la llamada. En prod no existe ninguna
-- versión previa (verificado 2026-07-28); el DROP va guarded por si hay drift
-- en dev.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_sig text;
BEGIN
  FOREACH v_sig IN ARRAY ARRAY[
    'public.get_cliente_estado_oferta()',
    'public.get_cliente_estado_oferta(integer)',
    'public.get_cliente_estado_oferta(integer, uuid)',
    'public.get_cliente_estado_oferta(text)'
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
-- Self-verifying: aborta el CI si algo no quedó como se espera.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_n integer;
  v_r record;
BEGIN
  SELECT count(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_cliente_estado_oferta';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'Se esperaba 1 firma de get_cliente_estado_oferta, hay %', v_n;
  END IF;

  IF to_regprocedure('public.get_cliente_estado_oferta(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Falta la firma get_cliente_estado_oferta(uuid)';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'get_cliente_estado_oferta'
      AND p.prosecdef = true
  ) THEN
    RAISE EXCEPTION 'get_cliente_estado_oferta quedó sin SECURITY DEFINER';
  END IF;

  IF NOT has_function_privilege('anon', 'public.get_cliente_estado_oferta(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.get_cliente_estado_oferta(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon/authenticated no pueden ejecutar get_cliente_estado_oferta';
  END IF;

  -- Smoke read-only: sin token y con token inexistente, todo en false sin error.
  SELECT * INTO v_r FROM public.get_cliente_estado_oferta(NULL);
  IF v_r.tiene_acceso OR v_r.tiene_propiedades OR v_r.es_cliente_existente
     OR v_r.email_enmascarado IS NOT NULL THEN
    RAISE EXCEPTION 'Token NULL no devolvió el resultado cerrado';
  END IF;

  SELECT * INTO v_r
  FROM public.get_cliente_estado_oferta('00000000-0000-0000-0000-000000000000');
  IF v_r.tiene_acceso OR v_r.tiene_propiedades OR v_r.es_cliente_existente
     OR v_r.email_enmascarado IS NOT NULL THEN
    RAISE EXCEPTION 'Token inexistente no devolvió el resultado cerrado';
  END IF;
END
$$;
