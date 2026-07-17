-- Portal Jurídico Fase 1 · Índice único parcial: una asignación ACTIVA por demanda
-- Fecha: 2026-07-17
--
-- Formaliza DDL-4A (Ejecuciones/ejecutar.md). Garantiza a nivel de BD que una demanda
-- no tenga más de una asignación con estatus='ACTIVA' a la vez. Sin esto, la regla solo
-- vive en código de app y se puede violar por concurrencia o acceso directo. Índice
-- parcial: solo restringe filas WHERE estatus='ACTIVA'; CERRADA y REASIGNADA quedan libres.
--
-- Diferencia vs el .md: se quita CONCURRENTLY. CONCURRENTLY no puede correr dentro de una
-- transacción y CI/CD envuelve cada migración en tx. La tabla está vacía en Preview
-- (confirmado 2026-07-17), así que un CREATE INDEX normal es instantáneo y sin bloqueo
-- relevante. IF NOT EXISTS lo hace idempotente.
--
-- Precondición: no deben existir duplicados ACTIVA por id_demanda; si los hubiera, el
-- CREATE UNIQUE INDEX falla (atómico, no crea nada) — comportamiento correcto: surface el
-- conflicto para resolverlo antes. Sin BEGIN/COMMIT. Las validaciones V-*/POST-*/UAT del
-- .md se omiten (SELECTs y pruebas manuales).

CREATE UNIQUE INDEX IF NOT EXISTS uidx_asignaciones_juridico_demanda_activa
  ON public.asignaciones_juridico (id_demanda)
  WHERE (estatus = 'ACTIVA');
