-- Activos comerciales: alta abierta con aprobación de Super Administrador
-- Fecha: 2026-08-18
-- Origen: Ejecuciones/ejecusiones.md (primera parte, con la guarda de la segunda)
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- Se quita la restriccion que impide dar de alta un activo comercial a quien no sea Super
-- Administrador, y se sustituye por un flujo de dos pasos:
--   1. Cualquier sesion autenticada puede dar de alta. Nace en BORRADOR
--      (propiedades.es_aprobado = false), que es como el resto del sistema representa
--      "capturado pero no publicado".
--   2. Solo un Super Administrador puede aprobarlo, lo que lo publica (es_aprobado = true).
--
-- El gate se quita de la CREACION, no de la PUBLICACION: capturar es barato y reversible,
-- publicar es lo que hace visible el activo al resto del sistema y ahi se conserva el
-- control. `es_aprobado` deja de aceptarse desde el payload — si el cliente pudiera mandar
-- true, el flujo de aprobacion seria decorativo.
--
-- ─── Por qué el prefijo es 143800 y no 120000 ─────────────────────────────────
-- Este archivo nacio como 20260818120000 y colisiono con
-- 20260818120000_crm_negocios_ia.sql, que entro a dev por otro PR con el mismo prefijo.
-- El efecto fue peor que un error: con dos archivos compartiendo `version`, el CLI toma
-- solo uno y este quedaba IGNORADO EN SILENCIO —no aparecio ni en la lista de pendientes
-- del deploy—, asi que las tres funciones nunca se habrian aplicado sin que nada fallara.
-- NO renombrar de vuelta.
--
-- ─── La guarda de id_edificio_modelo ya es la FINAL ───────────────────────────
-- El documento entrega la funcion con la guarda vieja y luego, en su segunda parte, indica
-- sustituirla. Aqui se escribe directamente la version final: generar la intermedia y
-- reemplazarla en el mismo PR seria 230 lineas de ruido. Requiere que
-- 20260818143700_propiedades_activos_sin_desarrollo.sql ya haya corrido, y por eso lleva un
-- timestamp posterior.
--
-- ─── Cómo se construyó el cuerpo ──────────────────────────────────────────────
-- El documento dice haberlo generado de la definicion viva en Preview aplicando solo los
-- cambios necesarios. Se comparo contra la version del repo
-- (20260702000000_activos_comerciales_modelo_catalogos_rpc.sql, linea 613) y coinciden:
-- mismo gate `is_super_admin` con 'not authorized', mismo
-- COALESCE((v_prop->>'es_aprobado')::boolean, true), y la misma variable `v_venta` que se
-- declara y nunca se usa (se conserva tal cual: quitarla no es el objeto de este cambio).
-- Los unicos cambios respecto a la version vigente son: se elimina el gate, es_aprobado
-- nace en false, y se valida id_edificio_modelo con un mensaje entendible en vez de dejar
-- que reviente el NOT NULL.
--
-- El MCP de Supabase estaba caido al preparar este archivo, asi que NO se pudo comparar
-- contra la definicion viva de PRODUCCION. Por eso la seccion 0 es self-verifying: si la
-- funcion en produccion no es la que se espera, la migracion aborta en vez de pisar
-- cambios ajenos con una version de Preview.
--
-- ─── ⚠ LIMITE IMPORTANTE: EL FLUJO DE APROBACION NO ES INFRANQUEABLE ──────────
-- La auditoria del documento anota que la RLS `propiedades_passthrough_write` permite
-- escribir a cualquier sesion que no sea de socio bancario, y concluye que "el control de
-- quien aprueba vive en la funcion". Eso es cierto solo para quien pasa POR la funcion.
-- Con ese passthrough, una sesion `authenticated` puede hacer por PostgREST un
--
--   PATCH /rest/v1/propiedades?id=eq.<n>   { "es_aprobado": true }
--
-- y publicar el activo sin tocar aprobar_activo_comercial. Es decir: mientras esa policy
-- siga como esta, el gate de Super Administrador cubre la via de la app, no la de la API.
-- No se toca aqui porque cambiar `propiedades_passthrough_write` afecta a 53 mil filas y a
-- todo el flujo de propiedades, y no es lo que pide el documento — pero conviene decidirlo
-- aparte si la aprobacion debe ser una garantia y no una convencion de la UI.
--
-- ─── Decisiones que se conservan del documento ────────────────────────────────
-- · `aprobar_activo_comercial` se acota a id_tipo_propiedad > 10 para que no sea una via
--   lateral para publicar departamentos, que tienen su propio flujo.
-- · Es idempotente: aprobar dos veces no falla ni altera nada la segunda vez (el UPDATE
--   lleva `es_aprobado IS DISTINCT FROM true`).
-- · Se agrega `rechazar_activo_comercial` por simetria: sin ella, un Super Administrador
--   que aprueba por error no tiene como revertirlo desde la app.
-- · NO se agrega columna de "quien aprobo y cuando": seria un ALTER TABLE sobre una tabla
--   de 53 mil filas por un dato que nadie ha pedido.
-- · Aprobar y rechazar se otorgan a `authenticated` porque el control real esta DENTRO de
--   la funcion (is_super_admin), no en el GRANT. `anon` no ejecuta ninguna.
--
-- Verificado contra el baseline: propiedades.es_aprobado es boolean NOT NULL DEFAULT false,
-- fecha_actualizacion es NOT NULL con default, e is_super_admin existe
-- (20260513000001_baseline_functions.sql).
--
-- Sin BEGIN/COMMIT (el CI envuelve cada archivo).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 0. Guard self-verifying: no pisar una versión inesperada de la función
--    Acepta dos estados: la versión vigente con el gate viejo (primera aplicación), o la
--    nueva ya aplicada (reaplicación). Cualquier otra cosa significa que alguien la cambió
--    por otro camino, y entonces se aborta.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $guard$
DECLARE
  v_def       text;
  v_es_vieja  boolean;
  v_es_nueva  boolean;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'crear_activo_comercial'
    AND pg_get_function_identity_arguments(p.oid) = 'payload jsonb';

  IF v_def IS NULL THEN
    RAISE EXCEPTION
      'No existe public.crear_activo_comercial(jsonb). Se esperaba la version creada por 20260702000000_activos_comerciales_modelo_catalogos_rpc.sql.';
  END IF;

  v_es_vieja := v_def LIKE '%not authorized%';
  v_es_nueva := v_def LIKE '%Se requiere una sesion activa para dar de alta un activo comercial%';

  IF NOT v_es_vieja AND NOT v_es_nueva THEN
    RAISE EXCEPTION
      'crear_activo_comercial no es ninguna de las dos versiones esperadas: no contiene el gate "not authorized" ni el mensaje de la version nueva. Alguien la modifico por otro camino; revisar la definicion viva antes de reemplazarla para no perder ese cambio.';
  END IF;

  IF v_es_nueva THEN
    RAISE NOTICE 'crear_activo_comercial ya estaba en la version nueva: se reaplica igual (idempotente).';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'is_super_admin'
  ) THEN
    RAISE EXCEPTION 'No existe public.is_super_admin: aprobar_activo_comercial y rechazar_activo_comercial dependen de ella.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'propiedades'
      AND column_name = 'id_edificio_modelo' AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION
      'propiedades.id_edificio_modelo sigue siendo NOT NULL. Aplicar primero 20260818143700_propiedades_activos_sin_desarrollo.sql, o esta funcion aceptaria activos sueltos que la columna rechaza.';
  END IF;
END
$guard$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Alta abierta y en borrador
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.crear_activo_comercial(payload jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id_propiedad bigint;
  v_tipo         int;
  v_prop         jsonb := payload->'propiedad';
  v_pac          jsonb := payload->'activo_comercial';
  v_atts         jsonb := payload->'atributos';
  v_venta        jsonb := payload->'oferta_venta';
  v_renta        jsonb := payload->'oferta_renta';
BEGIN
  -- Cualquier sesion autenticada puede capturar. El control esta en la aprobacion: el
  -- activo nace en borrador y no se publica hasta que un Super Administrador lo apruebe.
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Se requiere una sesion activa para dar de alta un activo comercial';
  END IF;

  v_tipo := (v_prop->>'id_tipo_propiedad')::int;
  IF v_tipo IS NULL OR v_tipo <= 10 THEN
    RAISE EXCEPTION 'id_tipo_propiedad debe ser > 10 (comercial)';
  END IF;

  -- Un terreno nunca cuelga de un desarrollo. Local, oficina y bodega pueden o no: lo
  -- declara el propio payload, y solo entonces se exige la terna.
  IF v_tipo <> 14
     AND COALESCE((v_prop->>'en_proyecto')::boolean, true)
     AND NULLIF(v_prop->>'id_edificio_modelo','') IS NULL THEN
    RAISE EXCEPTION 'Falta el modelo del edificio: elige Proyecto, Edificio y Modelo, o marca el activo como independiente';
  END IF;

  IF v_tipo = 14 AND NULLIF(v_prop->>'id_edificio_modelo','') IS NOT NULL THEN
    RAISE EXCEPTION 'Un terreno no puede pertenecer a un desarrollo';
  END IF;

  INSERT INTO public.propiedades (
    id_entidad_relacionada_dueno, id_vista, id_tipo_transaccion,
    id_edificio_modelo, id_tipo_propiedad, id_estatus_disponibilidad,
    numero_propiedad, numero_piso, m2_interiores, m2_exteriores,
    precio_lista, descripcion, url_imagen_portada,
    es_aprobado, activo
  ) VALUES (
    NULLIF(v_prop->>'id_entidad_relacionada_dueno','')::bigint,
    NULLIF(v_prop->>'id_vista','')::int,
    NULLIF(v_prop->>'id_tipo_transaccion','')::int,
    NULLIF(v_prop->>'id_edificio_modelo','')::int,
    v_tipo,
    COALESCE(NULLIF(v_prop->>'id_estatus_disponibilidad','')::int, 2),
    v_prop->>'numero_propiedad',
    v_prop->>'numero_piso',
    COALESCE(NULLIF(v_prop->>'m2_interiores','')::numeric, 0),
    COALESCE(NULLIF(v_prop->>'m2_exteriores','')::numeric, 0),
    COALESCE(NULLIF(v_prop->>'precio_lista','')::numeric, 0),
    v_prop->>'descripcion',
    v_prop->>'url_imagen_portada',
    false,   -- BORRADOR: publica la aprobacion, no el alta
    true
  )
  RETURNING id INTO v_id_propiedad;

  -- 1:1 activo_comercial
  IF v_pac IS NOT NULL THEN
    INSERT INTO public.propiedades_activo_comercial (
      id_propiedad, codigo_interno, anio_construccion, id_estado_conservacion,
      cuota_condominio_mensual, url_recorrido_virtual,
      ubicacion_direccion, ubicacion_ciudad, ubicacion_lat, ubicacion_lng,
      id_regimen_propiedad, subtipo_condominio, folio_real, clave_catastral,
      cuenta_predial, valor_catastral, predial_al_corriente, origen_ejidal,
      dominio_pleno, libre_gravamen, gravamen_descripcion, monto_predial_anual
    ) VALUES (
      v_id_propiedad,
      v_pac->>'codigo_interno',
      NULLIF(v_pac->>'anio_construccion','')::int,
      NULLIF(v_pac->>'id_estado_conservacion','')::smallint,
      NULLIF(v_pac->>'cuota_condominio_mensual','')::numeric,
      v_pac->>'url_recorrido_virtual',
      v_pac->>'ubicacion_direccion',
      v_pac->>'ubicacion_ciudad',
      NULLIF(v_pac->>'ubicacion_lat','')::numeric,
      NULLIF(v_pac->>'ubicacion_lng','')::numeric,
      NULLIF(v_pac->>'id_regimen_propiedad','')::smallint,
      v_pac->>'subtipo_condominio',
      v_pac->>'folio_real',
      v_pac->>'clave_catastral',
      v_pac->>'cuenta_predial',
      NULLIF(v_pac->>'valor_catastral','')::numeric,
      COALESCE((v_pac->>'predial_al_corriente')::boolean, false),
      COALESCE((v_pac->>'origen_ejidal')::boolean, false),
      COALESCE((v_pac->>'dominio_pleno')::boolean, true),
      COALESCE((v_pac->>'libre_gravamen')::boolean, true),
      v_pac->>'gravamen_descripcion',
      NULLIF(v_pac->>'monto_predial_anual','')::numeric
    );
  END IF;

  -- Atributos por tipo
  IF v_atts IS NOT NULL THEN
    IF v_tipo = 14 THEN
      INSERT INTO public.propiedades_atributos_terreno (
        id_propiedad, id_tipo_terreno, manzana, lote,
        superficie_terreno, superficie_construida, frente, fondo, numero_frentes,
        topografia, forma, id_uso_suelo, densidad, cos, cus, cas,
        niveles_permitidos, restricciones,
        serv_agua, serv_drenaje, serv_electricidad, serv_gas, serv_fibra,
        serv_alumbrado, serv_calles_pavimentadas, serv_banquetas,
        serv_urbanizado, serv_factibilidad_agua, serv_factibilidad_cfe
      ) VALUES (
        v_id_propiedad,
        NULLIF(v_atts->>'id_tipo_terreno','')::smallint,
        v_atts->>'manzana', v_atts->>'lote',
        NULLIF(v_atts->>'superficie_terreno','')::numeric,
        NULLIF(v_atts->>'superficie_construida','')::numeric,
        NULLIF(v_atts->>'frente','')::numeric,
        NULLIF(v_atts->>'fondo','')::numeric,
        NULLIF(v_atts->>'numero_frentes','')::smallint,
        v_atts->>'topografia', v_atts->>'forma',
        NULLIF(v_atts->>'id_uso_suelo','')::smallint,
        NULLIF(v_atts->>'densidad','')::numeric,
        NULLIF(v_atts->>'cos','')::numeric,
        NULLIF(v_atts->>'cus','')::numeric,
        NULLIF(v_atts->>'cas','')::numeric,
        NULLIF(v_atts->>'niveles_permitidos','')::smallint,
        v_atts->>'restricciones',
        COALESCE((v_atts->>'serv_agua')::boolean,false),
        COALESCE((v_atts->>'serv_drenaje')::boolean,false),
        COALESCE((v_atts->>'serv_electricidad')::boolean,false),
        COALESCE((v_atts->>'serv_gas')::boolean,false),
        COALESCE((v_atts->>'serv_fibra')::boolean,false),
        COALESCE((v_atts->>'serv_alumbrado')::boolean,false),
        COALESCE((v_atts->>'serv_calles_pavimentadas')::boolean,false),
        COALESCE((v_atts->>'serv_banquetas')::boolean,false),
        COALESCE((v_atts->>'serv_urbanizado')::boolean,false),
        COALESCE((v_atts->>'serv_factibilidad_agua')::boolean,false),
        COALESCE((v_atts->>'serv_factibilidad_cfe')::boolean,false)
      );
    ELSIF v_tipo = 12 THEN
      INSERT INTO public.propiedades_atributos_oficina (
        id_propiedad, edificio, piso, numero_oficina, corredor,
        area_rentable, area_util, factor_eficiencia, id_estandar_medicion,
        altura_libre, niveles, divisible, minimo_rentable,
        id_estado_acabados, id_clase_edificio, id_hvac,
        elevadores, planta_luz, seguridad_cctv, control_acceso,
        cajones_estacionamiento, ratio_estacionamiento, fibra, certificacion_leed
      ) VALUES (
        v_id_propiedad,
        v_atts->>'edificio', v_atts->>'piso',
        v_atts->>'numero_oficina', v_atts->>'corredor',
        NULLIF(v_atts->>'area_rentable','')::numeric,
        NULLIF(v_atts->>'area_util','')::numeric,
        NULLIF(v_atts->>'factor_eficiencia','')::numeric,
        NULLIF(v_atts->>'id_estandar_medicion','')::smallint,
        NULLIF(v_atts->>'altura_libre','')::numeric,
        NULLIF(v_atts->>'niveles','')::smallint,
        COALESCE((v_atts->>'divisible')::boolean,false),
        NULLIF(v_atts->>'minimo_rentable','')::numeric,
        NULLIF(v_atts->>'id_estado_acabados','')::smallint,
        NULLIF(v_atts->>'id_clase_edificio','')::smallint,
        NULLIF(v_atts->>'id_hvac','')::smallint,
        NULLIF(v_atts->>'elevadores','')::smallint,
        COALESCE((v_atts->>'planta_luz')::boolean,false),
        COALESCE((v_atts->>'seguridad_cctv')::boolean,false),
        COALESCE((v_atts->>'control_acceso')::boolean,false),
        NULLIF(v_atts->>'cajones_estacionamiento','')::smallint,
        v_atts->>'ratio_estacionamiento',
        COALESCE((v_atts->>'fibra')::boolean,false),
        v_atts->>'certificacion_leed'
      );
    ELSIF v_tipo IN (11, 13) THEN
      INSERT INTO public.propiedades_atributos_comercio (
        id_propiedad, id_tipo_comercio, plaza, numero_local, nivel,
        gla, area_privativa, mezzanine, terraza,
        frente_exhibicion, fondo, altura_libre, esquina,
        id_estado_entrega, id_tipo_centro, visibilidad,
        aforo_vehicular, foot_traffic, cajones_estacionamiento,
        capacidad_carga_piso, andenes_carga, patio_maniobras,
        kva_energia, licencia_funcionamiento
      ) VALUES (
        v_id_propiedad,
        NULLIF(v_atts->>'id_tipo_comercio','')::smallint,
        v_atts->>'plaza', v_atts->>'numero_local', v_atts->>'nivel',
        NULLIF(v_atts->>'gla','')::numeric,
        NULLIF(v_atts->>'area_privativa','')::numeric,
        NULLIF(v_atts->>'mezzanine','')::numeric,
        NULLIF(v_atts->>'terraza','')::numeric,
        NULLIF(v_atts->>'frente_exhibicion','')::numeric,
        NULLIF(v_atts->>'fondo','')::numeric,
        NULLIF(v_atts->>'altura_libre','')::numeric,
        COALESCE((v_atts->>'esquina')::boolean,false),
        NULLIF(v_atts->>'id_estado_entrega','')::smallint,
        NULLIF(v_atts->>'id_tipo_centro','')::smallint,
        v_atts->>'visibilidad',
        NULLIF(v_atts->>'aforo_vehicular','')::int,
        NULLIF(v_atts->>'foot_traffic','')::int,
        NULLIF(v_atts->>'cajones_estacionamiento','')::smallint,
        NULLIF(v_atts->>'capacidad_carga_piso','')::numeric,
        NULLIF(v_atts->>'andenes_carga','')::smallint,
        NULLIF(v_atts->>'patio_maniobras','')::numeric,
        NULLIF(v_atts->>'kva_energia','')::numeric,
        COALESCE((v_atts->>'licencia_funcionamiento')::boolean,false)
      );
    END IF;
  END IF;

  -- Oferta renta (opcional)
  IF v_renta IS NOT NULL AND (v_renta->>'renta_mensual') IS NOT NULL THEN
    INSERT INTO public.ofertas_renta (
      id_propiedad, activa, renta_mensual, precio_m2_mes, moneda,
      id_tipo_contrato, cam, cam_es_porcentaje, cuota_publicidad,
      plazo_forzoso_meses, deposito_meses, meses_gracia, escalacion_anual,
      id_indexacion, iva_aplica, id_giro_permitido, exclusividad,
      id_tipo_garantia, id_estatus_renta, comision_corretaje, comision_es_porcentaje,
      disponible_desde, fecha_fin_contrato_actual, inquilino_actual, porcentaje_ocupacion
    ) VALUES (
      v_id_propiedad,
      COALESCE((v_renta->>'activa')::boolean, true),
      (v_renta->>'renta_mensual')::numeric,
      NULLIF(v_renta->>'precio_m2_mes','')::numeric,
      COALESCE(v_renta->>'moneda','MXN'),
      NULLIF(v_renta->>'id_tipo_contrato','')::smallint,
      NULLIF(v_renta->>'cam','')::numeric,
      COALESCE((v_renta->>'cam_es_porcentaje')::boolean,false),
      NULLIF(v_renta->>'cuota_publicidad','')::numeric,
      NULLIF(v_renta->>'plazo_forzoso_meses','')::smallint,
      NULLIF(v_renta->>'deposito_meses','')::smallint,
      COALESCE(NULLIF(v_renta->>'meses_gracia','')::smallint, 0),
      NULLIF(v_renta->>'escalacion_anual','')::numeric,
      NULLIF(v_renta->>'id_indexacion','')::smallint,
      COALESCE((v_renta->>'iva_aplica')::boolean,true),
      NULLIF(v_renta->>'id_giro_permitido','')::smallint,
      v_renta->>'exclusividad',
      NULLIF(v_renta->>'id_tipo_garantia','')::smallint,
      NULLIF(v_renta->>'id_estatus_renta','')::smallint,
      NULLIF(v_renta->>'comision_corretaje','')::numeric,
      COALESCE((v_renta->>'comision_es_porcentaje')::boolean,true),
      NULLIF(v_renta->>'disponible_desde','')::date,
      NULLIF(v_renta->>'fecha_fin_contrato_actual','')::date,
      v_renta->>'inquilino_actual',
      NULLIF(v_renta->>'porcentaje_ocupacion','')::numeric
    );
  END IF;

  RETURN v_id_propiedad;
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Aprobación: publica el activo. Solo Super Administrador
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.aprobar_activo_comercial(p_id_propiedad bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tipo int;
BEGIN
  IF NOT public.is_super_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Solo un Super Administrador puede aprobar un activo comercial';
  END IF;

  SELECT id_tipo_propiedad INTO v_tipo
  FROM public.propiedades WHERE id = p_id_propiedad;

  IF v_tipo IS NULL THEN
    RAISE EXCEPTION 'La propiedad % no existe', p_id_propiedad;
  END IF;

  -- Acotado a comerciales: los departamentos tienen su propio flujo y esta funcion no debe
  -- ser una via lateral para publicarlos.
  IF v_tipo <= 10 THEN
    RAISE EXCEPTION 'La propiedad % no es un activo comercial', p_id_propiedad;
  END IF;

  -- Idempotente: aprobar dos veces no falla ni cambia nada la segunda vez.
  UPDATE public.propiedades
     SET es_aprobado = true, fecha_actualizacion = CURRENT_TIMESTAMP
   WHERE id = p_id_propiedad AND es_aprobado IS DISTINCT FROM true;

  RETURN true;
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. Regresar a borrador. Simetría de la anterior
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.rechazar_activo_comercial(p_id_propiedad bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tipo int;
BEGIN
  IF NOT public.is_super_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Solo un Super Administrador puede regresar un activo a borrador';
  END IF;

  SELECT id_tipo_propiedad INTO v_tipo
  FROM public.propiedades WHERE id = p_id_propiedad;

  IF v_tipo IS NULL THEN
    RAISE EXCEPTION 'La propiedad % no existe', p_id_propiedad;
  END IF;
  IF v_tipo <= 10 THEN
    RAISE EXCEPTION 'La propiedad % no es un activo comercial', p_id_propiedad;
  END IF;

  UPDATE public.propiedades
     SET es_aprobado = false, fecha_actualizacion = CURRENT_TIMESTAMP
   WHERE id = p_id_propiedad AND es_aprobado IS DISTINCT FROM false;

  RETURN true;
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. Permisos
--    Crear queda abierto a cualquier sesión autenticada; aprobar y rechazar también se
--    otorgan a `authenticated` porque el control real está DENTRO de la función
--    (is_super_admin), no en el GRANT. `anon` no ejecuta ninguna.
-- ═══════════════════════════════════════════════════════════════════════════════
REVOKE ALL ON FUNCTION public.crear_activo_comercial(jsonb)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.aprobar_activo_comercial(bigint)   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rechazar_activo_comercial(bigint)  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.crear_activo_comercial(jsonb)     TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.aprobar_activo_comercial(bigint)  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rechazar_activo_comercial(bigint) TO authenticated, service_role;

COMMENT ON FUNCTION public.crear_activo_comercial(jsonb) IS
  'Alta de activo comercial. Abierta a cualquier sesion autenticada; el activo nace en '
  'borrador (es_aprobado = false) y lo publica aprobar_activo_comercial. Exige Proyecto, '
  'Edificio y Modelo salvo que el payload lo declare independiente (en_proyecto = false) o '
  'sea un terreno (tipo 14), que nunca cuelga de un desarrollo.';
COMMENT ON FUNCTION public.aprobar_activo_comercial(bigint) IS
  'Publica un activo comercial (es_aprobado = true). Solo Super Administrador. Idempotente. '
  'OJO: la policy propiedades_passthrough_write permite a cualquier sesion authenticated '
  'poner es_aprobado = true por PostgREST sin pasar por aqui; este gate cubre la via de la '
  'app, no la de la API.';
COMMENT ON FUNCTION public.rechazar_activo_comercial(bigint) IS
  'Regresa un activo comercial a borrador (es_aprobado = false). Solo Super Administrador.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. Guard de cierre: las tres funciones quedaron como se espera
-- ═══════════════════════════════════════════════════════════════════════════════
DO $cierre$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'crear_activo_comercial';

  IF v_def LIKE '%not authorized%' THEN
    RAISE EXCEPTION 'crear_activo_comercial sigue con el gate viejo: el CREATE OR REPLACE no surtio efecto.';
  END IF;

  IF v_def NOT LIKE '%false,   -- BORRADOR%' THEN
    RAISE EXCEPTION 'crear_activo_comercial no esta forzando es_aprobado = false: el activo no naceria en borrador.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN ('aprobar_activo_comercial','rechazar_activo_comercial')
    GROUP BY true HAVING count(*) = 2
  ) THEN
    RAISE EXCEPTION 'Faltan aprobar_activo_comercial o rechazar_activo_comercial.';
  END IF;

  RAISE NOTICE
    'Activos comerciales: alta abierta en borrador, aprobacion y rechazo acotados a Super Administrador.';
END
$cierre$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
-- El gate viejo ya no esta y el borrador se fuerza:
--   SELECT pg_get_functiondef(oid) LIKE '%not authorized%' AS tiene_gate_viejo
--   FROM pg_proc WHERE proname = 'crear_activo_comercial';
--   -- esperado: false
--
-- Las tres funciones existen y `anon` no puede ejecutarlas:
--   SELECT p.proname, p.prosecdef,
--          has_function_privilege('anon',  p.oid, 'EXECUTE') AS anon,
--          has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname = 'public'
--     AND p.proname IN ('crear_activo_comercial','aprobar_activo_comercial','rechazar_activo_comercial');
--   -- esperado: prosecdef = true, anon = false, auth = true
--
-- Los activos existentes no se tocan:
--   SELECT count(*) FILTER (WHERE es_aprobado) AS aprobados,
--          count(*) FILTER (WHERE NOT es_aprobado) AS borradores
--   FROM public.propiedades WHERE id_tipo_propiedad > 10;
--   -- esperado: los 95 comerciales siguen en es_aprobado = true
--
-- ─── Front ────────────────────────────────────────────────────────────────────
-- La lista de Activos Comerciales ya pinta el badge Aprobado/Borrador desde es_aprobado,
-- asi que el estado se ve sin cambiar nada. Lo que falta en el front es el boton de
-- aprobar/rechazar llamando a las dos RPC nuevas, visible solo para Super Administrador.
