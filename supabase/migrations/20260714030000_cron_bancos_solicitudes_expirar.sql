-- Cron: bancos-solicitudes-expirar
-- Fecha: 2026-07-14
--
-- Cada hora invoca la edge function bancos-solicitudes-expirar, que marca solicitudes de
-- crédito vencidas (estatus='expirada'), notifica al cliente y libera el índice único
-- parcial uq_bancos_solicitudes_vigente (permite cambio de banco).
--
-- Reubicado desde sozu-edge-functions/supabase/migrations (las migraciones viven aquí).
-- Se corrige la versión original que hardcodeaba URL/anon de prod (en dev llamaría a prod):
-- la URL base y la anon key se leen de private.sozu_config (functions_base_url,
-- supabase_anon_key), igual que procesar_avisos_app / notificar_push_cliente. Si faltan,
-- no dispara (no genera URL nula). Poblar sozu_config por ambiente para activar.
--
-- Idempotente: CREATE EXTENSION IF NOT EXISTS, CREATE OR REPLACE, unschedule+schedule por
-- nombre. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION public.disparar_bancos_solicitudes_expirar()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_base text;
  v_anon text;
BEGIN
  SELECT value INTO v_base FROM private.sozu_config WHERE key = 'functions_base_url';
  SELECT value INTO v_anon FROM private.sozu_config WHERE key = 'supabase_anon_key';

  -- Sin config → no disparar (evita URL nula / header sin token).
  IF v_base IS NULL OR v_anon IS NULL THEN
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := rtrim(v_base, '/') || '/bancos-solicitudes-expirar',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_anon,
      'apikey',        v_anon
    ),
    body    := '{}'::jsonb
  );
END;
$$;

-- Reprogramar de forma idempotente.
DO $$
BEGIN
  PERFORM cron.unschedule('bancos-solicitudes-expirar');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

SELECT cron.schedule(
  'bancos-solicitudes-expirar',
  '0 * * * *',
  $$SELECT public.disparar_bancos_solicitudes_expirar()$$
);
