-- =============================================================================
-- La oferta digital cobra el apartado REAL de la propiedad, no $20,000 fijos
-- =============================================================================
-- `get_oferta_financials(integer)` arma su CTE `params` con `20000::numeric AS apartado`,
-- y de ahí salen `apartado` (cabecera y por plan) y `enganche_neto`. Ese número es el que
-- ve el cliente en la oferta digital y el que se le pide transferir en el flujo SPEI.
--
-- Pero el monto ya está modelado, y a nivel PROPIEDAD, no proyecto:
-- `propiedades.monto_apartado` (numeric, nullable, sin default).
--
-- ─── Verificado read-only el 2026-08-13 en prod (tzmhgfjmddkfyffkkmto) ───────
-- · 1,232 de 53,941 propiedades tienen monto_apartado. Los valores son reales y
--   variados: 20000 (699), 0 (164), 30000 (149), 100000 (145), 50000 (75).
-- · Sobre las 2,967 ofertas ACTIVAS:
--       115  propiedades con apartado de $100,000  ← hoy se les muestra $20,000
--       116  propiedades sin monto (NULL)
--         0  propiedades con monto 0
--   Son 80,000 pesos de diferencia por oferta, en la pantalla donde el cliente
--   transfiere. El bug ya está en producción; esta migración lo cierra.
-- · md5(pg_get_functiondef) idéntico en dev y prod y sin cambios desde el 2026-08-11:
--   2c8d839e81119143b63f8daa79953cf7
--
-- ─── Reglas que aplica ───────────────────────────────────────────────────────
-- · monto_apartado con valor → se usa tal cual, incluido 0 (proyecto/unidad que no cobra
--   apartado). No se trata 0 como "sin configurar".
-- · monto_apartado NULL → 20,000, que es exactamente lo que se cobra hoy. Así las 116
--   ofertas sin monto no cambian de comportamiento.
--
-- ─── Ojo, cambio visible para comercial ──────────────────────────────────────
-- La RPC calcula en vivo, así que al aplicar esto las 115 ofertas de $100,000 pasan de
-- mostrar 20,000 a mostrar 100,000 de inmediato, incluidas las ya enviadas por correo.
-- Es la corrección correcta —el cliente estaba viendo un monto que no correspondía— pero
-- comercial tiene que saberlo antes del deploy, no después.
--
-- ─── Fuera de alcance ────────────────────────────────────────────────────────
-- · No se agrega columna en `proyectos`: el grano del negocio es la propiedad y ya está
--   modelado ahí. Una segunda fuente para el mismo dato solo podría desalinearse.
-- · No se rellenan las 52,709 propiedades sin monto: mientras sea NULL cae al 20,000 de
--   siempre. Poblarlas es trabajo de negocio, no de esta migración.
-- · El front no requiere cambios: ya lee `apartadoAmount` desde `fin.apartado`, con
--   APARTADO_DEFAULT_MXN solo como red de seguridad.
--
-- Mismo cuerpo que la versión viva salvo el CTE `prop` (trae monto_apartado) y `params`
-- (apartado sale de ahí). CREATE OR REPLACE conserva firma, SECURITY DEFINER y ACL,
-- incluido el EXECUTE para anon de 20260811000000.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §0. Guards
-- -----------------------------------------------------------------------------
DO $guard$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.get_oferta_financials(integer)') IS NULL THEN
    RAISE EXCEPTION 'Anchor no encontrado: public.get_oferta_financials(integer) no existe';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'propiedades' AND column_name = 'monto_apartado'
  ) THEN
    RAISE EXCEPTION 'No existe propiedades.monto_apartado; esta migración depende de esa columna';
  END IF;

  SELECT pg_get_functiondef('public.get_oferta_financials(integer)'::regprocedure) INTO v_def;

  IF NOT (SELECT p.prosecdef FROM pg_proc p
          WHERE p.oid = 'public.get_oferta_financials(integer)'::regprocedure) THEN
    RAISE EXCEPTION 'get_oferta_financials dejó de ser SECURITY DEFINER; revisar antes de reemplazarla';
  END IF;

  -- O trae el literal que venimos a quitar, o ya lee la columna (re-ejecución).
  IF v_def NOT LIKE '%20000::numeric%' AND v_def NOT LIKE '%monto_apartado%' THEN
    RAISE EXCEPTION
      'Drift en get_oferta_financials: no se encontró ni el literal 20000::numeric ni monto_apartado. Reconciliar el cuerpo vivo antes de aplicar.';
  END IF;

  IF md5(v_def) <> '2c8d839e81119143b63f8daa79953cf7' THEN
    RAISE WARNING
      'get_oferta_financials cambió respecto al cuerpo auditado (md5 vivo=%). Esta migración lo reemplaza con la versión del repo.',
      md5(v_def);
  END IF;
END;
$guard$;

-- -----------------------------------------------------------------------------
-- §1. La RPC deja de hardcodear 20000
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_oferta_financials(p_oferta_id integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
WITH o AS (
  SELECT id, id_propiedad, id_esquema_pago_seleccionado, fecha_generacion, email_creador
  FROM ofertas
  WHERE id = p_oferta_id AND COALESCE(activo, true)
),
prop AS (
  SELECT p.id, p.precio_lista, p.id_edificio_modelo, p.monto_apartado
  FROM propiedades p
  WHERE p.id = (SELECT id_propiedad FROM o)
),
proj AS (
  SELECT pr.id,
         COALESCE(pr.fecha_entrega_proyecto::timestamp, pr.fecha_entrega) AS fecha_entrega
  FROM proyectos pr
  WHERE pr.id = (
    SELECT ed.id_proyecto FROM edificios ed
    WHERE ed.id = (
      SELECT em.id_edificio FROM edificios_modelos em
      WHERE em.id = (SELECT id_edificio_modelo FROM prop)
    )
  )
),
-- Valor de las bodegas incluidas (es_incluido) de la propiedad.
-- Costo = productos_servicios.precio_lista (precio por m²) × bodegas.m2.
-- Bodega incluida sin producto → costo 0.
bodegas_inc AS (
  SELECT COALESCE(SUM(COALESCE(ps.precio_lista, 0) * COALESCE(b.m2, 0)), 0)::numeric AS total
  FROM bodegas b
  LEFT JOIN productos_servicios ps ON ps.id = b.id_producto
  WHERE b.id_propiedad = (SELECT id FROM prop)
    AND b.es_incluido = true
    AND COALESCE(b.activo, true)
),
params AS (
  SELECT
    (SELECT precio_lista FROM prop)::numeric AS precio_lista,
    (SELECT total FROM bodegas_inc)::numeric  AS bodegas_incluidas_total,
    ((SELECT precio_lista FROM prop)::numeric + (SELECT total FROM bodegas_inc)::numeric) AS precio_base_calculo,
    (SELECT fecha_generacion FROM o)         AS fecha_generacion,
    (SELECT fecha_entrega FROM proj)         AS fecha_entrega,
    -- Apartado real de la unidad. El COALESCE cubre la propiedad sin monto configurado
    -- (NULL), que conserva los 20,000 de siempre. Un 0 explícito SÍ se respeta: es una
    -- unidad que no cobra apartado.
    COALESCE((SELECT monto_apartado FROM prop), 20000)::numeric AS apartado,
    CASE
      WHEN (SELECT fecha_entrega FROM proj) IS NULL THEN 0
      ELSE GREATEST(0,
        ( (EXTRACT(YEAR  FROM (SELECT fecha_entrega FROM proj))::int - EXTRACT(YEAR  FROM CURRENT_DATE)::int) * 12
        + (EXTRACT(MONTH FROM (SELECT fecha_entrega FROM proj))::int - EXTRACT(MONTH FROM CURRENT_DATE)::int) ) - 1
      )
    END AS meses_restantes
),
planes AS (
  SELECT
    e.id, e.nombre, e.orden, e.es_manual,
    COALESCE(e.porcentaje_descuento_aumento, 0) AS pct_desc,
    COALESCE(e.porcentaje_enganche, 0)          AS pct_eng,
    COALESCE(e.porcentaje_mensualidades, 0)     AS pct_mens,
    COALESCE(e.numero_mensualidades, 0)         AS num_mens,
    e.tramos_mensualidad,
    -- Base = precio_lista_depa + bodegas incluidas; luego se aplica el % descuento.
    (SELECT precio_base_calculo FROM params) * (1 + COALESCE(e.porcentaje_descuento_aumento, 0)/100) AS precio_final
  FROM esquemas_pago e
  WHERE e.id_proyecto = (SELECT id FROM proj)
    AND COALESCE(e.activo, true)
    AND (e.es_manual = false OR e.id = (SELECT id_esquema_pago_seleccionado FROM o))
),
-- Tramos normalizados (monto en pesos) por esquema.
tramos AS (
  SELECT pl.id AS esquema_id,
    COALESCE((elem->>'monto')::numeric, (elem->>'monto_mensualidad')::numeric / 100, 0) AS monto,
    COALESCE((elem->>'numero_mensualidades')::int, 0)                                   AS meses,
    COALESCE((elem->>'orden')::int, 0)                                                  AS orden
  FROM planes pl,
    jsonb_array_elements(
      CASE WHEN jsonb_typeof(pl.tramos_mensualidad) = 'array' THEN pl.tramos_mensualidad ELSE '[]'::jsonb END
    ) elem
),
calc AS (
  SELECT pl.*,
    (pl.precio_final * pl.pct_eng/100) AS enganche_total,
    (SELECT COALESCE(bool_or(t.monto > 0), false) FROM tramos t WHERE t.esquema_id = pl.id) AS tramo_has,
    (SELECT COALESCE(SUM(t.meses), 0)             FROM tramos t WHERE t.esquema_id = pl.id) AS tramo_meses,
    (SELECT COALESCE(SUM(t.monto * t.meses), 0)   FROM tramos t WHERE t.esquema_id = pl.id) AS tramo_parcialidades,
    (SELECT t.monto FROM tramos t WHERE t.esquema_id = pl.id ORDER BY t.orden LIMIT 1)      AS tramo_monto_first
  FROM planes pl
),
calc2 AS (
  SELECT c.*,
    CASE
      WHEN c.tramo_has THEN
        CASE WHEN c.es_manual THEN c.tramo_meses ELSE (SELECT meses_restantes FROM params) END
      ELSE LEAST((SELECT meses_restantes FROM params), c.num_mens)
    END AS meses,
    CASE
      WHEN c.tramo_has THEN
        CASE WHEN c.es_manual
             THEN CASE WHEN c.tramo_meses > 0 THEN c.tramo_parcialidades / c.tramo_meses ELSE 0 END
             ELSE COALESCE(c.tramo_monto_first, 0) END
      ELSE CASE WHEN c.num_mens > 0 THEN c.precio_final * c.pct_mens/100 / c.num_mens ELSE 0 END
    END AS mensualidad_monto
  FROM calc c
),
final AS (
  SELECT c.*,
    CASE
      WHEN c.tramo_has THEN
        CASE WHEN c.es_manual THEN c.tramo_parcialidades
             ELSE COALESCE(c.tramo_monto_first, 0) * c.meses END
      ELSE c.mensualidad_monto * c.meses
    END AS parcialidades_total
  FROM calc2 c
),
final2 AS (
  SELECT f.*,
    GREATEST(0, f.precio_final - f.enganche_total - f.parcialidades_total) AS escrituracion_monto
  FROM final f
)
SELECT jsonb_build_object(
  'oferta_id',        (SELECT id FROM o),
  'precio_lista',     (SELECT precio_lista FROM params),
  'bodegas_incluidas_total', (SELECT bodegas_incluidas_total FROM params),
  'precio_base_calculo',     (SELECT precio_base_calculo FROM params),
  'fecha_generacion', (SELECT fecha_generacion FROM params),
  'dias_vigencia',    7,
  'vigencia_hasta',   (SELECT fecha_generacion FROM params) + interval '7 days',
  'fecha_entrega',    (SELECT fecha_entrega FROM params),
  'meses_restantes',  (SELECT meses_restantes FROM params),
  'apartado',         (SELECT apartado FROM params),
  'agente', (
    SELECT jsonb_build_object(
      'email',           u.email,
      'nombre',          u.nombre,
      'foto_perfil_url', u.foto_perfil_url,
      'frase_perfil',    u.frase_perfil,
      'id_persona',      u.id_persona,
      'nombre_legal',    p.nombre_legal,
      'telefono',        p.telefono,
      'clave_pais',      p.clave_pais_telefono
    )
    FROM usuarios u
    LEFT JOIN personas p ON p.id = u.id_persona
    WHERE u.email = (SELECT email_creador FROM o)
    LIMIT 1
  ),
  'planes', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'esquema_id',          f.id,
      'nombre',              f.nombre,
      'orden',               f.orden,
      'es_manual',           f.es_manual,
      'pct_descuento',       f.pct_desc,
      'precio_final',        round(f.precio_final, 2),
      'pct_enganche',        f.pct_eng,
      'enganche_total',      round(f.enganche_total, 2),
      'apartado',            (SELECT apartado FROM params),
      'enganche_neto',       round(GREATEST(0, f.enganche_total - (SELECT apartado FROM params)), 2),
      'meses',               f.meses,
      'mensualidad_monto',   round(f.mensualidad_monto, 2),
      'parcialidades_total', round(f.parcialidades_total, 2),
      'pct_mensualidades',   CASE WHEN f.precio_final > 0 THEN round(f.parcialidades_total / f.precio_final * 100, 2) ELSE 0 END,
      'escrituracion_monto', round(f.escrituracion_monto, 2),
      'pct_escrituracion',   CASE WHEN f.precio_final > 0 THEN round(f.escrituracion_monto / f.precio_final * 100, 2) ELSE 0 END,
      'tramos', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('orden', t.orden, 'monto', round(t.monto, 2), 'meses', t.meses) ORDER BY t.orden)
        FROM tramos t WHERE t.esquema_id = f.id AND t.monto > 0
      ), '[]'::jsonb)
    ) ORDER BY f.orden NULLS LAST, f.id)
    FROM final2 f
  ), '[]'::jsonb)
);
$function$;

-- -----------------------------------------------------------------------------
-- §2. Post-check: el CREATE OR REPLACE debe haber conservado el ACL
-- -----------------------------------------------------------------------------
DO $post$
BEGIN
  IF NOT has_function_privilege('anon', 'public.get_oferta_financials(integer)'::regprocedure, 'execute') THEN
    RAISE EXCEPTION 'get_oferta_financials perdió el EXECUTE de anon; la oferta pública quedaría rota';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.get_oferta_financials(integer)'::regprocedure, 'execute') THEN
    RAISE EXCEPTION 'get_oferta_financials perdió el EXECUTE de authenticated';
  END IF;
END;
$post$;

COMMIT;

-- =============================================================================
-- Verificación (read-only, correr después del deploy)
-- =============================================================================
-- -- Ofertas activas cuyo apartado deja de ser 20,000 (esperado: las 115 de $100,000)
-- SELECT p.monto_apartado, count(*)
-- FROM public.ofertas o JOIN public.propiedades p ON p.id = o.id_propiedad
-- WHERE COALESCE(o.activo, true) AND p.monto_apartado IS NOT NULL AND p.monto_apartado <> 20000
-- GROUP BY p.monto_apartado;
--
-- -- La RPC devuelve el monto de la unidad
-- SELECT (public.get_oferta_financials(o.id) ->> 'apartado')::numeric AS rpc,
--        p.monto_apartado                                            AS columna
-- FROM public.ofertas o JOIN public.propiedades p ON p.id = o.id_propiedad
-- WHERE COALESCE(o.activo, true) AND p.monto_apartado = 100000 LIMIT 3;
--
-- -- Conserva SECURITY DEFINER y los EXECUTE
-- SELECT prosecdef,
--        has_function_privilege('anon', oid, 'execute')          AS anon_exec,
--        has_function_privilege('authenticated', oid, 'execute') AS auth_exec
-- FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='get_oferta_financials';
-- =============================================================================
