-- app_cliente_config · seed del version gate (edge cliente-app-version)
-- Fecha: 2026-07-28
--
-- Seed de keys que consume la edge cliente-app-version + el version gate del app cliente.
-- Tabla app_cliente_config (key text PK, value text, fecha_actualizacion) YA existe — sin
-- cambios de esquema, solo filas.
--   min_version      → si instalada < min: forzar actualización (bloqueante).
--   latest_version   → si instalada < latest (y ≥ min): aviso soft descartable.
--   force_update     → 'true' fuerza aunque cumpla min (push urgente). Normal 'false'.
--   android_store_url / ios_store_url → link por plataforma (botón oculto si vacío).
--   update_message   → texto opcional (vacío = default del app).
--
-- Upsert idempotente ON CONFLICT (key). Operación posterior (forzar/sugerir versión) se hace
-- actualizando estos valores, sin redeploy. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

INSERT INTO public.app_cliente_config (key, value, fecha_actualizacion) VALUES
  ('min_version',       '1.0.0', now()),
  ('latest_version',    '1.0.0', now()),
  ('force_update',      'false', now()),
  ('android_store_url', 'https://play.google.com/store/apps/details?id=com.sozu.clientes_app', now()),
  ('ios_store_url',     '', now()),
  ('update_message',    '', now())
ON CONFLICT (key) DO UPDATE
  SET value = EXCLUDED.value, fecha_actualizacion = now();
