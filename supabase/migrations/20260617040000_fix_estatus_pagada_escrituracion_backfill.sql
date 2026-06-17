-- Fix de datos histórico: propiedades en Escrituración (7) o Pagada completamente (9)
-- cuya CUENTA PRINCIPAL aún tiene saldo > $0.01.
--
-- Contexto: los triggers de promoción (actualizar_estatus_propiedad_pagada /
-- actualizar_estatus_a_escrituracion) solo PROMUEVEN, nunca DEGRADAN. Registros
-- marcados con la lógica anterior (más laxa) quedaron en 7/9 sin estar liquidados.
--
-- Alcance: SOLO la cuenta principal (ofertas.id_producto IS NULL), coherente con
-- la lógica de los triggers de promoción. Las cuentas hijas (bodega/estacionamiento)
-- NO degradan el estatus de la propiedad. Saldo = precio_final - SUM(pagos activos).
--
-- 5 = Vendido: estatus correcto cuando enganche/contrato están listos pero la
-- propiedad NO está liquidada al 100%.

UPDATE propiedades p
SET id_estatus_disponibilidad = 5,
    fecha_actualizacion = NOW()
WHERE p.id_estatus_disponibilidad IN (7, 9)
  AND EXISTS (
    SELECT 1
    FROM cuentas_cobranza cc
    JOIN ofertas o ON o.id = cc.id_oferta AND o.id_producto IS NULL
    WHERE o.id_propiedad = p.id
      AND cc.activo = true
      AND cc.precio_final - COALESCE(
            (SELECT SUM(pg.monto)
             FROM pagos pg
             WHERE pg.id_cuenta_cobranza = cc.id AND pg.activo = true), 0
          ) > 0.01
  );
