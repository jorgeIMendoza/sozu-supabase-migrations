-- P18: get_relacion_pagos con filtros idénticos a la bandeja de Cuentas de Cobranza.
-- Fecha: 2026-06-30 (generada 2026-07-01)
--
-- Nueva firma (10 params): proyecto/clabe/cliente/unidad/cuenta/tipos/prioridades/
-- invalidos + paginación. Devuelve por pago parcialidades_vencidas, invalidos y
-- tipo_categoria (métricas por cuenta, calculadas 1 vez por cuenta activa y filtradas
-- server-side). Prioridad/Invalidos derivan de conteos por cuenta. Elimina la lógica
-- de dispersiones/aplicaciones (ya no se usa). Validado en dev por el autor 2026-06-30
-- (~311ms métricas por cuenta). Firma nueva -> CREATE OR REPLACE. Idempotente.
--
-- DROP de overloads viejos (IF EXISTS) para dejar solo la firma nueva y evitar
-- ambigüedad de PostgREST al resolver la función. El front llama la firma nueva
-- (front + este RPC van juntos en el deploy).
--
-- NOTA: no se pudo consultar dev en esta sesión (MCP desconectado). Columnas
-- referenciadas ya confirmadas en migraciones previas de esta sesión (P14/P16).

CREATE OR REPLACE FUNCTION public.get_relacion_pagos(
  p_proyecto_id integer DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0,
  p_clabe text DEFAULT NULL,
  p_cliente text DEFAULT NULL,
  p_unidad text DEFAULT NULL,
  p_cuenta text DEFAULT NULL,
  p_tipos text[] DEFAULT NULL,
  p_prioridades text[] DEFAULT NULL,
  p_invalidos text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
  v_hoy date := current_date;
BEGIN
  WITH cuenta_metrics AS (
    SELECT cc.id AS cuenta_id,
      (SELECT COUNT(*) FROM acuerdos_pago ap
         WHERE ap.id_cuenta_cobranza = cc.id AND ap.activo = true
           AND ap.pago_completado = false AND ap.fecha_pago < v_hoy)::int AS parcialidades_vencidas,
      (SELECT COUNT(*)::int FROM (
          SELECT 1
          FROM acuerdos_pago ap2
          JOIN aplicaciones_pago apl2 ON apl2.id_acuerdo_pago = ap2.id
            AND apl2.activo = true AND apl2.id_pago IS NOT NULL
          LEFT JOIN LATERAL (
            SELECT pv.estado FROM pago_validaciones pv
            WHERE pv.id_pago = apl2.id_pago ORDER BY pv.fecha_creacion DESC LIMIT 1
          ) lv ON true
          WHERE ap2.id_cuenta_cobranza = cc.id AND lv.estado IS DISTINCT FROM 'coincide'
      ) inv) AS invalidos
    FROM cuentas_cobranza cc WHERE cc.activo = true
  ),
  base AS (
    SELECT
      p.id AS pago_id, p.monto, p.fecha_pago, p.clave_rastreo, p.url_cep, p.url_recibo,
      p.descripcion, p.id_cuenta_cobranza, mp.nombre AS metodo_pago, cc.clabe_stp,
      per.nombre_legal AS cliente, pr.numero_propiedad AS num_propiedad, ps.nombre AS producto,
      CASE
        WHEN cc.id_propiedad IS NOT NULL THEN 'propiedad'
        WHEN o.id_producto IS NOT NULL THEN 'producto'
        ELSE NULL
      END AS tipo_cuenta,
      CASE
        WHEN cc.id_propiedad IS NOT NULL THEN 'Propiedad'
        WHEN lower(coalesce(ps.nombre,'')) LIKE '%bodega%' THEN 'Bodega'
        WHEN lower(coalesce(ps.nombre,'')) LIKE '%estacionamiento%' THEN 'Estacionamiento'
        WHEN o.id_producto IS NOT NULL THEN 'Producto'
        ELSE 'Producto'
      END AS tipo_categoria,
      proy.nombre AS proyecto, proy.id AS proyecto_id,
      (p.url_cep IS NOT NULL AND length(trim(p.url_cep)) > 0) AS tiene_cep,
      COALESCE(cm.parcialidades_vencidas, 0) AS parcialidades_vencidas,
      COALESCE(cm.invalidos, 0) AS invalidos
    FROM pagos p
    LEFT JOIN metodos_pago mp ON mp.id = p.id_metodos_pago
    LEFT JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
    LEFT JOIN cuenta_metrics cm ON cm.cuenta_id = cc.id
    LEFT JOIN ofertas o ON o.id = cc.id_oferta
    LEFT JOIN personas per ON per.id = o.id_persona_lead
    LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
    LEFT JOIN propiedades pr ON pr.id = cc.id_propiedad
    LEFT JOIN edificios_modelos em ON em.id = pr.id_edificio_modelo
    LEFT JOIN edificios ed ON ed.id = em.id_edificio
    LEFT JOIN proyectos proy ON proy.id = COALESCE(ed.id_proyecto, ps.id_proyecto)
    WHERE p.activo = true
      AND (cc.id_propiedad IS NOT NULL OR o.id_producto IS NOT NULL)
  ),
  nivel AS (
    SELECT b.*,
      CASE WHEN parcialidades_vencidas = 0 THEN 'Al día'
           WHEN parcialidades_vencidas = 1 THEN 'Alerta'
           WHEN parcialidades_vencidas = 2 THEN 'Urgente' ELSE 'Crítico' END AS nivel_prio,
      CASE WHEN invalidos = 0 THEN 'Al día'
           WHEN invalidos = 1 THEN 'Alerta'
           WHEN invalidos = 2 THEN 'Urgente' ELSE 'Crítico' END AS nivel_inv
    FROM base b
  ),
  filtered AS (
    SELECT * FROM nivel
    WHERE (p_proyecto_id IS NULL OR proyecto_id = p_proyecto_id)
      AND (p_tipos IS NULL OR tipo_categoria = ANY(p_tipos))
      AND (p_prioridades IS NULL OR nivel_prio = ANY(p_prioridades))
      AND (p_invalidos IS NULL OR nivel_inv = ANY(p_invalidos))
      AND (p_clabe IS NULL OR p_clabe = '' OR clabe_stp ILIKE '%' || p_clabe || '%')
      AND (p_cliente IS NULL OR p_cliente = '' OR cliente ILIKE '%' || p_cliente || '%')
      AND (p_unidad IS NULL OR p_unidad = '' OR num_propiedad ILIKE '%' || p_unidad || '%')
      AND (p_cuenta IS NULL OR p_cuenta = '' OR
           id_cuenta_cobranza::text ILIKE '%' || regexp_replace(p_cuenta, '\D', '', 'g') || '%')
  ),
  totals AS (
    SELECT
      COUNT(*) AS total,
      COALESCE(SUM(monto), 0) AS total_monto,
      COUNT(*) FILTER (WHERE tiene_cep) AS total_validos,
      COUNT(*) FILTER (WHERE NOT tiene_cep) AS total_sin_validar
    FROM filtered
  ),
  paginated AS (
    SELECT * FROM filtered
    ORDER BY fecha_pago DESC, pago_id DESC
    LIMIT p_limit OFFSET p_offset
  )
  SELECT jsonb_build_object(
    'total', (SELECT total FROM totals),
    'total_monto', (SELECT total_monto FROM totals),
    'total_validos', (SELECT total_validos FROM totals),
    'total_sin_validar', (SELECT total_sin_validar FROM totals),
    'pagos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'pago_id', pago_id,
        'monto', monto,
        'fecha_pago', fecha_pago,
        'clave_rastreo', clave_rastreo,
        'url_cep', url_cep,
        'url_recibo', url_recibo,
        'descripcion', descripcion,
        'id_cuenta_cobranza', id_cuenta_cobranza,
        'metodo_pago', metodo_pago,
        'clabe_stp', clabe_stp,
        'cliente', cliente,
        'num_propiedad', num_propiedad,
        'producto', producto,
        'tipo_cuenta', tipo_cuenta,
        'tipo_categoria', tipo_categoria,
        'proyecto', proyecto,
        'proyecto_id', proyecto_id,
        'tiene_cep', tiene_cep,
        'parcialidades_vencidas', parcialidades_vencidas,
        'invalidos', invalidos
      )) FROM paginated
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- Limpieza: quitar overloads viejos (ya no los usa el front). Deja solo la firma nueva.
DROP FUNCTION IF EXISTS public.get_relacion_pagos(integer, text, text, boolean, text, integer, integer);
DROP FUNCTION IF EXISTS public.get_relacion_pagos(integer, text, text, boolean, text, integer, integer, text[]);
DROP FUNCTION IF EXISTS public.get_relacion_pagos(integer, text, text, boolean, text, integer, integer, text[], boolean);
