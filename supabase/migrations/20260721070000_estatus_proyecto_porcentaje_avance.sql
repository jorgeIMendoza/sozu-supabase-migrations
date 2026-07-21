-- Avance de obra — columna real de % por etapa (fuente única de verdad)
-- Fecha: 2026-07-21
--
-- Unifica el "avance de obra" en estatus_proyecto.porcentaje_avance (editable por etapa),
-- en vez del % por tiempo transcurrido (oferta/agente/cliente/socio) o el ordinal
-- round(id/total*100) (Editar Proyecto). El front ya consume esta fuente vía
-- src/utils/avanceObra.ts, con fallback al legacy round(id/total*100) mientras la columna
-- no exista => aplicar esto NO rompe nada y activa la fuente real.
--
-- Verificado read-only vs prod 2026-07-21: columna no existe; 13 etapas ids 1-13 que
-- coinciden con el seed (dev y prod comparten catálogo).
--
-- Seed = mismos valores que se mostraban antes (round(id/13*100)) para que NADA cambie
-- visualmente al activar; editables luego con UPDATE. El seed usa guard
-- porcentaje_avance IS NULL: en el primer apply setea todo (columna recién creada = NULL),
-- y si por algo se re-aplicara NO pisa ediciones manuales posteriores.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS + UPDATE guarded.

-- 1) Columna nueva con CHECK de rango
ALTER TABLE public.estatus_proyecto
  ADD COLUMN IF NOT EXISTS porcentaje_avance smallint
  CONSTRAINT estatus_proyecto_porcentaje_avance_rango CHECK (porcentaje_avance BETWEEN 0 AND 100);

-- 2) Seed inicial (equivalente al comportamiento previo). Guard IS NULL: no pisa ediciones.
UPDATE public.estatus_proyecto AS e SET porcentaje_avance = v.pct
FROM (VALUES
  (1, 8),   -- Preparación
  (2, 15),  -- Demolición
  (3, 23),  -- Excavación
  (4, 31),  -- Muros
  (5, 38),  -- Sótanos
  (6, 46),  -- Planta Baja
  (7, 54),  -- Primeros Niveles
  (8, 62),  -- Niveles Medios
  (9, 69),  -- Últimos Niveles
  (10, 77), -- Fachada
  (11, 85), -- Interiores
  (12, 92), -- Detalles
  (13, 100) -- Finalizado
) AS v(id, pct)
WHERE e.id = v.id
  AND e.porcentaje_avance IS NULL;
