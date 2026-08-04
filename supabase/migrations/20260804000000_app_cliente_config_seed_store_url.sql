-- Version gate del app de clientes: seed de la URL de la store (valor estable).
-- -----------------------------------------------------------------------------
-- La tabla public.app_cliente_config y la edge function cliente-app-version ya
-- existen (migración 20260713040000). Esta migración solo siembra el valor
-- ESTABLE del version gate: la URL de Google Play.
--
-- Los valores OPERATIVOS (min_version, latest_version, force_update,
-- update_message) NO se ponen aquí: cambian en cada release y se setean a mano
-- al publicar (ver Ejecuciones_manuales/20260803_version_gate_config.md). Por eso
-- este seed usa ON CONFLICT DO NOTHING: no pisa lo que se haya ajustado a mano.
--
-- iOS: la URL (apps.apple.com/app/idXXXXXXXXXX) se agrega cuando exista la app
-- publicada en App Store; por ahora se omite para no meter un id inválido.
-- -----------------------------------------------------------------------------

INSERT INTO public.app_cliente_config (key, value) VALUES
  ('android_store_url',
   'https://play.google.com/store/apps/details?id=com.sozu.clientes_app')
ON CONFLICT (key) DO NOTHING;
