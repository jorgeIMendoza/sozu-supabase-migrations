-- Despacho de push para las notificaciones del Portal de Agentes.
-- Fecha: 2026-08-11
--
-- ─── Por qué ──────────────────────────────────────────────────────────────────
-- La migración 20260810020000 creó `notificaciones_agente`, `push_tokens_agente`
-- y `push_preferencias_agente`, y la app ya lee la campana. Pero NADIE empujaba:
-- el único trigger de push que existía es el de `notificaciones_cliente`, así que
-- una notificación insertada para un agente se guardaba y ahí se quedaba. El
-- síntoma es el peor de todos: no hay error, solo un push que nunca llega.
--
-- ─── Cómo ─────────────────────────────────────────────────────────────────────
-- Espejo de `notificar_push_cliente()` (20260708040000 + 20260709000000), con
-- una sola diferencia en el cuerpo: manda `app: 'agentes'` para que
-- `notificaciones-push` lea las tablas del agente y no las del cliente. Esa
-- function ya acepta el parámetro (default 'clientes', contrato viejo intacto);
-- si se aplica esta migración ANTES de desplegarla, el push responde
-- `400 app_invalida` y no se envía nada — no rompe el insert, solo no empuja.
--
-- Requiere las mismas 3 llaves en `private.sozu_config` que ya usa el cliente y
-- que en producción están puestas: `push_dispatch_secret`, `functions_base_url`
-- y `supabase_anon_key`. Sin ellas la función retorna sin enviar: un push que no
-- sale NUNCA debe tumbar el insert de la notificación.

BEGIN;

CREATE OR REPLACE FUNCTION public.notificar_push_agente()
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
  -- Authorization/apikey (anon) los exige el gateway de Supabase antes de llegar
  -- a la función; x-push-secret lo valida la propia edge function.
  PERFORM net.http_post(
    url     := rtrim(v_base, '/') || '/notificaciones-push',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_anon,
      'apikey',        v_anon,
      'x-push-secret', v_secret
    ),
    -- `app` es lo único que distingue este trigger del de clientes.
    body    := jsonb_build_object('id', NEW.id, 'app', 'agentes')
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.notificar_push_agente() IS
  'Dispara notificaciones-push con app=agentes al insertar en notificaciones_agente. Espejo de notificar_push_cliente().';

DROP TRIGGER IF EXISTS trg_notificaciones_agente_push ON public.notificaciones_agente;
CREATE TRIGGER trg_notificaciones_agente_push
  AFTER INSERT ON public.notificaciones_agente
  FOR EACH ROW EXECUTE FUNCTION public.notificar_push_agente();

COMMIT;

-- ─── Validación ───────────────────────────────────────────────────────────────
-- SELECT tgname, tgenabled, pg_get_triggerdef(oid)
-- FROM pg_trigger
-- WHERE tgrelid = 'public.notificaciones_agente'::regclass AND NOT tgisinternal;
--
-- SELECT key FROM private.sozu_config
-- WHERE key IN ('push_dispatch_secret','functions_base_url','supabase_anon_key');
--   -- Deben salir las 3. Si falta alguna, el trigger no envía y no avisa.
--
-- ─── UAT (sin datos residuales) ───────────────────────────────────────────────
-- BEGIN;
--   INSERT INTO public.notificaciones_agente
--     (email_agente, tipo, categoria, titulo, descripcion)
--   VALUES
--     ('<correo de un agente con dispositivo registrado>', 'informativa', 'general',
--      'Prueba de push', 'Si llega al teléfono, el trigger funciona.')
--   RETURNING id;
--   -- La llamada de pg_net es asíncrona: su resultado se consulta después del
--   -- COMMIT en net._http_response. Dentro de la transacción solo se comprueba
--   -- que el INSERT no falle.
-- ROLLBACK;
--
-- Para probarlo de verdad hay que dejar la fila (sin ROLLBACK) y luego:
--   SELECT status_code, content FROM net._http_response ORDER BY id DESC LIMIT 3;
-- Esperado: 200 con {"enviados": N}. `{"enviados":0,"motivo":"sin_dispositivos"}`
-- significa que el trigger sí disparó y que ese agente no tiene token todavía.
