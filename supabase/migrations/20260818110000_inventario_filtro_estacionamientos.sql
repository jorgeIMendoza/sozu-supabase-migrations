-- Filtro de estacionamiento por cantidad de cajones en el inventario disponible.
-- Fecha: 2026-08-18
--
-- El filtro es hoy un sí/no (p_has_estacionamiento boolean). Se agrega
-- p_estacionamientos integer[] para filtrar por cantidad EXACTA de cajones, y
-- filter_options.estacionamientos con las cantidades que existen en el inventario
-- consultado, para que el front pinte solo opciones que devuelven resultados.
--
-- p_has_estacionamiento se conserva (el front viejo sigue llamando igual mientras se
-- despliega el nuevo) pero queda subordinado: si viene p_estacionamientos, manda ése.
--
-- Verificado read-only el 2026-08-18 en dev y prod:
--   * get_inventario_disponible_v2 es IDÉNTICA en ambos entornos
--     (md5(pg_get_functiondef) = 0c80bbcbc8f601ba6545ff79d9e2a2f3, 12 args,
--      owner postgres, ACL {postgres,authenticated,service_role}=X, SECURITY DEFINER,
--      search_path=public).
--   * Ninguna otra función ni vista la referencia, así que el DROP no arrastra nada.
--   * Inventario disponible en prod: 12 unidades con 1 cajón (Bottura, Daiku, Margot),
--     78 con 2 (Daiku), 0 con 0/3/4+. Total 90. Por eso la opción "No" del filtro actual
--     nunca devuelve nada y una lista fija de 1..4 mostraría opciones muertas.
--
-- Las opciones se calculan sobre inv_extras (todos los filtros MENOS el de
-- estacionamiento). Si se derivaran de inv_base, al elegir "2 cajones" el select se
-- colapsaría a [2] y el usuario no podría volver a "1".
--
-- Cambio de firma → DROP + CREATE (agregar el parámetro con DEFAULT crearía una
-- sobrecarga y las llamadas existentes quedarían ambiguas). Idempotente y self-guarded.
-- Sin BEGIN/COMMIT (el CI/CD envuelve en tx).

-- ─── 0. Anchor: abortar si la función viva no es la esperada ─────────────────
DO $anchor$
DECLARE
  v_args text;
BEGIN
  SELECT string_agg(pg_get_function_identity_arguments(p.oid), ' | ')
  INTO v_args
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_inventario_disponible_v2';

  IF v_args IS NULL THEN
    RAISE EXCEPTION 'anchor: public.get_inventario_disponible_v2 no existe';
  END IF;

  -- pg_get_function_identity_arguments devuelve NOMBRE + tipo, no solo tipos, así que
  -- el anclaje va contra el último parámetro por nombre.
  -- Acepta el estado previo (termina en p_max_price numeric) y el ya migrado (termina en
  -- p_estacionamientos integer[]). Cualquier otra cosa es drift.
  IF v_args NOT LIKE '%p_max_price numeric'
     AND v_args NOT LIKE '%p_estacionamientos integer[]'
  THEN
    RAISE EXCEPTION
      'anchor: get_inventario_disponible_v2 tiene una firma inesperada (%); revisar drift',
      v_args;
  END IF;
END
$anchor$;

-- ─── 1. Reemplazo de la función con el parámetro nuevo ──────────────────────

DROP FUNCTION IF EXISTS public.get_inventario_disponible_v2(
  integer[], text[], text[], integer[], text[], boolean, boolean, text, integer, integer, numeric, numeric
);

CREATE OR REPLACE FUNCTION public.get_inventario_disponible_v2(
  p_accessible_project_ids integer[] DEFAULT NULL::integer[],
  p_project_names          text[]    DEFAULT NULL::text[],
  p_model_names            text[]    DEFAULT NULL::text[],
  p_bedrooms               integer[] DEFAULT NULL::integer[],
  p_levels                 text[]    DEFAULT NULL::text[],
  p_has_bodega             boolean   DEFAULT NULL::boolean,
  p_has_estacionamiento    boolean   DEFAULT NULL::boolean,
  p_sort_price             text      DEFAULT NULL::text,
  p_page                   integer   DEFAULT 0,
  p_page_size              integer   DEFAULT 30,
  p_min_price              numeric   DEFAULT NULL::numeric,
  p_max_price              numeric   DEFAULT NULL::numeric,
  p_estacionamientos       integer[] DEFAULT NULL::integer[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN (
    WITH base_props AS (
      -- First: cheap filter on propiedades + joins without laterals
      SELECT
        p.id, p.numero_propiedad, p.numero_piso, p.precio_lista,
        p.m2_interiores, p.m2_exteriores,
        pr.id AS proyecto_id, pr.nombre AS proyecto_nombre,
        ed.nombre AS edificio_nombre,
        mo.id AS modelo_id, mo.nombre AS modelo_nombre,
        mo.numero_recamaras, mo.numero_completo_banos, mo.numero_medio_bano
      FROM propiedades p
      INNER JOIN edificios_modelos em ON em.id = p.id_edificio_modelo
      INNER JOIN edificios ed ON ed.id = em.id_edificio
      INNER JOIN proyectos pr ON pr.id = ed.id_proyecto
      INNER JOIN modelos mo ON mo.id = em.id_modelo
      WHERE p.id_estatus_disponibilidad = 2
        AND p.es_aprobado = true
        AND pr.activo = true AND pr.publicar = true
        AND (p_accessible_project_ids IS NULL OR pr.id = ANY(p_accessible_project_ids))
        AND (p_project_names IS NULL OR pr.nombre = ANY(p_project_names))
        AND (p_model_names IS NULL OR mo.nombre = ANY(p_model_names))
        AND (p_bedrooms IS NULL OR mo.numero_recamaras = ANY(p_bedrooms))
        AND (p_levels IS NULL OR p.numero_piso = ANY(p_levels))
        AND (p_min_price IS NULL OR p.precio_lista >= p_min_price)
        AND (p_max_price IS NULL OR p.precio_lista <= p_max_price)
    ),
    -- Conteos + filtro de bodega. El de estacionamiento se aplica DESPUÉS, para que
    -- las opciones del select se calculen sobre este universo y no se colapsen a la
    -- opción ya elegida.
    inv_extras AS (
      SELECT
        bp.*,
        COALESCE(bod.cnt, 0) AS bodegas_count,
        COALESCE(est.cnt, 0) AS estacionamientos_count,
        COALESCE(est.tipos, '[]'::jsonb) AS estacionamientos_tipos
      FROM base_props bp
      LEFT JOIN LATERAL (
        SELECT count(*)::int AS cnt FROM bodegas b WHERE b.id_propiedad = bp.id AND b.activo = true
      ) bod ON true
      LEFT JOIN LATERAL (
        SELECT count(*)::int AS cnt,
          jsonb_agg(DISTINCT te.nombre) FILTER (WHERE te.nombre IS NOT NULL) AS tipos
        FROM estacionamientos e
        LEFT JOIN tipos_estacionamiento te ON te.id = e.id_tipo
        WHERE e.id_propiedad = bp.id AND e.activo = true
      ) est ON true
      WHERE (p_has_bodega IS NULL OR (p_has_bodega = true AND COALESCE(bod.cnt, 0) > 0) OR (p_has_bodega = false AND COALESCE(bod.cnt, 0) = 0))
    ),
    -- Cantidades de cajones que existen en el inventario consultado (incluye el 0 solo
    -- si de verdad hay unidades sin cajón). Es lo que el front usa para pintar el select.
    estac_options AS (
      SELECT COALESCE(jsonb_agg(DISTINCT estacionamientos_count ORDER BY estacionamientos_count), '[]'::jsonb) AS opts
      FROM inv_extras
    ),
    inv_base AS (
      SELECT *
      FROM inv_extras
      WHERE
        -- Cantidad exacta de cajones. Manda sobre el booleano heredado.
        CASE
          WHEN p_estacionamientos IS NOT NULL AND array_length(p_estacionamientos, 1) > 0
            THEN estacionamientos_count = ANY(p_estacionamientos)
          WHEN p_has_estacionamiento IS TRUE  THEN estacionamientos_count > 0
          WHEN p_has_estacionamiento IS FALSE THEN estacionamientos_count = 0
          ELSE true
        END
    ),
    inv_count AS (
      SELECT count(*)::int AS total FROM inv_base
    ),
    project_counts AS (
      SELECT jsonb_object_agg(proyecto_nombre, cnt) AS counts
      FROM (SELECT proyecto_nombre, count(*)::int AS cnt FROM inv_base GROUP BY proyecto_nombre) sub
    ),
    inv_page AS (
      SELECT * FROM inv_base
      ORDER BY
        CASE WHEN p_sort_price = 'asc' THEN precio_lista END ASC NULLS LAST,
        CASE WHEN p_sort_price = 'desc' THEN precio_lista END DESC NULLS LAST,
        CASE WHEN p_sort_price IS NULL OR p_sort_price NOT IN ('asc','desc') THEN random() END
      LIMIT p_page_size OFFSET p_page * p_page_size
    ),
    -- Images only for the page results
    page_with_imgs AS (
      SELECT ip.*,
        COALESCE(pimg.imgs, '[]'::jsonb) AS propiedad_imagenes
      FROM inv_page ip
      LEFT JOIN LATERAL (
        SELECT jsonb_agg(jsonb_build_object('id', mp.id, 'url', mp.url) ORDER BY mp.id) AS imgs
        FROM multimedias_propiedad mp
        WHERE mp.id_propiedad = ip.id AND mp.activo = true AND mp.es_imagen = true
      ) pimg ON true
    ),
    page_modelo_imgs AS (
      SELECT DISTINCT ON (mid) b.modelo_id AS mid,
        (SELECT jsonb_agg(jsonb_build_object('id', mm.id, 'url', mm.url) ORDER BY mm.id)
         FROM multimedias_modelo mm
         WHERE mm.id_modelo = b.modelo_id AND mm.activo = true AND mm.es_imagen = true AND mm.ver_como_imagen_de_propiedad = true
        ) AS imgs
      FROM inv_page b
    ),
    page_esquemas AS (
      SELECT DISTINCT ON (pid) b.proyecto_id AS pid,
        (SELECT jsonb_agg(jsonb_build_object(
          'id', s.id, 'nombre', s.nombre, 'id_proyecto', s.id_proyecto,
          'porcentaje_enganche', s.porcentaje_enganche,
          'porcentaje_mensualidades', s.porcentaje_mensualidades,
          'porcentaje_entrega', s.porcentaje_entrega,
          'numero_mensualidades', s.numero_mensualidades,
          'porcentaje_descuento_aumento', s.porcentaje_descuento_aumento,
          'tramos_mensualidad', s.tramos_mensualidad,
          'es_manual', s.es_manual
        ) ORDER BY s.nombre)
        FROM esquemas_pago s
        WHERE s.id_proyecto = b.proyecto_id AND s.activo = true AND s.es_manual = false
        ) AS schemes
      FROM inv_page b
    ),
    filter_options AS (
      SELECT jsonb_build_object(
        'proyectos', COALESCE((SELECT jsonb_agg(DISTINCT proyecto_nombre ORDER BY proyecto_nombre) FROM inv_base), '[]'::jsonb),
        'modelos', COALESCE((SELECT jsonb_agg(DISTINCT modelo_nombre ORDER BY modelo_nombre) FROM inv_base), '[]'::jsonb),
        'recamaras', COALESCE((SELECT jsonb_agg(DISTINCT numero_recamaras ORDER BY numero_recamaras) FROM inv_base WHERE numero_recamaras IS NOT NULL), '[]'::jsonb),
        'niveles', COALESCE((SELECT jsonb_agg(DISTINCT numero_piso ORDER BY numero_piso) FROM inv_base WHERE numero_piso IS NOT NULL), '[]'::jsonb),
        'estacionamientos', (SELECT opts FROM estac_options)
      ) AS opts
    )
    SELECT jsonb_build_object(
      'total_count', (SELECT total FROM inv_count),
      'project_counts', COALESCE((SELECT counts FROM project_counts), '{}'::jsonb),
      'propiedades', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id', b.id, 'numero_propiedad', b.numero_propiedad, 'numero_piso', b.numero_piso,
        'precio_lista', b.precio_lista, 'm2_interiores', b.m2_interiores, 'm2_exteriores', b.m2_exteriores,
        'proyecto_id', b.proyecto_id, 'proyecto_nombre', b.proyecto_nombre,
        'edificio_nombre', b.edificio_nombre, 'modelo_id', b.modelo_id, 'modelo_nombre', b.modelo_nombre,
        'numero_recamaras', b.numero_recamaras, 'numero_completo_banos', b.numero_completo_banos,
        'numero_medio_bano', b.numero_medio_bano, 'bodegas_count', b.bodegas_count,
        'estacionamientos_count', b.estacionamientos_count, 'estacionamientos_tipos', b.estacionamientos_tipos,
        'propiedad_imagenes', b.propiedad_imagenes
      )) FROM page_with_imgs b), '[]'::jsonb),
      'modelo_imagenes', COALESCE((SELECT jsonb_object_agg(mid::text, COALESCE(imgs, '[]'::jsonb)) FROM page_modelo_imgs), '{}'::jsonb),
      'esquemas_pago_proyecto', COALESCE((SELECT jsonb_object_agg(pid::text, COALESCE(schemes, '[]'::jsonb)) FROM page_esquemas), '{}'::jsonb),
      'filter_options', (SELECT opts FROM filter_options)
    )
  );
END;
$function$;

-- ─── 2. Permisos: reponer los de la versión anterior, sin regalar anon ──────
-- El DROP se llevó la ACL. Y una función NUEVA en public nace con EXECUTE para anon por
-- las DEFAULT PRIVILEGES del proyecto
-- ({postgres,anon,authenticated,service_role}=X), así que REVOKE FROM PUBLIC no basta:
-- hay que revocarle a anon por nombre. La versión anterior NO tenía anon y no debe
-- ganarlo: es SECURITY DEFINER y expone inventario y precios de lista.

REVOKE ALL ON FUNCTION public.get_inventario_disponible_v2(
  integer[], text[], text[], integer[], text[], boolean, boolean, text, integer, integer, numeric, numeric, integer[]
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_inventario_disponible_v2(
  integer[], text[], text[], integer[], text[], boolean, boolean, text, integer, integer, numeric, numeric, integer[]
) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_inventario_disponible_v2(
  integer[], text[], text[], integer[], text[], boolean, boolean, text, integer, integer, numeric, numeric, integer[]
) IS
  'Inventario disponible paginado. p_estacionamientos filtra por cantidad EXACTA de cajones y '
  'manda sobre p_has_estacionamiento (booleano heredado). filter_options.estacionamientos trae '
  'las cantidades que existen en el inventario consultado, calculadas antes de aplicar ese '
  'filtro para que el select no se colapse a la opción ya elegida.';

-- PostgREST cachea la firma: sin esto, la llamada con p_estacionamientos responde PGRST202.
NOTIFY pgrst, 'reload schema';
