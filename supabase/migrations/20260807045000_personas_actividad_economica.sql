-- Portal del Cliente — dónde guardar la actividad económica de la CSF
-- Fecha: 2026-08-07
--
-- La Constancia de Situación Fiscal trae la sección «Actividades Económicas». El Portal del
-- Cliente ya extrae los datos de la CSF y se los muestra al cliente para que los confirme
-- antes de subir el archivo; todos los demás campos de esa pantalla tienen columna en
-- `personas`, la actividad económica no, así que hoy el dato se pierde.
--
-- ─── Verificado read-only contra prod (tzmhgfjmddkfyffkkmto, 2026-08-07) ──────
--   * `personas` tiene 53 columnas y NINGUNA de actividad, giro o similar.
--   * No hay catálogo que reutilizar: la tabla `actividades` es el catálogo del log de
--     auditoría (CREAR, ACTUALIZAR, VER…) que consume `logs_actividad`; nada que ver con el SAT.
--   * `personas.ocupacion` es otro concepto —ocupación libre del titular, 455 filas con valor:
--     Comerciante, Empresario/a, Empleado/a…— y NO se reutiliza. Además existe
--     `_bak_personas_ocupacion_20260722`, respaldo de una normalización previa: esa columna ya
--     se tocó una vez y mezclarle un segundo concepto la vuelve a ensuciar.
--
-- Texto libre y sin catálogo a propósito: la CSF trae la actividad como texto del SAT
-- («Compra-venta de bienes raíces», «Servicios de contabilidad…») y en el PDF no hay una clave
-- estable con la que amarrar un catálogo. Guardar el texto y normalizarlo después es
-- reversible; inventar hoy una tabla de claves no lo es.
--
-- Sin default, sin backfill y sin índice: nadie filtra por ella todavía.
-- La escribe SOLO la Edge Function `cliente-expediente` al confirmar la CSF, con el valor que
-- el cliente aceptó. Ningún trigger, ningún proceso automático. Hoy no la lee nadie: se agrega
-- para que el dato deje de perderse.
--
-- No bloquea nada: mientras la columna no exista, la Edge Function manda la actividad con
-- `solo_lectura: true` y el app la muestra deshabilitada.
--
-- Idempotente (ADD COLUMN IF NOT EXISTS). Sin BEGIN/COMMIT (el CI envuelve en transacción).

ALTER TABLE public.personas
  ADD COLUMN IF NOT EXISTS actividad_economica text;

COMMENT ON COLUMN public.personas.actividad_economica IS
  'Actividad económica declarada en la Constancia de Situación Fiscal del SAT, tal cual la '
  'reporta el documento. Texto libre: el PDF no trae una clave estable con la que amarrar un '
  'catálogo. Distinta de `ocupacion`, que es la ocupación libre del titular. La escribe solo '
  'la Edge Function cliente-expediente cuando el cliente confirma los datos de su CSF.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'personas'
      AND column_name = 'actividad_economica' AND data_type = 'text' AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION 'personas.actividad_economica no quedó como text NULL';
  END IF;
END $$;

-- Rollback (sin dependencias: nada la lee):
--   ALTER TABLE public.personas DROP COLUMN IF EXISTS actividad_economica;
