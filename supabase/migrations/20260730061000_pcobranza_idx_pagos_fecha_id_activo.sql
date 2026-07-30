-- Rendimiento · Índice keyset para la paginación de Relación de Pagos
-- Fecha: 2026-07-30
--
-- POR QUÉ
--   El orden por defecto de Relación de Pagos es `fecha_pago DESC, id DESC`. Hoy existe
--   `idx_pagos_fecha_activo (fecha_pago) WHERE activo`, que sirve la primera clave pero no
--   el desempate: el plan medido en prod añade un `Incremental Sort` por cada página, y
--   `fecha_pago` no es única (hasta 95 pagos comparten fecha), así que el desempate importa
--   para que dos páginas consecutivas no se solapen.
--
--   Con el índice compuesto el plan queda en `Index Scan Backward` puro y la página de 15
--   se sirve sin ordenar nada (medido: 0.39 ms de punta a punta sobre 22,544 pagos activos).
--
-- POR QUÉ NO SE CREAN LOS OTROS DOS ÍNDICES QUE PEDÍAN LAS ESPECIFICACIONES
--   · idx_aplicaciones_pago_pago_activo (id_pago, activo): redundante. Ya existe el UNIQUE
--     `uq_apppago_pago_acuerdo (id_pago, id_acuerdo_pago, activo, es_multa)` y el plan real
--     lo usa como `Index Cond: ((id_pago = …) AND (activo = true))`.
--   · idx_pagos_activo_id (id DESC) WHERE activo: aporta poco. De 22,578 pagos solo 34 están
--     inactivos, así que `pagos_pkey` ya sirve el keyset de Validación de Pagos —es el índice
--     que aparece en el plan medido para esa RPC.
--
--   Se dejan fuera a propósito: un índice de más se paga en cada INSERT/UPDATE de `pagos` y
--   `aplicaciones_pago`, que son tablas de escritura constante.
--
-- No se usa CREATE INDEX CONCURRENTLY: `supabase db push` corre cada migración dentro de una
-- transacción y CONCURRENTLY no es transaccionable. Con 22.5k filas el lock es de milisegundos.
--
-- Idempotente (IF NOT EXISTS) y self-verifying.
-- Sin BEGIN/COMMIT (el CI envuelve en transacción).

CREATE INDEX IF NOT EXISTS idx_pagos_fecha_id_activo
  ON public.pagos (fecha_pago DESC, id DESC)
  WHERE activo = true;

COMMENT ON INDEX public.idx_pagos_fecha_id_activo IS
  'Orden por defecto de Relación de Pagos (fecha_pago DESC, id DESC) sobre pagos activos. '
  'El desempate por id es lo que evita que dos páginas consecutivas se solapen cuando varios '
  'pagos comparten fecha.';

DO $$
BEGIN
  IF to_regclass('public.idx_pagos_fecha_id_activo') IS NULL THEN
    RAISE EXCEPTION 'No se creó idx_pagos_fecha_id_activo';
  END IF;
  RAISE NOTICE 'idx_pagos_fecha_id_activo OK';
END $$;
