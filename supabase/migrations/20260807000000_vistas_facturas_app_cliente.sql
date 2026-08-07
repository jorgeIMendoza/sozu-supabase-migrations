-- Portal del Cliente (app Flutter) — vistas de facturas
-- Fecha: 2026-08-07
--
-- ─── Qué resuelven ────────────────────────────────────────────────────────────
-- Las facturas del cliente están completas en la base; lo que está mal es el armado
-- en las Edge Functions. Dos defectos, los dos de forma, no de dato:
--
--   1. `facturas_mantenimientos` guarda el PDF y el XML en FILAS SEPARADAS con el mismo
--      `id_pago` (verificado en prod: 92 filas = 46 pagos x 2). Quien emite una entrada
--      por fila duplica la lista y cada copia sale con un solo archivo.
--   2. La cuenta de mantenimiento no tiene unidad: `id_propiedad` e `id_oferta` en NULL.
--      La unidad cuelga de `id_cuenta_cobranza_padre`, y sin seguir ese enlace la
--      factura sale sin unidad (y en Pagos aparece una «propiedad» sin nombre).
--
-- ─── Los tres objetos y de quién es cada uno ──────────────────────────────────
--   vw_unidad_por_cuenta      GENÉRICA. Unidad resuelta por cuenta de cobranza
--                             (directa -> oferta -> cuenta padre). La consumen tanto
--                             `cliente-documentos` como `cliente-pagos`: el bug de la
--                             unidad se arregla en un solo lugar.
--   vw_evidencia_facturas     GENÉRICA. Los tres tipos —compra, mantenimiento y
--                             comisión— una fila por FACTURA con PDF y XML en columnas.
--                             Para auditoría/admin.
--   vw_app_cliente_facturas   CONTRATO DE LA APP FLUTTER. Solo lo que el cliente ve:
--                             compra y mantenimiento. La comisión de venta es dinero de
--                             Sozu, no del cliente, y queda deliberadamente fuera del
--                             objeto que toca un endpoint de cliente.
--
-- Nombres: prefijo `vw_` (en esta base `v_` está contaminado: cinco TABLAS se llaman
-- `v_esquema_id`, `v_id_propiedad`, etc.) y namespace `app_cliente` para lo exclusivo de
-- la app, igual que la tabla `app_cliente_config`. `cliente` a secas es ambiguo: el
-- portal WEB de clientes también se llamaba así y está muerto.
--
-- ─── Verificado read-only contra prod (tzmhgfjmddkfyffkkmto, 2026-08-06) ──────
--   * Jerarquía de cuentas de UN solo nivel: 0 cuentas con abuelo → basta un self-join.
--   * `vw_unidad_por_cuenta`: 1797 cuentas, 0 sin propiedad, 0 sin etiqueta;
--     305 son hijas y las 305 resuelven unidad por la padre. Las hijas 1594/1614/1630
--     (el caso roto de `cliente-pagos`) resuelven Margot 1020/1007/1005.
--   * `vw_evidencia_facturas`:
--       compra        267 facturas / 245 unidades (532 archivos)
--       mantenimiento  46 facturas /  28 unidades (todas con PDF y XML)
--       comisión       20 facturas /  18 unidades
--     0 filas sin unidad en los tres tipos.
--   * Margot 814 -> cuenta raíz 301, cuenta hija 1413, 5 facturas de mantenimiento,
--     3 de ellas en julio (01 y 02 por $652.50, 06 por $1,305): la vista las deja como
--     5 facturas distintas, no agrupa por mes.
--   * DOS facturas de compra quedan sin XML —cuentas 301 y 193, que tienen un PDF de
--     más—. Es un hueco de dato preexistente, no del emparejado: sale como factura con
--     PDF y sin XML, que es la verdad.
--   * `facturas_mantenimientos.monto` = `pagos.monto` en las 92 filas.
--
-- ─── SEGURIDAD: las vistas NO son la capa de aislamiento ──────────────────────
-- `security_invoker = true` hereda las RLS de las tablas base, y ésas NO aíslan por
-- cliente: `cuentas_cobranza` y `documentos` usan `current_socio_bancario_id() IS NULL`
-- (verdadero para un cliente normal → ve todo) y `facturas_mantenimientos` usa
-- `auth.uid() IS NOT NULL` (cualquiera logueado ve todo). Si la app apuntara a estas
-- vistas con su propio JWT, cada cliente vería facturas de los demás.
--
-- Por eso: se REVOCA `anon` y `authenticated`. El dato al cliente sale por Edge Function
-- con `service_role` (rolbypassrls = true), que resuelve las cuentas de la persona
-- logueada vía `compradores` y filtra por ellas. Las vistas no exponen PII: ni persona,
-- ni nombre legal, ni RFC.
--
-- TRAMPA AL RECREAR: los privilegios por defecto de `public` otorgan `arwdDxtm` a `anon`
-- y `authenticated` en CADA relación nueva. Este archivo hace DROP + CREATE, así que el
-- bloque de REVOKE del final es OBLIGATORIO en toda recreación: sin él la vista queda
-- legible por cualquier usuario logueado, en silencio.
--
-- Idempotente (DROP IF EXISTS + CREATE) y sin BEGIN/COMMIT (el CI envuelve en tx).
-- El DROP va de la que depende hacia la base, sin CASCADE.

DROP VIEW IF EXISTS public.vw_app_cliente_facturas;
DROP VIEW IF EXISTS public.vw_evidencia_facturas;
DROP VIEW IF EXISTS public.vw_unidad_por_cuenta;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) Unidad de cada cuenta de cobranza  (genérica)
--    Resolución en cascada: id_propiedad directa -> propiedad de la oferta ->
--    lo que resuelva la cuenta PADRE (las cuentas de mantenimiento no traen ninguna
--    de las dos). Un solo nivel de padre: verificado, no hay abuelos.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE VIEW public.vw_unidad_por_cuenta
WITH (security_invoker = true) AS
WITH resuelta AS (
  SELECT cc.id                                     AS id_cuenta,
         cc.id_cuenta_cobranza_padre,
         cc.activo,
         COALESCE(cc.id_propiedad, o.id_propiedad) AS id_propiedad_directa
  FROM public.cuentas_cobranza cc
  LEFT JOIN public.ofertas o ON o.id = cc.id_oferta
)
SELECT r.id_cuenta,
       -- La cuenta que representa la UNIDAD: la padre si es hija, ella misma si no.
       -- El CFDI de compra cuelga de la padre y el pago de mantenimiento de la hija;
       -- sin unificar aquí, la misma unidad sale dos veces en la lista del cliente.
       COALESCE(r.id_cuenta_cobranza_padre, r.id_cuenta)         AS id_cuenta_raiz,
       r.id_cuenta_cobranza_padre,
       r.activo                                                  AS cuenta_activa,
       COALESCE(r.id_propiedad_directa, pa.id_propiedad_directa) AS id_propiedad,
       pr.numero_propiedad,
       py.id                                                     AS id_proyecto,
       py.nombre                                                 AS proyecto,
       CASE
         WHEN py.nombre IS NOT NULL AND pr.numero_propiedad IS NOT NULL
           THEN py.nombre || ' ' || pr.numero_propiedad
       END                                                       AS unidad
FROM resuelta r
LEFT JOIN resuelta pa ON pa.id_cuenta = r.id_cuenta_cobranza_padre
LEFT JOIN public.propiedades pr
       ON pr.id = COALESCE(r.id_propiedad_directa, pa.id_propiedad_directa)
LEFT JOIN public.edificios_modelos em ON em.id = pr.id_edificio_modelo
LEFT JOIN public.edificios e          ON e.id  = em.id_edificio
LEFT JOIN public.proyectos py         ON py.id = e.id_proyecto;

COMMENT ON VIEW public.vw_unidad_por_cuenta IS
  'Genérica. Unidad (proyecto + numero_propiedad) resuelta por cuenta de cobranza: '
  'directa, por oferta o por cuenta padre. `id_cuenta_raiz` es la cuenta que representa '
  'la unidad. Solo lectura, sin PII. NO aisla por cliente: consumir con service_role '
  'filtrando por las cuentas de la persona logueada.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) Evidencia de facturas  (genérica) — UNA FILA POR FACTURA, PDF y XML en columnas
--    tipo = compra | mantenimiento | comision
-- ─────────────────────────────────────────────────────────────────────────────
CREATE VIEW public.vw_evidencia_facturas
WITH (security_invoker = true) AS
WITH compra_archivos AS (
  -- `documentos` guarda XML (tipo 21) y PDF (tipo 22) como filas independientes, sin
  -- folio (`numero` viene NULL en las 532) y con la misma `fecha_creacion`. Se emparejan
  -- por posición dentro de la cuenta: los ids se generan consecutivos por par, así que el
  -- n-ésimo PDF corresponde al n-ésimo XML. FULL JOIN para no perder los desbalanceados.
  SELECT d.id_cuenta_cobranza::bigint AS id_cuenta_origen,
         d.id_tipo_documento,
         d.url,
         d.fecha_creacion,
         row_number() OVER (PARTITION BY d.id_cuenta_cobranza, d.id_tipo_documento
                            ORDER BY d.id) AS rn
  FROM public.documentos d
  WHERE d.activo
    AND d.es_draft = false
    AND d.id_tipo_documento IN (21, 22)
    AND d.id_cuenta_cobranza IS NOT NULL
),
compra AS (
  SELECT COALESCE(pdf.id_cuenta_origen, xml.id_cuenta_origen)   AS id_cuenta_origen,
         COALESCE(pdf.fecha_creacion, xml.fecha_creacion)::date AS fecha,
         pdf.url                                                AS url_pdf,
         xml.url                                                AS url_xml
  FROM      (SELECT * FROM compra_archivos WHERE id_tipo_documento = 22) pdf
  FULL JOIN (SELECT * FROM compra_archivos WHERE id_tipo_documento = 21) xml
         ON xml.id_cuenta_origen = pdf.id_cuenta_origen
        AND xml.rn               = pdf.rn
),
mantenimiento AS (
  -- Colapsa las filas PDF/XML del mismo pago: una factura por `id_pago`. NO se agrupa
  -- por mes: puede haber varias en el mismo mes (Margot 814 tiene 3 en julio) y todas
  -- son comprobantes fiscales del cliente; ocultar una es ocultarle un CFDI.
  SELECT p.id                               AS id_pago,
         p.id_cuenta_cobranza::bigint        AS id_cuenta_origen,
         p.fecha_pago                        AS fecha,
         p.monto                             AS monto,
         max(nullif(fm.url_factura_pdf, '')) AS url_pdf,
         max(nullif(fm.url_factura_xml, '')) AS url_xml
  FROM public.facturas_mantenimientos fm
  JOIN public.pagos p ON p.id = fm.id_pago
  WHERE p.activo
    AND (nullif(fm.url_factura_pdf, '') IS NOT NULL
      OR nullif(fm.url_factura_xml, '') IS NOT NULL)
  GROUP BY p.id, p.id_cuenta_cobranza, p.fecha_pago, p.monto
),
comision AS (
  -- Factura de la comisión de venta: vive en columnas de la propia cuenta. Se excluyen
  -- los drafts (en prod: 21 cuentas con PDF, de las cuales 1 es draft).
  SELECT cc.id                                  AS id_cuenta_origen,
         cc.fecha_pago_comision                  AS fecha,
         cc.monto_comision_pagado                AS monto,
         nullif(cc.url_factura_comision, '')     AS url_pdf,
         nullif(cc.url_factura_xml_comision, '') AS url_xml
  FROM public.cuentas_cobranza cc
  WHERE cc.activo
    AND COALESCE(cc.es_draft_factura_comision, false) = false
    AND (nullif(cc.url_factura_comision, '')     IS NOT NULL
      OR nullif(cc.url_factura_xml_comision, '') IS NOT NULL)
),
evidencia AS (
  SELECT 'compra'::text AS tipo, id_cuenta_origen, NULL::integer AS id_pago,
         fecha, NULL::numeric AS monto, url_pdf, url_xml
  FROM compra
  UNION ALL
  SELECT 'mantenimiento', id_cuenta_origen, id_pago, fecha, monto, url_pdf, url_xml
  FROM mantenimiento
  UNION ALL
  SELECT 'comision', id_cuenta_origen, NULL::integer, fecha, monto, url_pdf, url_xml
  FROM comision
)
SELECT ev.tipo,
       -- Para filtrar y agrupar en el consumidor: la cuenta que representa la unidad.
       u.id_cuenta_raiz     AS id_cuenta,
       ev.id_cuenta_origen,          -- la cuenta donde vive el archivo (hija en mantenimiento)
       ev.id_pago,
       u.id_propiedad,
       u.id_proyecto,
       u.proyecto,
       u.numero_propiedad,
       u.unidad,
       ev.fecha,
       ev.monto,
       ev.url_pdf,
       ev.url_xml
FROM evidencia ev
LEFT JOIN public.vw_unidad_por_cuenta u ON u.id_cuenta = ev.id_cuenta_origen;

COMMENT ON VIEW public.vw_evidencia_facturas IS
  'Genérica (auditoría/admin). Una fila por FACTURA —no por archivo— con PDF y XML en '
  'columnas: tipo = compra | mantenimiento | comision. `id_cuenta` es la cuenta raiz '
  '(padre) para que compra y mantenimiento de la misma unidad agrupen igual. Solo '
  'lectura, sin PII. NO aisla por cliente. Para la app usar vw_app_cliente_facturas.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) Contrato de la app Flutter — solo las facturas que el cliente ve
--    Sin comisión: es dinero de Sozu, no del cliente.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE VIEW public.vw_app_cliente_facturas
WITH (security_invoker = true) AS
SELECT ef.tipo,                       -- 'compra' | 'mantenimiento'
       ef.id_cuenta,                  -- SIEMPRE la cuenta padre: agrupa igual en ambos tipos
       ef.id_cuenta_origen,
       ef.id_pago,                    -- NULL en compra; una factura por pago en mantenimiento
       ef.id_propiedad,
       ef.unidad AS propiedad,        -- p.ej. 'Margot 814'
       ef.fecha,
       ef.monto,                      -- NULL en compra
       ef.url_pdf,
       ef.url_xml
FROM public.vw_evidencia_facturas ef
WHERE ef.tipo IN ('compra', 'mantenimiento');

COMMENT ON VIEW public.vw_app_cliente_facturas IS
  'Contrato de la app Flutter de clientes: facturas de compra y de mantenimiento, una '
  'fila por factura, con la unidad ya resuelta en `propiedad`. Excluye la comisión de '
  'venta a propósito. Solo lectura, sin PII. NO aisla por cliente: consumir desde Edge '
  'Function con service_role, filtrando por las cuentas de la persona logueada.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) Privilegios — OBLIGATORIO en toda recreación (ver «TRAMPA AL RECREAR» arriba)
-- ─────────────────────────────────────────────────────────────────────────────
REVOKE ALL PRIVILEGES ON TABLE public.vw_unidad_por_cuenta     FROM anon, authenticated;
REVOKE ALL PRIVILEGES ON TABLE public.vw_evidencia_facturas    FROM anon, authenticated;
REVOKE ALL PRIVILEGES ON TABLE public.vw_app_cliente_facturas  FROM anon, authenticated;

GRANT SELECT ON TABLE public.vw_unidad_por_cuenta     TO service_role;
GRANT SELECT ON TABLE public.vw_evidencia_facturas    TO service_role;
GRANT SELECT ON TABLE public.vw_app_cliente_facturas  TO service_role;

-- `georgia_mcp_ro` (lectura por MCP, solo para diagnóstico) existe en prod pero NO en
-- dev: un GRANT incondicional aborta el `supabase db push` de deploy-dev con
-- «role "georgia_mcp_ro" does not exist». Mismo guard que 20260723000000.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'georgia_mcp_ro') THEN
    RAISE NOTICE 'Rol georgia_mcp_ro no existe; se omite el GRANT de lectura.';
    RETURN;
  END IF;

  GRANT SELECT ON TABLE public.vw_unidad_por_cuenta    TO georgia_mcp_ro;
  GRANT SELECT ON TABLE public.vw_evidencia_facturas   TO georgia_mcp_ro;
  GRANT SELECT ON TABLE public.vw_app_cliente_facturas TO georgia_mcp_ro;
END $$;

-- Rollback:
--   DROP VIEW IF EXISTS public.vw_app_cliente_facturas;
--   DROP VIEW IF EXISTS public.vw_evidencia_facturas;
--   DROP VIEW IF EXISTS public.vw_unidad_por_cuenta;
-- Si se vuelve a aplicar, NO omitir el bloque 4: sin el REVOKE las vistas quedan
-- legibles por cualquier usuario logueado.
