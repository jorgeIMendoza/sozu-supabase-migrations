-- P16: optimizar get_dashboard_cobranza_kpis (índices + reescritura con temp tables).
-- Fecha: 2026-07-01
--
-- La RPC tardaba ~11s por (1) faltar índices en tablas base y (2) re-ejecutar el join
-- chain acuerdos_pago->cuentas->propiedades->edificios + subquery correlacionada a
-- aplicaciones_pago en ~15 bloques. Fix: 6 índices + materializar el join chain y el
-- rollup de aplicaciones_pago UNA vez en temp tables _ap/_pg; escalares/aging/morosidad/
-- por_proyecto/series leen de ahí. pipeline/ceps/clientes_criticos/duenos sin cambios
-- (los aceleran los índices). Mismos parámetros, mismas claves, misma semántica.
--
-- CAMBIO vs spec: CREATE INDEX sin CONCURRENTLY. CONCURRENTLY no puede correr dentro de
-- transacción y CI/CD (supabase db push) envuelve cada migración en una tx -> fallaría.
-- Las tablas son chicas (pagos 21k, propiedades 53k) -> el lock de creación es trivial.
-- Idempotente (IF NOT EXISTS + CREATE OR REPLACE). Verificado en dev: los 6 índices no existían.
--
-- ÚNICO cambio de comportamiento: por_proyecto devuelve solo proyectos con actividad en
-- el scope (no los 1044 activos en ceros). Montos idénticos.

-- ════ PASO 1 — Índices ════
CREATE INDEX IF NOT EXISTS idx_pagos_cuenta_activo
  ON public.pagos (id_cuenta_cobranza, activo);

CREATE INDEX IF NOT EXISTS idx_pagos_fecha_activo
  ON public.pagos (fecha_pago)
  WHERE activo = true;

CREATE INDEX IF NOT EXISTS idx_acuerdos_vencido
  ON public.acuerdos_pago (fecha_pago)
  WHERE activo = true AND pago_completado = false;

CREATE INDEX IF NOT EXISTS idx_edificios_id_proyecto
  ON public.edificios (id_proyecto);

CREATE INDEX IF NOT EXISTS idx_propiedades_dueno
  ON public.propiedades (id_entidad_relacionada_dueno)
  WHERE id_entidad_relacionada_dueno IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_propiedades_estatus
  ON public.propiedades (id_estatus_disponibilidad)
  WHERE activo = true;

ANALYZE public.pagos;
ANALYZE public.acuerdos_pago;
ANALYZE public.propiedades;
ANALYZE public.edificios;

-- ════ PASO 2 — Reescritura del RPC ════
CREATE OR REPLACE FUNCTION public.get_dashboard_cobranza_kpis(
  p_proyecto_id integer DEFAULT NULL::integer,
  p_fecha_inicio date DEFAULT NULL::date,
  p_fecha_fin date DEFAULT NULL::date,
  p_entidad_ids integer[] DEFAULT NULL::integer[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  v_mes_inicio date;
  v_mes_fin date;
  v_hoy date;
  v_cobrado_mes numeric;
  v_programado_mes numeric;
BEGIN
  v_hoy := current_date;
  v_mes_inicio := COALESCE(p_fecha_inicio, date_trunc('month', v_hoy)::date);
  v_mes_fin := COALESCE(p_fecha_fin, (date_trunc('month', v_hoy) + interval '1 month' - interval '1 day')::date);

  -- ════ Acuerdos materializados: join chain + aplicaciones_pago UNA sola vez ════
  CREATE TEMP TABLE _ap ON COMMIT DROP AS
  SELECT ap.id,
         ap.id_cuenta_cobranza,
         ap.monto,
         ap.fecha_pago,
         ap.pago_completado,
         ap.id_concepto,
         ed.id_proyecto,
         GREATEST(ap.monto - COALESCE(apl.pagado, 0), 0) AS pend
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza AND cc.activo = true
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  LEFT JOIN (
    SELECT id_acuerdo_pago, SUM(monto) AS pagado
    FROM aplicaciones_pago
    WHERE activo = true AND es_multa = false
    GROUP BY id_acuerdo_pago
  ) apl ON apl.id_acuerdo_pago = ap.id
  WHERE ap.activo = true
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  CREATE INDEX ON _ap (id_proyecto);

  -- ════ Pagos materializados: join chain UNA sola vez ════
  CREATE TEMP TABLE _pg ON COMMIT DROP AS
  SELECT p.monto,
         p.fecha_pago,
         ed.id_proyecto
  FROM pagos p
  JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza AND cc.activo = true
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE p.activo = true
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  CREATE INDEX ON _pg (id_proyecto);

  -- ════ Para recovery_rate ════
  SELECT COALESCE(SUM(monto), 0) INTO v_cobrado_mes
  FROM _pg WHERE fecha_pago BETWEEN v_mes_inicio AND v_mes_fin;

  SELECT COALESCE(SUM(pend), 0) INTO v_programado_mes
  FROM _ap WHERE fecha_pago BETWEEN v_mes_inicio AND v_mes_fin;

  -- ════ Escalares ════
  result := jsonb_build_object(
    'cobrado_total',         (SELECT COALESCE(SUM(monto), 0) FROM _pg),
    'vencido_total',         (SELECT COALESCE(SUM(pend), 0) FROM _ap WHERE pago_completado = false AND fecha_pago < v_hoy),
    'vencido_total_sin_ce',  (SELECT COALESCE(SUM(pend), 0) FROM _ap WHERE pago_completado = false AND fecha_pago < v_hoy AND id_concepto <> 3),
    'pendiente_total',       (SELECT COALESCE(SUM(monto), 0) FROM _ap WHERE pago_completado = false AND fecha_pago >= v_hoy),
    'cobrado_mes',           v_cobrado_mes,
    'programado_mes',        v_programado_mes,
    'programado_mes_sin_ce', (SELECT COALESCE(SUM(pend), 0) FROM _ap WHERE fecha_pago BETWEEN v_mes_inicio AND v_mes_fin AND id_concepto <> 3),
    'por_cobrar_mes',        (SELECT COALESCE(SUM(pend), 0) FROM _ap WHERE pago_completado = false AND fecha_pago BETWEEN v_mes_inicio AND v_mes_fin),
    'por_cobrar_mes_sin_ce', (SELECT COALESCE(SUM(pend), 0) FROM _ap WHERE pago_completado = false AND fecha_pago BETWEEN v_mes_inicio AND v_mes_fin AND id_concepto <> 3),
    'recovery_rate', CASE WHEN v_programado_mes > 0 THEN ROUND((v_cobrado_mes / v_programado_mes * 100)::numeric, 1) ELSE 0 END
  );

  -- ════ Aging ════
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
        SUM(CASE WHEN id_concepto <> 3 THEN pend ELSE 0 END) AS monto_sin_ce,
        COUNT(*) AS cantidad
      FROM _ap
      WHERE pago_completado = false AND fecha_pago < v_hoy
      GROUP BY 1 ORDER BY 1
    ) a
  ));

  -- ════ Morosidad (cuentas por # parcialidades vencidas) ════
  result := result || jsonb_build_object('morosidad', (
    SELECT COALESCE(jsonb_agg(row_to_json(m)), '[]'::jsonb)
    FROM (
      SELECT
        CASE WHEN cnt = 1 THEN '1_vencida' WHEN cnt = 2 THEN '2_vencidas' ELSE '3_plus' END AS grupo,
        COUNT(*)::integer AS cuentas
      FROM (
        SELECT id_cuenta_cobranza, LEAST(COUNT(*), 3) AS cnt
        FROM _ap
        WHERE pago_completado = false AND fecha_pago < v_hoy
        GROUP BY id_cuenta_cobranza
      ) sub
      GROUP BY 1 ORDER BY 1
    ) m
  ));

  -- ════ Por proyecto (solo proyectos con actividad en el scope) ════
  result := result || jsonb_build_object('por_proyecto', (
    SELECT COALESCE(jsonb_agg(row_to_json(pp)), '[]'::jsonb)
    FROM (
      SELECT pr.nombre AS proyecto, pr.id AS proyecto_id,
        COALESCE(c.cobrado, 0) AS cobrado,
        COALESCE(v.vencido, 0) AS vencido,
        COALESCE(pe.pendiente, 0) AS pendiente
      FROM proyectos pr
      JOIN (
        SELECT id_proyecto FROM _pg WHERE id_proyecto IS NOT NULL
        UNION
        SELECT id_proyecto FROM _ap WHERE id_proyecto IS NOT NULL
      ) scope ON scope.id_proyecto = pr.id
      LEFT JOIN (SELECT id_proyecto, SUM(monto) AS cobrado FROM _pg GROUP BY 1) c ON c.id_proyecto = pr.id
      LEFT JOIN (SELECT id_proyecto, SUM(pend) AS vencido FROM _ap WHERE pago_completado = false AND fecha_pago < v_hoy GROUP BY 1) v ON v.id_proyecto = pr.id
      LEFT JOIN (SELECT id_proyecto, SUM(monto) AS pendiente FROM _ap WHERE pago_completado = false AND fecha_pago >= v_hoy GROUP BY 1) pe ON pe.id_proyecto = pr.id
      WHERE pr.activo = true
        AND (p_proyecto_id IS NULL OR pr.id = p_proyecto_id)
      ORDER BY pr.nombre
    ) pp
  ));

  -- ════ Cobrado mensual (últimos 12 meses) ════
  result := result || jsonb_build_object('cobrado_mensual', (
    SELECT COALESCE(jsonb_agg(row_to_json(cm)), '[]'::jsonb)
    FROM (
      SELECT to_char(date_trunc('month', fecha_pago), 'YYYY-MM') AS mes, SUM(monto) AS cobrado
      FROM _pg
      WHERE fecha_pago >= (v_hoy - interval '12 months')
      GROUP BY 1 ORDER BY 1
    ) cm
  ));

  -- ════ Programado mensual (últimos 12 meses) ════
  result := result || jsonb_build_object('programado_mensual', (
    SELECT COALESCE(jsonb_agg(row_to_json(pm)), '[]'::jsonb)
    FROM (
      SELECT to_char(date_trunc('month', fecha_pago), 'YYYY-MM') AS mes,
        SUM(monto) AS programado,
        SUM(CASE WHEN id_concepto <> 3 THEN monto ELSE 0 END) AS programado_sin_ce
      FROM _ap
      WHERE fecha_pago >= (v_hoy - interval '12 months')
      GROUP BY 1 ORDER BY 1
    ) pm
  ));

  -- ════ Pipeline (ruta a escrituración) — sin cambios ════
  result := result || jsonb_build_object('pipeline', (
    WITH scope_props AS (
      SELECT prop.id, prop.id_estatus_disponibilidad AS est
      FROM propiedades prop
      JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      JOIN edificios ed ON ed.id = em.id_edificio
      WHERE prop.activo = true
        AND prop.id_estatus_disponibilidad IN (5,7,8,9)
        AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
        AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
    ),
    cand AS (SELECT id FROM scope_props WHERE est = 5),
    listas AS (
      SELECT p.id FROM cand p
      WHERE (SELECT MAX(cc.precio_final) FROM cuentas_cobranza cc
             WHERE cc.id_propiedad = p.id AND cc.activo = true AND cc.id_tipo_cancelacion IS NULL) > 100000
        AND EXISTS (SELECT 1 FROM cuentas_cobranza cc
             WHERE cc.id_propiedad = p.id AND cc.activo = true AND cc.id_tipo_cancelacion IS NULL)
        AND NOT EXISTS (
          SELECT 1 FROM cuentas_cobranza cc
          WHERE cc.id_propiedad = p.id AND cc.activo = true AND cc.id_tipo_cancelacion IS NULL
            AND (NOT EXISTS (SELECT 1 FROM acuerdos_pago ap WHERE ap.id_cuenta_cobranza = cc.id)
                 OR EXISTS (SELECT 1 FROM acuerdos_pago ap WHERE ap.id_cuenta_cobranza = cc.id AND ap.pago_completado = false)))
    )
    SELECT jsonb_build_object(
      'vendidas',              (SELECT COUNT(*) FROM scope_props WHERE est = 5),
      'listas_escrituracion',  (SELECT COUNT(*) FROM listas),
      'en_escrituracion',      (SELECT COUNT(*) FROM scope_props WHERE est = 7),
      'entregadas',            (SELECT COUNT(*) FROM scope_props WHERE est = 8),
      'pagadas_completamente', (SELECT COUNT(*) FROM scope_props WHERE est = 9)
    )
  ));

  -- ════ CEPs sin extraer = pagos con url_cep IS NULL — sin cambios ════
  result := result || jsonb_build_object('ceps_sin_validar', (
    SELECT COUNT(*)
    FROM pagos p
    JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
    LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
    LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
    LEFT JOIN edificios ed ON ed.id = em.id_edificio
    WHERE p.activo = true
      AND p.url_cep IS NULL
      AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
      AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
  ));

  -- ════ Clientes críticos — sin cambios ════
  result := result || jsonb_build_object('clientes_criticos', (
    WITH cc_eff AS (
      SELECT cc.id AS cuenta_id, cc.fecha_compra,
             COALESCE(cc.id_oferta, ccp.id_oferta) AS id_oferta,
             COALESCE(cc.id_propiedad, ccp.id_propiedad) AS id_propiedad
      FROM cuentas_cobranza cc
      LEFT JOIN cuentas_cobranza ccp ON ccp.id = cc.id_cuenta_cobranza_padre
      WHERE cc.activo = true
    ),
    rows AS (
      SELECT e.cuenta_id,
        per.nombre_legal AS cliente_nombre,
        pr.nombre AS proyecto,
        prop.numero_propiedad,
        CASE WHEN o.id_producto IS NOT NULL THEN ps.nombre ELSE NULL END AS producto_nombre,
        CASE WHEN o.id_producto IS NOT NULL THEN 'Producto' ELSE 'Propiedad' END AS tipo_cuenta,
        (SELECT COUNT(*) FROM acuerdos_pago ap
           WHERE ap.id_cuenta_cobranza = e.cuenta_id AND ap.activo = true
             AND ap.pago_completado = false AND ap.fecha_pago < v_hoy) AS parcialidades_vencidas,
        (SELECT COALESCE(SUM(GREATEST(ap.monto - COALESCE((
              SELECT SUM(a.monto) FROM aplicaciones_pago a
              WHERE a.id_acuerdo_pago = ap.id AND a.activo = true AND a.es_multa = false), 0), 0)), 0)
           FROM acuerdos_pago ap
           WHERE ap.id_cuenta_cobranza = e.cuenta_id AND ap.activo = true
             AND ap.pago_completado = false AND ap.fecha_pago < v_hoy) AS monto_vencido,
        (SELECT MAX(pg.fecha_pago) FROM pagos pg WHERE pg.id_cuenta_cobranza = e.cuenta_id AND pg.activo = true) AS ult,
        e.fecha_compra,
        prop.id_estatus_disponibilidad AS est,
        prop.id_entidad_relacionada_dueno AS dueno,
        ed.id_proyecto AS proy_id
      FROM cc_eff e
      LEFT JOIN ofertas o ON o.id = e.id_oferta
      LEFT JOIN personas per ON per.id = o.id_persona_lead
      LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
      LEFT JOIN propiedades prop ON prop.id = e.id_propiedad
      LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      LEFT JOIN edificios ed ON ed.id = em.id_edificio
      LEFT JOIN proyectos pr ON pr.id = COALESCE(ed.id_proyecto, ps.id_proyecto)
    ),
    fin AS (
      SELECT *,
        CASE WHEN ult IS NOT NULL THEN (v_hoy - ult)::int
             WHEN fecha_compra IS NOT NULL THEN (v_hoy - fecha_compra)::int ELSE 0 END AS dias_sin_pagar
      FROM rows
      WHERE parcialidades_vencidas > 0
        AND (est IS NULL OR est NOT IN (8,9))
        AND (p_proyecto_id IS NULL OR proy_id = p_proyecto_id)
        AND (p_entidad_ids IS NULL OR dueno = ANY(p_entidad_ids))
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'cuenta_id', cuenta_id,
      'cliente_nombre', cliente_nombre,
      'proyecto', proyecto,
      'numero_propiedad', numero_propiedad,
      'producto_nombre', producto_nombre,
      'tipo_cuenta', tipo_cuenta,
      'parcialidades_vencidas', parcialidades_vencidas,
      'monto_vencido', monto_vencido,
      'dias_sin_pagar', dias_sin_pagar
    ) ORDER BY dias_sin_pagar DESC, monto_vencido DESC) FILTER (WHERE dias_sin_pagar >= 90), '[]'::jsonb)
    FROM fin
  ));

  -- ════ Dueños de proyectos SOZU (fuente del filtro) — sin cambios ════
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
