-- Log interno de eventos CRM -> Meta (Conversions API for Leads).
-- Cada envio de la Edge Function meta-capi-lead-stage queda registrado aqui para
-- trazabilidad: status, respuesta de Meta, fbtrace_id, error y reintentos.
-- Pedido por Rodrigo (marketing) como parte del cierre de la senal CRM -> Meta.
-- Migracion idempotente / self-guarded.

BEGIN;

CREATE TABLE IF NOT EXISTS public.crm_meta_capi_eventos (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_entidad_relacionada  bigint,
  event_name              text        NOT NULL,      -- ej. marketingqualifiedlead
  event_id                text        NOT NULL,      -- UUID para deduplicacion en Meta
  meta_leadgen_id         text,
  status                  text        NOT NULL,      -- 'sent' | 'error' | 'skipped'
  events_received         integer,                   -- lo que devuelve Meta
  fbtrace_id              text,                       -- rastreo de Meta
  intentos                integer     NOT NULL DEFAULT 1,
  test_event_code         text,
  meta_response           jsonb,                      -- respuesta cruda de Meta
  error                   text,
  fecha_creacion          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.crm_meta_capi_eventos IS
  'Log de eventos enviados del CRM a Meta (Conversions API for Leads) via la Edge Function meta-capi-lead-stage. Trazabilidad por evento: status, respuesta de Meta, fbtrace_id, error y reintentos.';

CREATE INDEX IF NOT EXISTS idx_crm_meta_capi_eventos_er
  ON public.crm_meta_capi_eventos (id_entidad_relacionada);
CREATE INDEX IF NOT EXISTS idx_crm_meta_capi_eventos_fecha
  ON public.crm_meta_capi_eventos (fecha_creacion DESC);
CREATE INDEX IF NOT EXISTS idx_crm_meta_capi_eventos_event_id
  ON public.crm_meta_capi_eventos (event_id);

-- RLS: lectura para usuarios autenticados; la ESCRITURA la hace la Edge Function
-- con service_role (que ignora RLS), por eso NO se define policy de INSERT.
ALTER TABLE public.crm_meta_capi_eventos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS crm_meta_capi_eventos_select ON public.crm_meta_capi_eventos;
CREATE POLICY crm_meta_capi_eventos_select
  ON public.crm_meta_capi_eventos
  FOR SELECT
  TO authenticated
  USING (true);

GRANT SELECT ON public.crm_meta_capi_eventos TO authenticated;
REVOKE ALL ON public.crm_meta_capi_eventos FROM anon;

COMMIT;
