-- notarios.trabaja_con_sozu: notaría habilitada para asignaciones operativas SOZU.
-- Fecha: 2026-06-24
--
-- activo = no eliminada del catálogo; trabaja_con_sozu = disponible en el selector
-- operativo. Pre-activa las 13 notarías con historial real de cuentas asignadas.
-- Idempotente (ADD COLUMN IF NOT EXISTS + UPDATE por ids). Verificado en dev: columna
-- no existía; 309 notarios; los 13 ids existen.

ALTER TABLE public.notarios
  ADD COLUMN IF NOT EXISTS trabaja_con_sozu BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.notarios.trabaja_con_sozu IS
  'Notaría habilitada para nuevas asignaciones operativas SOZU. activo = no eliminada del catálogo; trabaja_con_sozu = disponible en selector operativo.';

-- Pre-activar notarías con historial real de cuentas asignadas (13).
UPDATE public.notarios
SET    trabaja_con_sozu = TRUE
WHERE  id IN (9, 17, 21, 43, 49, 52, 95, 152, 166, 186, 298, 308, 309);
