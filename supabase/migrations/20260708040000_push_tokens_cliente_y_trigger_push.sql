-- Push notifications (FCM) para el portal del cliente
-- Fecha: 2026-07-08
--
-- Paso 1: tabla push_tokens_cliente (tokens de dispositivo por cliente).
-- Paso 4: trigger en notificaciones_cliente que dispara la edge function
--         notificaciones-push (FCM v1) al insertar una notificación.
--
-- IMPORTANTE — secret y URL NO se hardcodean (el spec original los ponía en el
-- cuerpo del trigger). En su lugar el trigger los lee de private.sozu_config:
--   key 'push_dispatch_secret'  → header x-push-secret que valida la edge function.
--   key 'functions_base_url'    → base de functions del ambiente (dev VPS vs prod cloud).
-- Si falta cualquiera de los dos, el trigger NO envía push y NUNCA bloquea el insert.
-- Poblar sozu_config en CADA ambiente para activar el push (ver nota al final).
--
-- Idempotente: CREATE ... IF NOT EXISTS, DROP TRIGGER IF EXISTS + CREATE, CREATE OR REPLACE.
-- Sin BEGIN/COMMIT (CI/CD envuelve en tx). Verificado en dev: set_fecha_actualizacion(),
-- notificaciones_cliente y pg_net existen; push_tokens_cliente no existía.

-- ==============================================================
-- Paso 1 — Tabla de tokens
-- ==============================================================

CREATE TABLE IF NOT EXISTS public.push_tokens_cliente (
  id                    bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  email_cliente         text NOT NULL,
  token                 text NOT NULL,
  plataforma            text NOT NULL CHECK (plataforma IN ('android','ios','web')),
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp with time zone NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT push_tokens_cliente_pkey PRIMARY KEY (id),
  CONSTRAINT push_tokens_cliente_token_key UNIQUE (token)
);

CREATE INDEX IF NOT EXISTS idx_push_tokens_email
  ON public.push_tokens_cliente (email_cliente)
  WHERE (activo = true);

-- Solo service_role (edge functions) toca esta tabla; sin policies.
ALTER TABLE public.push_tokens_cliente ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS trg_push_tokens_cliente_upd ON public.push_tokens_cliente;
CREATE TRIGGER trg_push_tokens_cliente_upd BEFORE UPDATE
  ON public.push_tokens_cliente
  FOR EACH ROW EXECUTE FUNCTION set_fecha_actualizacion();

-- ==============================================================
-- Paso 4 — Trigger que dispara el push al insertar notificación
-- ==============================================================

CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION public.notificar_push_cliente()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_secret text;
  v_base   text;
BEGIN
  SELECT value INTO v_secret FROM private.sozu_config WHERE key = 'push_dispatch_secret';
  SELECT value INTO v_base   FROM private.sozu_config WHERE key = 'functions_base_url';

  -- Sin secret o sin URL configurados → no enviar push (nunca bloquear el insert).
  IF v_secret IS NULL OR v_base IS NULL THEN
    RETURN NEW;
  END IF;

  -- Llamada asíncrona (pg_net); si falla no bloquea el insert.
  PERFORM net.http_post(
    url     := rtrim(v_base, '/') || '/notificaciones-push',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'x-push-secret', v_secret
    ),
    body    := jsonb_build_object('id', NEW.id)
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notificaciones_cliente_push ON public.notificaciones_cliente;
CREATE TRIGGER trg_notificaciones_cliente_push
  AFTER INSERT ON public.notificaciones_cliente
  FOR EACH ROW EXECUTE FUNCTION public.notificar_push_cliente();

-- ==============================================================
-- Activación del push por ambiente (ejecutar UNA vez por ambiente; NO va en la
-- migración porque el secret no debe versionarse). En dev y en prod:
--
--   INSERT INTO private.sozu_config (key, value) VALUES
--     ('push_dispatch_secret', '<secret que también se setea como PUSH_DISPATCH_SECRET en la edge function>'),
--     ('functions_base_url',   'https://<host>/functions/v1')   -- dev: VPS; prod: https://tzmhgfjmddkfyffkkmto.supabase.co/functions/v1
--   ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
--
-- Mientras sozu_config no tenga ambas keys, el trigger no envía push (sin error).
-- ==============================================================
