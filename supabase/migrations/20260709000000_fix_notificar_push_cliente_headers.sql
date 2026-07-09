-- Fix headers de notificar_push_cliente: agregar Authorization/apikey (anon)
-- Fecha: 2026-07-09
--
-- La versión creada en 20260708040000 solo mandaba el header x-push-secret. El
-- gateway de Supabase exige apikey/Authorization (anon) antes de enrutar a la
-- edge function, así que sin ellos la llamada devuelve 401 y el push nunca llega.
-- Se agrega la key 'supabase_anon_key' de private.sozu_config y se incluye en los
-- headers. CREATE OR REPLACE idempotente; el trigger existente sigue apuntando a
-- esta función (no se toca). Ajuste ya validado por el autor directamente en BD.

CREATE OR REPLACE FUNCTION public.notificar_push_cliente()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_secret text;
  v_base   text;
  v_anon   text;
BEGIN
  SELECT value INTO v_secret FROM private.sozu_config WHERE key = 'push_dispatch_secret';
  SELECT value INTO v_base   FROM private.sozu_config WHERE key = 'functions_base_url';
  SELECT value INTO v_anon   FROM private.sozu_config WHERE key = 'supabase_anon_key';

  -- Sin secret o sin URL configurados → no enviar push (nunca bloquear el insert).
  IF v_secret IS NULL OR v_base IS NULL THEN
    RETURN NEW;
  END IF;

  -- Llamada asíncrona (pg_net); si falla no bloquea el insert.
  -- Authorization/apikey (anon) los exige el gateway de Supabase antes de llegar a
  -- la función; x-push-secret lo valida la propia edge function.
  PERFORM net.http_post(
    url     := rtrim(v_base, '/') || '/notificaciones-push',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_anon,
      'apikey',        v_anon,
      'x-push-secret', v_secret
    ),
    body    := jsonb_build_object('id', NEW.id)
  );

  RETURN NEW;
END;
$$;
