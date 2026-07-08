-- get_oferta_financials: desglose financiero autoritativo de la oferta digital.
--
-- Calcula server-side (no manipulable desde la consola del navegador) el desglose de
-- pagos de una oferta: apartado fijo ($20,000), enganche neto, parcialidades y pago a
-- escrituracion, ademas de meses restantes y vigencia (7 dias). El front solo renderiza.
--
-- Reglas de negocio:
--  - Apartado fijo $20,000 MXN, se descuenta del enganche (enganche_neto = enganche_total - 20000).
--  - precio_final = precio_lista * (1 + porcentaje_descuento_aumento/100).
--  - meses_restantes = de CURRENT_DATE a la fecha de entrega, menos 1 (el mes de entrega
--    no es mensualidad: es el Pago a escrituracion). Baja conforme pasan los dias.
--  - Pago a escrituracion absorbe el saldo: precio_final - enganche_total - parcialidades_total.
--  - Esquemas manuales conservan su calendario de tramos; los dinamicos recalculan vs entrega.
--
-- NOTA sobre tramos_mensualidad (esquemas escalonados). Existen DOS formatos en datos:
--   a) {orden, numero_mensualidades, monto}              -> monto en PESOS   (manuales)
--   b) {orden, numero_mensualidades, monto_mensualidad}  -> monto en CENTAVOS (dinamicos)
-- El monto por tramo se normaliza con COALESCE(monto, monto_mensualidad/100).
--
--  - Manual escalonado: parcialidades_total = SUM(monto_i * numero_mensualidades_i)
--    y meses = SUM(numero_mensualidades_i) (calendario contractual fijo). Los tramos
--    pueden tener montos distintos, por eso se suma tramo a tramo (no monto_1 * meses_totales).
--  - Dinamico escalonado: monto fijo del tramo * meses_restantes; el resto va a escrituracion.
--
-- SELECCION DE PLANES. Un proyecto puede tener cientos de esquemas manuales, cada uno
-- dedicado a UNA oferta negociada. Devolver todos por proyecto filtraria esquemas ajenos.
-- Por eso solo se devuelven los esquemas dinamicos del proyecto (catalogo general) MAS el
-- esquema manual seleccionado por ESTA oferta (id_esquema_pago_seleccionado), si aplica.

CREATE OR REPLACE FUNCTION public.get_oferta_financials(p_oferta_id integer)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
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
params AS (
  SELECT
    (SELECT precio_lista FROM prop)::numeric AS precio_lista,
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
    (SELECT precio_lista FROM params) * (1 + COALESCE(e.porcentaje_descuento_aumento, 0)/100) AS precio_final
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
    -- Meses de parcialidades: manual escalonado = calendario propio;
    -- dinamico escalonado = meses_restantes; estandar = min(meses_restantes, num_mens).
    CASE
      WHEN c.tramo_has THEN
        CASE WHEN c.es_manual THEN c.tramo_meses ELSE (SELECT meses_restantes FROM params) END
      ELSE LEAST((SELECT meses_restantes FROM params), c.num_mens)
    END AS meses,
    -- Mensualidad nominal (para desglose visual).
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
    -- Parcialidades totales realmente adeudadas segun el calendario aplicable.
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
  'fecha_generacion', (SELECT fecha_generacion FROM params),
  'dias_vigencia',    7,
  'vigencia_hasta',   (SELECT fecha_generacion FROM params) + interval '7 days',
  'fecha_entrega',    (SELECT fecha_entrega FROM params),
  'meses_restantes',  (SELECT meses_restantes FROM params),
  'apartado',         (SELECT apartado FROM params),
  -- Datos del creador de la oferta (responsable). usuarios/personas tienen RLS que bloquea
  -- anon -> aqui se exponen server-side (SECURITY DEFINER) para la oferta publica.
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
      -- Calendario de tramos (montos en pesos) para esquemas escalonados; [] si no aplica.
      'tramos', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('orden', t.orden, 'monto', round(t.monto, 2), 'meses', t.meses) ORDER BY t.orden)
        FROM tramos t WHERE t.esquema_id = f.id AND t.monto > 0
      ), '[]'::jsonb)
    ) ORDER BY f.orden NULLS LAST, f.id)
    FROM final2 f
  ), '[]'::jsonb)
);
$$;

-- La oferta digital es publica (sin sesion) -> el rol anon debe poder ejecutar.
GRANT EXECUTE ON FUNCTION public.get_oferta_financials(integer) TO anon, authenticated;
