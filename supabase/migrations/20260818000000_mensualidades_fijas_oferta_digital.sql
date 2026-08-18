-- Mensualidades fijas por proyecto/unidad en la Oferta Digital.
-- Fecha: 2026-08-17
--
-- Permite que un proyecto (o una unidad concreta) fije el número de mensualidades
-- de la Oferta Digital en lugar de derivarlo de la fecha de entrega, sin perder la
-- lógica dinámica actual: NULL = comportamiento histórico, bit a bit.
--
-- Petición (Rodrigo vía Jorge, agosto 2026): las ventas de Daiku van con 35
-- mensualidades fijas + el pago a escrituración como mes 36, independientes de la
-- fecha de entrega.
--
-- Resolución: COALESCE(propiedades.mensualidades_fijas,
--                      proyectos.mensualidades_fijas,
--                      <regla dinámica: hoy → fecha_entrega, menos 1 mes>)
-- La unidad gana sobre el proyecto; el proyecto sobre la regla vieja.
--
-- Esta migración NO mueve ninguna oferta: deja ambas columnas en NULL. El DML que
-- prende la bandera en Daiku se entrega y ejecuta aparte.
--
-- Anclada a la definición viva de get_oferta_financials verificada en dev y prod
-- el 2026-08-17 (md5(prosrc) = b602e065d883b10a7645a3424cd5db6a, 7532 chars).
-- Idempotente y self-guarded. Sin BEGIN/COMMIT (el CI/CD envuelve en tx).

-- ─── 0. Anchor: abortar si la función viva no es la esperada ──────────────────
-- Evita pisar un cambio ajeno con una definición vieja. Acepta el estado previo
-- (contiene la expresión histórica de meses_restantes) y el estado ya migrado.
DO $anchor$
DECLARE
  v_src text;
BEGIN
  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'get_oferta_financials'
    AND pg_get_function_identity_arguments(p.oid) = 'p_oferta_id integer';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'anchor: public.get_oferta_financials(integer) no existe';
  END IF;

  IF position('mensualidades_fijas' IN v_src) = 0
     AND position('EXTRACT(MONTH FROM (SELECT fecha_entrega FROM proj))' IN v_src) = 0
  THEN
    RAISE EXCEPTION
      'anchor: get_oferta_financials cambió (md5=%); revisar drift antes de reemplazar',
      md5(v_src);
  END IF;
END
$anchor$;

-- ─── 1. Columnas de configuración ────────────────────────────────────────────
-- NULL  = modo dinámico (regla histórica: hoy → entrega, menos 1 mes).
-- Valor = modo fijo, ese número de MENSUALIDADES (el pago a escrituración va aparte:
--         35 mensualidades = 36 meses de plan).

ALTER TABLE public.proyectos
  ADD COLUMN IF NOT EXISTS mensualidades_fijas integer;

ALTER TABLE public.propiedades
  ADD COLUMN IF NOT EXISTS mensualidades_fijas integer;

ALTER TABLE public.proyectos
  DROP CONSTRAINT IF EXISTS proyectos_mensualidades_fijas_check;
ALTER TABLE public.proyectos
  ADD CONSTRAINT proyectos_mensualidades_fijas_check
  CHECK (mensualidades_fijas IS NULL OR (mensualidades_fijas >= 0 AND mensualidades_fijas <= 600));

ALTER TABLE public.propiedades
  DROP CONSTRAINT IF EXISTS propiedades_mensualidades_fijas_check;
ALTER TABLE public.propiedades
  ADD CONSTRAINT propiedades_mensualidades_fijas_check
  CHECK (mensualidades_fijas IS NULL OR (mensualidades_fijas >= 0 AND mensualidades_fijas <= 600));

COMMENT ON COLUMN public.proyectos.mensualidades_fijas IS
  'Número FIJO de mensualidades de la Oferta Digital para este proyecto. NULL = dinámico '
  '(meses de hoy a proyectos.fecha_entrega menos 1). El pago a escrituración NO se cuenta '
  'aquí: 35 mensualidades = 36 meses de plan. Lo resuelve get_oferta_financials.';

COMMENT ON COLUMN public.propiedades.mensualidades_fijas IS
  'Override por unidad del mismo concepto que proyectos.mensualidades_fijas. Gana sobre '
  'el proyecto. NULL = hereda del proyecto.';

-- ─── 2. RPC: meses_restantes con la cascada unidad → proyecto → dinámico ──────
-- Único cambio funcional respecto de la definición viva: las CTEs prop/proj traen
-- mensualidades_fijas, params la resuelve y el JSON gana las llaves
-- 'mensualidades_fijas' y 'meses_modo'. Todo lo demás es idéntico.

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
  SELECT p.id, p.precio_lista, p.id_edificio_modelo, p.monto_apartado, p.mensualidades_fijas
  FROM propiedades p
  WHERE p.id = (SELECT id_propiedad FROM o)
),
proj AS (
  SELECT pr.id,
         COALESCE(pr.fecha_entrega_proyecto::timestamp, pr.fecha_entrega) AS fecha_entrega,
         pr.mensualidades_fijas
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
    -- Mensualidades fijas configuradas: la unidad gana sobre el proyecto.
    COALESCE((SELECT mensualidades_fijas FROM prop), (SELECT mensualidades_fijas FROM proj)) AS mensualidades_fijas,
    -- Número de mensualidades del plan:
    --   1) si hay mensualidades_fijas (unidad o proyecto) → ese número, tal cual;
    --   2) si no → regla histórica: meses de hoy a la entrega, menos 1 (ese mes es el
    --      pago a escrituración, no una mensualidad).
    CASE
      WHEN COALESCE((SELECT mensualidades_fijas FROM prop), (SELECT mensualidades_fijas FROM proj)) IS NOT NULL
        THEN GREATEST(0, COALESCE((SELECT mensualidades_fijas FROM prop), (SELECT mensualidades_fijas FROM proj)))
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
  -- Nuevos: el front pinta la leyenda y decide si el número es negociable.
  'mensualidades_fijas', (SELECT mensualidades_fijas FROM params),
  'meses_modo',       CASE WHEN (SELECT mensualidades_fijas FROM params) IS NOT NULL
                           THEN 'fijo' ELSE 'dinamico' END,
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

-- La oferta pública la consume sin sesión. CREATE OR REPLACE conserva los privilegios
-- (verificado: anon/authenticated/postgres/service_role ya tienen EXECUTE), pero se
-- reafirman por si la función se recreara desde cero.
GRANT EXECUTE ON FUNCTION public.get_oferta_financials(integer) TO anon, authenticated;
