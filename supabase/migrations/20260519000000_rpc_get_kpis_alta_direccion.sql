-- RPC para el Portal Alta Dirección
-- Retorna KPIs ejecutivos de ventas y comisiones, opcionalmente filtrados por proyecto y período.
-- Join path: cuentas_cobranza → propiedades → edificios_modelos → edificios → proyectos

CREATE OR REPLACE FUNCTION public.get_kpis_alta_direccion(
    p_proyecto_id  INTEGER DEFAULT NULL,
    p_fecha_inicio DATE    DEFAULT NULL,
    p_fecha_fin    DATE    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_result JSONB;
BEGIN
    -- ── 1. KPIs globales de ventas y comisiones ──────────────────────────────
    SELECT jsonb_build_object(
        'total_ventas',                  COUNT(*),
        'monto_total_ventas',            COALESCE(SUM(cc.precio_final), 0),
        'ticket_promedio',               COALESCE(AVG(cc.precio_final), 0),
        'comision_total_generada',       COALESCE(SUM(cc.precio_final * cc.porcentaje_comision_venta / 100), 0),
        'comision_total_pagada',         COALESCE(SUM(CASE WHEN cc.es_pagada_comision_venta THEN cc.monto_comision_pagado ELSE 0 END), 0),
        'comision_pendiente',            COALESCE(SUM(CASE WHEN NOT cc.es_pagada_comision_venta THEN cc.precio_final * cc.porcentaje_comision_venta / 100 ELSE 0 END), 0),
        'cuentas_liquidadas',            COUNT(*) FILTER (WHERE cc.es_pagada_comision_venta = true),
        'cuentas_vendidas_sin_comision', COUNT(*) FILTER (WHERE cc.es_pagada_comision_venta = false)
    ) INTO v_result
    FROM cuentas_cobranza cc
    LEFT JOIN propiedades         prop ON prop.id = cc.id_propiedad
    LEFT JOIN edificios_modelos   em   ON em.id   = prop.id_edificio_modelo
    LEFT JOIN edificios            ed   ON ed.id   = em.id_edificio
    WHERE cc.activo = true
      AND cc.fecha_compra IS NOT NULL
      AND (p_fecha_inicio IS NULL OR cc.fecha_compra >= p_fecha_inicio)
      AND (p_fecha_fin    IS NULL OR cc.fecha_compra <= p_fecha_fin)
      AND (p_proyecto_id  IS NULL OR ed.id_proyecto = p_proyecto_id);

    -- ── 2. Breakdown por proyecto ─────────────────────────────────────────────
    v_result := v_result || jsonb_build_object('por_proyecto', (
        SELECT COALESCE(jsonb_agg(row_to_json(pp) ORDER BY (row_to_json(pp)->>'monto_ventas')::numeric DESC), '[]'::jsonb)
        FROM (
            SELECT
                pr.id    AS proyecto_id,
                pr.nombre AS proyecto,
                COUNT(cc.id)                                                                   AS total_ventas,
                COALESCE(SUM(cc.precio_final), 0)                                              AS monto_ventas,
                COALESCE(SUM(cc.precio_final * cc.porcentaje_comision_venta / 100), 0)         AS comision_generada,
                COALESCE(SUM(CASE WHEN cc.es_pagada_comision_venta THEN cc.monto_comision_pagado ELSE 0 END), 0) AS comision_pagada,
                COUNT(cc.id) FILTER (WHERE cc.es_pagada_comision_venta = true)                 AS cuentas_liquidadas
            FROM proyectos pr
            LEFT JOIN edificios          ed   ON ed.id_proyecto       = pr.id
            LEFT JOIN edificios_modelos  em   ON em.id_edificio        = ed.id
            LEFT JOIN propiedades        prop ON prop.id_edificio_modelo = em.id
            LEFT JOIN cuentas_cobranza   cc   ON cc.id_propiedad = prop.id
                AND cc.activo = true
                AND cc.fecha_compra IS NOT NULL
                AND (p_fecha_inicio IS NULL OR cc.fecha_compra >= p_fecha_inicio)
                AND (p_fecha_fin    IS NULL OR cc.fecha_compra <= p_fecha_fin)
            WHERE pr.activo = true
              AND (p_proyecto_id IS NULL OR pr.id = p_proyecto_id)
            GROUP BY pr.id, pr.nombre
        ) pp
    ));

    -- ── 3. Tendencia mensual de ventas (últimos 12 meses) ────────────────────
    v_result := v_result || jsonb_build_object('ventas_mensuales', (
        SELECT COALESCE(jsonb_agg(row_to_json(vm)), '[]'::jsonb)
        FROM (
            SELECT
                to_char(date_trunc('month', cc.fecha_compra), 'YYYY-MM') AS mes,
                COUNT(*)                                                   AS total_ventas,
                COALESCE(SUM(cc.precio_final), 0)                          AS monto
            FROM cuentas_cobranza cc
            LEFT JOIN propiedades        prop ON prop.id = cc.id_propiedad
            LEFT JOIN edificios_modelos  em   ON em.id  = prop.id_edificio_modelo
            LEFT JOIN edificios           ed   ON ed.id  = em.id_edificio
            WHERE cc.activo = true
              AND cc.fecha_compra IS NOT NULL
              AND cc.fecha_compra >= (CURRENT_DATE - INTERVAL '12 months')
              AND (p_proyecto_id  IS NULL OR ed.id_proyecto = p_proyecto_id)
              AND (p_fecha_inicio IS NULL OR cc.fecha_compra >= p_fecha_inicio)
              AND (p_fecha_fin    IS NULL OR cc.fecha_compra <= p_fecha_fin)
            GROUP BY 1
            ORDER BY 1
        ) vm
    ));

    -- ── 4. Top 5 ventas más recientes ────────────────────────────────────────
    v_result := v_result || jsonb_build_object('ventas_recientes', (
        SELECT COALESCE(jsonb_agg(row_to_json(vr)), '[]'::jsonb)
        FROM (
            SELECT
                cc.id                                AS cuenta_id,
                cc.fecha_compra,
                cc.precio_final,
                cc.es_pagada_comision_venta,
                pr.nombre                            AS proyecto,
                prop.numero_propiedad
            FROM cuentas_cobranza cc
            LEFT JOIN propiedades        prop ON prop.id = cc.id_propiedad
            LEFT JOIN edificios_modelos  em   ON em.id  = prop.id_edificio_modelo
            LEFT JOIN edificios           ed   ON ed.id  = em.id_edificio
            LEFT JOIN proyectos           pr   ON pr.id  = ed.id_proyecto
            WHERE cc.activo = true
              AND cc.fecha_compra IS NOT NULL
              AND (p_proyecto_id  IS NULL OR ed.id_proyecto = p_proyecto_id)
            ORDER BY cc.fecha_compra DESC
            LIMIT 5
        ) vr
    ));

    RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_kpis_alta_direccion(INTEGER, DATE, DATE) TO authenticated;
