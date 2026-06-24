-- Notificación al SUBIR (INSERT) un documento legal: dispara cuando se inserta un
-- documento tipo 18 (Contrato firmado completamente) o 56 (Convenio modificatorio),
-- invocando la edge function notificar-documento-subido.
--
-- Usa anon key hardcodeada (NO private.get_edge_function_key(), que es NULL en prod;
-- ver trigger_check_escrituracion). El anon key es JWT válido y pasa el gateway.

CREATE OR REPLACE FUNCTION public.trigger_notificar_documento_legal()
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
  IF NEW.id_tipo_documento IN (18, 56)
     AND COALESCE(NEW.activo, true) = true THEN
    SELECT net.http_post(
      url     := v_supabase_url || '/functions/v1/notificar-documento-subido',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_anon_key),
      body    := jsonb_build_object('id_documento', NEW.id, 'tipo_evento', 'documento_legal_subido')
    ) INTO v_request_id;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS after_documento_legal_subido ON public.documentos;
CREATE TRIGGER after_documento_legal_subido
  AFTER INSERT ON public.documentos
  FOR EACH ROW EXECUTE FUNCTION public.trigger_notificar_documento_legal();
