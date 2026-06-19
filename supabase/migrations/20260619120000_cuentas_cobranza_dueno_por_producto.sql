-- Fix: en el listado/export de cuentas de cobranza, la columna "Propietario"/dueño
-- mostraba siempre el dueño de la PROPIEDAD, incluso para cuentas tipo Producto/Servicio.
-- Para esas cuentas el vendedor debe ser el dueño del PRODUCTO
-- (productos_servicios.id_entidad_relacionada_dueno vía ofertas.id_producto).
--
-- Cambio en ambos RPCs: la entidad dueña se resuelve con
--   CASE WHEN o.id_producto IS NOT NULL THEN ps.id_entidad_relacionada_dueno
--        ELSE prop.id_entidad_relacionada_dueno END
-- El filtro de acceso p_dueno_entity_ids (representante de empresa dueña) se mantiene
-- sobre prop.id_entidad_relacionada_dueno (control de acceso por propiedad, sin cambios).

CREATE OR REPLACE FUNCTION public.get_cuentas_cobranza_paginadas(p_page integer DEFAULT 1, p_per_page integer DEFAULT 50, p_id_cuenta text DEFAULT NULL::text, p_proyecto text DEFAULT NULL::text, p_clabe text DEFAULT NULL::text, p_no_propiedad text DEFAULT NULL::text, p_modelo text DEFAULT NULL::text, p_compradores text DEFAULT NULL::text, p_producto text DEFAULT NULL::text, p_estatus_ids integer[] DEFAULT NULL::integer[], p_tipos text[] DEFAULT NULL::text[], p_activo boolean DEFAULT true, p_proyecto_ids integer[] DEFAULT NULL::integer[], p_dueno_entity_ids integer[] DEFAULT NULL::integer[], p_search text DEFAULT NULL::text)
 RETURNS TABLE(id integer, clabe_stp text, fecha_compra text, precio_final numeric, activo boolean, id_oferta integer, tipo text, proyecto text, id_proyecto integer, modelo text, edificio text, numero_propiedad text, id_propiedad integer, producto text, id_producto integer, comprador text, compradores_json jsonb, id_estatus_disponibilidad integer, estatus_disponibilidad_nombre text, vendedor text, dueno text, id_entidad_relacionada_dueno integer, id_cuenta_cobranza_padre integer, metraje numeric, precio_lista numeric, pagado numeric, restante numeric, tiene_acuerdos boolean, apartado_pagado boolean, total_acuerdos numeric, discrepancia numeric, cash_limit numeric, cash_paid numeric, cash_payments jsonb, collection_id integer, total_count bigint, motivo_cancelacion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_offset integer;
  v_total bigint;
  v_id_padded text;
BEGIN
  v_offset := (p_page - 1) * p_per_page;
  v_id_padded := NULLIF(TRIM(COALESCE(p_id_cuenta, '')), '');

  SELECT COUNT(DISTINCT cc.id) INTO v_total
  FROM cuentas_cobranza cc
  LEFT JOIN ofertas o ON o.id = cc.id_oferta
  LEFT JOIN propiedades prop ON prop.id = o.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios e ON e.id = em.id_edificio
  LEFT JOIN proyectos proy ON proy.id = e.id_proyecto
  LEFT JOIN modelos m ON m.id = em.id_modelo
  LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
  LEFT JOIN compradores comp_filter ON comp_filter.id_cuenta_cobranza = cc.id AND comp_filter.activo = true
  LEFT JOIN personas per_filter ON per_filter.id = comp_filter.id_persona
  WHERE cc.activo = p_activo
    AND cc.id_cuenta_cobranza_padre IS NULL
    AND (
      v_id_padded IS NULL
      OR LPAD(cc.id::text, 6, '0') ILIKE '%' || v_id_padded || '%'
    )
    AND (p_clabe IS NULL OR cc.clabe_stp ILIKE '%' || p_clabe || '%')
    AND (p_proyecto IS NULL OR proy.nombre ILIKE '%' || p_proyecto || '%')
    AND (p_no_propiedad IS NULL OR prop.numero_propiedad ILIKE '%' || p_no_propiedad || '%')
    AND (p_modelo IS NULL OR m.nombre ILIKE '%' || p_modelo || '%')
    AND (p_producto IS NULL OR ps.nombre ILIKE '%' || p_producto || '%')
    AND (p_compradores IS NULL OR per_filter.nombre_legal ILIKE '%' || p_compradores || '%')
    AND (p_estatus_ids IS NULL OR prop.id_estatus_disponibilidad = ANY(p_estatus_ids))
    AND (p_tipos IS NULL OR
         (CASE
           WHEN o.id_producto IS NOT NULL THEN 'Producto'
           WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
           ELSE 'Servicio'
         END) = ANY(p_tipos))
    AND (p_proyecto_ids IS NULL OR e.id_proyecto = ANY(p_proyecto_ids))
    AND (p_dueno_entity_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_dueno_entity_ids))
    AND (p_search IS NULL OR (
      cc.id::text ILIKE '%' || p_search || '%'
      OR LPAD(cc.id::text, 6, '0') ILIKE '%' || p_search || '%'
      OR cc.clabe_stp ILIKE '%' || p_search || '%'
      OR proy.nombre ILIKE '%' || p_search || '%'
      OR prop.numero_propiedad ILIKE '%' || p_search || '%'
      OR ps.nombre ILIKE '%' || p_search || '%'
      OR per_filter.nombre_legal ILIKE '%' || p_search || '%'
    ));

  RETURN QUERY
  WITH acuerdos_info AS (
    SELECT
      ap.id_cuenta_cobranza,
      SUM(ap.monto) AS suma_acuerdos,
      COUNT(*) > 0 AS tiene_acuerdos_flag
    FROM acuerdos_pago ap
    WHERE ap.activo = true
    GROUP BY ap.id_cuenta_cobranza
  ),
  apartado_info AS (
    SELECT
      ap.id_cuenta_cobranza,
      bool_and(ap.pago_completado) AS apartado_pagado_flag
    FROM acuerdos_pago ap
    WHERE ap.activo = true
      AND ap.id_concepto IN (1, 2)  -- 1=Apartado, 2=Enganche
    GROUP BY ap.id_cuenta_cobranza
  ),
  pagos_info AS (
    SELECT
      p.id_cuenta_cobranza,
      SUM(p.monto) AS total_pagado
    FROM pagos p
    WHERE p.activo = true
    GROUP BY p.id_cuenta_cobranza
  ),
  cash_info AS (
    SELECT
      p.id_cuenta_cobranza,
      SUM(p.monto) AS cash_paid,
      jsonb_agg(jsonb_build_object('fecha_pago', p.fecha_pago, 'monto', p.monto)) AS cash_payments
    FROM pagos p
    WHERE p.activo = true AND p.id_metodos_pago = 2
    GROUP BY p.id_cuenta_cobranza
  ),
  compradores_info AS (
    SELECT
      comp.id_cuenta_cobranza,
      jsonb_agg(
        jsonb_build_object(
          'id_persona', per.id,
          'nombre_legal', per.nombre_legal,
          'rfc', per.rfc,
          'porcentaje_copropiedad', comp.porcentaje_copropiedad
        )
        ORDER BY per.nombre_legal
      ) AS compradores_data,
      STRING_AGG(per.nombre_legal, ', ' ORDER BY per.nombre_legal) AS compradores_str
    FROM compradores comp
    JOIN personas per ON per.id = comp.id_persona
    WHERE comp.activo = true
    GROUP BY comp.id_cuenta_cobranza
  )
  SELECT
    cc.id::integer,
    cc.clabe_stp,
    cc.fecha_compra::text,
    cc.precio_final,
    cc.activo,
    cc.id_oferta,
    CASE
      WHEN o.id_producto IS NOT NULL THEN 'Producto'
      WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
      ELSE 'Servicio'
    END AS tipo,
    proy.nombre AS proyecto,
    e.id_proyecto AS id_proyecto,
    m.nombre AS modelo,
    e.nombre AS edificio,
    prop.numero_propiedad,
    prop.id::integer AS id_propiedad,
    ps.nombre AS producto,
    ps.id AS id_producto,
    ci.compradores_str AS comprador,
    COALESCE(ci.compradores_data, '[]'::jsonb) AS compradores_json,
    prop.id_estatus_disponibilidad,
    ed.nombre AS estatus_disponibilidad_nombre,
    NULL::text AS vendedor,
    per_dueno.nombre_legal AS dueno,
    (CASE WHEN o.id_producto IS NOT NULL THEN ps.id_entidad_relacionada_dueno ELSE prop.id_entidad_relacionada_dueno END)::integer AS id_entidad_relacionada_dueno,
    cc.id_cuenta_cobranza_padre::integer,
    (COALESCE(prop.m2_interiores,0) + COALESCE(prop.m2_exteriores,0) + COALESCE(prop.m2_loft,0))::numeric AS metraje,
    prop.precio_lista::numeric,
    COALESCE(pi.total_pagado, 0) AS pagado,
    (cc.precio_final - COALESCE(pi.total_pagado, 0)) AS restante,
    COALESCE(ai.tiene_acuerdos_flag, false) AS tiene_acuerdos,
    COALESCE(api.apartado_pagado_flag, false) AS apartado_pagado,
    COALESCE(ai.suma_acuerdos, 0) AS total_acuerdos,
    (cc.precio_final - COALESCE(ai.suma_acuerdos, 0)) AS discrepancia,
    NULL::numeric AS cash_limit,
    COALESCE(chi.cash_paid, 0) AS cash_paid,
    COALESCE(chi.cash_payments, '[]'::jsonb) AS cash_payments,
    cc.collection_id::integer,
    v_total AS total_count,
    NULL::text AS motivo_cancelacion
  FROM cuentas_cobranza cc
  LEFT JOIN ofertas o ON o.id = cc.id_oferta
  LEFT JOIN propiedades prop ON prop.id = o.id_propiedad
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios e ON e.id = em.id_edificio
  LEFT JOIN proyectos proy ON proy.id = e.id_proyecto
  LEFT JOIN modelos m ON m.id = em.id_modelo
  LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
  LEFT JOIN estatus_disponibilidad ed ON ed.id = prop.id_estatus_disponibilidad
  LEFT JOIN entidades_relacionadas er_dueno ON er_dueno.id = CASE WHEN o.id_producto IS NOT NULL THEN ps.id_entidad_relacionada_dueno ELSE prop.id_entidad_relacionada_dueno END
  LEFT JOIN personas per_dueno ON per_dueno.id = er_dueno.id_persona
  LEFT JOIN acuerdos_info ai ON ai.id_cuenta_cobranza = cc.id
  LEFT JOIN apartado_info api ON api.id_cuenta_cobranza = cc.id
  LEFT JOIN pagos_info pi ON pi.id_cuenta_cobranza = cc.id
  LEFT JOIN cash_info chi ON chi.id_cuenta_cobranza = cc.id
  LEFT JOIN compradores_info ci ON ci.id_cuenta_cobranza = cc.id
  WHERE cc.activo = p_activo
    AND cc.id_cuenta_cobranza_padre IS NULL
    AND (
      v_id_padded IS NULL
      OR LPAD(cc.id::text, 6, '0') ILIKE '%' || v_id_padded || '%'
    )
    AND (p_clabe IS NULL OR cc.clabe_stp ILIKE '%' || p_clabe || '%')
    AND (p_proyecto IS NULL OR proy.nombre ILIKE '%' || p_proyecto || '%')
    AND (p_no_propiedad IS NULL OR prop.numero_propiedad ILIKE '%' || p_no_propiedad || '%')
    AND (p_modelo IS NULL OR m.nombre ILIKE '%' || p_modelo || '%')
    AND (p_producto IS NULL OR ps.nombre ILIKE '%' || p_producto || '%')
    AND (p_compradores IS NULL OR EXISTS (
      SELECT 1 FROM compradores cf2
      JOIN personas pf2 ON pf2.id = cf2.id_persona
      WHERE cf2.id_cuenta_cobranza = cc.id
        AND cf2.activo = true
        AND pf2.nombre_legal ILIKE '%' || p_compradores || '%'
    ))
    AND (p_estatus_ids IS NULL OR prop.id_estatus_disponibilidad = ANY(p_estatus_ids))
    AND (p_tipos IS NULL OR
         (CASE
           WHEN o.id_producto IS NOT NULL THEN 'Producto'
           WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
           ELSE 'Servicio'
         END) = ANY(p_tipos))
    AND (p_proyecto_ids IS NULL OR e.id_proyecto = ANY(p_proyecto_ids))
    AND (p_dueno_entity_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_dueno_entity_ids))
    AND (p_search IS NULL OR (
      cc.id::text ILIKE '%' || p_search || '%'
      OR LPAD(cc.id::text, 6, '0') ILIKE '%' || p_search || '%'
      OR cc.clabe_stp ILIKE '%' || p_search || '%'
      OR proy.nombre ILIKE '%' || p_search || '%'
      OR prop.numero_propiedad ILIKE '%' || p_search || '%'
      OR ps.nombre ILIKE '%' || p_search || '%'
      OR EXISTS (
        SELECT 1 FROM compradores cf3
        JOIN personas pf3 ON pf3.id = cf3.id_persona
        WHERE cf3.id_cuenta_cobranza = cc.id
          AND cf3.activo = true
          AND pf3.nombre_legal ILIKE '%' || p_search || '%'
      )
    ))
  ORDER BY cc.id DESC
  LIMIT p_per_page
  OFFSET v_offset;
END;
$function$;


CREATE OR REPLACE FUNCTION public.get_cuentas_cobranza_export(p_id_cuenta text DEFAULT NULL::text, p_proyecto text DEFAULT NULL::text, p_clabe text DEFAULT NULL::text, p_no_propiedad text DEFAULT NULL::text, p_modelo text DEFAULT NULL::text, p_compradores text DEFAULT NULL::text, p_producto text DEFAULT NULL::text, p_estatus_ids integer[] DEFAULT NULL::integer[], p_tipos text[] DEFAULT NULL::text[], p_activo boolean DEFAULT true, p_proyecto_ids integer[] DEFAULT NULL::integer[], p_dueno_entity_ids integer[] DEFAULT NULL::integer[], p_limit integer DEFAULT 50000, p_offset integer DEFAULT 0)
 RETURNS TABLE(id integer, clabe_stp text, fecha_compra text, precio_final numeric, tipo text, proyecto text, modelo text, edificio text, numero_propiedad text, producto text, comprador text, estatus_disponibilidad_nombre text, vendedor text, dueno text, metraje numeric, precio_lista numeric, pagado numeric, restante numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET statement_timeout TO '120s'
AS $function$
BEGIN
  RETURN QUERY
  WITH pagos_sum AS (
    SELECT p.id_cuenta_cobranza, SUM(p.monto) as total_pagado
    FROM pagos p
    WHERE p.activo = true
    GROUP BY p.id_cuenta_cobranza
  ),
  primer_comprador AS (
    SELECT DISTINCT ON (comp.id_cuenta_cobranza)
      comp.id_cuenta_cobranza,
      pers.nombre_legal
    FROM compradores comp
    JOIN personas pers ON comp.id_persona = pers.id
    WHERE comp.activo = true
    ORDER BY comp.id_cuenta_cobranza, pers.id
  )
  SELECT
    cc.id::integer AS id,
    cc.clabe_stp,
    cc.fecha_compra::text,
    cc.precio_final,
    CASE
      WHEN o.id_producto IS NOT NULL THEN 'Producto'
      WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
      ELSE 'Servicio'
    END AS tipo,
    COALESCE(pr.nombre, pr2.nombre) AS proyecto,
    m.nombre AS modelo,
    edif.nombre AS edificio,
    prop.numero_propiedad,
    ps.nombre AS producto,
    pc.nombre_legal AS comprador,
    ed.nombre AS estatus_disponibilidad_nombre,
    vendedor_pers.nombre_legal AS vendedor,
    dueno_pers.nombre_legal AS dueno,
    COALESCE(prop.m2_interiores, 0) + COALESCE(prop.m2_exteriores, 0) AS metraje,
    prop.precio_lista,
    COALESCE(psum.total_pagado, 0) AS pagado,
    cc.precio_final - COALESCE(psum.total_pagado, 0) AS restante
  FROM cuentas_cobranza cc
  JOIN ofertas o ON cc.id_oferta = o.id
  LEFT JOIN propiedades prop ON o.id_propiedad = prop.id
  LEFT JOIN edificios_modelos em ON prop.id_edificio_modelo = em.id
  LEFT JOIN edificios edif ON em.id_edificio = edif.id
  LEFT JOIN proyectos pr ON edif.id_proyecto = pr.id
  LEFT JOIN modelos m ON em.id_modelo = m.id
  LEFT JOIN productos_servicios ps ON o.id_producto = ps.id
  LEFT JOIN proyectos pr2 ON ps.id_proyecto = pr2.id
  LEFT JOIN estatus_disponibilidad ed ON prop.id_estatus_disponibilidad = ed.id
  LEFT JOIN personas vendedor_pers ON vendedor_pers.id = o.id_persona_lead
  LEFT JOIN entidades_relacionadas er ON er.id = CASE WHEN o.id_producto IS NOT NULL THEN ps.id_entidad_relacionada_dueno ELSE prop.id_entidad_relacionada_dueno END AND er.activo = true
  LEFT JOIN personas dueno_pers ON dueno_pers.id = er.id_persona
  LEFT JOIN pagos_sum psum ON psum.id_cuenta_cobranza = cc.id
  LEFT JOIN primer_comprador pc ON pc.id_cuenta_cobranza = cc.id
  WHERE cc.activo = p_activo
    AND cc.id_cuenta_cobranza_padre IS NULL
    AND (p_id_cuenta IS NULL OR cc.id::text ILIKE '%' || p_id_cuenta || '%')
    AND (p_clabe IS NULL OR cc.clabe_stp ILIKE '%' || p_clabe || '%')
    AND (p_proyecto IS NULL OR COALESCE(pr.nombre, pr2.nombre) ILIKE '%' || p_proyecto || '%')
    AND (p_no_propiedad IS NULL OR prop.numero_propiedad ILIKE '%' || p_no_propiedad || '%')
    AND (p_modelo IS NULL OR m.nombre ILIKE '%' || p_modelo || '%')
    AND (p_compradores IS NULL OR pc.nombre_legal ILIKE '%' || p_compradores || '%')
    AND (p_producto IS NULL OR ps.nombre ILIKE '%' || p_producto || '%')
    AND (p_estatus_ids IS NULL OR prop.id_estatus_disponibilidad = ANY(p_estatus_ids))
    AND (p_tipos IS NULL OR (
      CASE
        WHEN o.id_producto IS NOT NULL THEN 'Producto'
        WHEN o.id_propiedad IS NOT NULL THEN 'Propiedad'
        ELSE 'Servicio'
      END
    ) = ANY(p_tipos))
    AND (p_proyecto_ids IS NULL OR COALESCE(pr.id, pr2.id) = ANY(p_proyecto_ids))
    AND (p_dueno_entity_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_dueno_entity_ids))
  ORDER BY cc.id DESC
  LIMIT p_limit
  OFFSET p_offset;
END;
$function$;
