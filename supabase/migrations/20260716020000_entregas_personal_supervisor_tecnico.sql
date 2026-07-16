-- Entregas: personal supervisor/técnico en checklist + indicadores en entidades_relacionadas
-- Fecha: 2026-07-16
--
-- Formaliza el DDL autorizado en DEV (Ejecuciones/ejecutar.md). Cinco bloques:
--   1) entregas_checklist_items: +id_supervisor_er, +id_tecnico_er (FK a
--      entidades_relacionadas), +fecha_actualizacion + trigger set_fecha_actualizacion.
--   2A) entidades_relacionadas.fecha_actualizacion: timestamp → timestamptz (interpretando
--       los valores crudos como UTC; validado contra muestra histórica el 2026-07-16).
--   2B) entidades_relacionadas: +es_supervisor_entregas, +es_tecnico_entregas + trigger.
--   3) Backfill: personal de mantenimiento (tipo 22 activo) → es_tecnico_entregas=true.
--   4) Migrar id_responsable_er → id_tecnico_er (sin sobrescribir asignaciones previas).
--
-- FKs BIGINT: entidades_relacionadas.id es bigint. Idempotente: ADD/CREATE IF NOT EXISTS,
-- DROP TRIGGER IF EXISTS, backfills con WHERE que evita reaplicar, y el ALTER TYPE del 2A
-- va en DO-block guard (solo corre si el tipo aún es 'timestamp without time zone', para no
-- corromper el valor si la migración se reejecuta o el DDL ya se aplicó a mano en DEV).
-- Sin BEGIN/COMMIT (CI/CD envuelve en tx). La sección de validación del .md se omite (son
-- SELECTs de verificación, se corren aparte).

-- ================================================================
-- BLOQUE 1 — entregas_checklist_items: personal + fecha_actualizacion
-- ================================================================
ALTER TABLE public.entregas_checklist_items
  ADD COLUMN IF NOT EXISTS id_supervisor_er    bigint REFERENCES public.entidades_relacionadas(id),
  ADD COLUMN IF NOT EXISTS id_tecnico_er       bigint REFERENCES public.entidades_relacionadas(id),
  ADD COLUMN IF NOT EXISTS fecha_actualizacion timestamptz NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_eci_supervisor_er
  ON public.entregas_checklist_items(id_supervisor_er) WHERE id_supervisor_er IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_eci_tecnico_er
  ON public.entregas_checklist_items(id_tecnico_er) WHERE id_tecnico_er IS NOT NULL;

DROP TRIGGER IF EXISTS trg_entregas_checklist_items_upd ON public.entregas_checklist_items;
CREATE TRIGGER trg_entregas_checklist_items_upd
  BEFORE UPDATE ON public.entregas_checklist_items
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- ================================================================
-- BLOQUE 2A — entidades_relacionadas.fecha_actualizacion → timestamptz
--   Guard: solo convierte si el tipo aún es timestamp sin zona (evita
--   re-aplicar AT TIME ZONE 'UTC' sobre un timestamptz, que lo corrompería).
-- ================================================================
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'entidades_relacionadas'
      AND column_name = 'fecha_actualizacion'
      AND data_type = 'timestamp without time zone'
  ) THEN
    ALTER TABLE public.entidades_relacionadas
      ALTER COLUMN fecha_actualizacion TYPE timestamptz
      USING fecha_actualizacion AT TIME ZONE 'UTC';
  END IF;
END $$;

ALTER TABLE public.entidades_relacionadas ALTER COLUMN fecha_actualizacion SET DEFAULT now();
ALTER TABLE public.entidades_relacionadas ALTER COLUMN fecha_actualizacion SET NOT NULL;

-- ================================================================
-- BLOQUE 2B — entidades_relacionadas: indicadores operativos + trigger
-- ================================================================
ALTER TABLE public.entidades_relacionadas
  ADD COLUMN IF NOT EXISTS es_supervisor_entregas boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS es_tecnico_entregas    boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_er_sup_entregas
  ON public.entidades_relacionadas(es_supervisor_entregas) WHERE es_supervisor_entregas = true;

CREATE INDEX IF NOT EXISTS idx_er_tec_entregas
  ON public.entidades_relacionadas(es_tecnico_entregas) WHERE es_tecnico_entregas = true;

DROP TRIGGER IF EXISTS trg_entidades_relacionadas_upd ON public.entidades_relacionadas;
CREATE TRIGGER trg_entidades_relacionadas_upd
  BEFORE UPDATE ON public.entidades_relacionadas
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- ================================================================
-- BLOQUE 3 — Backfill: personal de mantenimiento (tipo 22 activo) → técnico
--   Tipo 8 (proveedores) y supervisores: habilitación manual desde UI.
-- ================================================================
UPDATE public.entidades_relacionadas
  SET es_tecnico_entregas = true
  WHERE id_tipo_entidad = 22 AND activo = true AND es_tecnico_entregas = false;

-- ================================================================
-- BLOQUE 4 — Migrar id_responsable_er → id_tecnico_er
--   WHERE id_tecnico_er IS NULL evita sobrescribir asignaciones previas.
--   id_responsable_er se conserva intacto.
-- ================================================================
UPDATE public.entregas_checklist_items
  SET id_tecnico_er = id_responsable_er
  WHERE id_responsable_er IS NOT NULL AND id_tecnico_er IS NULL;
