-- Avisos del admin a AGENTES del app (push / email / WA, calendarizables)
-- Fecha: 2026-08-13
--
-- ─── Por qué ──────────────────────────────────────────────────────────────────
-- La pantalla "Nuevo aviso" del app de agentes es la del cliente portada tal
-- cual: manda a `admin-avisos-app`, que resuelve COMPRADORES y escribe en
-- `notificaciones_cliente`. O sea que desde el portal de agentes se avisa a los
-- clientes, no a los agentes, y el destino se elige por proyecto/modelo/nivel/
-- unidad, que de un agente no dicen nada.
--
-- Esta migración crea la cola gemela para agentes. El destino aquí es el ROL
-- (3 Agente Inmobiliario, 9 Agente Interno), que es lo único que segmenta a esta
-- población: `ids_roles`. NULL = todos los agentes con acceso al portal.
--
-- ─── Espejo de `avisos_app` (20260708050000) ──────────────────────────────────
-- Misma forma a propósito, para que un arreglo en una se pueda copiar a la otra
-- sin traducir. Dos diferencias de fondo:
--
--  1. Destino por `ids_roles integer[]` en vez de los cuatro ids de la jerarquía
--     de propiedades.
--  2. `categoria` usa el set del AGENTE (mismo CHECK que
--     `notificaciones_agente`, 20260810020000): comisiones, ofertas, leads,
--     citas, documentos, capacitacion, general. Poner aquí las del cliente
--     (pagos, mantenimiento, entrega…) haría que el aviso se insertara en la
--     cola y reventara al escribir la notificación, que es el peor momento para
--     enterarse. El set de `tipo` sí es idéntico.
--
-- El push NO se dispara desde aquí: al insertar en `notificaciones_agente` ya
-- actúa el trigger `trg_notificaciones_agente_push` (20260811040000), que llama
-- a `notificaciones-push` con app='agentes'.
--
-- Idempotente: CREATE ... IF NOT EXISTS, DROP TRIGGER IF EXISTS + CREATE,
-- CREATE OR REPLACE, unschedule+schedule por nombre. Sin BEGIN/COMMIT (el CI
-- envuelve en transacción).

-- ==============================================================
-- Paso 1 — Tabla avisos_app_agente
-- ==============================================================

CREATE TABLE IF NOT EXISTS public.avisos_app_agente (
  id                    bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  titulo                text NOT NULL,
  mensaje               text NOT NULL,
  tipo                  text NOT NULL DEFAULT 'informativa' CHECK (
                          tipo = ANY (ARRAY['urgente','accionable','informativa','exito'])),
  categoria             text NOT NULL DEFAULT 'general' CHECK (
                          categoria = ANY (ARRAY['comisiones','ofertas','leads','citas','documentos','capacitacion','general'])),
  canales               text[] NOT NULL DEFAULT '{push}',
  -- NULL = todos los agentes con acceso al portal. Es `roles.id`, no un
  -- catálogo propio: el gate del portal ya se define por ahí.
  ids_roles             integer[] NULL,
  url_accion            text NULL,
  etiqueta_accion       text NULL,
  programado_para       timestamp with time zone NULL,
  estado                text NOT NULL DEFAULT 'pendiente' CHECK (
                          estado = ANY (ARRAY['pendiente','enviado','cancelado','error'])),
  total_destinatarios   integer NULL,
  total_push            integer NULL,
  total_email           integer NULL,
  total_wa              integer NULL,
  error                 text NULL,
  creado_por            text NULL,
  fecha_envio           timestamp with time zone NULL,
  fecha_creacion        timestamp with time zone NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT avisos_app_agente_pkey PRIMARY KEY (id)
);

COMMENT ON TABLE public.avisos_app_agente IS
  'Cola de avisos del admin a agentes del app (inmediatos o programados). '
  'Espejo de avisos_app con destino por rol en vez de por propiedad.';
COMMENT ON COLUMN public.avisos_app_agente.ids_roles IS
  'roles.id destino (3 Agente Inmobiliario, 9 Agente Interno). NULL = todos.';

CREATE INDEX IF NOT EXISTS idx_avisos_app_agente_pendientes
  ON public.avisos_app_agente (programado_para)
  WHERE (estado = 'pendiente');

-- Solo service_role (edge function) la toca; sin policies.
ALTER TABLE public.avisos_app_agente ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS trg_avisos_app_agente_upd ON public.avisos_app_agente;
CREATE TRIGGER trg_avisos_app_agente_upd BEFORE UPDATE
  ON public.avisos_app_agente
  FOR EACH ROW EXECUTE FUNCTION set_fecha_actualizacion();

-- ==============================================================
-- Paso 2 — Cron que procesa los avisos programados
-- ==============================================================

CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE OR REPLACE FUNCTION public.procesar_avisos_app_agente()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_secret text;
  v_base   text;
  v_anon   text;
BEGIN
  -- Sin pendientes vencidos: no llamar a la función (ahorra invocaciones).
  IF NOT EXISTS (
    SELECT 1 FROM avisos_app_agente
    WHERE estado = 'pendiente' AND programado_para <= now()
  ) THEN
    RETURN;
  END IF;

  SELECT value INTO v_secret FROM private.sozu_config WHERE key = 'push_dispatch_secret';
  SELECT value INTO v_base   FROM private.sozu_config WHERE key = 'functions_base_url';
  SELECT value INTO v_anon   FROM private.sozu_config WHERE key = 'supabase_anon_key';

  -- Sin config → no llamar (evita URL nula / header sin token).
  IF v_secret IS NULL OR v_base IS NULL OR v_anon IS NULL THEN
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := rtrim(v_base, '/') || '/admin-avisos-agentes',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_anon,
      'apikey',        v_anon,
      'x-push-secret', v_secret
    ),
    body    := jsonb_build_object('action', 'procesar')
  );
END;
$$;

COMMENT ON FUNCTION public.procesar_avisos_app_agente() IS
  'Dispara admin-avisos-agentes (action procesar) para los avisos programados '
  'vencidos. Espejo de procesar_avisos_app().';

-- Reprogramar de forma idempotente (unschedule si ya existe, luego schedule).
DO $$
BEGIN
  PERFORM cron.unschedule('avisos-app-agente-procesar');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

SELECT cron.schedule(
  'avisos-app-agente-procesar',
  '* * * * *',
  $$SELECT public.procesar_avisos_app_agente()$$
);

-- Revisar: SELECT * FROM cron.job;
-- Quitar:  SELECT cron.unschedule('avisos-app-agente-procesar');
-- Requiere private.sozu_config poblada por ambiente (push_dispatch_secret,
-- functions_base_url, supabase_anon_key), las mismas tres llaves que ya usan el
-- push y el cron de avisos del cliente.
