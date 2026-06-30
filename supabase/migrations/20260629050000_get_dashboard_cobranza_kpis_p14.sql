-- P14: RPC unificado del Dashboard de Cobranza.
-- Fecha: 2026-06-29
--
-- Amplía get_dashboard_cobranza_kpis para que una sola llamada alimente todo el dashboard.
-- Agrega al JSON: pipeline (vendidas/listas/escrituración/entregadas/pagadas, server-side),
-- ceps_sin_validar (pagos url_cep IS NULL), clientes_criticos (prioridad 'purple': >=1
-- parcialidad vencida y >=90 días sin pagar) y duenos (dueños de proyectos SOZU, fuente del
-- filtro; NO se filtra por p_entidad_ids). Todo respeta p_proyecto_id y p_entidad_ids salvo duenos.
-- Firma sin cambios -> CREATE OR REPLACE. Idempotente. Verificado en dev: las 4 secciones
-- nuevas corren y coinciden con los esperados (pipeline 8038/2/136/92/40, ceps 7522,
-- clientes_criticos 330 = bandeja purple, duenos Tallwood/Hevi/Jmdq/Dakini).
--
-- NOTA: tras esto, get_duenos_cobranza() y get_cuentas_de_duenos(int[]) (P13) quedan sin uso.
-- Se conservan (no se dropean aquí); eliminar en una migración aparte si se confirma.

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
  v_cobrado_total numeric;
  v_vencido_total numeric;
  v_vencido_total_sin_ce numeric;
  v_pendiente_total numeric;
  v_cobrado_mes numeric;
  v_programado_mes numeric;
  v_programado_mes_sin_ce numeric;
  v_por_cobrar_mes numeric;
  v_por_cobrar_mes_sin_ce numeric;
  v_mes_inicio date;
  v_mes_fin date;
  v_hoy date;
BEGIN
  v_hoy := current_date;
  v_mes_inicio := COALESCE(p_fecha_inicio, date_trunc('month', v_hoy)::date);
  v_mes_fin := COALESCE(p_fecha_fin, (date_trunc('month', v_hoy) + interval '1 month' - interval '1 day')::date);

  SELECT COALESCE(SUM(p.monto), 0) INTO v_cobrado_total
  FROM pagos p
  JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE p.activo = true AND cc.activo = true
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_vencido_total
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_vencido_total_sin_ce
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
    AND ap.id_concepto != 3
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(ap.monto), 0) INTO v_pendiente_total
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false AND ap.fecha_pago >= v_hoy
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(p.monto), 0) INTO v_cobrado_mes
  FROM pagos p
  JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE p.activo = true AND cc.activo = true
    AND p.fecha_pago >= v_mes_inicio AND p.fecha_pago <= v_mes_fin
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_programado_mes
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.fecha_pago >= v_mes_inicio AND ap.fecha_pago <= v_mes_fin
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_programado_mes_sin_ce
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.fecha_pago >= v_mes_inicio AND ap.fecha_pago <= v_mes_fin
    AND ap.id_concepto != 3
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_por_cobrar_mes
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false
    AND ap.fecha_pago >= v_mes_inicio AND ap.fecha_pago <= v_mes_fin
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  SELECT COALESCE(SUM(
    GREATEST(ap.monto - COALESCE((
      SELECT SUM(apl.monto) FROM aplicaciones_pago apl
      WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
    ), 0), 0)
  ), 0) INTO v_por_cobrar_mes_sin_ce
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE ap.activo = true AND cc.activo = true
    AND ap.pago_completado = false
    AND ap.fecha_pago >= v_mes_inicio AND ap.fecha_pago <= v_mes_fin
    AND ap.id_concepto != 3
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  result := jsonb_build_object(
    'cobrado_total', v_cobrado_total,
    'vencido_total', v_vencido_total,
    'vencido_total_sin_ce', v_vencido_total_sin_ce,
    'pendiente_total', v_pendiente_total,
    'cobrado_mes', v_cobrado_mes,
    'programado_mes', v_programado_mes,
    'programado_mes_sin_ce', v_programado_mes_sin_ce,
    'por_cobrar_mes', v_por_cobrar_mes,
    'por_cobrar_mes_sin_ce', v_por_cobrar_mes_sin_ce,
    'recovery_rate', CASE WHEN v_programado_mes > 0 THEN ROUND((v_cobrado_mes / v_programado_mes * 100)::numeric, 1) ELSE 0 END
  );

  result := result || jsonb_build_object('aging', (
    SELECT COALESCE(jsonb_agg(row_to_json(a)), '[]'::jsonb)
    FROM (
      SELECT
        CASE
          WHEN v_hoy - ap.fecha_pago BETWEEN 1 AND 30 THEN '1-30'
          WHEN v_hoy - ap.fecha_pago BETWEEN 31 AND 60 THEN '31-60'
          WHEN v_hoy - ap.fecha_pago BETWEEN 61 AND 90 THEN '61-90'
          ELSE '90+'
        END AS rango,
        SUM(GREATEST(ap.monto - COALESCE((
          SELECT SUM(apl.monto) FROM aplicaciones_pago apl
          WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
        ), 0), 0)) AS monto,
        SUM(CASE WHEN ap.id_concepto != 3 THEN GREATEST(ap.monto - COALESCE((
          SELECT SUM(apl.monto) FROM aplicaciones_pago apl
          WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true AND apl.es_multa = false
        ), 0), 0) ELSE 0 END) AS monto_sin_ce,
        COUNT(*) AS cantidad
      FROM acuerdos_pago ap
      JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
      LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
      LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      LEFT JOIN edificios ed ON ed.id = em.id_edificio
      WHERE ap.activo = true AND cc.activo = true
        AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
        AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
        AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
      GROUP BY 1 ORDER BY 1
    ) a
  ));

  result := result || jsonb_build_object('morosidad', (
    SELECT COALESCE(jsonb_agg(row_to_json(m)), '[]'::jsonb)
    FROM (
      SELECT
        CASE WHEN cnt = 1 THEN '1_vencida' WHEN cnt = 2 THEN '2_vencidas' ELSE '3_plus' END AS grupo,
        SUM(total)::integer AS cuentas
      FROM (
        SELECT ap.id_cuenta_cobranza, LEAST(COUNT(*), 3) AS cnt, 1 AS total
        FROM acuerdos_pago ap
        JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
        LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
        LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
        LEFT JOIN edificios ed ON ed.id = em.id_edificio
        WHERE ap.activo = true AND cc.activo = true
          AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
          AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
          AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
        GROUP BY ap.id_cuenta_cobranza HAVING COUNT(*) >= 1
      ) sub
      GROUP BY 1 ORDER BY 1
    ) m
  ));

  result := result || jsonb_build_object('por_proyecto', (
    SELECT COALESCE(jsonb_agg(row_to_json(pp)), '[]'::jsonb)
    FROM (
      SELECT
        pr.nombre AS proyecto,
        pr.id AS proyecto_id,
        COALESCE((
          SELECT SUM(p2.monto) FROM pagos p2
          JOIN cuentas_cobranza cc2 ON cc2.id = p2.id_cuenta_cobranza
          LEFT JOIN propiedades prop2 ON prop2.id = cc2.id_propiedad
          LEFT JOIN edificios_modelos em2 ON em2.id = prop2.id_edificio_modelo
          LEFT JOIN edificios ed2 ON ed2.id = em2.id_edificio
          WHERE p2.activo = true AND cc2.activo = true AND ed2.id_proyecto = pr.id
            AND (p_entidad_ids IS NULL OR prop2.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
        ), 0) AS cobrado,
        COALESCE((
          SELECT SUM(GREATEST(ap2.monto - COALESCE((
            SELECT SUM(apl2.monto) FROM aplicaciones_pago apl2
            WHERE apl2.id_acuerdo_pago = ap2.id AND apl2.activo = true AND apl2.es_multa = false
          ), 0), 0))
          FROM acuerdos_pago ap2
          JOIN cuentas_cobranza cc2 ON cc2.id = ap2.id_cuenta_cobranza
          LEFT JOIN propiedades prop2 ON prop2.id = cc2.id_propiedad
          LEFT JOIN edificios_modelos em2 ON em2.id = prop2.id_edificio_modelo
          LEFT JOIN edificios ed2 ON ed2.id = em2.id_edificio
          WHERE ap2.activo = true AND cc2.activo = true
            AND ap2.pago_completado = false AND ap2.fecha_pago < v_hoy AND ed2.id_proyecto = pr.id
            AND (p_entidad_ids IS NULL OR prop2.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
        ), 0) AS vencido,
        COALESCE((
          SELECT SUM(ap2.monto) FROM acuerdos_pago ap2
          JOIN cuentas_cobranza cc2 ON cc2.id = ap2.id_cuenta_cobranza
          LEFT JOIN propiedades prop2 ON prop2.id = cc2.id_propiedad
          LEFT JOIN edificios_modelos em2 ON em2.id = prop2.id_edificio_modelo
          LEFT JOIN edificios ed2 ON ed2.id = em2.id_edificio
          WHERE ap2.activo = true AND cc2.activo = true
            AND ap2.pago_completado = false AND ap2.fecha_pago >= v_hoy AND ed2.id_proyecto = pr.id
            AND (p_entidad_ids IS NULL OR prop2.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
        ), 0) AS pendiente
      FROM proyectos pr
      WHERE pr.activo = true
        AND (p_proyecto_id IS NULL OR pr.id = p_proyecto_id)
      ORDER BY pr.nombre
    ) pp
  ));

  result := result || jsonb_build_object('cobrado_mensual', (
    SELECT COALESCE(jsonb_agg(row_to_json(cm)), '[]'::jsonb)
    FROM (
      SELECT to_char(date_trunc('month', p.fecha_pago), 'YYYY-MM') AS mes, SUM(p.monto) AS cobrado
      FROM pagos p
      JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
      LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
      LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      LEFT JOIN edificios ed ON ed.id = em.id_edificio
      WHERE p.activo = true AND cc.activo = true
        AND p.fecha_pago >= (v_hoy - interval '12 months')
        AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
        AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
      GROUP BY 1 ORDER BY 1
    ) cm
  ));

  result := result || jsonb_build_object('programado_mensual', (
    SELECT COALESCE(jsonb_agg(row_to_json(pm)), '[]'::jsonb)
    FROM (
      SELECT
        to_char(date_trunc('month', ap.fecha_pago), 'YYYY-MM') AS mes,
        SUM(ap.monto) AS programado,
        SUM(CASE WHEN ap.id_concepto != 3 THEN ap.monto ELSE 0 END) AS programado_sin_ce
      FROM acuerdos_pago ap
      JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
      LEFT JOIN propiedades prop ON prop.id = cc.id_propiedad
      LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      LEFT JOIN edificios ed ON ed.id = em.id_edificio
      WHERE ap.activo = true AND cc.activo = true
        AND ap.fecha_pago >= (v_hoy - interval '12 months')
        AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
        AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
      GROUP BY 1 ORDER BY 1
    ) pm
  ));

  -- ════ NUEVO: Pipeline (ruta a escrituración) ════
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

  -- ════ NUEVO: CEPs sin extraer = pagos con url_cep IS NULL ════
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

  -- ════ NUEVO: Clientes críticos (prioridad "purple") ════
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

  -- ════ NUEVO: Dueños de proyectos SOZU (fuente del filtro; NO filtra por p_entidad_ids) ════
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
