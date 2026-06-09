-- Filtros de destinatario por modelo y piso en avisos.
-- Fecha: 2026-06-09
--
-- La Bandeja de "Administrar avisos" (Comunicación) permite acotar los destinatarios
-- Cliente por DESARROLLO (avisos_proyectos). Se agrega además el filtrado por MODELO y
-- PISO, ambos dependientes del/los desarrollo(s) seleccionado(s). La selección se guarda
-- en una columna jsonb en avisos para que la restaure la edición y la apliquen tanto el
-- envío manual (enviar-aviso-bulk) como el automático/evento (evaluar-triggers-evento).
--
-- Shape:
--   { "modelos": ["Modelo A", ...],   -- nombres de modelos (modelos.nombre)
--     "pisos":   ["1", "2", ...] }    -- valores de propiedades.numero_piso (texto)
-- Array vacío o ausente = sin filtro (todos). Default '{}'.

ALTER TABLE public.avisos
  ADD COLUMN IF NOT EXISTS filtros_destinatario jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.avisos.filtros_destinatario IS
  'Filtros adicionales de destinatario Cliente dependientes del desarrollo. {"modelos":[nombres modelos.nombre],"pisos":[valores propiedades.numero_piso]}. Array vacío/ausente = sin filtro. Lo consumen enviar-aviso-bulk y evaluar-triggers-evento.';
