-- Ajuste del modelo de Negocios (ver 20260716120000_crm_negocios.sql).
-- Confirmado por ventas (Manuel Nava / Sergio, 2026-07-17):
--   * Un negocio pertenece a UN solo contacto (un contacto sí puede tener varios
--     negocios) -> se agrega crm_negocios.id_entidad_relacionada y se descarta la M:N.
--   * Campos nuevos del negocio: tipo_negocio y prioridad.
--   * Las etapas siguen siendo POR pipeline (crm_pipeline_etapas no cambia).
--   * La fecha de cierre reutiliza la columna existente fecha_cierre_estimada.

ALTER TABLE public.crm_negocios
    ADD COLUMN IF NOT EXISTS id_entidad_relacionada BIGINT
        REFERENCES public.entidades_relacionadas(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS tipo_negocio TEXT,   -- 'cliente_nuevo' | 'cliente_existente'
    ADD COLUMN IF NOT EXISTS prioridad    TEXT;   -- 'baja' | 'media' | 'alta'

CREATE INDEX IF NOT EXISTS idx_crm_negocios_er ON public.crm_negocios (id_entidad_relacionada);

-- La tabla intermedia ya no aplica: un negocio = un contacto.
DROP TABLE IF EXISTS public.crm_negocios_contactos;
