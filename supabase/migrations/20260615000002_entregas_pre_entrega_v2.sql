-- Módulo Entregas (V2): columnas de trazabilidad PRE-ENTREGA / ENTREGA.
-- Fecha: 2026-06-15
--
-- V2 minimalista respecto a V1: NO persiste datos derivados.
--   * Sin entregas.checklist_pct (se calcula items_completos/total_items).
--   * Sin entregas.acta_estatus (se deriva de documentos tipo 24).
--   * Sin entregas_checklist_categorias.orden (ORDER BY nombre).
--   * Sin función/trigger de recálculo.
-- Solo agrega columnas capturadas por el usuario (no derivables) + 3 índices.
-- Idempotente (ADD COLUMN / CREATE INDEX IF NOT EXISTS). No DROP/TRUNCATE/DELETE.
--
-- Corrección vs el spec: entregas_observaciones.id_checklist_item se declara BIGINT
-- (no integer) para que la FK calce con entregas_checklist_items.id (bigint).

-- ── entregas_checklist_categorias: tipo de checklist ─────────
ALTER TABLE public.entregas_checklist_categorias
  ADD COLUMN IF NOT EXISTS tipo_checklist varchar(20) NOT NULL DEFAULT 'PRE_ENTREGA';

-- ── entregas_checklist_items: trazabilidad de revisión ───────
ALTER TABLE public.entregas_checklist_items
  ADD COLUMN IF NOT EXISTS responsable      varchar(255),
  ADD COLUMN IF NOT EXISTS fecha_revision   timestamptz,
  ADD COLUMN IF NOT EXISTS fecha_compromiso date;

-- ── entregas_observaciones: vínculo a ítem y cierre ──────────
-- id_checklist_item nullable (observaciones generales sin ítem); bigint para calzar FK.
ALTER TABLE public.entregas_observaciones
  ADD COLUMN IF NOT EXISTS id_checklist_item bigint REFERENCES public.entregas_checklist_items(id),
  ADD COLUMN IF NOT EXISTS responsable        varchar(255),
  ADD COLUMN IF NOT EXISTS fecha_compromiso   date,
  ADD COLUMN IF NOT EXISTS fecha_cierre       timestamptz;

-- ── Índices de soporte (parciales WHERE activo = true) ───────
CREATE INDEX IF NOT EXISTS idx_entregas_id_propiedad
  ON public.entregas(id_propiedad)
  WHERE activo = true;

CREATE INDEX IF NOT EXISTS idx_checklist_cats_id_entrega
  ON public.entregas_checklist_categorias(id_entrega)
  WHERE activo = true;

CREATE INDEX IF NOT EXISTS idx_obs_entrega_estatus
  ON public.entregas_observaciones(id_entrega, estatus)
  WHERE activo = true;
