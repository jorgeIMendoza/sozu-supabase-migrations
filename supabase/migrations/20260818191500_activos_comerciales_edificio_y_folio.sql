-- Activos comerciales: vínculo por edificio y folio automático
-- Fecha: 2026-08-18
-- Origen: Ejecuciones/ejecusiones.md (documento consolidado)
--
-- ═══════════════════════════════════════════════════════════════════════════════
-- ATENCION: EL DOCUMENTO PARTE DE UNA PREMISA QUE YA NO SE CUMPLE
-- ═══════════════════════════════════════════════════════════════════════════════
-- El documento dice sustituir a los dos anteriores "que no llegaron a ejecutarse". Los dos
-- SI se ejecutaron, en los dos entornos:
--
--   20260818143700_propiedades_activos_sin_desarrollo.sql
--   20260818143800_activos_comerciales_alta_draft_aprobacion.sql
--
--   Deploy Migrations to Dev        2026-08-19T00:12:12Z  success
--   Deploy Migrations to Production 2026-08-19T00:16:52Z  success
--
-- Por eso este archivo NO reaplica lo que ya esta puesto. De los cuatro cambios que pide el
-- documento, dos ya estan vivos:
--
--   1. Alta abierta y borrador ............ YA APLICADO (143800)
--   2. Activos sin desarrollo ............. YA APLICADO (143700)
--   3. Vinculo por edificio ............... ESTE ARCHIVO
--   4. Folio automatico ................... ESTE ARCHIVO
--
-- Reaplicar los dos primeros tal como los describe el documento no seria inocuo: su
-- reemplazo de `crear_activo_comercial` esta redactado sobre la definicion ANTERIOR (la del
-- gate 'not authorized'), que ya no existe en ningun ambiente. Aqui se parte de la
-- definicion vigente —la que dejo 143800— y se le aplican solo los cambios 3 y 4.
--
-- ─── Qué entra ────────────────────────────────────────────────────────────────
-- · `propiedades.id_edificio`: columna NUEVA, no un reemplazo. Las unidades de desarrollo
--   siguen usando id_edificio_modelo, donde el modelo si significa algo (describe la
--   distribucion de un departamento). Un activo comercial usa id_edificio y deja el otro en
--   NULL. Migrar los 95 existentes queda fuera: funcionan como estan.
-- · `numero_propiedad` deja de ser obligatorio y lo asigna la funcion.
-- · Folio consecutivo generado EN LA BASE, no en el cliente: dos usuarios guardando a la vez
--   producirian el mismo numero si el consecutivo se calculara leyendo el maximo. Una
--   secuencia lo resuelve sin bloqueos. Una sola secuencia con prefijo por tipo (LOC-, OFI-,
--   BOD-, TER-), para que el folio sea unico en toda la cartera y el prefijo solo lo haga
--   legible.
--
-- ─── Lo que NO se crea, y por qué ─────────────────────────────────────────────
-- El documento pide un indice `uq_prop_sin_modelo_numero` sobre numero_propiedad. Ya existe
-- `uq_prop_sin_edificio_numero`, creado por 143700, con el mismo alcance util:
--
--   UNIQUE (numero_propiedad) WHERE id_edificio_modelo IS NULL AND activo
--
-- La unica diferencia del propuesto es un `numero_propiedad IS NOT NULL` en el predicado,
-- que no cambia el comportamiento: en PostgreSQL dos NULL nunca colisionan en un indice
-- unico. Crear el segundo seria un indice unico duplicado sobre la misma tabla, con su coste
-- en cada escritura y sin ninguna proteccion extra.
--
-- Verificado contra el baseline: `edificios.id` es integer GENERATED ALWAYS AS IDENTITY, asi
-- que la FK es integer.
--
-- Idempotente: ADD COLUMN / CREATE INDEX / CREATE SEQUENCE IF NOT EXISTS, DROP CONSTRAINT
-- antes del ADD, y CREATE OR REPLACE en las funciones. Sin BEGIN/COMMIT (el CI envuelve cada
-- archivo, y un COMMIT explicito dejaria fuera el registro en schema_migrations).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 0. Guard previo: partir del estado que se espera
-- ═══════════════════════════════════════════════════════════════════════════════
DO $guard$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'crear_activo_comercial'
    AND pg_get_function_identity_arguments(p.oid) = 'payload jsonb';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'No existe public.crear_activo_comercial(jsonb).';
  END IF;

  -- El gate viejo solo puede seguir ahi si 143800 no llego a este ambiente. En ese caso
  -- este archivo dejaria el alta abierta sin querer, asi que se aborta.
  IF v_def LIKE '%not authorized%' THEN
    RAISE EXCEPTION
      'crear_activo_comercial aun tiene el gate "not authorized": falta aplicar 20260818143800_activos_comerciales_alta_draft_aprobacion.sql antes que este archivo.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'propiedades'
      AND column_name = 'id_edificio_modelo' AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION
      'propiedades.id_edificio_modelo sigue siendo NOT NULL: falta aplicar 20260818143700_propiedades_activos_sin_desarrollo.sql.';
  END IF;
END
$guard$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Vínculo por edificio
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.propiedades
  ADD COLUMN IF NOT EXISTS id_edificio integer;

ALTER TABLE public.propiedades
  DROP CONSTRAINT IF EXISTS fk_propiedades_edificio;
ALTER TABLE public.propiedades
  ADD CONSTRAINT fk_propiedades_edificio
  FOREIGN KEY (id_edificio) REFERENCES public.edificios (id)
  ON UPDATE CASCADE ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS ix_propiedades_id_edificio
  ON public.propiedades (id_edificio) WHERE id_edificio IS NOT NULL;

COMMENT ON COLUMN public.propiedades.id_edificio IS
  'Edificio del activo comercial. Las unidades de desarrollo usan id_edificio_modelo; un '
  'activo comercial usa esta y deja aquella en NULL.';

COMMENT ON COLUMN public.propiedades.id_edificio_modelo IS
  'Vinculo con edificios_modelos. NULL en activos comerciales: el modelo describe la '
  'distribucion de un departamento y no les aplica.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. El número deja de ser obligatorio: lo asigna la función
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.propiedades
  ALTER COLUMN numero_propiedad DROP NOT NULL;

CREATE SEQUENCE IF NOT EXISTS public.activos_comerciales_folio_seq;

COMMENT ON SEQUENCE public.activos_comerciales_folio_seq IS
  'Consecutivo unico de folio de activo comercial. Una sola secuencia para toda la cartera: '
  'el prefijo por tipo solo hace legible el folio, no lo particiona.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. Folio legible por tipo
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.siguiente_folio_activo_comercial(p_tipo int)
 RETURNS text
 LANGUAGE sql
 VOLATILE
 SET search_path TO 'public'
AS $function$
  SELECT CASE p_tipo
           WHEN 11 THEN 'LOC-'
           WHEN 12 THEN 'OFI-'
           WHEN 13 THEN 'BOD-'
           WHEN 14 THEN 'TER-'
           ELSE 'ACT-'
         END
      || lpad(nextval('public.activos_comerciales_folio_seq')::text, 6, '0');
$function$;

COMMENT ON FUNCTION public.siguiente_folio_activo_comercial(int) IS
  'Folio consecutivo de activo comercial, con prefijo legible por tipo. Una sola secuencia: '
  'el folio es unico en toda la cartera.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. crear_activo_comercial: edificio en vez de modelo, y folio automático
--    Se parte de la definición vigente (la que dejó 143800) y se le aplican solo los
--    cambios 3 y 4 del documento. El gate de creación y el borrador ya venían de ahí.
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
  -- declara el payload, y solo entonces se exige el edificio.
  IF v_tipo <> 14
     AND COALESCE((v_prop->>'en_proyecto')::boolean, true)
     AND NULLIF(v_prop->>'id_edificio','') IS NULL THEN
    RAISE EXCEPTION 'Falta el edificio: elige Proyecto y Edificio, o marca el activo como independiente';
  END IF;

  IF v_tipo = 14 AND NULLIF(v_prop->>'id_edificio','') IS NOT NULL THEN
    RAISE EXCEPTION 'Un terreno no puede pertenecer a un desarrollo';
  END IF;

  -- id_edificio_modelo NO se envia: queda NULL. El modelo describe la distribucion de un
  -- departamento y no aplica a un activo comercial.
  INSERT INTO public.propiedades (
    id_entidad_relacionada_dueno, id_vista, id_tipo_transaccion,
    id_edificio, id_tipo_propiedad, id_estatus_disponibilidad,
    numero_propiedad, numero_piso, m2_interiores, m2_exteriores,
    precio_lista, descripcion, url_imagen_portada,
    es_aprobado, activo
  ) VALUES (
    NULLIF(v_prop->>'id_entidad_relacionada_dueno','')::bigint,
    NULLIF(v_prop->>'id_vista','')::int,
    NULLIF(v_prop->>'id_tipo_transaccion','')::int,
    NULLIF(v_prop->>'id_edificio','')::int,
    v_tipo,
    COALESCE(NULLIF(v_prop->>'id_estatus_disponibilidad','')::int, 2),
    COALESCE(NULLIF(v_prop->>'numero_propiedad',''),
             public.siguiente_folio_activo_comercial(v_tipo)),
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

COMMENT ON FUNCTION public.crear_activo_comercial(jsonb) IS
  'Alta de activo comercial. Abierta a cualquier sesion autenticada; nace en borrador '
  '(es_aprobado = false) y lo publica aprobar_activo_comercial. Cuelga de id_edificio, no de '
  'id_edificio_modelo. Si el payload no trae numero_propiedad, se asigna un folio '
  'consecutivo con prefijo por tipo.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. Permisos
-- ═══════════════════════════════════════════════════════════════════════════════
REVOKE ALL ON FUNCTION public.siguiente_folio_activo_comercial(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.siguiente_folio_activo_comercial(int) TO authenticated, service_role;

-- La funcion de alta es SECURITY DEFINER, asi que la secuencia la consume su owner; el
-- GRANT queda por si el folio se pide de forma suelta desde la app.
GRANT USAGE ON SEQUENCE public.activos_comerciales_folio_seq TO authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. Guard de cierre
-- ═══════════════════════════════════════════════════════════════════════════════
DO $cierre$
DECLARE
  v_def   text;
  v_cols  int;
  v_folio text;
BEGIN
  SELECT count(*) INTO v_cols
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'propiedades'
    AND column_name = 'id_edificio';

  IF v_cols <> 1 THEN
    RAISE EXCEPTION 'No quedo creada propiedades.id_edificio.';
  END IF;

  SELECT count(*) INTO v_cols
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'propiedades'
    AND column_name = 'numero_propiedad' AND is_nullable = 'YES';

  IF v_cols <> 1 THEN
    RAISE EXCEPTION 'numero_propiedad sigue siendo NOT NULL: la funcion no podria omitirlo.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'crear_activo_comercial'
    AND pg_get_function_identity_arguments(p.oid) = 'payload jsonb';

  IF v_def NOT LIKE '%siguiente_folio_activo_comercial%' THEN
    RAISE EXCEPTION 'crear_activo_comercial no quedo con el folio automatico.';
  END IF;

  -- El folio se prueba de verdad, no solo por texto. Consume un valor de la secuencia, que
  -- es justo lo que se espera de un consecutivo.
  SELECT public.siguiente_folio_activo_comercial(12) INTO v_folio;

  IF v_folio IS NULL OR v_folio NOT LIKE 'OFI-%' THEN
    RAISE EXCEPTION 'siguiente_folio_activo_comercial(12) devolvio %, se esperaba un OFI-xxxxxx.', v_folio;
  END IF;

  RAISE NOTICE
    'Activos comerciales: id_edificio creada, numero_propiedad opcional, folio de prueba %.',
    v_folio;
END
$cierre$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='propiedades'
--     AND column_name IN ('id_edificio','id_edificio_modelo','numero_propiedad')
--   ORDER BY column_name;
--   -- esperado: id_edificio integer YES · id_edificio_modelo integer YES
--   --           numero_propiedad text YES
--
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid='public.propiedades'::regclass AND conname='fk_propiedades_edificio';
--
--   SELECT public.siguiente_folio_activo_comercial(11),  -- LOC-
--          public.siguiente_folio_activo_comercial(12),  -- OFI-
--          public.siguiente_folio_activo_comercial(13),  -- BOD-
--          public.siguiente_folio_activo_comercial(14);  -- TER-
--
-- Los 95 activos existentes no se tocan: conservan su id_edificio_modelo y su numero.
--   SELECT count(*) FILTER (WHERE id_edificio IS NOT NULL) AS con_edificio,
--          count(*) FILTER (WHERE id_edificio_modelo IS NOT NULL) AS con_modelo
--   FROM public.propiedades WHERE id_tipo_propiedad > 10;
--   -- esperado justo despues de aplicar: con_edificio = 0, con_modelo = 95
--
-- ─── Lo que sigue pendiente, del PR anterior ──────────────────────────────────
-- La policy `propiedades_passthrough_write` permite a cualquier sesion authenticated poner
-- es_aprobado = true por PostgREST sin pasar por aprobar_activo_comercial. El gate de Super
-- Administrador cubre la via de la app, no la de la API. Sigue sin resolverse.
--
-- ─── Front ────────────────────────────────────────────────────────────────────
-- El alta debe enviar `id_edificio` (no `id_edificio_modelo`), puede omitir
-- `numero_propiedad` para que la base asigne el folio, y debe mandar `en_proyecto: false`
-- cuando el activo sea independiente.
