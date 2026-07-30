-- Portal Bancos — branding por banco: columnas logo_url e icono_url en bancos_convenio
-- Fecha: 2026-07-30
--
-- NOTA: re-timestamp de 20260730050000 → 20260730140000. El timestamp original colisionó en
-- schema_migrations con otra migración (20260730050000_auditoria_secdef_sin_guarda_authz.sql)
-- ya aplicada a dev (SQLSTATE 23505 en el deploy del PR #491). Este archivo reemplaza al viejo.
--
-- La pantalla «Bancos» del Portal Bancos ya intenta guardar el branding del banco: sube el
-- archivo al bucket `documentos` y luego hace UPDATE bancos_convenio SET logo_url/icono_url,
-- que falla porque las columnas NO existen (imagen queda huérfana, botón sigue en «Subir»).
-- Además useBancosConvenio pide logo_url/icono_url en SEL_FULL; al fallar cae a SEL_BASE que
-- tampoco trae tasa_min/tasa_max/cat_min/cat_max — con estas columnas el portal recupera las tasas.
--
-- El branding va en `bancos_convenio` (no en `bancos`): es del convenio con SOZU, junto a
-- `color_marca`/`producto_nombre`/`orden`. `text` nulable sin default: NULL = «sin imagen»
-- (el front degrada a cuadro con color_marca + iniciales). Sin UPDATE de datos: las imágenes
-- ya subidas quedaron huérfanas por timestamp y no se re-asocian; hay que volver a subirlas.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS. Seguro en Preview y Producción. Sin BEGIN/COMMIT (CI/CD tx).

ALTER TABLE public.bancos_convenio
  ADD COLUMN IF NOT EXISTS logo_url  text,
  ADD COLUMN IF NOT EXISTS icono_url text;

COMMENT ON COLUMN public.bancos_convenio.logo_url IS
  'URL pública (bucket `documentos`) del logo ancho / wordmark del banco. NULL = usar color_marca.';
COMMENT ON COLUMN public.bancos_convenio.icono_url IS
  'URL pública (bucket `documentos`) de la marca cuadrada del banco, para listas compactas y header del portal. NULL = usar color_marca.';
COMMENT ON COLUMN public.bancos_convenio.color_marca IS
  'Color de marca del banco en #hex. Tematiza el Portal Bancos (--primary y derivados) para los usuarios de ese banco.';
