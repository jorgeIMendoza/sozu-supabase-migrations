-- Saneo: propagar url_factura_comision + bajar draft en CC-001769 y CCP-001773
-- Fecha: 2026-07-09
--
-- El botón "Ejecutar pago" (Pagos a externos) depende de es_pagada_comision_venta, que
-- solo se marca al ejecutar el cobro en "Cobros por gestionar", bandeja que exige
-- es_draft_factura_comision = false y url_factura_comision NOT NULL. El flujo de subir la
-- factura de comisión externa no sincronizaba esos campos (ya corregido en el front:
-- facturaComisionExterna.ts / ComisionesExternas.tsx / DocumentsTab.tsx).
--
-- Estas cuentas tienen la factura del externo solo en documentos (tipo 46). Se propaga la
-- URL a cuentas_cobranza y se baja el flag draft. CC-001770 ya se saneó por separado.
--
-- Idempotente: guard url_factura_comision IS NULL. Datos prod-específicos (1769/1773 no
-- existen en dev) → no-op en dev, efectivo en prod. Sin BEGIN/COMMIT (CI/CD en tx).

UPDATE public.cuentas_cobranza cc
SET url_factura_comision = d.url,
    es_draft_factura_comision = false,
    fecha_actualizacion = now()
FROM (
  SELECT DISTINCT ON (id_cuenta_cobranza) id_cuenta_cobranza, url
  FROM public.documentos
  WHERE id_cuenta_cobranza IN (1769, 1773)
    AND id_tipo_documento = 46   -- Factura de comisión externa
    AND activo = true
  ORDER BY id_cuenta_cobranza, id DESC
) d
WHERE cc.id = d.id_cuenta_cobranza
  AND cc.url_factura_comision IS NULL;
