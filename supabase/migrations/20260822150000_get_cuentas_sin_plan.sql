-- =============================================================================
-- get_cuentas_sin_plan(): detector de cuentas que nunca recibieron plan de pagos
-- =============================================================================
-- Solo lectura. No modifica datos y NO toca get_cuentas_plan_incompleto().
--
-- ─── El agujero ──────────────────────────────────────────────────────────────
-- `trg_autogenerar_plan_acuerdos` es AFTER INSERT ON acuerdos_pago: la generacion
-- del plan la arranca insertar un acuerdo. Si nunca se inserto ninguno, el trigger
-- nunca corre. Su propio comentario manda a `get_cuentas_plan_incompleto()` como red
-- de seguridad, pero esa red no ve el caso de CERO acuerdos. Verificado en prod
-- (2026-08-22) leyendo su definicion:
--   · `p_solo_tramos` con default TRUE exige `tramos_mensualidad` como array no
--     vacio. Los esquemas 725, 730 y 943 lo tienen en NULL -> la llamada por
--     default devuelve 0 filas.
--   · el filtro `GREATEST(...) > 0` (meses esperados) deja fuera al esquema 943,
--     que tiene `numero_mensualidades = 0`: CC-001730 es invisible incluso con
--     `p_solo_tramos = false`.
--   · `JOIN esquemas_pago` es INNER: una cuenta cuya oferta no tenga esquema
--     desaparece de la consulta.
-- Esa funcion mide "le faltan parcialidades a un plan que EXISTE" y eso esta bien;
-- no se toca. Lo que faltaba es la otra pregunta: "no hay plan".
--
-- ─── Alcance medido en prod al 2026-08-22 ────────────────────────────────────
-- 18 cuentas activas no-hijas sin ningun acuerdo activo; las 18 son de producto.
-- 3 tienen precio que cobrar:
--     906  $29,000.00  Bottura 901   Condensadoras Bottura   esq 725
--     1730 $29,000.00  Bottura 1109  Condensadoras Bottura   esq 943
--     627  $13,054.64  Margot 1207   Persianas/cortinas Joy  esq 730
-- Las otras 15 traen precio_final = 0 (nada que cobrar) pero son el mismo defecto,
-- asi que salen con p_incluir_sin_precio = true.
--
-- ─── Decisiones ──────────────────────────────────────────────────────────────
-- · `p_incluir_sin_precio` default FALSE: lo que urge son las 3 con precio.
-- · Devuelve `fecha_creacion` para distinguir el origen sin hardcodear nada: las de
--   la carga masiva comparten 2025-11-26 22:31:56.640874 al microsegundo; las altas
--   manuales son timestamps sueltos del 2026-01-27.
-- · LEFT JOIN a proyecto/unidad/producto: son columnas para LEER el resultado, no
--   para filtrar. Con INNER JOIN se repetiria el error de la funcion vieja.
-- · Sin GRANT a `anon`: es diagnostico interno.
--
-- NOTA de tipo (correccion sobre la especificacion): `cuentas_cobranza.fecha_creacion`
-- es `timestamp without time zone`, no `timestamptz`. Declararlo `timestamptz` NO rompe
-- el CI —se probo en contenedor: Postgres acepta el cast de asignacion al retornar— pero
-- le pega al valor el offset del `TimeZone` de la sesion, o sea le inventa una zona que
-- la columna no tiene. Con el default de Supabase (UTC) se lee igual y la diferencia es
-- cosmetica; con otra zona de sesion, no. Se declara `timestamp` para reflejar la columna
-- real y que el consumidor decida como interpretarla.
-- =============================================================================
BEGIN;

-- -----------------------------------------------------------------------------
-- §1. Guarda de anclaje: el nombre debe estar libre con OTRA firma
-- -----------------------------------------------------------------------------
-- CREATE OR REPLACE no puede cambiar el tipo de retorno de una funcion existente. Si
-- alguien ya creo `get_cuentas_sin_plan` —con otros argumentos, o con los mismos y otro
-- RETURNS TABLE— el REPLACE muere con 42P13 "cannot change return type of existing
-- function", que no dice cual es la diferencia ni que hay que hacer. Comprobado en
-- contenedor. Se aborta antes, nombrando la firma viva y el DROP que haria falta.
DO $anchor$
DECLARE
  v_firmas text;
BEGIN
  SELECT string_agg(format('%s(%s) -> %s',
                           p.proname,
                           pg_get_function_identity_arguments(p.oid),
                           pg_get_function_result(p.oid)), '; ')
    INTO v_firmas
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'get_cuentas_sin_plan'
    AND (pg_get_function_identity_arguments(p.oid) <> 'p_incluir_sin_precio boolean'
         OR pg_get_function_result(p.oid) <> 'TABLE(id_cuenta bigint, id_oferta integer, '
            || 'precio_final numeric, proyecto text, unidad text, producto text, '
            || 'es_producto boolean, id_esquema integer, fecha_creacion timestamp without time zone)');

  IF v_firmas IS NOT NULL THEN
    RAISE EXCEPTION
      'Ya existe public.get_cuentas_sin_plan con otra firma (%). Hay que DROP FUNCTION antes de reemplazarla.',
      v_firmas;
  END IF;
END
$anchor$;

-- -----------------------------------------------------------------------------
-- §2. La funcion
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_cuentas_sin_plan(
  p_incluir_sin_precio boolean DEFAULT false
)
RETURNS TABLE (
  id_cuenta       bigint,
  id_oferta       integer,
  precio_final    numeric,
  proyecto        text,
  unidad          text,
  producto        text,
  es_producto     boolean,
  id_esquema      integer,
  fecha_creacion  timestamp
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT cc.id,
         cc.id_oferta,
         cc.precio_final,
         pr.nombre,
         p.numero_propiedad,
         ps.nombre,
         (o.id_producto IS NOT NULL),
         o.id_esquema_pago_seleccionado,
         cc.fecha_creacion
  FROM public.cuentas_cobranza cc
  -- LEFT JOIN a proposito: son columnas para LEER el resultado, no para filtrar. La
  -- funcion vieja se volvio ciega justamente por hacer INNER JOIN a esquemas_pago.
  LEFT JOIN public.ofertas o              ON o.id  = cc.id_oferta
  LEFT JOIN public.productos_servicios ps ON ps.id = o.id_producto
  LEFT JOIN public.propiedades p          ON p.id  = COALESCE(cc.id_propiedad, o.id_propiedad)
  LEFT JOIN public.edificios_modelos em   ON em.id = p.id_edificio_modelo
  LEFT JOIN public.edificios ed           ON ed.id = em.id_edificio
  LEFT JOIN public.proyectos pr           ON pr.id = ed.id_proyecto
  WHERE cc.activo
    -- Las hijas de mantenimiento llevan precio_final = 0 y plan recurrente: no aplica.
    AND cc.id_cuenta_cobranza_padre IS NULL
    AND (p_incluir_sin_precio OR cc.precio_final > 0)
    -- La condicion entera: cero acuerdos activos. No depende del esquema.
    AND NOT EXISTS (
      SELECT 1 FROM public.acuerdos_pago a
      WHERE a.id_cuenta_cobranza = cc.id AND a.activo
    )
  ORDER BY cc.precio_final DESC, cc.id;
$function$;

COMMENT ON FUNCTION public.get_cuentas_sin_plan(boolean) IS
  'Cuentas activas no-hijas SIN ningun acuerdo activo, o sea que nunca recibieron plan de pagos. '
  'Responde una pregunta distinta a get_cuentas_plan_incompleto(), que mide si a un plan EXISTENTE '
  'le faltan parcialidades y por diseño no ve el caso de cero acuerdos (default p_solo_tramos = true '
  'exige tramos, y el filtro de meses esperados > 0 excluye los esquemas con numero_mensualidades = 0). '
  'p_incluir_sin_precio = false (default) devuelve solo las que tienen precio que cobrar.';

-- -----------------------------------------------------------------------------
-- §3. Permisos
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.get_cuentas_sin_plan(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_cuentas_sin_plan(boolean) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- §4. Self-verifying
-- -----------------------------------------------------------------------------
DO $verify$
DECLARE
  v_oid oid;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'get_cuentas_sin_plan'
    AND pg_get_function_identity_arguments(p.oid) = 'p_incluir_sin_precio boolean';

  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'No se creo public.get_cuentas_sin_plan(boolean).';
  END IF;

  IF (SELECT provolatile FROM pg_proc WHERE oid = v_oid) <> 's' THEN
    RAISE EXCEPTION 'get_cuentas_sin_plan deberia ser STABLE.';
  END IF;

  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
    RAISE EXCEPTION 'get_cuentas_sin_plan deberia ser SECURITY DEFINER.';
  END IF;

  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'get_cuentas_sin_plan: authenticated sin EXECUTE.';
  END IF;

  IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'get_cuentas_sin_plan: anon quedo con EXECUTE.';
  END IF;

  -- Coherencia: la funcion debe devolver exactamente lo que dice la condicion cruda.
  IF (SELECT count(*) FROM public.get_cuentas_sin_plan(true))
     <> (SELECT count(*) FROM public.cuentas_cobranza cc
          WHERE cc.activo AND cc.id_cuenta_cobranza_padre IS NULL
            AND NOT EXISTS (SELECT 1 FROM public.acuerdos_pago a
                             WHERE a.id_cuenta_cobranza = cc.id AND a.activo)) THEN
    RAISE EXCEPTION 'get_cuentas_sin_plan(true) no coincide con la consulta cruda.';
  END IF;
END
$verify$;

COMMIT;
