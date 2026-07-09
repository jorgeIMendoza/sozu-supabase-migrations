-- Canal de envío configurable por aviso (email / whatsapp / ambos).
-- Hasta ahora el canal solo existía para avisos automáticos por evento
-- (avisos_triggers_evento.canal); los avisos manuales y cron no tenían
-- forma de elegir canal y enviar-aviso-bulk decidía por su cuenta.
-- NULL = comportamiento legacy (consolidado → email con metadata WA;
-- personalizado → email y/o WhatsApp según datos del destinatario).

ALTER TABLE public.avisos
  ADD COLUMN IF NOT EXISTS canal text
  CHECK (canal IS NULL OR canal IN ('email', 'whatsapp', 'ambos'));

COMMENT ON COLUMN public.avisos.canal IS
  'Canal de envío del aviso: email, whatsapp o ambos. NULL = comportamiento legacy previo a la columna.';
