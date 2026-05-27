-- Nuevo reporte en Finanzas: Cartera Activa — Proyección de Pagos
-- Muestra cuentas activas con monto atrasado y proyección del siguiente mes.

INSERT INTO public.reportes (id_submenu, nombre, descripcion, query_sql, nombre_archivo, activo, prendido, filtros_configuracion)
VALUES (
  (SELECT id FROM public.submenus WHERE vista_front_end = '/admin/reportes/finanzas' LIMIT 1),
  'Cartera Activa — Proyección de Pagos',
  'Muestra todas las cuentas de cobranza activas con el monto atrasado a la fecha y la proyección de pagos para el siguiente mes.',
  $body$WITH
acuerdos_pendiente AS (
  SELECT
    ap.id, ap.id_cuenta_cobranza, ap.id_concepto,
    ap.fecha_pago, ap.pago_completado, ap.orden, ap.monto,
    ap.monto - COALESCE(SUM(aplp.monto), 0) AS monto_pendiente
  FROM acuerdos_pago ap
  LEFT JOIN aplicaciones_pago aplp ON aplp.id_acuerdo_pago = ap.id AND aplp.activo = true
  WHERE ap.activo = true
  GROUP BY ap.id, ap.id_cuenta_cobranza, ap.id_concepto,
           ap.fecha_pago, ap.pago_completado, ap.orden, ap.monto
),
contraentrega AS (
  SELECT id_cuenta_cobranza,
         SUM(monto) AS pago_contraentrega,
         TO_CHAR(MAX(fecha_pago), 'DD-MM-YYYY') AS fecha_contraentrega
  FROM acuerdos_pago
  WHERE id_concepto = 3 AND activo = true
  GROUP BY id_cuenta_cobranza
),
ultimo_pago_completo AS (
  SELECT id_cuenta_cobranza,
         TO_CHAR(MAX(fecha_pago), 'DD-MM-YYYY') AS fecha_ultimo_pago_completo
  FROM acuerdos_pago
  WHERE pago_completado = true AND activo = true
  GROUP BY id_cuenta_cobranza
),
atrasado AS (
  SELECT id_cuenta_cobranza,
         SUM(monto_pendiente) AS total_atrasado
  FROM acuerdos_pendiente
  WHERE pago_completado = false
    AND fecha_pago <= CURRENT_DATE
    AND id_concepto != 3
  GROUP BY id_cuenta_cobranza
),
siguiente_mes AS (
  SELECT id_cuenta_cobranza,
         SUM(monto_pendiente) AS total_siguiente_mes
  FROM acuerdos_pendiente
  WHERE pago_completado = false
    AND fecha_pago >= DATE_TRUNC('month', CURRENT_DATE + INTERVAL '1 month')
    AND fecha_pago <  DATE_TRUNC('month', CURRENT_DATE + INTERVAL '2 months')
    AND id_concepto != 3
  GROUP BY id_cuenta_cobranza
),
comprador_principal AS (
  SELECT DISTINCT ON (id_cuenta_cobranza)
    id_cuenta_cobranza, id_persona
  FROM compradores
  WHERE activo = true
  ORDER BY id_cuenta_cobranza, porcentaje_copropiedad DESC NULLS LAST
)
SELECT
  cc.id                                                            AS cuenta_cobranza,
  p.nombre_legal                                                   AS nombre_cliente,
  COALESCE(proy_prop.nombre, proy_prod.nombre)                     AS proyecto,
  CASE WHEN o.id_producto IS NOT NULL THEN 'Producto' ELSE 'Propiedad' END AS tipo,
  prop.numero_propiedad                                            AS numero_departamento,
  m.nombre                                                         AS modelo,
  ps.nombre                                                        AS nombre_producto,
  vend.nombre_legal                                                AS vendedor,
  cc.precio_final,
  ct.pago_contraentrega,
  ct.fecha_contraentrega,
  upc.fecha_ultimo_pago_completo,
  COALESCE(atr.total_atrasado, 0)                                  AS atrasado_a_la_fecha,
  COALESCE(sm.total_siguiente_mes, 0)                              AS esperado_sig_mes_sin_atrasados,
  COALESCE(sm.total_siguiente_mes, 0) + COALESCE(atr.total_atrasado, 0) AS esperado_sig_mes_con_atrasados
FROM cuentas_cobranza cc
LEFT JOIN ofertas o              ON o.id   = cc.id_oferta
LEFT JOIN comprador_principal cp ON cp.id_cuenta_cobranza = cc.id
LEFT JOIN personas p             ON p.id   = cp.id_persona
LEFT JOIN propiedades prop       ON prop.id = COALESCE(cc.id_propiedad, o.id_propiedad)
LEFT JOIN edificios_modelos em   ON em.id  = prop.id_edificio_modelo
LEFT JOIN modelos m              ON m.id   = em.id_modelo
LEFT JOIN edificios ed           ON ed.id  = em.id_edificio
LEFT JOIN proyectos proy_prop    ON proy_prop.id = ed.id_proyecto
LEFT JOIN entidades_relacionadas er ON er.id = prop.id_entidad_relacionada_dueno
LEFT JOIN personas vend          ON vend.id = er.id_persona
LEFT JOIN productos_servicios ps ON ps.id  = o.id_producto
LEFT JOIN proyectos proy_prod    ON proy_prod.id = ps.id_proyecto
LEFT JOIN contraentrega ct       ON ct.id_cuenta_cobranza = cc.id
LEFT JOIN ultimo_pago_completo upc ON upc.id_cuenta_cobranza = cc.id
LEFT JOIN atrasado atr           ON atr.id_cuenta_cobranza = cc.id
LEFT JOIN siguiente_mes sm       ON sm.id_cuenta_cobranza = cc.id
WHERE cc.activo = true
{{AND COALESCE(proy_prop.id, proy_prod.id) = :id_proyecto}}
ORDER BY cc.id$body$,
  'cartera_activa_proyeccion',
  true,
  true,
  '[{"nombre":"id_proyecto","label":"Proyecto","tipo":"select","tabla":"proyectos","campo_valor":"id","campo_label":"nombre","requerido":false}]'::jsonb
);
