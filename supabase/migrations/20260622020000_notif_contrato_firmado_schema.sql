-- Notificación: "Contrato firmado por ambas partes"
-- DDL: columna de destinatarios configurables + función trigger + trigger.
-- Dispara cuando un documento tipo 18 (Contrato firmado) pasa a id_estatus_verificacion = 2 (Validado).
-- Patrón de llamada a edge function vía pg_net + private.get_edge_function_key()
-- (igual que 20260518000001_trigger_generar_factura_al_vender.sql).

-- 1. Columna para listas de destinatarios fijos por tipo de venta (editable por SQL sin redeploy).
ALTER TABLE public.notificaciones_configuracion
  ADD COLUMN IF NOT EXISTS destinatarios_extra jsonb;

-- 2. Función trigger: notifica al validar el contrato firmado por ambas partes.
CREATE OR REPLACE FUNCTION public.trigger_notificar_contrato_firmado()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_key TEXT;
BEGIN
  IF NEW.id_tipo_documento = 18
     AND NEW.id_estatus_verificacion = 2
     AND (OLD.id_estatus_verificacion IS NULL OR OLD.id_estatus_verificacion <> 2)
     AND COALESCE(NEW.activo, true) = true THEN

    v_key := private.get_edge_function_key();
    IF v_key IS NOT NULL THEN
      PERFORM net.http_post(
        url     := 'https://tzmhgfjmddkfyffkkmto.supabase.co/functions/v1/notificar-contrato-firmado',
        headers := jsonb_build_object(
          'Content-Type',  'application/json',
          'Authorization', 'Bearer ' || v_key
        ),
        body    := jsonb_build_object('id_documento', NEW.id)
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

-- 3. Trigger sobre documentos (AFTER UPDATE del estatus de verificación).
DROP TRIGGER IF EXISTS after_contrato_firmado_validado ON public.documentos;
CREATE TRIGGER after_contrato_firmado_validado
  AFTER UPDATE OF id_estatus_verificacion ON public.documentos
  FOR EACH ROW EXECUTE FUNCTION public.trigger_notificar_contrato_firmado();
