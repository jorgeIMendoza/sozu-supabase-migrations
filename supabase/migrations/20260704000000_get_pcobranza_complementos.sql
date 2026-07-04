-- Portal Cobranza > menú Complementos — espeja el dashboard de Inmuebles.
-- get_pcobranza_complementos: dashboard de cobranza de EXTRAS. Complemento EXACTO
-- de get_pcobranza_inmuebles (unidades del flujo de venta, conceptos 1-6). Aquí va
-- todo lo que aquel excluye en SOZU (inmuebles + este = 100% SOZU):
--   * PRODUCTOS: cuentas de producto — Condensadora (cat 4), Paquete/Persiana
--     (cat 3), Servicio (id_producto no nulo, cat NULL) — cualquier concepto.
--   * MANTENIMIENTO: acuerdos concepto 11 sobre cuentas de unidad.
--   * OTROS: cuentas de unidad con concepto ∉ {1..6, 11} — categoría = nombre
--     puntual del concepto (conceptos_pago.nombre): Fondo de reserva, multas, etc.
--
-- Rework vs la versión previa (20260703070000): ahora ESPEJA Inmuebles. Cambios:
--   - Añade escalares del mes (cobrado_mes, programado_mes, por_cobrar_mes,
--     recovery_rate), series mensuales (cobrado_mensual por fecha de pago;
--     programado_mensual por vencimiento; año actual + 4 previos) y aging.
--   - Añade segundo temp _pgc a nivel APLICACIÓN (cobrado por fecha de pago),
--     para cobrado_total / cobrado_mes / cobrado_mensual y cobrado por cat/proyecto.
--   - p_fecha_inicio/p_fecha_fin (Año/Mes) YA NO filtran el universo: solo definen
--     el mes de la sección "por mes" (default = mes actual), igual que Inmuebles.
-- Misma firma (5 args) -> CREATE OR REPLACE en sitio. SECURITY DEFINER. Sin BEGIN/COMMIT.

CREATE OR REPLACE FUNCTION public.get_pcobranza_complementos(
  p_proyecto_id integer DEFAULT NULL::integer,
  p_entidad_ids integer[] DEFAULT NULL::integer[],
  p_tipo text DEFAULT NULL::text,
  p_fecha_inicio date DEFAULT NULL::date,
  p_fecha_fin date DEFAULT NULL::date
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  v_hoy date := current_date;
  v_mes_inicio date;
  v_mes_fin date;
  v_cobrado_mes numeric;
  v_programado_mes numeric;
BEGIN
  -- Periodo (Año/Mes). NO filtra el universo: solo alimenta la sección "por mes"
  -- y el rango del gráfico mensual (igual que el dashboard de Inmuebles).
  v_mes_inicio := COALESCE(p_fecha_inicio, date_trunc('month', v_hoy)::date);
  v_mes_fin := COALESCE(p_fecha_fin, (date_trunc('month', v_hoy) + interval '1 month' - interval '1 day')::date);

  -- Universo = proyectos SOZU (entidad relacionada tipo 5).
  CREATE TEMP TABLE _sozu ON COMMIT DROP AS
  SELECT DISTINCT id_proyecto FROM entidades_relacionadas
  WHERE id_tipo_entidad = 5 AND activo = true AND id_proyecto IS NOT NULL;

  -- COMPLEMENTO EXACTO del dashboard: todo lo que el dashboard de unidades EXCLUYE
  -- en SOZU (productos cat 3/4 + servicio; mantenimiento concepto 11; otros cargos
  -- de unidad con concepto ∉ 1-6). Sin traslape ni huecos. Este _pm es el nivel
  -- ACUERDO (programado por fecha de vencimiento; pend = monto - aplicado).
  CREATE TEMP TABLE _pm ON COMMIT DROP AS
  SELECT ap.id,
         ap.id_cuenta_cobranza,
         ap.monto,
         ap.fecha_pago,
         ap.pago_completado,
         ed.id_proyecto,
         pr.nombre AS proyecto,
         per.nombre_legal AS cliente,
         prop.numero_propiedad,
         GREATEST(ap.monto - COALESCE(apl.pagado, 0), 0) AS pend,
         CASE
           WHEN o.id_producto IS NOT NULL AND ps.id_categoria = 4 THEN 'Condensadora'
           WHEN o.id_producto IS NOT NULL AND ps.id_categoria = 3 THEN 'Paquete y persianas'
           WHEN o.id_producto IS NOT NULL AND ps.id_categoria IS NULL THEN 'Servicio'
           WHEN ap.id_concepto = 11 THEN 'Mantenimiento'
           ELSE cp.nombre  -- nombre puntual: Fondo de reserva, Pago de multa, etc.
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
  LEFT JOIN proyectos pr ON pr.id = ed.id_proyecto
  LEFT JOIN (
    SELECT id_acuerdo_pago, SUM(monto) AS pagado
    FROM aplicaciones_pago WHERE activo = true AND es_multa = false
    GROUP BY id_acuerdo_pago
  ) apl ON apl.id_acuerdo_pago = ap.id
  WHERE ap.activo = true
    AND ed.id_proyecto IN (SELECT id_proyecto FROM _sozu)
    AND (
      (o.id_producto IS NOT NULL AND (ps.id_categoria IN (3, 4) OR ps.id_categoria IS NULL))
      OR ((o.id_producto IS NULL OR ps.id_categoria IN (1, 2)) AND ap.id_concepto NOT IN (1, 2, 3, 4, 5, 6))
    )
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  DELETE FROM _pm WHERE p_tipo IS NOT NULL AND tipo <> p_tipo;
  CREATE INDEX ON _pm (id_proyecto);

  -- _pgc: nivel APLICACIÓN — cobrado por fecha de PAGO (mismo universo/scope).
  -- Sirve para cobrado_total, cobrado por mes y series mensuales de cobrado.
  CREATE TEMP TABLE _pgc ON COMMIT DROP AS
  SELECT apl.monto,
         pg.fecha_pago,
         ed.id_proyecto,
         CASE
           WHEN o.id_producto IS NOT NULL AND ps.id_categoria = 4 THEN 'Condensadora'
           WHEN o.id_producto IS NOT NULL AND ps.id_categoria = 3 THEN 'Paquete y persianas'
           WHEN o.id_producto IS NOT NULL AND ps.id_categoria IS NULL THEN 'Servicio'
           WHEN ap.id_concepto = 11 THEN 'Mantenimiento'
           ELSE cp.nombre
         END AS categoria,
         CASE
           WHEN o.id_producto IS NOT NULL AND (ps.id_categoria IN (3, 4) OR ps.id_categoria IS NULL) THEN 'productos'
           WHEN ap.id_concepto = 11 THEN 'mantenimiento'
           ELSE 'otros'
         END AS tipo
  FROM aplicaciones_pago apl
  JOIN acuerdos_pago ap ON ap.id = apl.id_acuerdo_pago AND ap.activo = true
  JOIN pagos pg ON pg.id = apl.id_pago AND pg.activo = true
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza AND cc.activo = true
  LEFT JOIN cuentas_cobranza ccp ON ccp.id = cc.id_cuenta_cobranza_padre
  LEFT JOIN ofertas o ON o.id = cc.id_oferta
  LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
  LEFT JOIN conceptos_pago cp ON cp.id = ap.id_concepto
  LEFT JOIN propiedades prop ON prop.id = COALESCE(cc.id_propiedad, ccp.id_propiedad)
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE apl.activo = true AND apl.es_multa = false
    AND ed.id_proyecto IN (SELECT id_proyecto FROM _sozu)
    AND (
      (o.id_producto IS NOT NULL AND (ps.id_categoria IN (3, 4) OR ps.id_categoria IS NULL))
      OR ((o.id_producto IS NULL OR ps.id_categoria IN (1, 2)) AND ap.id_concepto NOT IN (1, 2, 3, 4, 5, 6))
    )
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  DELETE FROM _pgc WHERE p_tipo IS NOT NULL AND tipo <> p_tipo;
  CREATE INDEX ON _pgc (id_proyecto);

  -- Escalares del mes (para recovery + sección "por mes").
  SELECT COALESCE(SUM(monto), 0) INTO v_cobrado_mes
  FROM _pgc WHERE fecha_pago BETWEEN v_mes_inicio AND v_mes_fin;
  SELECT COALESCE(SUM(monto), 0) INTO v_programado_mes
  FROM _pm WHERE fecha_pago BETWEEN v_mes_inicio AND v_mes_fin;

  -- ════ Escalares ════
  result := jsonb_build_object(
    'cobrado_total',   (SELECT COALESCE(SUM(monto), 0) FROM _pgc),
    'pendiente_total', (SELECT COALESCE(SUM(pend), 0) FROM _pm WHERE pago_completado = false),
    'vencido_total',   (SELECT COALESCE(SUM(pend), 0) FROM _pm WHERE pago_completado = false AND fecha_pago < v_hoy),
    'cuentas_count',   (SELECT COUNT(DISTINCT id_cuenta_cobranza) FROM _pm),
    'acuerdos_count',  (SELECT COUNT(*) FROM _pm),
    'cobrado_mes',     v_cobrado_mes,
    'programado_mes',  v_programado_mes,
    'por_cobrar_mes',  (SELECT COALESCE(SUM(pend), 0) FROM _pm WHERE pago_completado = false AND fecha_pago BETWEEN v_mes_inicio AND v_mes_fin),
    'recovery_rate',   CASE WHEN v_programado_mes > 0 THEN ROUND((v_cobrado_mes / v_programado_mes * 100)::numeric, 1) ELSE 0 END
  );

  -- ════ Cobrado mensual (año actual + 4 previos) — por fecha de pago ════
  result := result || jsonb_build_object('cobrado_mensual', (
    SELECT COALESCE(jsonb_agg(row_to_json(cm)), '[]'::jsonb)
    FROM (
      SELECT to_char(date_trunc('month', fecha_pago), 'YYYY-MM') AS mes, SUM(monto) AS cobrado
      FROM _pgc WHERE fecha_pago >= make_date(EXTRACT(YEAR FROM v_hoy)::int - 4, 1, 1)
      GROUP BY 1 ORDER BY 1
    ) cm
  ));

  -- ════ Programado mensual (año actual + 4 previos) — por fecha de vencimiento ════
  result := result || jsonb_build_object('programado_mensual', (
    SELECT COALESCE(jsonb_agg(row_to_json(pm)), '[]'::jsonb)
    FROM (
      SELECT to_char(date_trunc('month', fecha_pago), 'YYYY-MM') AS mes, SUM(monto) AS programado
      FROM _pm WHERE fecha_pago >= make_date(EXTRACT(YEAR FROM v_hoy)::int - 4, 1, 1)
      GROUP BY 1 ORDER BY 1
    ) pm
  ));

  -- ════ Antigüedad de cartera (buckets de días de atraso del cargo) ════
  result := result || jsonb_build_object('aging', (
    SELECT COALESCE(jsonb_agg(row_to_json(a)), '[]'::jsonb)
    FROM (
      SELECT
        CASE
          WHEN v_hoy - fecha_pago BETWEEN 1 AND 30 THEN '1-30'
          WHEN v_hoy - fecha_pago BETWEEN 31 AND 60 THEN '31-60'
          WHEN v_hoy - fecha_pago BETWEEN 61 AND 90 THEN '61-90'
          ELSE '90+'
        END AS rango,
        SUM(pend) AS monto,
        COUNT(*) AS cantidad
      FROM _pm
      WHERE pago_completado = false AND fecha_pago < v_hoy
      GROUP BY 1 ORDER BY 1
    ) a
  ));

  -- ════ Por categoría (pend/vencido del acuerdo + cobrado por pago) ════
  result := result || jsonb_build_object('por_categoria', (
    SELECT COALESCE(jsonb_agg(row_to_json(c) ORDER BY c.monto_total DESC), '[]'::jsonb)
    FROM (
      SELECT m.categoria, m.tipo, m.acuerdos, m.monto_total,
        COALESCE(g.cobrado, 0) AS cobrado, m.pendiente, m.vencido
      FROM (
        SELECT categoria, tipo, COUNT(*) AS acuerdos, COALESCE(SUM(monto), 0) AS monto_total,
          COALESCE(SUM(pend) FILTER (WHERE pago_completado = false), 0) AS pendiente,
          COALESCE(SUM(pend) FILTER (WHERE pago_completado = false AND fecha_pago < v_hoy), 0) AS vencido
        FROM _pm GROUP BY categoria, tipo
      ) m
      LEFT JOIN (SELECT categoria, SUM(monto) AS cobrado FROM _pgc GROUP BY categoria) g
        ON g.categoria = m.categoria
    ) c
  ));

  -- ════ Por proyecto (pend/vencido del acuerdo + cobrado por pago) ════
  result := result || jsonb_build_object('por_proyecto', (
    SELECT COALESCE(jsonb_agg(row_to_json(pp) ORDER BY pp.proyecto), '[]'::jsonb)
    FROM (
      SELECT pr.nombre AS proyecto, pr.id AS proyecto_id,
        COALESCE(g.cobrado, 0) AS cobrado, m.pendiente, m.vencido
      FROM (
        SELECT id_proyecto,
          COALESCE(SUM(pend) FILTER (WHERE pago_completado = false), 0) AS pendiente,
          COALESCE(SUM(pend) FILTER (WHERE pago_completado = false AND fecha_pago < v_hoy), 0) AS vencido
        FROM _pm GROUP BY id_proyecto
      ) m
      JOIN proyectos pr ON pr.id = m.id_proyecto
      LEFT JOIN (SELECT id_proyecto, SUM(monto) AS cobrado FROM _pgc GROUP BY id_proyecto) g
        ON g.id_proyecto = m.id_proyecto
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
        MAX(cliente) AS cliente, MAX(numero_propiedad) AS numero_propiedad, MAX(proyecto) AS proyecto,
        SUM(pend) FILTER (WHERE pago_completado = false AND fecha_pago < v_hoy) AS venc_cat,
        COUNT(*) FILTER (WHERE pago_completado = false AND fecha_pago < v_hoy) AS n_cat
      FROM _pm
      GROUP BY id_cuenta_cobranza, categoria, tipo
    ),
    tot AS (
      SELECT id_cuenta_cobranza,
        MAX(cliente) AS cliente, MAX(numero_propiedad) AS numero_propiedad, MAX(proyecto) AS proyecto,
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
      'proyecto', t.proyecto,
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

GRANT EXECUTE ON FUNCTION public.get_pcobranza_complementos(integer, integer[], text, date, date)
  TO anon, authenticated, service_role;
