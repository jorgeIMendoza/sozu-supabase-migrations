-- Relación de Pagos — agrega modelo, estatus_propiedad y cliente_email
-- Fecha: 2026-07-03
--
-- Iguala la salida de get_relacion_pagos al estándar de Cuentas de Cobranza:
--   modelo            (modelos.nombre, para "modelo · unidad" en Proyecto)
--   estatus_propiedad (estatus_disponibilidad.nombre, secundario bajo Tipo)
--   cliente_email     (personas.email, secundario bajo Cliente)
--
-- Backward-compatible: sólo agrega llaves al jsonb; no cambia la firma (9 args)
-- ni rompe otros consumidores (portal-escrituración usa el mismo RPC e ignora
-- las llaves nuevas). CREATE OR REPLACE reemplaza en sitio. NOTIFY pgrst recarga
-- el schema cache de PostgREST. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

CREATE OR REPLACE FUNCTION public.get_relacion_pagos(p_proyecto_id integer DEFAULT NULL::integer, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_clabe text DEFAULT NULL::text, p_cliente text DEFAULT NULL::text, p_unidad text DEFAULT NULL::text, p_cuenta text DEFAULT NULL::text, p_tipos text[] DEFAULT NULL::text[], p_estatus text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
  v_hoy date := current_date;
BEGIN
  WITH base AS (
    SELECT
      p.id AS pago_id, p.monto, p.fecha_pago, p.clave_rastreo, p.url_cep, p.url_recibo,
      p.descripcion, p.id_cuenta_cobranza, mp.nombre AS metodo_pago, cc.clabe_stp,
      per.nombre_legal AS cliente, per.email AS cliente_email,
      pr.numero_propiedad AS num_propiedad, mod.nombre AS modelo,
      est.nombre AS estatus_propiedad, ps.nombre AS producto,
      val.estado AS validacion_estado,
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
      CASE val.estado
        WHEN 'coincide'    THEN 'valido'
        WHEN 'no_coincide' THEN 'invalido'
        WHEN 'error'       THEN 'error'
        ELSE 'sin_revisar'
      END AS estatus,
      CASE WHEN val.estado IS DISTINCT FROM 'coincide' AND p.fecha_pago IS NOT NULL
           THEN GREATEST(0, (v_hoy - p.fecha_pago)::int) ELSE 0 END AS atraso,
      proy.nombre AS proyecto, proy.id AS proyecto_id,
      (p.url_cep IS NOT NULL AND length(trim(p.url_cep)) > 0) AS tiene_cep
    FROM pagos p
    LEFT JOIN metodos_pago mp ON mp.id = p.id_metodos_pago
    LEFT JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
    LEFT JOIN ofertas o ON o.id = cc.id_oferta
    LEFT JOIN personas per ON per.id = o.id_persona_lead
    LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
    LEFT JOIN propiedades pr ON pr.id = cc.id_propiedad
    LEFT JOIN edificios_modelos em ON em.id = pr.id_edificio_modelo
    LEFT JOIN edificios ed ON ed.id = em.id_edificio
    LEFT JOIN modelos mod ON mod.id = em.id_modelo
    LEFT JOIN estatus_disponibilidad est ON est.id = pr.id_estatus_disponibilidad
    LEFT JOIN proyectos proy ON proy.id = COALESCE(ed.id_proyecto, ps.id_proyecto)
    LEFT JOIN LATERAL (
      SELECT pv.estado FROM pago_validaciones pv
      WHERE pv.id_pago = p.id ORDER BY pv.fecha_creacion DESC LIMIT 1
    ) val ON true
    WHERE p.activo = true
      AND (cc.id_propiedad IS NOT NULL OR o.id_producto IS NOT NULL)
  ),
  filtered AS (
    SELECT * FROM base
    WHERE (p_proyecto_id IS NULL OR proyecto_id = p_proyecto_id)
      AND (p_tipos IS NULL OR tipo_categoria = ANY(p_tipos))
      AND (p_estatus IS NULL OR estatus = ANY(p_estatus))
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
      COUNT(*) FILTER (WHERE tiene_cep AND validacion_estado = 'coincide') AS total_validos,
      COUNT(*) FILTER (WHERE url_recibo IS NOT NULL AND validacion_estado IS DISTINCT FROM 'coincide') AS total_sin_validar
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
        'pago_id', pago_id, 'monto', monto, 'fecha_pago', fecha_pago,
        'clave_rastreo', clave_rastreo, 'url_cep', url_cep, 'url_recibo', url_recibo,
        'descripcion', descripcion, 'id_cuenta_cobranza', id_cuenta_cobranza,
        'metodo_pago', metodo_pago, 'clabe_stp', clabe_stp, 'cliente', cliente,
        'cliente_email', cliente_email, 'num_propiedad', num_propiedad, 'modelo', modelo,
        'estatus_propiedad', estatus_propiedad, 'producto', producto, 'tipo_cuenta', tipo_cuenta,
        'tipo_categoria', tipo_categoria, 'estatus', estatus, 'atraso', atraso,
        'proyecto', proyecto, 'proyecto_id', proyecto_id, 'tiene_cep', tiene_cep
      )) FROM paginated
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

NOTIFY pgrst, 'reload schema';
