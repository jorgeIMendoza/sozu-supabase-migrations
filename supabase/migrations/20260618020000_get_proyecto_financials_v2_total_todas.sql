-- get_proyecto_financials v2: agrega total_pagado_todas_cuentas.
-- Fecha: 2026-06-18
--
-- El top card "Total pagado" (modo proyecto completo) debe reflejar el universo
-- completo (departamentos + bodegas/estacionamientos separados), no solo cuentas
-- principales. v1 solo exponía total_pagado de cuentas principales (correcto para
-- precio_final/saldo_pendiente, que excluyen accesorios).
--
-- Cambio único vs v1: se agrega el campo total_pagado_todas_cuentas numeric al final
-- del RETURNS TABLE = SUM(aplicaciones_pago.monto, no multa) de TODAS las cuentas.
-- Los 11 campos existentes conservan nombre, tipo y posición. total_pagado mantiene
-- su semántica (solo principales).
--
-- DROP + CREATE (no OR REPLACE): cambiar RETURNS TABLE no se permite con OR REPLACE.
-- En transacción. Verificado en dev: v1 existe con 11 OUT, sin total_pagado_todas_cuentas.

BEGIN;

DROP FUNCTION IF EXISTS public.get_proyecto_financials(bigint);

CREATE FUNCTION public.get_proyecto_financials(p_proyecto_id bigint)
RETURNS TABLE (
  total_unidades bigint,
  total_cuentas bigint,
  total_pagos bigint,
  total_con_comprobante bigint,
  precio_final numeric,
  total_pagado numeric,
  saldo_pendiente numeric,
  efectivo_pagado numeric,
  limite_efectivo numeric,
  efectivo_aun_permitido numeric,
  valor_escrituracion numeric,
  total_pagado_todas_cuentas numeric   -- NUEVO (al final): aplicaciones de TODAS las cuentas
)
LANGUAGE sql
STABLE
AS $$
WITH edificios_proyecto AS (
  SELECT e.id
  FROM public.edificios e
  WHERE e.id_proyecto = p_proyecto_id
    AND COALESCE(e.activo, true) = true
),
edificios_modelos_proyecto AS (
  SELECT em.id
  FROM public.edificios_modelos em
  WHERE em.id_edificio IN (SELECT id FROM edificios_proyecto)
    AND COALESCE(em.activo, true) = true
),
propiedades_proyecto AS (
  SELECT p.id
  FROM public.propiedades p
  WHERE p.id_edificio_modelo IN (SELECT id FROM edificios_modelos_proyecto)
    AND COALESCE(p.activo, true) = true
),
bodegas_accesorias AS (
  SELECT DISTINCT b.id_producto
  FROM public.bodegas b
  WHERE b.id_propiedad IN (SELECT id FROM propiedades_proyecto)
    AND COALESCE(b.activo, true)       = true
    AND COALESCE(b.es_incluido, false) = false
    AND b.id_producto IS NOT NULL
),
estacionamientos_accesorios AS (
  SELECT DISTINCT es.id_producto
  FROM public.estacionamientos es
  WHERE es.id_propiedad IN (SELECT id FROM propiedades_proyecto)
    AND COALESCE(es.activo, true)       = true
    AND COALESCE(es.es_incluido, false) = false
    AND es.id_producto IS NOT NULL
),
ofertas_accesorias AS (
  SELECT DISTINCT o.id
  FROM public.ofertas o
  WHERE COALESCE(o.activo, true) = true
    AND (
      o.id_producto IN (SELECT id_producto FROM bodegas_accesorias)
      OR o.id_producto IN (SELECT id_producto FROM estacionamientos_accesorios)
    )
),
cuentas_todas AS (
  SELECT
    cc.id,
    cc.id_propiedad,
    cc.id_oferta,
    COALESCE(cc.precio_final, 0)::numeric AS precio_final,
    COALESCE(cc.valor_uma, 0)::numeric AS valor_uma,
    CASE
      WHEN cc.id_oferta IN (SELECT id FROM ofertas_accesorias)
      THEN true
      ELSE false
    END AS es_accesoria
  FROM public.cuentas_cobranza cc
  WHERE cc.id_propiedad IN (SELECT id FROM propiedades_proyecto)
    AND COALESCE(cc.activo, true) = true
),
cuentas_principales AS (
  SELECT *
  FROM cuentas_todas
  WHERE es_accesoria = false
),
acuerdos_principales AS (
  SELECT ap.id, ap.id_cuenta_cobranza
  FROM public.acuerdos_pago ap
  WHERE ap.id_cuenta_cobranza IN (SELECT id FROM cuentas_principales)
    AND COALESCE(ap.activo, true) = true
),
pagado_principal AS (
  SELECT
    COALESCE(SUM(COALESCE(app.monto, 0)), 0)::numeric AS total_pagado
  FROM public.aplicaciones_pago app
  WHERE app.id_acuerdo_pago IN (SELECT id FROM acuerdos_principales)
    AND COALESCE(app.activo,  true)  = true
    AND COALESCE(app.es_multa, false) = false
),
-- NUEVO: acuerdos de TODAS las cuentas (principal + accesorios)
acuerdos_todas AS (
  SELECT ap.id
  FROM public.acuerdos_pago ap
  WHERE ap.id_cuenta_cobranza IN (SELECT id FROM cuentas_todas)
    AND COALESCE(ap.activo, true) = true
),
-- NUEVO: total pagado de TODAS las cuentas
pagado_todas AS (
  SELECT
    COALESCE(SUM(COALESCE(app.monto, 0)), 0)::numeric AS total_pagado_todas
  FROM public.aplicaciones_pago app
  WHERE app.id_acuerdo_pago IN (SELECT id FROM acuerdos_todas)
    AND COALESCE(app.activo,  true)  = true
    AND COALESCE(app.es_multa, false) = false
),
pagos_todas AS (
  SELECT
    p.id,
    p.id_cuenta_cobranza,
    COALESCE(p.monto, 0)::numeric AS monto,
    p.id_metodos_pago,
    p.url_cep,
    p.url_recibo
  FROM public.pagos p
  WHERE p.id_cuenta_cobranza IN (SELECT id FROM cuentas_todas)
    AND COALESCE(p.activo, true) = true
),
efectivo AS (
  SELECT COALESCE(SUM(monto), 0)::numeric AS efectivo_pagado
  FROM pagos_todas
  WHERE id_metodos_pago = 1
),
resumen AS (
  SELECT
    (SELECT COUNT(*) FROM propiedades_proyecto)::bigint AS total_unidades,
    (SELECT COUNT(*) FROM cuentas_todas)::bigint AS total_cuentas,
    (SELECT COUNT(*) FROM pagos_todas)::bigint AS total_pagos,
    (
      SELECT COUNT(*)
      FROM pagos_todas
      WHERE url_cep IS NOT NULL OR url_recibo IS NOT NULL
    )::bigint AS total_con_comprobante,
    COALESCE((SELECT SUM(precio_final) FROM cuentas_principales), 0)::numeric AS precio_final,
    COALESCE((SELECT total_pagado FROM pagado_principal), 0)::numeric AS total_pagado,
    COALESCE((SELECT efectivo_pagado FROM efectivo), 0)::numeric AS efectivo_pagado,
    COALESCE((SELECT SUM(valor_uma * 8025) FROM cuentas_principales), 0)::numeric AS limite_efectivo,
    COALESCE((SELECT SUM(precio_final) FROM cuentas_todas), 0)::numeric AS valor_escrituracion,
    COALESCE((SELECT total_pagado_todas FROM pagado_todas), 0)::numeric AS total_pagado_todas_cuentas
)
SELECT
  total_unidades,
  total_cuentas,
  total_pagos,
  total_con_comprobante,
  precio_final,
  total_pagado,
  GREATEST(precio_final - total_pagado, 0)::numeric AS saldo_pendiente,
  efectivo_pagado,
  limite_efectivo,
  GREATEST(limite_efectivo - efectivo_pagado, 0)::numeric AS efectivo_aun_permitido,
  valor_escrituracion,
  total_pagado_todas_cuentas
FROM resumen;
$$;

COMMENT ON FUNCTION public.get_proyecto_financials(bigint) IS
  'v2 — KPIs financieros agregados del proyecto. Agrega total_pagado_todas_cuentas '
  '= SUM(aplicaciones_pago) de todas las cuentas (principal + bodegas + estacionamientos). '
  'total_pagado conserva su semántica original (solo principales), consistente con '
  'precio_final y saldo_pendiente. No reemplaza get_relacion_pagos.';

COMMIT;

NOTIFY pgrst, 'reload schema';
