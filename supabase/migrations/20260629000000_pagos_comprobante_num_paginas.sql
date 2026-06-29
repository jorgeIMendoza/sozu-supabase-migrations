-- PLD: agregar comprobante_num_paginas a public.pagos.
-- Fecha: 2026-06-27 (generada 2026-06-29)
--
-- Almacena el número de páginas del comprobante (url_recibo), calculado con pdfjs
-- al cargar el archivo. Permite que la validación PLD lea desde BD sin depender de
-- acceso al archivo en Storage ni CORS. Aplica a pagos de efectivo (id_metodos_pago=1)
-- sin clave_rastreo (sin trazabilidad STP).
--   NULL  -> no analizado (datos históricos o archivo no-PDF)
--   1     -> una página: insuficiente para PLD
--   >= 2  -> válido para PLD (ticket + estado de cuenta)
-- Idempotente. Verificado en dev: columna/constraint/índice no existen;
-- columnas referenciadas (id_metodos_pago, clave_rastreo, url_recibo, activo,
-- id_cuenta_cobranza) existen. Datos históricos quedan en NULL;
-- validacion_documental_efectivo se mantiene intacto.

-- 1. Columna
ALTER TABLE public.pagos
  ADD COLUMN IF NOT EXISTS comprobante_num_paginas SMALLINT DEFAULT NULL;

-- 2. Comentario en catálogo
COMMENT ON COLUMN public.pagos.comprobante_num_paginas IS
  'Número de páginas del comprobante adjunto (url_recibo), calculado con pdfjs '
  'al momento de la carga del archivo. NULL = no analizado. >= 2 = válido para '
  'PLD (efectivo sin clave_rastreo).';

-- 3. Restricción de integridad (>= 1 si no es NULL).
--    ADD CONSTRAINT no soporta IF NOT EXISTS -> guard por pg_constraint.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_pagos_comprobante_num_paginas'
  ) THEN
    ALTER TABLE public.pagos
      ADD CONSTRAINT chk_pagos_comprobante_num_paginas
      CHECK (comprobante_num_paginas IS NULL OR comprobante_num_paginas >= 1);
  END IF;
END $$;

-- 4. Índice parcial: cola de validación PLD (efectivo sin clave_rastreo, con
--    comprobante aún no analizado).
CREATE INDEX IF NOT EXISTS idx_pagos_pld_pendiente
  ON public.pagos (id_cuenta_cobranza)
  WHERE id_metodos_pago = 1
    AND clave_rastreo IS NULL
    AND url_recibo IS NOT NULL
    AND comprobante_num_paginas IS NULL
    AND activo = true;
