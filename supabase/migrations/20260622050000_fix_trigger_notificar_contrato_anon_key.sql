-- Fix: el trigger del contrato firmado usaba private.get_edge_function_key(), que
-- devuelve NULL en producción (private.sozu_config nunca se sembró) => net.http_post
-- nunca se ejecutaba y no se enviaba el correo.
--
-- Se cambia al patrón que SÍ funciona en prod (anon key hardcodeada, igual que
-- trigger_check_escrituracion). El anon key es un JWT válido y pasa el gateway
-- (verify_jwt) de la edge function; ésta usa su propio SERVICE_ROLE_KEY internamente.

CREATE OR REPLACE FUNCTION public.trigger_notificar_contrato_firmado()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_request_id BIGINT;
  v_supabase_url TEXT := 'https://tzmhgfjmddkfyffkkmto.supabase.co';
  v_anon_key TEXT := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR6bWhnZmptZGRrZnlmZmtrbXRvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTczNTU0NDUsImV4cCI6MjA3MjkzMTQ0NX0.8DaFtWO6zyJg14jFo_Zm2idYKwI-mvfmUtlixG2JDSE';
BEGIN
  IF NEW.id_tipo_documento = 18
     AND NEW.id_estatus_verificacion = 2
     AND (OLD.id_estatus_verificacion IS NULL OR OLD.id_estatus_verificacion <> 2)
     AND COALESCE(NEW.activo, true) = true THEN
    SELECT net.http_post(
      url     := v_supabase_url || '/functions/v1/notificar-contrato-firmado',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_anon_key),
      body    := jsonb_build_object('id_documento', NEW.id)
    ) INTO v_request_id;
  END IF;
  RETURN NEW;
END;
$function$;
