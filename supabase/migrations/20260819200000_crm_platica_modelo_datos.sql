-- Platica propio — modelo de datos del agente de IA por WhatsApp (multi-proyecto).
-- Tablas crm_platica_* + pgvector (RAG) + RPC de búsqueda semántica + RLS.
-- Base para las Edge Functions whatsapp-webhook / whatsapp-agente y la bandeja del CRM.

-- pgvector para RAG (base de conocimiento del agente)
CREATE EXTENSION IF NOT EXISTS vector;

-- 1. Agente por proyecto (configuración + número de WhatsApp que atiende)
CREATE TABLE IF NOT EXISTS public.crm_platica_agentes (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_proyecto         integer NOT NULL REFERENCES public.proyectos(id),
  nombre              text NOT NULL DEFAULT 'Asistente',
  modelo              text NOT NULL DEFAULT 'gpt-4o-mini',
  system_prompt       text NOT NULL DEFAULT '',
  wa_phone_number_id  text UNIQUE,            -- id del número de WhatsApp (Meta) que atiende este agente
  activo              boolean NOT NULL DEFAULT true,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.crm_platica_agentes IS 'Config del agente IA de WhatsApp por proyecto (platica propio).';

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

-- 4. Documentos de conocimiento (por proyecto)
CREATE TABLE IF NOT EXISTS public.crm_platica_documentos (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_proyecto    integer NOT NULL REFERENCES public.proyectos(id),
  titulo         text NOT NULL,
  contenido      text NOT NULL,
  activo         boolean NOT NULL DEFAULT true,
  fecha_creacion timestamptz NOT NULL DEFAULT now()
);

-- 5. Chunks vectorizados (RAG)
CREATE TABLE IF NOT EXISTS public.crm_platica_chunks (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_documento   bigint NOT NULL REFERENCES public.crm_platica_documentos(id) ON DELETE CASCADE,
  id_proyecto    integer NOT NULL REFERENCES public.proyectos(id),
  contenido      text NOT NULL,
  embedding      vector(1536) NOT NULL,
  fecha_creacion timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_platica_chunks_embedding ON public.crm_platica_chunks USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS idx_platica_chunks_proyecto  ON public.crm_platica_chunks (id_proyecto);

-- 6. Dedup de webhooks (reemplaza el KV de Cloudflare)
CREATE TABLE IF NOT EXISTS public.crm_platica_webhook_seen (
  wa_message_id  text PRIMARY KEY,
  fecha_creacion timestamptz NOT NULL DEFAULT now()
);

-- RPC: búsqueda semántica por proyecto (similitud coseno)
CREATE OR REPLACE FUNCTION public.crm_platica_match_chunks(
  p_id_proyecto integer,
  p_embedding   vector(1536),
  p_count       integer DEFAULT 5
)
RETURNS TABLE (id bigint, contenido text, similitud double precision)
LANGUAGE sql STABLE
AS $$
  SELECT c.id, c.contenido, 1 - (c.embedding <=> p_embedding) AS similitud
  FROM public.crm_platica_chunks c
  WHERE c.id_proyecto = p_id_proyecto
  ORDER BY c.embedding <=> p_embedding
  LIMIT GREATEST(p_count, 1);
$$;

-- RLS: habilitar. Las Edge Functions usan service_role (bypass). Usuarios autenticados: leer/gestionar.
ALTER TABLE public.crm_platica_agentes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_platica_contactos_wa ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_platica_mensajes     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_platica_documentos   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_platica_chunks       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_platica_webhook_seen ENABLE ROW LEVEL SECURITY;

-- Piloto: cualquier usuario autenticado del CRM puede leer/gestionar.
-- (Fase 2: endurecer a RLS por proyecto vía proyectos_acceso.)
DROP POLICY IF EXISTS platica_agentes_auth    ON public.crm_platica_agentes;
DROP POLICY IF EXISTS platica_contactos_auth  ON public.crm_platica_contactos_wa;
DROP POLICY IF EXISTS platica_mensajes_auth   ON public.crm_platica_mensajes;
DROP POLICY IF EXISTS platica_documentos_auth ON public.crm_platica_documentos;
DROP POLICY IF EXISTS platica_chunks_auth     ON public.crm_platica_chunks;

CREATE POLICY platica_agentes_auth    ON public.crm_platica_agentes      FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY platica_contactos_auth  ON public.crm_platica_contactos_wa FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY platica_mensajes_auth   ON public.crm_platica_mensajes     FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY platica_documentos_auth ON public.crm_platica_documentos   FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY platica_chunks_auth     ON public.crm_platica_chunks       FOR ALL TO authenticated USING (true) WITH CHECK (true);
-- crm_platica_webhook_seen: sin política para authenticated → solo service_role (Edge Functions).
