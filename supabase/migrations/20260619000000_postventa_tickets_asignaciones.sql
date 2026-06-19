-- Postventa: asignación de responsable interno + proveedor externo en tickets.
-- Fecha: 2026-06-19
--
-- Agrega a postventa_tickets dos FK nullable a entidades_relacionadas:
--   id_responsable_interno → personal SOZU/mantenimiento (UI filtra id_tipo_entidad IN (5,9))
--   id_proveedor_externo   → proveedor externo           (UI filtra id_tipo_entidad = 8)
-- Ambas NULL por defecto → no rompen tickets históricos.
--
-- Corrección vs el spec: las columnas se declaran BIGINT (no integer). El spec eligió
-- integer basándose en types.ts (que mapea bigint→number), pero en BD
-- entidades_relacionadas.id es BIGINT → con integer la FK no calzaría. bigint es además
-- lo solicitado originalmente.
--
-- Idempotente (ADD COLUMN IF NOT EXISTS / CREATE INDEX IF NOT EXISTS). Verificado en dev:
-- postventa_tickets y entidades_relacionadas existen; las columnas no existían (el DDL
-- del 18-jun con nombre id_proveedor no se aplicó).

ALTER TABLE public.postventa_tickets
  ADD COLUMN IF NOT EXISTS id_responsable_interno bigint
    CONSTRAINT postventa_tickets_id_responsable_interno_fkey
    REFERENCES public.entidades_relacionadas(id)
    ON UPDATE CASCADE
    ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS id_proveedor_externo bigint
    CONSTRAINT postventa_tickets_id_proveedor_externo_fkey
    REFERENCES public.entidades_relacionadas(id)
    ON UPDATE CASCADE
    ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_postventa_tickets_responsable_interno
  ON public.postventa_tickets (id_responsable_interno)
  WHERE id_responsable_interno IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_postventa_tickets_proveedor_externo
  ON public.postventa_tickets (id_proveedor_externo)
  WHERE id_proveedor_externo IS NOT NULL;
