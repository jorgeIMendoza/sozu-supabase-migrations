-- Avisos del admin a clientes del app (push / email / WA, calendarizables)
-- Fecha: 2026-07-08
--
-- Paso 1: tabla avisos_app (cola de avisos; inmediatos o programados).
-- Paso 3: cron (pg_cron) cada minuto que dispara la edge function admin-avisos-app
--         (action 'procesar') para los avisos programados vencidos.
--
-- Igual que el push (20260708040000): el cron NO hardcodea secret ni URL; los lee de
-- private.sozu_config (push_dispatch_secret, functions_base_url, supabase_anon_key).
-- Si falta cualquiera, no llama a la función (no genera URL nula ni error).
--
-- Idempotente: CREATE ... IF NOT EXISTS, DROP TRIGGER IF EXISTS + CREATE, CREATE OR
-- REPLACE, unschedule+schedule por nombre. Sin BEGIN/COMMIT (CI/CD envuelve en tx).
-- Verificado en dev: pg_cron y set_fecha_actualizacion existen; avisos_app no existía.

-- ==============================================================
-- Paso 1 — Tabla avisos_app
-- ==============================================================

CREATE TABLE IF NOT EXISTS public.avisos_app (
  id                    bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  titulo                text NOT NULL,
  mensaje               text NOT NULL,
  tipo                  text NOT NULL DEFAULT 'informativa' CHECK (
                          tipo = ANY (ARRAY['urgente','accionable','informativa','exito'])),
  categoria             text NOT NULL DEFAULT 'pagos' CHECK (
                          categoria = ANY (ARRAY['pagos','documentos','mantenimiento','construccion','reventa','entrega'])),
  canales               text[] NOT NULL DEFAULT '{push}',
  id_proyecto           integer NULL,
  id_modelo             integer NULL,
  id_propiedad          bigint NULL,
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
  CONSTRAINT avisos_app_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_avisos_app_pendientes
  ON public.avisos_app (programado_para)
  WHERE (estado = 'pendiente');

-- Solo service_role (edge function) la toca; sin policies.
ALTER TABLE public.avisos_app ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS trg_avisos_app_upd ON public.avisos_app;
CREATE TRIGGER trg_avisos_app_upd BEFORE UPDATE
  ON public.avisos_app
  FOR EACH ROW EXECUTE FUNCTION set_fecha_actualizacion();

-- ==============================================================
-- Paso 3 — Cron que procesa los avisos programados
-- ==============================================================

CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE OR REPLACE FUNCTION public.procesar_avisos_app()
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
    SELECT 1 FROM avisos_app
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
    url     := rtrim(v_base, '/') || '/admin-avisos-app',
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

-- Reprogramar de forma idempotente (unschedule si ya existe, luego schedule).
DO $$
BEGIN
  PERFORM cron.unschedule('avisos-app-procesar');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

SELECT cron.schedule(
  'avisos-app-procesar',
  '* * * * *',
  $$SELECT public.procesar_avisos_app()$$
);

-- Revisar: SELECT * FROM cron.job;   Quitar: SELECT cron.unschedule('avisos-app-procesar');
-- Recordatorio: poblar private.sozu_config (push_dispatch_secret, functions_base_url,
-- supabase_anon_key) por ambiente para que el cron dispare admin-avisos-app.
