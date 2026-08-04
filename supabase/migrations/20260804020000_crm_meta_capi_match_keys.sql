-- Agrega match_keys a crm_meta_capi_eventos: registra que datos de user_data se
-- enviaron a Meta en cada evento (ej. "lead_id,em,ph"). Sirve para verificar por
-- evento que el email/telefono hasheado van incluidos (trazabilidad de la calidad
-- de match que pidio Rodrigo). Migracion idempotente.

BEGIN;

ALTER TABLE public.crm_meta_capi_eventos
  ADD COLUMN IF NOT EXISTS match_keys text;

COMMENT ON COLUMN public.crm_meta_capi_eventos.match_keys IS
  'Datos de match (claves de user_data) enviados a Meta en este evento, ej. "lead_id,em,ph".';

COMMIT;
