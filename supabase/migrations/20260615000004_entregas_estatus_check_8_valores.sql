-- Ampliar el CHECK de entregas.estatus a 8 valores (flujo PRE-ENTREGA).
-- Fecha: 2026-06-15
--
-- El constraint actual sólo permite 5 valores (PROGRAMADA, EN_PROCESO, ENTREGADA,
-- CON_OBSERVACIONES, REPROGRAMADA). El módulo de Entregas usa 3 adicionales
-- (PENDIENTE_PRE_ENTREGA, PRE_ENTREGA_EN_PROCESO, LISTO) → handleIniciarPreEntrega
-- falla el INSERT con "violates check constraint entregas_estatus_check".
--
-- Es una expansión pura: todos los valores previos siguen válidos, ninguna fila
-- existente se invalida. DROP IF EXISTS + ADD para idempotencia.
-- Nota: ADD CONSTRAINT toma ACCESS EXCLUSIVE LOCK y escanea las filas; en prod
-- ejecutar en ventana de baja actividad (la tabla entregas es pequeña).

ALTER TABLE public.entregas
  DROP CONSTRAINT IF EXISTS entregas_estatus_check;

ALTER TABLE public.entregas
  ADD CONSTRAINT entregas_estatus_check
  CHECK (estatus = ANY (ARRAY[
    'PENDIENTE_PRE_ENTREGA'::text,
    'PRE_ENTREGA_EN_PROCESO'::text,
    'LISTO'::text,
    'PROGRAMADA'::text,
    'EN_PROCESO'::text,
    'ENTREGADA'::text,
    'CON_OBSERVACIONES'::text,
    'REPROGRAMADA'::text
  ]));
