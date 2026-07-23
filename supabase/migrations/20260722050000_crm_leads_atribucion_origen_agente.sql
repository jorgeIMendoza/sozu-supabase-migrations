-- crm_leads_atribucion · columna origen_agente
-- Fecha: 2026-07-22
--
-- Agrega el nombre del agente independiente / inmobiliaria de procedencia del lead.
-- Lo usa la carga masiva de contactos (columna "Agente independiente/inmobiliaria"
-- del Excel): es un DATO de atribución, no una categoría. La categoría "Agente
-- Externo" se maneja aparte en crm_categorias. Nullable: solo aplica a contactos de
-- procedencia externa; el resto queda en NULL.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

ALTER TABLE public.crm_leads_atribucion
  ADD COLUMN IF NOT EXISTS origen_agente text;
