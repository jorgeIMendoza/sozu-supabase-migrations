-- Columnas `hubspot_id` para la migración de datos HubSpot → CRM.
-- Uso: (1) idempotencia — re-correr la migración sin duplicar; (2) ligar negocios↔contactos
-- por el "ID de registro" de HubSpot. Son de una sola vez: se pueden DROP tras validar la migración.
-- IF NOT EXISTS para que sea seguro correrla más de una vez.

ALTER TABLE public.crm_leads_atribucion ADD COLUMN IF NOT EXISTS hubspot_id text;
ALTER TABLE public.crm_negocios          ADD COLUMN IF NOT EXISTS hubspot_id text;

CREATE INDEX IF NOT EXISTS idx_crm_leads_atribucion_hubspot_id
  ON public.crm_leads_atribucion (hubspot_id) WHERE hubspot_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_crm_negocios_hubspot_id
  ON public.crm_negocios (hubspot_id) WHERE hubspot_id IS NOT NULL;

COMMENT ON COLUMN public.crm_leads_atribucion.hubspot_id IS 'ID de registro del contacto en HubSpot (migración one-time; se puede eliminar después).';
COMMENT ON COLUMN public.crm_negocios.hubspot_id IS 'ID de registro del negocio en HubSpot (migración one-time; se puede eliminar después).';
