-- Portal Cobranza > menú Productos y Mantenimiento.
-- Crea get_pcobranza_productos_mantenimiento: dashboard de cobranza de EXTRAS.
-- COMPLEMENTO EXACTO de get_pcobranza_dashboard (que quedó solo con unidades del
-- flujo de venta: cuenta de unidad + conceptos 1-6). Aquí vive todo lo que aquel
-- EXCLUYE dentro de SOZU, sin traslape ni huecos (dashboard + este = 100% SOZU):
--   * PRODUCTOS: cuentas de producto — Condensadora (cat 4), Paquete/Persiana
--     (cat 3), Servicio (id_producto no nulo, cat NULL) — cualquier concepto.
--   * MANTENIMIENTO: acuerdos concepto 11 sobre cuentas de unidad.
--   * OTROS: cuentas de unidad con concepto que NO es de venta (1-6) ni 11 —
--     Fondo de reserva (12), multas, cancelación, asignación, etc. La categoría
--     es el nombre PUNTUAL del concepto (conceptos_pago.nombre), no "Otros".
-- Universo: proyectos SOZU (entidades_relacionadas.id_tipo_entidad = 5). La
-- propiedad efectiva se resuelve por la cuenta o, si es hija, por su padre.
-- Filtro p_tipo: 'productos' | 'mantenimiento' | 'otros' | NULL (todos).
-- CREATE OR REPLACE, SECURITY DEFINER. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

CREATE OR REPLACE FUNCTION public.get_pcobranza_productos_mantenimiento(
  p_proyecto_id integer DEFAULT NULL::integer,
  p_entidad_ids integer[] DEFAULT NULL::integer[],
  p_tipo text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  v_hoy date := current_date;
BEGIN
  -- Universo = proyectos SOZU (entidad relacionada tipo 5).
  CREATE TEMP TABLE _sozu ON COMMIT DROP AS
  SELECT DISTINCT id_proyecto FROM entidades_relacionadas
  WHERE id_tipo_entidad = 5 AND activo = true AND id_proyecto IS NOT NULL;

  -- COMPLEMENTO EXACTO del dashboard: todo lo que el dashboard de unidades
  -- EXCLUYE dentro de proyectos SOZU. El dashboard toma (cuenta de unidad AND
  -- concepto de venta 1-6); aquí va el resto, sin traslape ni huecos:
  --   * PRODUCTOS: cuentas de producto — Condensadora (cat 4), Paquete/Persiana
  --     (cat 3), Servicio (id_producto no nulo, cat NULL) — cualquier concepto.
  --   * MANTENIMIENTO: acuerdos concepto 11 sobre cuentas de unidad.
  --   * OTROS: cuentas de unidad con concepto que NO es de venta (1-6) ni 11 —
  --     Fondo de reserva (12), multas, cancelación, asignación, etc.
  -- Dashboard + este RPC = 100% de la cobranza SOZU.
  -- cobrado = aplicado (aplicaciones_pago, es_multa=false); pend = monto - cobrado.
  CREATE TEMP TABLE _pm ON COMMIT DROP AS
  SELECT ap.id,
         ap.id_cuenta_cobranza,
         ap.monto,
         ap.fecha_pago,
         ap.pago_completado,
         ed.id_proyecto,
         per.nombre_legal AS cliente,
         prop.numero_propiedad,
         COALESCE(apl.pagado, 0) AS cobrado,
         GREATEST(ap.monto - COALESCE(apl.pagado, 0), 0) AS pend,
         CASE
           WHEN o.id_producto IS NOT NULL AND ps.id_categoria = 4 THEN 'Condensadora'
           WHEN o.id_producto IS NOT NULL AND ps.id_categoria = 3 THEN 'Paquete y persianas'
           WHEN o.id_producto IS NOT NULL AND ps.id_categoria IS NULL THEN 'Servicio'
           WHEN ap.id_concepto = 11 THEN 'Mantenimiento'
           -- Resto: nombre PUNTUAL del concepto (Fondo de reserva, Pago de multa,
           -- Pago por cancelación, Asignación, etc.), no un "Otros" genérico.
           ELSE cp.nombre
         END AS categoria,
         CASE
           WHEN o.id_producto IS NOT NULL AND (ps.id_categoria IN (3, 4) OR ps.id_categoria IS NULL) THEN 'productos'
           WHEN ap.id_concepto = 11 THEN 'mantenimiento'
           ELSE 'otros'
         END AS tipo
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza AND cc.activo = true
  LEFT JOIN cuentas_cobranza ccp ON ccp.id = cc.id_cuenta_cobranza_padre
  LEFT JOIN ofertas o ON o.id = cc.id_oferta
  LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
  LEFT JOIN conceptos_pago cp ON cp.id = ap.id_concepto
  LEFT JOIN personas per ON per.id = o.id_persona_lead
  LEFT JOIN propiedades prop ON prop.id = COALESCE(cc.id_propiedad, ccp.id_propiedad)
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  LEFT JOIN (
    SELECT id_acuerdo_pago, SUM(monto) AS pagado
    FROM aplicaciones_pago
    WHERE activo = true AND es_multa = false
    GROUP BY id_acuerdo_pago
  ) apl ON apl.id_acuerdo_pago = ap.id
  WHERE ap.activo = true
    AND ed.id_proyecto IN (SELECT id_proyecto FROM _sozu)
    AND (
      -- Cuenta de PRODUCTO (condensadora/paquete/servicio), cualquier concepto.
      (o.id_producto IS NOT NULL AND (ps.id_categoria IN (3, 4) OR ps.id_categoria IS NULL))
      -- o cuenta de UNIDAD (depto/bodega/estac) con concepto que NO es de venta.
      OR ((o.id_producto IS NULL OR ps.id_categoria IN (1, 2)) AND ap.id_concepto NOT IN (1, 2, 3, 4, 5, 6))
    )
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  -- Filtro por tipo (productos | mantenimiento | otros) sobre la clasificación.
  DELETE FROM _pm WHERE p_tipo IS NOT NULL AND tipo <> p_tipo;

  CREATE INDEX ON _pm (id_proyecto);

  -- ════ Escalares ════
  result := jsonb_build_object(
    'cobrado_total',   (SELECT COALESCE(SUM(cobrado), 0) FROM _pm),
    'pendiente_total', (SELECT COALESCE(SUM(pend), 0) FROM _pm WHERE pago_completado = false),
    'vencido_total',   (SELECT COALESCE(SUM(pend), 0) FROM _pm WHERE pago_completado = false AND fecha_pago < v_hoy),
    'cuentas_count',   (SELECT COUNT(DISTINCT id_cuenta_cobranza) FROM _pm),
    'acuerdos_count',  (SELECT COUNT(*) FROM _pm)
  );

  -- ════ Por categoría ════
  result := result || jsonb_build_object('por_categoria', (
    SELECT COALESCE(jsonb_agg(row_to_json(c) ORDER BY c.monto_total DESC), '[]'::jsonb)
    FROM (
      SELECT categoria, tipo,
        COUNT(*) AS acuerdos,
        COALESCE(SUM(monto), 0) AS monto_total,
        COALESCE(SUM(cobrado), 0) AS cobrado,
        COALESCE(SUM(pend) FILTER (WHERE pago_completado = false), 0) AS pendiente,
        COALESCE(SUM(pend) FILTER (WHERE pago_completado = false AND fecha_pago < v_hoy), 0) AS vencido
      FROM _pm GROUP BY categoria, tipo
    ) c
  ));

  -- ════ Por proyecto ════
  result := result || jsonb_build_object('por_proyecto', (
    SELECT COALESCE(jsonb_agg(row_to_json(pp) ORDER BY pp.proyecto), '[]'::jsonb)
    FROM (
      SELECT pr.nombre AS proyecto, pr.id AS proyecto_id,
        COALESCE(SUM(x.cobrado), 0) AS cobrado,
        COALESCE(SUM(x.pend) FILTER (WHERE x.pago_completado = false), 0) AS pendiente,
        COALESCE(SUM(x.pend) FILTER (WHERE x.pago_completado = false AND x.fecha_pago < v_hoy), 0) AS vencido
      FROM _pm x JOIN proyectos pr ON pr.id = x.id_proyecto
      GROUP BY pr.nombre, pr.id
    ) pp
  ));

  -- ════ Cuentas con saldo vencido (morosidad de extras) ════
  -- Una cuenta puede tener cargos de varias categorías/tipos (ej. depto con
  -- mantenimiento Y fondo de reserva). Se reporta UNA fila por cuenta: monto y
  -- conteo = TOTAL vencido de la cuenta; categoría/tipo = el DOMINANTE (mayor
  -- vencido) — así categoría y tipo siempre son consistentes entre sí.
  result := result || jsonb_build_object('cuentas_vencidas', (
    WITH venc AS (
      SELECT id_cuenta_cobranza, categoria, tipo,
        MAX(cliente) AS cliente, MAX(numero_propiedad) AS numero_propiedad,
        SUM(pend) FILTER (WHERE pago_completado = false AND fecha_pago < v_hoy) AS venc_cat,
        COUNT(*) FILTER (WHERE pago_completado = false AND fecha_pago < v_hoy) AS n_cat
      FROM _pm
      GROUP BY id_cuenta_cobranza, categoria, tipo
    ),
    tot AS (
      SELECT id_cuenta_cobranza,
        MAX(cliente) AS cliente, MAX(numero_propiedad) AS numero_propiedad,
        SUM(venc_cat) AS vencido, SUM(n_cat) AS parcialidades_vencidas
      FROM venc GROUP BY id_cuenta_cobranza
      HAVING SUM(venc_cat) > 0
    ),
    dom AS (  -- categoría/tipo con mayor vencido por cuenta
      SELECT DISTINCT ON (id_cuenta_cobranza) id_cuenta_cobranza, categoria, tipo
      FROM venc WHERE venc_cat > 0
      ORDER BY id_cuenta_cobranza, venc_cat DESC
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'cuenta_id', t.id_cuenta_cobranza,
      'cliente', t.cliente,
      'numero_propiedad', t.numero_propiedad,
      'categoria', d.categoria,
      'tipo', d.tipo,
      'parcialidades_vencidas', t.parcialidades_vencidas,
      'vencido', t.vencido
    ) ORDER BY t.vencido DESC), '[]'::jsonb)
    FROM tot t JOIN dom d ON d.id_cuenta_cobranza = t.id_cuenta_cobranza
  ));

  -- ════ Dueños de proyectos SOZU (fuente del filtro) ════
  result := result || jsonb_build_object('duenos', (
    WITH sozu_proj AS (
      SELECT DISTINCT er.id_proyecto
      FROM entidades_relacionadas er
      JOIN edificios ed ON ed.id_proyecto = er.id_proyecto
      WHERE er.cuenta_madre_stp IS NOT NULL AND er.activo = true
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', d.nombre, 'entidad_ids', d.entidad_ids) ORDER BY d.nombre), '[]'::jsonb)
    FROM (
      SELECT COALESCE(per.nombre_comercial, per.nombre_legal, 'Entidad ' || er.id::text) AS nombre,
             array_agg(DISTINCT er.id ORDER BY er.id)::int[] AS entidad_ids
      FROM propiedades prop
      JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      JOIN edificios ed ON ed.id = em.id_edificio
      JOIN sozu_proj sp ON sp.id_proyecto = ed.id_proyecto
      JOIN entidades_relacionadas er ON er.id = prop.id_entidad_relacionada_dueno
      LEFT JOIN personas per ON per.id = er.id_persona
      WHERE prop.activo = true
      GROUP BY 1
    ) d
  ));

  RETURN result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_pcobranza_productos_mantenimiento(integer, integer[], text)
  TO anon, authenticated, service_role;
