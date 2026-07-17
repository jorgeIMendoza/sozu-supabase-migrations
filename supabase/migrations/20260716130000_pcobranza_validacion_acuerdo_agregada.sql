-- Cobranza — estado "Valido" del acuerdo padre agrega TODOS sus pagos
-- ---------------------------------------------------------------------------------
-- BUG (verificado prod 2026-07-16): en el detalle de cuenta (tab Acuerdos de Pago),
-- la columna "Valido" del acuerdo con varios pagos mostraba SOLO la validación del
-- pago más reciente (LATERAL up: ORDER BY pg.fecha_pago DESC LIMIT 1). Debía reflejar
-- el peor estado entre TODOS sus pagos.
--
-- Caso real: CC-000620, acuerdo 19493 (Enganche), 3 pagos:
--   15906 2025-08-01 coincide  <- el que se mostraba
--   15904 2024-03-22 sin_evidencia
--   15905 2024-02-28 no_coincide
--   Hoy mostraba "Coincide"; con el fix muestra "No coincide" (verificado: estado_padre='no_coincide').
--
-- Regla de agregación (sobre aplicaciones_pago activas, es_multa=false, id_pago NOT NULL,
-- tomando por pago su validación más reciente pago_validaciones.fecha_creacion DESC):
--   sin pagos -> NULL ("Sin validar")
--   TODOS coincide -> 'coincide'
--   si no, el PEOR: error > no_coincide > monto_ilegible > monto_ausente_db > sin_evidencia
--   si solo quedan pagos sin registro de validación -> NULL ("Sin validar")
--
-- Cambio vs def viva (2 ediciones dentro del subquery v_acuerdos):
--   1) campo validacion: up.val_json -> jsonb_build_object('estado', val_agg.estado_agg)
--   2) nuevo LATERAL val_agg entre los LATERAL up y mu.
-- El LATERAL up se conserva (sigue dando up_json para ultimoPago); su val_json deja de usarse.
-- Acuerdos de 1 pago no cambian (agregar sobre 1 = ese estado). Front no requiere cambios
-- (solo consume validacion.estado). CREATE OR REPLACE => idempotente.

CREATE OR REPLACE FUNCTION public.get_pcobranza_cuenta_detalle(p_cuenta_id integer)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_hoy date := current_date;
  c              record;   -- cuenta
  v_es_mant      boolean;
  v_oferta_id    integer;
  v_cta_comp     integer;  -- cuenta para compradores (padre si mantenimiento)
  o              record;   -- oferta + esquema + propiedad + producto
  v_prop_id      integer;
  em             record;   -- edificio_modelo
  v_proy_nombre  text := '';
  v_edif_nombre  text := '';
  v_modelo_nombre text := '';
  v_estatus_prop text := '';
  v_num_prop     text;
  v_m2_int       numeric := 0;
  v_m2_ext       numeric := 0;
  v_precio       numeric;
  v_producto_nombre text;
  v_categoria_nombre text;
  v_tipo         text;
  v_agente       jsonb := NULL;
  v_esquema_pct  jsonb := NULL;
  v_compradores  jsonb;
  v_comp_ids     jsonb;
  v_cliente_nombre text;
  v_acuerdos     jsonb;
  v_pagos        jsonb;
  v_aplic_list   jsonb;
  v_total_pagado numeric;
  v_total_aplic_all numeric;
  v_pagado_efectivo numeric;
  v_monto_vencido numeric;
  v_parc_venc    integer;
  usu            record;
  v_rol          text;
BEGIN
  SELECT id, clabe_stp, precio_final, fecha_compra, valor_uma, id_oferta, id_propiedad, activo, id_cuenta_cobranza_padre
    INTO c FROM cuentas_cobranza WHERE id = p_cuenta_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cuenta no encontrada'; END IF;

  v_es_mant  := (c.id_cuenta_cobranza_padre IS NOT NULL AND c.id_oferta IS NULL);
  v_precio   := COALESCE(c.precio_final, 0);
  v_oferta_id := c.id_oferta;
  IF v_es_mant AND c.id_cuenta_cobranza_padre IS NOT NULL THEN
    SELECT id_oferta INTO v_oferta_id FROM cuentas_cobranza WHERE id = c.id_cuenta_cobranza_padre;
  END IF;
  v_cta_comp := CASE WHEN v_es_mant AND c.id_cuenta_cobranza_padre IS NOT NULL
                     THEN c.id_cuenta_cobranza_padre ELSE p_cuenta_id END;

  -- Oferta + esquema + propiedad + producto/categoría.
  -- Se ejecuta SIEMPRE (ver nota de cabecera): v_oferta_id NULL → 0 filas → o = NULLs asignado.
  SELECT
    of.id, of.id_producto, of.email_creador, of.id_propiedad AS of_prop,
    esq.nombre AS esq_nombre, esq.porcentaje_enganche, esq.porcentaje_mensualidades,
    esq.porcentaje_entrega, esq.numero_mensualidades,
    pr.id AS prop_id, pr.numero_propiedad, pr.m2_interiores, pr.m2_exteriores,
    pr.id_edificio_modelo, pr.id_estatus_disponibilidad,
    ps.nombre AS prod_nombre, cp.nombre AS cat_nombre
    INTO o
  FROM ofertas of
  LEFT JOIN esquemas_pago esq ON esq.id = of.id_esquema_pago_seleccionado
  LEFT JOIN propiedades pr    ON pr.id = of.id_propiedad
  LEFT JOIN productos_servicios ps ON ps.id = of.id_producto
  LEFT JOIN categorias_producto cp ON cp.id = ps.id_categoria
  WHERE of.id = v_oferta_id;

  v_prop_id := COALESCE(o.prop_id, c.id_propiedad);
  v_producto_nombre := o.prod_nombre;
  v_categoria_nombre := o.cat_nombre;
  v_tipo := CASE WHEN v_es_mant THEN 'Mantenimiento'
                 WHEN v_producto_nombre IS NOT NULL THEN COALESCE(v_categoria_nombre, 'Producto')
                 ELSE 'Propiedad' END;

  IF o.esq_nombre IS NOT NULL OR o.porcentaje_enganche IS NOT NULL THEN
    v_esquema_pct := jsonb_build_object(
      'enganche', COALESCE(o.porcentaje_enganche, 0),
      'mensualidades', COALESCE(o.porcentaje_mensualidades, 0),
      'entrega', COALESCE(o.porcentaje_entrega, 0),
      'numMensualidades', COALESCE(o.numero_mensualidades, 0)
    );
  END IF;

  -- Detalles de propiedad (o proyecto vía producto)
  IF o.prop_id IS NOT NULL THEN
    v_num_prop := o.numero_propiedad;
    v_m2_int := COALESCE(o.m2_interiores, 0);
    v_m2_ext := COALESCE(o.m2_exteriores, 0);
    IF o.id_edificio_modelo IS NOT NULL THEN
      SELECT ed.nombre AS edif, ed.id_proyecto, mo.nombre AS modelo
        INTO em
      FROM edificios_modelos emx
      LEFT JOIN edificios ed ON ed.id = emx.id_edificio
      LEFT JOIN modelos   mo ON mo.id = emx.id_modelo
      WHERE emx.id = o.id_edificio_modelo;
      v_edif_nombre := COALESCE(em.edif, '');
      v_modelo_nombre := COALESCE(em.modelo, '');
      IF em.id_proyecto IS NOT NULL THEN
        SELECT COALESCE(nombre, '') INTO v_proy_nombre FROM proyectos WHERE id = em.id_proyecto;
      END IF;
    END IF;
    IF o.id_estatus_disponibilidad IS NOT NULL THEN
      SELECT COALESCE(nombre, '') INTO v_estatus_prop FROM estatus_disponibilidad WHERE id = o.id_estatus_disponibilidad;
    END IF;
  ELSIF v_producto_nombre IS NOT NULL AND o.id_producto IS NOT NULL THEN
    SELECT COALESCE(p2.nombre, '') INTO v_proy_nombre
    FROM productos_servicios ps2 LEFT JOIN proyectos p2 ON p2.id = ps2.id_proyecto
    WHERE ps2.id = o.id_producto;
  END IF;

  -- Agente (via oferta.email_creador → usuarios)
  IF o.email_creador IS NOT NULL THEN
    SELECT u.nombre, u.email, u.telefono, r.nombre AS rol INTO usu
    FROM usuarios u LEFT JOIN roles r ON r.id = u.rol_id
    WHERE u.email = o.email_creador;
    v_rol := COALESCE(usu.rol, '');
    v_agente := jsonb_build_object(
      'nombre', COALESCE(usu.nombre, o.email_creador),
      'email',  COALESCE(usu.email, o.email_creador),
      'telefono', usu.telefono,
      'rolNombre', v_rol,
      'tipoAgente', CASE WHEN lower(v_rol) LIKE '%agente%' THEN 'Agente' ELSE COALESCE(NULLIF(v_rol,''), 'Otro') END,
      'organizacion', CASE WHEN COALESCE(usu.email, o.email_creador) LIKE '%@sozu.com%' THEN 'Sozu' ELSE NULL END
    );
  END IF;

  -- Compradores
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'id_persona', cb.id_persona,
      'nombre', COALESCE(pe.nombre_legal, ''),
      'porcentaje', cb.porcentaje_copropiedad)), '[]'::jsonb),
    COALESCE(jsonb_agg(cb.id_persona) FILTER (WHERE cb.id_persona IS NOT NULL), '[]'::jsonb),
    COALESCE(NULLIF(string_agg(NULLIF(pe.nombre_legal, ''), ', '), ''), 'Sin nombre')
    INTO v_compradores, v_comp_ids, v_cliente_nombre
  FROM compradores cb
  LEFT JOIN personas pe ON pe.id = cb.id_persona
  WHERE cb.id_cuenta_cobranza = v_cta_comp AND cb.activo = true;

  -- Acuerdos (con aplicacionesDetalle, ultimoPago, validación, multas)
  SELECT COALESCE(jsonb_agg(row_to_json(t) ORDER BY t.ord_sort, t.orden), '[]'::jsonb)
    INTO v_acuerdos
  FROM (
    SELECT
      a.id, a.orden,
      a.monto::numeric AS monto,
      agg.monto_aplicado AS "montoAplicado",
      a.fecha_pago,
      a.pago_completado,
      COALESCE(cpto.nombre, 'Sin concepto') AS concepto,
      CASE WHEN a.pago_completado THEN 'pagado'
           WHEN a.fecha_pago IS NULL THEN 'pendiente'
           WHEN a.fecha_pago < v_hoy THEN 'vencido'
           WHEN a.fecha_pago <= v_hoy + 30 THEN 'proximo'
           ELSE 'pendiente' END AS estado,
      agg.num_aplicaciones AS "numAplicaciones",
      agg.aplicaciones_detalle AS "aplicacionesDetalle",
      up.up_json AS "ultimoPago",
      agg.pago_ids AS "pagoIds",
      jsonb_build_object('estado', val_agg.estado_agg) AS validacion,
      mu.multas_json AS multas,
      -- helpers de orden (no se serializan porque row_to_json las incluye; se filtran abajo)
      CASE WHEN v_es_mant THEN 0 ELSE a.orden END AS ord_sort
    FROM acuerdos_pago a
    LEFT JOIN conceptos_pago cpto ON cpto.id = a.id_concepto
    LEFT JOIN LATERAL (
      SELECT
        COALESCE(SUM(ap.monto), 0)::numeric AS monto_aplicado,
        COUNT(*)::int AS num_aplicaciones,
        COALESCE(jsonb_agg(DISTINCT ap.id_pago) FILTER (WHERE ap.id_pago IS NOT NULL), '[]'::jsonb) AS pago_ids,
        COALESCE(jsonb_agg(jsonb_build_object(
          'id', ap.id, 'monto', ap.monto, 'id_pago', ap.id_pago,
          'fecha_pago', pg.fecha_pago,
          'metodo', CASE WHEN ap.id_pago IS NULL THEN NULL ELSE COALESCE(mp.nombre, 'Sin método') END,
          'clave_rastreo', pg.clave_rastreo,
          'url_cep', pg.url_cep, 'url_recibo', pg.url_recibo,
          'validacion', v.val
        ) ORDER BY ap.id), '[]'::jsonb) AS aplicaciones_detalle
      FROM aplicaciones_pago ap
      LEFT JOIN pagos pg ON pg.id = ap.id_pago
      LEFT JOIN metodos_pago mp ON mp.id = pg.id_metodos_pago
      LEFT JOIN LATERAL (
        SELECT jsonb_build_object('estado', pv.estado, 'motivo', pv.motivo,
               'monto_esperado', pv.monto_esperado, 'monto_real', pv.monto_real) AS val
        FROM pago_validaciones pv WHERE pv.id_pago = ap.id_pago
        ORDER BY pv.fecha_creacion DESC LIMIT 1
      ) v ON ap.id_pago IS NOT NULL
      WHERE ap.id_acuerdo_pago = a.id AND ap.activo = true AND ap.es_multa = false
    ) agg ON true
    LEFT JOIN LATERAL (
      SELECT
        jsonb_build_object(
          'id', pg.id, 'id_metodos_pago', pg.id_metodos_pago,
          'metodo', COALESCE(mp.nombre, 'Sin método'),
          'monto', pg.monto,
          'clave_rastreo', pg.clave_rastreo, 'fecha_pago', pg.fecha_pago,
          'url_cep', pg.url_cep, 'url_recibo', pg.url_recibo
        ) AS up_json,
        (SELECT jsonb_build_object('estado', pv.estado, 'motivo', pv.motivo,
                'monto_esperado', pv.monto_esperado, 'monto_real', pv.monto_real)
         FROM pago_validaciones pv WHERE pv.id_pago = pg.id
         ORDER BY pv.fecha_creacion DESC LIMIT 1) AS val_json
      FROM aplicaciones_pago ap2
      JOIN pagos pg ON pg.id = ap2.id_pago
      LEFT JOIN metodos_pago mp ON mp.id = pg.id_metodos_pago
      WHERE ap2.id_acuerdo_pago = a.id AND ap2.activo = true AND ap2.es_multa = false AND ap2.id_pago IS NOT NULL
      ORDER BY pg.fecha_pago DESC NULLS LAST
      LIMIT 1
    ) up ON true
    LEFT JOIN LATERAL (
      SELECT CASE
        WHEN COUNT(*) = 0 THEN NULL
        WHEN COUNT(*) FILTER (WHERE s.estado IS DISTINCT FROM 'coincide') = 0 THEN 'coincide'
        WHEN COUNT(*) FILTER (WHERE s.estado = 'error')            > 0 THEN 'error'
        WHEN COUNT(*) FILTER (WHERE s.estado = 'no_coincide')      > 0 THEN 'no_coincide'
        WHEN COUNT(*) FILTER (WHERE s.estado = 'monto_ilegible')   > 0 THEN 'monto_ilegible'
        WHEN COUNT(*) FILTER (WHERE s.estado = 'monto_ausente_db') > 0 THEN 'monto_ausente_db'
        WHEN COUNT(*) FILTER (WHERE s.estado = 'sin_evidencia')    > 0 THEN 'sin_evidencia'
        ELSE NULL   -- quedan solo pagos sin registro de validación → "Sin validar"
      END AS estado_agg
      FROM (
        SELECT (
          SELECT pv.estado FROM pago_validaciones pv
          WHERE pv.id_pago = apv.id_pago
          ORDER BY pv.fecha_creacion DESC LIMIT 1
        ) AS estado
        FROM aplicaciones_pago apv
        WHERE apv.id_acuerdo_pago = a.id AND apv.activo = true
          AND apv.es_multa = false AND apv.id_pago IS NOT NULL
      ) s
    ) val_agg ON true
    LEFT JOIN LATERAL (
      SELECT CASE WHEN COUNT(*) > 0 THEN jsonb_build_object(
        'count', COUNT(*), 'total', COALESCE(SUM(m.monto), 0),
        'items', jsonb_agg(jsonb_build_object(
          'id', m.id, 'id_acuerdo_pago', m.id_acuerdo_pago, 'monto', m.monto,
          'descripcion', m.descripcion, 'id_tipo_multa', m.id_tipo_multa, 'activo', m.activo,
          'tipos_multa', jsonb_build_object('nombre', tm.nombre)))
      ) ELSE NULL END AS multas_json
      FROM multas m LEFT JOIN tipos_multa tm ON tm.id = m.id_tipo_multa
      WHERE m.id_acuerdo_pago = a.id AND m.activo = true
    ) mu ON true
    WHERE a.id_cuenta_cobranza = p_cuenta_id AND a.activo = true
    ORDER BY CASE WHEN v_es_mant THEN a.fecha_pago END DESC, a.orden ASC
  ) t;

  -- Quitar helper ord_sort del json de cada acuerdo
  v_acuerdos := (SELECT COALESCE(jsonb_agg(elem - 'ord_sort'), '[]'::jsonb) FROM jsonb_array_elements(v_acuerdos) elem);

  -- Totales derivados de acuerdos
  SELECT
    COALESCE(SUM((e->>'montoAplicado')::numeric), 0),
    COALESCE(SUM(CASE WHEN (e->>'pago_completado')::boolean = false
                       AND (e->>'fecha_pago') IS NOT NULL
                       AND (e->>'fecha_pago')::date < v_hoy
                  THEN GREATEST(0, (e->>'monto')::numeric - (e->>'montoAplicado')::numeric) END), 0),
    COALESCE(COUNT(*) FILTER (WHERE (e->>'pago_completado')::boolean = false
                       AND (e->>'fecha_pago') IS NOT NULL
                       AND (e->>'fecha_pago')::date < v_hoy), 0)
    INTO v_total_pagado, v_monto_vencido, v_parc_venc
  FROM jsonb_array_elements(v_acuerdos) e;

  SELECT COALESCE(SUM(ap.monto), 0) INTO v_total_aplic_all
  FROM aplicaciones_pago ap
  JOIN acuerdos_pago a ON a.id = ap.id_acuerdo_pago
  WHERE a.id_cuenta_cobranza = p_cuenta_id AND a.activo = true AND ap.activo = true;

  -- Pagos directos de la cuenta (tab Pagos)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', p.id, 'fecha_pago', p.fecha_pago, 'monto', p.monto,
      'clave_rastreo', p.clave_rastreo, 'metodo', COALESCE(mp.nombre, 'Sin método'),
      'id_metodos_pago', p.id_metodos_pago, 'url_cep', p.url_cep, 'url_recibo', p.url_recibo,
      'descripcion', p.descripcion,
      'validacion', (SELECT jsonb_build_object('estado', pv.estado, 'motivo', pv.motivo,
                            'monto_esperado', pv.monto_esperado, 'monto_real', pv.monto_real)
                     FROM pago_validaciones pv WHERE pv.id_pago = p.id ORDER BY pv.fecha_creacion DESC LIMIT 1)
    ) ORDER BY p.fecha_pago DESC), '[]'::jsonb),
    COALESCE(SUM(p.monto) FILTER (WHERE p.id_metodos_pago = 1), 0)
    INTO v_pagos, v_pagado_efectivo
  FROM pagos p LEFT JOIN metodos_pago mp ON mp.id = p.id_metodos_pago
  WHERE p.id_cuenta_cobranza = p_cuenta_id AND p.activo = true;

  -- aplicacionesList (flat, ordenada por fecha_pago NULLS LAST, luego orden)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', ap.id, 'monto', ap.monto, 'id_pago', ap.id_pago,
      'concepto', COALESCE(cpto.nombre, 'Sin concepto'),
      'acuerdoOrden', a.orden, 'fechaLimite', a.fecha_pago,
      'fecha_pago', pg.fecha_pago,
      'id_metodos_pago', pg.id_metodos_pago,
      'metodo', CASE WHEN ap.id_pago IS NULL THEN NULL ELSE COALESCE(mp.nombre, 'Sin método') END,
      'clave_rastreo', pg.clave_rastreo, 'url_cep', pg.url_cep, 'url_recibo', pg.url_recibo,
      'validacion', (SELECT jsonb_build_object('estado', pv.estado, 'motivo', pv.motivo,
                            'monto_esperado', pv.monto_esperado, 'monto_real', pv.monto_real)
                     FROM pago_validaciones pv WHERE pv.id_pago = ap.id_pago ORDER BY pv.fecha_creacion DESC LIMIT 1)
    ) ORDER BY pg.fecha_pago ASC NULLS LAST, a.orden ASC), '[]'::jsonb)
    INTO v_aplic_list
  FROM aplicaciones_pago ap
  JOIN acuerdos_pago a ON a.id = ap.id_acuerdo_pago AND a.activo = true
  LEFT JOIN conceptos_pago cpto ON cpto.id = a.id_concepto
  LEFT JOIN pagos pg ON pg.id = ap.id_pago
  LEFT JOIN metodos_pago mp ON mp.id = pg.id_metodos_pago
  WHERE a.id_cuenta_cobranza = p_cuenta_id AND ap.activo = true AND ap.es_multa = false;

  RETURN jsonb_build_object(
    'clabe_stp', c.clabe_stp,
    'precio_final', v_precio,
    'fecha_compra', c.fecha_compra,
    'valor_uma', c.valor_uma,
    'activo', COALESCE(c.activo, true),
    'clienteNombre', v_cliente_nombre,
    'compradores', v_compradores,
    'compradorPersonaIds', v_comp_ids,
    'agente', v_agente,
    'ofertaId', o.id,
    'ofertaProductoId', o.id_producto,
    'propiedadId', v_prop_id,
    'esquemaNombre', COALESCE(o.esq_nombre, ''),
    'esquemaPct', v_esquema_pct,
    'proyectoNombre', v_proy_nombre,
    'edificioNombre', v_edif_nombre,
    'modeloNombre', v_modelo_nombre,
    'numero_propiedad', v_num_prop,
    'productoNombre', v_producto_nombre,
    'tipo', v_tipo,
    'm2Interiores', v_m2_int,
    'm2Exteriores', v_m2_ext,
    'precioM2', CASE WHEN v_m2_int > 0 THEN v_precio / v_m2_int ELSE NULL END,
    'estatusPropiedad', v_estatus_prop,
    'totalPagado', v_total_pagado,
    'totalAplicacionesAll', v_total_aplic_all,
    'saldoPendiente', v_precio - v_total_pagado,
    'montoVencido', v_monto_vencido,
    'parcialidadesVencidas', v_parc_venc,
    'pagadoEfectivo', v_pagado_efectivo,
    'acuerdos', v_acuerdos,
    'pagos', v_pagos,
    'aplicacionesList', v_aplic_list,
    'esMantenimiento', v_es_mant
  );
END;
$function$;
