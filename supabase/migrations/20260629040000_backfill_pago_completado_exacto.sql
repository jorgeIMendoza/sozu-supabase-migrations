-- P02 (OPCIONAL): backfill de pago_completado para acuerdos ya pagados pero stale.
-- Fecha: 2026-06-29
--
-- El trigger corrige de aquí en adelante; este backfill limpia los stale actuales SIN
-- tocar nada conciliado a mano: solo marca false -> true los genuinamente pagados
-- (SUM no-multa >= monto), excluyendo conceptos 7/9 y cuentas inactivas. NO revierte
-- (no hace true -> false). Idempotente: re-ejecutar no afecta más filas.
-- OPCIONAL: si no se desea limpiar el histórico, omitir esta migración (el trigger
-- recalculará cada cuenta cuando se mueva un abono).

UPDATE acuerdos_pago ap
SET pago_completado = true
FROM cuentas_cobranza cc
WHERE cc.id = ap.id_cuenta_cobranza
  AND cc.activo = true
  AND ap.activo = true
  AND ap.pago_completado = false
  AND ap.id_concepto NOT IN (7, 9)
  AND COALESCE((SELECT SUM(a.monto) FROM aplicaciones_pago a
        WHERE a.id_acuerdo_pago = ap.id AND a.activo AND NOT a.es_multa), 0) >= ap.monto;
