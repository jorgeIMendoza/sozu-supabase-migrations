-- Entregas: evidencia por ítem + responsable institucional + log de checklist
-- Fecha: 2026-07-15
--
-- 1. entregas_evidencia: id_item (evidencia por ítem del checklist; NULL = nivel entrega,
--    compatible con histórico) + tipo_evidencia (GENERAL/INCIDENCIA/REPARACION/VALIDACION).
-- 2. entregas_checklist_items: id_responsable_er (responsable institucional, patrón Postventa).
--    El campo responsable TEXT existente se conserva durante UAT (se dropea en migración
--    posterior una vez validado).
-- 3. entregas_checklist_log: bitácora del checklist (modelo postventa_log_actividades) +
--    fecha_actualizacion con trigger que la autollena en cada UPDATE (set_fecha_actualizacion).
--
-- NOTA: las PK de entregas_checklist_items / entidades_relacionadas / entregas son BIGINT
-- (no integer como asumía el ASSERT del borrador) → las columnas FK se declaran BIGINT para
-- coincidir. Se omitió el bloque ASSERT (verificaba 'integer', que es falso). id del log como
-- BIGINT GENERATED ALWAYS AS IDENTITY (convención del proyecto).
--
-- Idempotente: ADD COLUMN IF NOT EXISTS, CREATE TABLE/INDEX IF NOT EXISTS. Sin BEGIN/COMMIT.

-- ── 1. entregas_evidencia: id_item + tipo_evidencia ──────────────────────────
ALTER TABLE public.entregas_evidencia
  ADD COLUMN IF NOT EXISTS id_item bigint NULL REFERENCES public.entregas_checklist_items(id),
  ADD COLUMN IF NOT EXISTS tipo_evidencia text NOT NULL DEFAULT 'GENERAL'
    CHECK (tipo_evidencia IN ('GENERAL','INCIDENCIA','REPARACION','VALIDACION'));

CREATE INDEX IF NOT EXISTS idx_entregas_evidencia_item
  ON public.entregas_evidencia(id_item) WHERE id_item IS NOT NULL;

-- ── 2. entregas_checklist_items: id_responsable_er ───────────────────────────
ALTER TABLE public.entregas_checklist_items
  ADD COLUMN IF NOT EXISTS id_responsable_er bigint NULL REFERENCES public.entidades_relacionadas(id);

CREATE INDEX IF NOT EXISTS idx_entregas_checklist_items_responsable
  ON public.entregas_checklist_items(id_responsable_er) WHERE id_responsable_er IS NOT NULL;

-- ── 3. entregas_checklist_log ────────────────────────────────────────────────
-- tipo_evento esperado: CAMBIO_ESTATUS, ASIGNACION_RESPONSABLE, REVERSION_ESTATUS,
-- REGISTRO_EVIDENCIA, VOBO_APROBADO, VOBO_RECHAZADO. usuario/estatus sin FK (patrón postventa).
CREATE TABLE IF NOT EXISTS public.entregas_checklist_log (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_entrega        bigint NULL REFERENCES public.entregas(id),
  id_checklist_item bigint NOT NULL REFERENCES public.entregas_checklist_items(id),
  tipo_evento       text NOT NULL,
  accion            text,
  estatus_anterior  text,
  estatus_nuevo     text,
  observaciones     text,
  usuario           text,
  metadata          jsonb,
  activo            boolean NOT NULL DEFAULT true,
  fecha_creacion    timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now()
);

-- Autollenar fecha_actualizacion en cada UPDATE (función existente set_fecha_actualizacion).
DROP TRIGGER IF EXISTS trg_entregas_checklist_log_upd ON public.entregas_checklist_log;
CREATE TRIGGER trg_entregas_checklist_log_upd
  BEFORE UPDATE ON public.entregas_checklist_log
  FOR EACH ROW EXECUTE FUNCTION set_fecha_actualizacion();

CREATE INDEX IF NOT EXISTS idx_entregas_checklist_log_entrega
  ON public.entregas_checklist_log(id_entrega);
CREATE INDEX IF NOT EXISTS idx_entregas_checklist_log_item
  ON public.entregas_checklist_log(id_checklist_item);
CREATE INDEX IF NOT EXISTS idx_entregas_checklist_log_fecha
  ON public.entregas_checklist_log(fecha_creacion DESC);
