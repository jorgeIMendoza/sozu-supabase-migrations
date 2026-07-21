-- get_oferta_financials · bodegas incluidas suman a la base del precio final
-- Fecha: 2026-07-21
--
-- Cuando la propiedad tiene bodega con es_incluido=true, su valor
-- (productos_servicios.precio_lista × bodegas.m2) suma a la BASE del precio final:
--   precio_final = (precio_lista_depa + Σ costo_bodega_incluida) × (1 + %descuento/100)
-- El precio_lista mostrado (y precio/m²) sigue siendo el del depa; solo cambia la base.
-- Front ya aplica la regla (oferta digital, PDF, cuenta manual); este RPC es la fuente de
-- verdad server-side de la oferta digital y debe replicarla.
--
-- Cambios vs versión previa: CTE bodegas_inc (suma valor de bodegas incluidas); params expone
-- bodegas_incluidas_total + precio_base_calculo; planes.precio_final usa precio_base_calculo.
-- El JSON sigue devolviendo precio_lista = precio del depa (display) + los 2 nuevos informativos.
--
-- Idempotente: CREATE OR REPLACE. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

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
  SELECT p.id, p.precio_lista, p.id_edificio_modelo
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
    20000::numeric                           AS apartado,
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
