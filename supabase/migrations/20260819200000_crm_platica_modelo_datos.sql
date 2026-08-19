-- Platica propio — modelo de datos del agente de IA por WhatsApp (multi-proyecto).
-- Agente configurable por proyecto (número + token gestionables desde el front),
-- contactos de WhatsApp, historial de mensajes, base de conocimiento (búsqueda de
-- texto) y dedup de webhooks. LLM = Claude (Anthropic). RAG vectorial (pgvector) NO
-- se incluye aquí: Anthropic no da embeddings; la base de conocimiento se consulta por
-- texto. (Fase 2: chunks + pgvector si se agrega un proveedor de embeddings.)

-- 1. Agente por proyecto (config + credenciales de WhatsApp, editables desde el CRM)
CREATE TABLE IF NOT EXISTS public.crm_platica_agentes (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_proyecto         integer NOT NULL REFERENCES public.proyectos(id),
  nombre              text NOT NULL DEFAULT 'Asistente',
  modelo              text NOT NULL DEFAULT 'claude-haiku-4-5-20251001',
  system_prompt       text NOT NULL DEFAULT '',
  wa_phone_number_id  text UNIQUE,            -- id del número de WhatsApp (Meta) que atiende este agente
  wa_token            text,                   -- token de envío (System User / temporal de pruebas), gestionable desde el front
  activo              boolean NOT NULL DEFAULT true,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id_proyecto)                        -- 1 agente por proyecto (upsert desde el front)
);
COMMENT ON TABLE public.crm_platica_agentes IS 'Config del agente IA de WhatsApp por proyecto (platica propio).';
COMMENT ON COLUMN public.crm_platica_agentes.wa_token IS 'Token de WhatsApp Cloud API (piloto: en BD, editable desde el front; Fase 2: mover a secreto/cifrado).';

-- 2. Contacto de WhatsApp (usuario final que escribe)
CREATE TABLE IF NOT EXISTS public.crm_platica_contactos_wa (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_proyecto            integer NOT NULL REFERENCES public.proyectos(id),
  wa_number              text NOT NULL,
  nombre                 text,
  id_entidad_relacionada bigint REFERENCES public.entidades_relacionadas(id), -- enlace al contacto CRM real (opcional)
  pausado                boolean NOT NULL DEFAULT false,   -- intervención humana: true = el bot no responde
  fecha_creacion         timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id_proyecto, wa_number)
);

-- 3. Mensajes (historial de la conversación)
CREATE TABLE IF NOT EXISTS public.crm_platica_mensajes (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_contacto_wa bigint NOT NULL REFERENCES public.crm_platica_contactos_wa(id) ON DELETE CASCADE,
  rol            text NOT NULL CHECK (rol IN ('user','assistant','system')),
  contenido      text NOT NULL,
  wa_message_id  text,          -- id del mensaje en Meta (trazabilidad)
  fecha_creacion timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_platica_mensajes_contacto ON public.crm_platica_mensajes (id_contacto_wa, id);

-- 4. Base de conocimiento por proyecto (consultada por texto)
CREATE TABLE IF NOT EXISTS public.crm_platica_documentos (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_proyecto    integer NOT NULL REFERENCES public.proyectos(id),
  titulo         text NOT NULL,
  contenido      text NOT NULL,
  activo         boolean NOT NULL DEFAULT true,
  fecha_creacion timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_platica_documentos_proyecto ON public.crm_platica_documentos (id_proyecto) WHERE activo;

-- 5. Dedup de webhooks (reemplaza el KV de Cloudflare)
CREATE TABLE IF NOT EXISTS public.crm_platica_webhook_seen (
  wa_message_id  text PRIMARY KEY,
  fecha_creacion timestamptz NOT NULL DEFAULT now()
);

-- RLS: habilitar. Las Edge Functions usan service_role (bypass). Usuarios autenticados: leer/gestionar.
ALTER TABLE public.crm_platica_agentes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_platica_contactos_wa ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_platica_mensajes     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_platica_documentos   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_platica_webhook_seen ENABLE ROW LEVEL SECURITY;

-- Piloto: cualquier usuario autenticado del CRM puede leer/gestionar.
-- (Fase 2: endurecer a RLS por proyecto vía proyectos_acceso, y proteger wa_token.)
DROP POLICY IF EXISTS platica_agentes_auth    ON public.crm_platica_agentes;
DROP POLICY IF EXISTS platica_contactos_auth  ON public.crm_platica_contactos_wa;
DROP POLICY IF EXISTS platica_mensajes_auth   ON public.crm_platica_mensajes;
DROP POLICY IF EXISTS platica_documentos_auth ON public.crm_platica_documentos;

CREATE POLICY platica_agentes_auth    ON public.crm_platica_agentes      FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY platica_contactos_auth  ON public.crm_platica_contactos_wa FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY platica_mensajes_auth   ON public.crm_platica_mensajes     FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY platica_documentos_auth ON public.crm_platica_documentos   FOR ALL TO authenticated USING (true) WITH CHECK (true);
-- crm_platica_webhook_seen: sin política para authenticated → solo service_role (Edge Functions).
