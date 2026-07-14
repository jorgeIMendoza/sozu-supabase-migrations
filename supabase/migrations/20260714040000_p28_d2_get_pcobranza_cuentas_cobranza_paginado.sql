-- P28 D.2 — CC (CollectionInbox): get_pcobranza_cuentas_cobranza paginación server-side
-- ---------------------------------------------------------------------------------------
-- Reemplaza la RPC que devolvía TODO el universo (array) y filtraba/ordenaba/paginaba en
-- cliente. Nueva firma recibe todos los filtros de la bandeja + orden + limit/offset y
-- devuelve { total, kpis, modelos, estatus, cuentas }. La forma de cada fila en `cuentas`
-- es idéntica a la anterior (verificado vs definición viva en prod).
--
-- Cuerpo basado en la definición VIVA (fuente de verdad): incluye Cancelada, id_propiedad
-- efectivo vía oferta/padre (eff_cc), universo con canceladas y subquery de inválidos.
-- Cambio de default sort: antes rank por color de prioridad; ahora (p_sort_key IS NULL)
-- ordena parcialidades_vencidas DESC, invalidos DESC — el front controla el orden.
--
-- Niveles prioridad/inválidos: nivelDeParcialidades del front (0=Al día,1=Alerta,2=Urgente,>=3=Crítico).

DROP FUNCTION IF EXISTS public.get_pcobranza_cuentas_cobranza(integer, text, boolean);

CREATE OR REPLACE FUNCTION public.get_pcobranza_cuentas_cobranza(
  p_proyecto_id   integer  DEFAULT NULL,
  p_search        text     DEFAULT NULL,
  p_solo_vencidas boolean  DEFAULT false,
  p_cliente       text     DEFAULT NULL,
  p_unidad        text     DEFAULT NULL,
  p_clabe         text     DEFAULT NULL,
  p_cuenta        text     DEFAULT NULL,
  p_modelos       text[]   DEFAULT NULL,
  p_tipos         text[]   DEFAULT NULL,
  p_estatus       text[]   DEFAULT NULL,
  p_prioridad     text[]   DEFAULT NULL,   -- nivel de parcialidades vencidas
  p_invalid_level text[]   DEFAULT NULL,   -- nivel de pagos inválidos
  p_sort_key      text     DEFAULT NULL,
  p_sort_dir      text     DEFAULT 'asc',
  p_limit         integer  DEFAULT 15,
  p_offset        integer  DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  v_hoy date := current_date;
  v_asc boolean := (COALESCE(p_sort_dir, 'asc') <> 'desc');
BEGIN
  WITH base AS (
    SELECT
      cc.id AS cuenta_id,
      cc.clabe_stp,
      cc.precio_final,
      cc.fecha_compra,
      p.nombre_legal  AS cliente_nombre,
      p.email         AS cliente_email,
      p.telefono      AS cliente_telefono,
      pr.nombre       AS proyecto,
      pr.id           AS proyecto_id,
      ed.nombre       AS edificio,
      prop.numero_propiedad,
      mod.nombre      AS modelo,
      prop.id_estatus_disponibilidad AS id_estatus_disponibilidad,
      CASE WHEN cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL THEN 'Cancelada' ELSE est.nombre END AS estatus_propiedad,
      CASE WHEN eff_o.id_producto IS NOT NULL THEN ps.nombre ELSE NULL END AS producto_nombre,
      CASE
        WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL THEN 'Mantenimiento'
        WHEN eff_o.id_producto IS NOT NULL THEN 'Producto'
        ELSE 'Propiedad'
      END AS tipo_cuenta,
      CASE
        WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL THEN 'Mantenimiento'
        WHEN eff_o.id_producto IS NULL THEN 'Propiedad'
        WHEN ps.id_categoria = 1 THEN 'Estacionamiento'
        WHEN ps.id_categoria = 2 THEN 'Bodega'
        WHEN ps.id_categoria IN (3, 4) THEN 'Producto'
        ELSE 'Adicional'
      END AS tipo_categoria,
      COALESCE(vc.parcialidades_vencidas, 0) AS parcialidades_vencidas,
      COALESCE(vc.monto_vencido,          0) AS monto_vencido,
      COALESCE(vc.saldo_pendiente,        0) AS saldo_pendiente,
      COALESCE(vc.invalidos,              0) AS invalidos,
      vc.proximo_vencimiento,
      vc.ultima_fecha_pago,
      CASE
        WHEN vc.ultima_fecha_pago IS NOT NULL THEN GREATEST(0, (v_hoy - vc.ultima_fecha_pago)::int)
        WHEN cc.fecha_compra IS NOT NULL       THEN GREATEST(0, (v_hoy - cc.fecha_compra)::int)
        ELSE 0
      END AS dias_sin_pagar,
      CASE
        WHEN cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL THEN 'gray'
        WHEN COALESCE(vc.parcialidades_vencidas, 0) = 0 THEN 'green'
        ELSE
          CASE
            WHEN (CASE WHEN vc.ultima_fecha_pago IS NOT NULL THEN (v_hoy - vc.ultima_fecha_pago)::int
                       WHEN cc.fecha_compra IS NOT NULL THEN (v_hoy - cc.fecha_compra)::int ELSE 0 END) >= 90 THEN 'purple'
            WHEN (CASE WHEN vc.ultima_fecha_pago IS NOT NULL THEN (v_hoy - vc.ultima_fecha_pago)::int
                       WHEN cc.fecha_compra IS NOT NULL THEN (v_hoy - cc.fecha_compra)::int ELSE 0 END) >= 60 THEN 'red_dark'
            WHEN (CASE WHEN vc.ultima_fecha_pago IS NOT NULL THEN (v_hoy - vc.ultima_fecha_pago)::int
                       WHEN cc.fecha_compra IS NOT NULL THEN (v_hoy - cc.fecha_compra)::int ELSE 0 END) >= 30 THEN 'red'
            ELSE 'yellow'
          END
      END AS prioridad
    FROM cuentas_cobranza cc
    LEFT JOIN cuentas_cobranza cc_padre ON cc_padre.id = cc.id_cuenta_cobranza_padre
    LEFT JOIN LATERAL (
      SELECT COALESCE(cc.id_oferta, cc_padre.id_oferta) AS id_oferta,
             COALESCE(cc.id_propiedad, cc_padre.id_propiedad) AS id_propiedad
    ) eff_cc ON true
    LEFT JOIN ofertas            eff_o ON eff_o.id  = eff_cc.id_oferta
    LEFT JOIN personas           p     ON p.id       = eff_o.id_persona_lead
    LEFT JOIN propiedades        prop  ON prop.id    = COALESCE(eff_cc.id_propiedad, eff_o.id_propiedad)
    LEFT JOIN edificios_modelos  em    ON em.id      = prop.id_edificio_modelo
    LEFT JOIN edificios          ed    ON ed.id      = em.id_edificio
    LEFT JOIN modelos            mod   ON mod.id     = em.id_modelo
    LEFT JOIN estatus_disponibilidad est ON est.id  = prop.id_estatus_disponibilidad
    LEFT JOIN productos_servicios ps   ON ps.id      = eff_o.id_producto
    LEFT JOIN proyectos          pr    ON pr.id      = COALESCE(ed.id_proyecto, ps.id_proyecto)
    LEFT JOIN LATERAL (
      SELECT
        COUNT(CASE WHEN ap.pago_completado = false AND ap.fecha_pago < v_hoy THEN 1 END)::int AS parcialidades_vencidas,
        COALESCE(SUM(CASE WHEN ap.pago_completado = false AND ap.fecha_pago < v_hoy
          THEN GREATEST(ap.monto - COALESCE(apl.aplicado, 0), 0) END), 0) AS monto_vencido,
        COALESCE(SUM(CASE WHEN ap.pago_completado = false
          THEN GREATEST(ap.monto - COALESCE(apl.aplicado, 0), 0) END), 0) AS saldo_pendiente,
        MIN(CASE WHEN ap.pago_completado = false AND ap.fecha_pago >= v_hoy THEN ap.fecha_pago END) AS proximo_vencimiento,
        (SELECT MAX(pg.fecha_pago) FROM pagos pg WHERE pg.id_cuenta_cobranza = cc.id AND pg.activo = true) AS ultima_fecha_pago,
        (
          SELECT COUNT(*)::int FROM (
            SELECT 1
            FROM acuerdos_pago      ap2
            JOIN aplicaciones_pago  apl2 ON apl2.id_acuerdo_pago = ap2.id AND apl2.activo = true AND apl2.id_pago IS NOT NULL
            LEFT JOIN LATERAL (
              SELECT pv.estado FROM pago_validaciones pv WHERE pv.id_pago = apl2.id_pago ORDER BY pv.fecha_creacion DESC LIMIT 1
            ) latest_v ON true
            WHERE ap2.id_cuenta_cobranza = cc.id AND latest_v.estado IS DISTINCT FROM 'coincide'
            UNION ALL
            SELECT 1
            FROM acuerdos_pago ap3
            WHERE ap3.id_cuenta_cobranza = cc.id AND ap3.activo = true AND eff_o.id_producto IS NOT NULL
              AND NOT EXISTS (
                SELECT 1 FROM aplicaciones_pago apl3
                WHERE apl3.id_acuerdo_pago = ap3.id AND apl3.activo = true AND apl3.id_pago IS NOT NULL
              )
          ) inv
        ) AS invalidos
      FROM acuerdos_pago ap
      LEFT JOIN LATERAL (
        SELECT COALESCE(SUM(a.monto), 0) AS aplicado
        FROM aplicaciones_pago a
        WHERE a.id_acuerdo_pago = ap.id AND a.activo = true AND a.es_multa = false
      ) apl ON true
      WHERE ap.id_cuenta_cobranza = cc.id AND ap.activo = true
    ) vc ON true
    WHERE (cc.activo = true OR (cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL))
      AND (p_proyecto_id IS NULL OR pr.id = p_proyecto_id)
      AND (
        p_search IS NULL OR p_search = '' OR
        cc.clabe_stp          ILIKE '%' || p_search || '%' OR
        p.nombre_legal        ILIKE '%' || p_search || '%' OR
        p.email               ILIKE '%' || p_search || '%' OR
        prop.numero_propiedad ILIKE '%' || p_search || '%' OR
        ps.nombre             ILIKE '%' || p_search || '%' OR
        ed.nombre             ILIKE '%' || p_search || '%' OR
        pr.nombre             ILIKE '%' || p_search || '%'
      )
  ),
  filtered AS (
    SELECT * FROM base
    WHERE (p_solo_vencidas = false OR parcialidades_vencidas > 0)
      AND (p_cliente IS NULL OR p_cliente = '' OR cliente_nombre ILIKE '%'||p_cliente||'%' OR cliente_email ILIKE '%'||p_cliente||'%')
      AND (p_unidad  IS NULL OR p_unidad  = '' OR numero_propiedad ILIKE '%'||p_unidad||'%')
      AND (p_clabe   IS NULL OR p_clabe   = '' OR clabe_stp ILIKE '%'||p_clabe||'%')
      AND (p_cuenta  IS NULL OR p_cuenta  = '' OR
           cuenta_id::text ILIKE '%' || NULLIF(regexp_replace(p_cuenta, '\D', '', 'g'), '') || '%')
      AND (p_modelos IS NULL OR modelo = ANY(p_modelos))
      AND (p_tipos   IS NULL OR tipo_categoria = ANY(p_tipos))
      AND (p_estatus IS NULL OR estatus_propiedad = ANY(p_estatus))
      AND (p_prioridad IS NULL OR
        (CASE WHEN parcialidades_vencidas = 0 THEN 'Al día'
              WHEN parcialidades_vencidas = 1 THEN 'Alerta'
              WHEN parcialidades_vencidas = 2 THEN 'Urgente'
              ELSE 'Crítico' END) = ANY(p_prioridad))
      AND (p_invalid_level IS NULL OR
        (CASE WHEN invalidos = 0 THEN 'Al día'
              WHEN invalidos = 1 THEN 'Alerta'
              WHEN invalidos = 2 THEN 'Urgente'
              ELSE 'Crítico' END) = ANY(p_invalid_level))
  ),
  ordered AS (
    SELECT *, row_number() OVER (
      ORDER BY
        CASE WHEN p_sort_key='account'      AND v_asc     THEN cuenta_id              END ASC,
        CASE WHEN p_sort_key='account'      AND NOT v_asc THEN cuenta_id              END DESC,
        CASE WHEN p_sort_key='client'       AND v_asc     THEN lower(cliente_nombre)  END ASC,
        CASE WHEN p_sort_key='client'       AND NOT v_asc THEN lower(cliente_nombre)  END DESC,
        CASE WHEN p_sort_key='price'        AND v_asc     THEN precio_final           END ASC,
        CASE WHEN p_sort_key='price'        AND NOT v_asc THEN precio_final           END DESC,
        CASE WHEN p_sort_key='overdue'      AND v_asc     THEN monto_vencido          END ASC,
        CASE WHEN p_sort_key='overdue'      AND NOT v_asc THEN monto_vencido          END DESC,
        CASE WHEN p_sort_key='pending'      AND v_asc     THEN saldo_pendiente        END ASC,
        CASE WHEN p_sort_key='pending'      AND NOT v_asc THEN saldo_pendiente        END DESC,
        CASE WHEN p_sort_key='installments' AND v_asc     THEN parcialidades_vencidas END ASC,
        CASE WHEN p_sort_key='installments' AND NOT v_asc THEN parcialidades_vencidas END DESC,
        CASE WHEN p_sort_key='invalid'      AND v_asc     THEN invalidos              END ASC,
        CASE WHEN p_sort_key='invalid'      AND NOT v_asc THEN invalidos              END DESC,
        CASE WHEN p_sort_key='daysLate'     AND v_asc     THEN dias_sin_pagar         END ASC,
        CASE WHEN p_sort_key='daysLate'     AND NOT v_asc THEN dias_sin_pagar         END DESC,
        CASE WHEN p_sort_key IS NULL THEN parcialidades_vencidas END DESC,
        CASE WHEN p_sort_key IS NULL THEN invalidos              END DESC,
        cuenta_id ASC
    ) AS rn
    FROM filtered
  ),
  page AS (
    SELECT * FROM ordered WHERE rn > p_offset AND rn <= p_offset + p_limit
  )
  SELECT jsonb_build_object(
    'total', (SELECT COUNT(*) FROM filtered),
    'kpis', jsonb_build_object(
      'total',      (SELECT COUNT(*) FROM filtered),
      'overdue',    (SELECT COALESCE(SUM(monto_vencido), 0)   FROM filtered),
      'pending',    (SELECT COALESCE(SUM(saldo_pendiente), 0) FROM filtered),
      'in_arrears', (SELECT COUNT(*) FROM filtered WHERE parcialidades_vencidas > 0)
    ),
    'modelos', (SELECT COALESCE(jsonb_agg(DISTINCT modelo ORDER BY modelo) FILTER (WHERE modelo IS NOT NULL), '[]'::jsonb) FROM base),
    'estatus', (SELECT COALESCE(jsonb_agg(DISTINCT estatus_propiedad ORDER BY estatus_propiedad) FILTER (WHERE estatus_propiedad IS NOT NULL), '[]'::jsonb) FROM base),
    'cuentas', COALESCE((SELECT jsonb_agg(to_jsonb(page) - 'rn' ORDER BY rn) FROM page), '[]'::jsonb)
  ) INTO result;

  RETURN result;
END;
$function$;
