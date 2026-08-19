-- Activos comerciales que no pertenecen a un desarrollo
-- Fecha: 2026-08-18
-- Origen: Ejecuciones/ejecusiones.md (segunda parte)
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- `propiedades.id_edificio_modelo` deja de ser obligatoria. Hoy toda propiedad tiene que
-- colgar de un edificio y un modelo, y para una oficina en un edificio ajeno o un terreno
-- suelto no existe tal cosa.
--
-- No se elimina la restriccion para las unidades de desarrollo: una propiedad dentro de un
-- proyecto sigue necesitando su edificio y modelo. Lo que cambia es que deja de ser
-- obligatorio para TODAS. Quien lo exige ahora es
-- `crear_activo_comercial` (20260818120000), segun el tipo y segun lo que declare el
-- payload.
--
-- ─── Por qué el prefijo es 143700 y no 110000 ─────────────────────────────────
-- Este archivo nacio como 20260818110000 y colisiono con
-- 20260818110000_inventario_filtro_estacionamientos.sql, que entro a dev por otro PR con
-- el mismo prefijo. Los 14 digitos son la `version` y la PK de
-- supabase_migrations.schema_migrations, asi que el segundo en aplicarse revienta. El SQL
-- llego a ejecutarse (el NOTICE reporto la columna ya nullable) pero se revirtio con la
-- transaccion: la columna sigue NOT NULL. NO renombrar de vuelta.
--
-- ─── Por qué este archivo va ANTES que el de las funciones ────────────────────
-- El documento lista el orden inverso (primero alta-draft, luego activos sin desarrollo),
-- que es el correcto si se aplican en dias distintos. Aplicandose en el mismo deploy el
-- orden seguro es el contrario: si la funcion que acepta un activo suelto entrara primero,
-- entre una migracion y otra un alta sin edificio reventaria contra el NOT NULL. Con la
-- columna ya nullable, la funcion nunca acepta algo que la columna rechace.
--
-- ─── Riesgo asumido, del propio documento ─────────────────────────────────────
-- El cambio es acotado —una columna pasa a admitir NULL— pero su superficie no lo es:
-- 44 funciones y 2 vistas (vw_unidad_por_cuenta, v_pagos_detalle) leen esa columna.
-- Ninguna deja de funcionar por un NULL (los JOIN simplemente no encuentran fila), pero un
-- activo sin desarrollo NO APARECERA en nada que agrupe por proyecto. Eso es correcto por
-- definicion —no pertenece a ninguno— pero conviene revisarlo con quien mantiene los
-- reportes antes de aplicarlo en Produccion.
--
-- Tambien conviene saber que quitar un NOT NULL es facil y reponerlo no: volver atras
-- exigiria limpiar o rellenar las filas que hayan quedado en NULL.
--
-- ─── El UNIQUE existente deja un hueco ────────────────────────────────────────
-- `uq_prop_por_edificio_numero UNIQUE (id_edificio_modelo, numero_propiedad)` no protege a
-- los activos sueltos: en PostgreSQL dos NULL no colisionan, asi que (NULL, 'OFN-1') y
-- (NULL, 'OFN-1') convivirian. El indice parcial de la seccion 2 cubre ese hueco.
--
-- Verificado contra el baseline del repo: `id_edificio_modelo integer NOT NULL` sin
-- default, `numero_propiedad text NOT NULL`, `activo boolean NOT NULL DEFAULT true`, y la
-- constraint uq_prop_por_edificio_numero existe (baseline linea 2654).
--
-- Idempotente: DROP NOT NULL sobre una columna ya nullable no falla, y el indice va con
-- IF NOT EXISTS. Sin BEGIN/COMMIT (el CI envuelve cada archivo).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. La columna deja de ser obligatoria
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.propiedades
  ALTER COLUMN id_edificio_modelo DROP NOT NULL;

COMMENT ON COLUMN public.propiedades.id_edificio_modelo IS
  'Vinculo con edificios_modelos. NULL solo para activos comerciales que no pertenecen a '
  'un desarrollo (locales, oficinas y bodegas independientes, y terrenos). Las unidades de '
  'proyecto siguen exigiendolo: lo valida crear_activo_comercial, no un CHECK, para que '
  'cambiar la regla de negocio no obligue a un ALTER TABLE.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Unicidad del número para los activos sueltos
--    Cubre el hueco que deja uq_prop_por_edificio_numero cuando id_edificio_modelo es NULL.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $guard$
DECLARE
  v_dups bigint;
BEGIN
  SELECT count(*) INTO v_dups FROM (
    SELECT 1 FROM public.propiedades
    WHERE id_edificio_modelo IS NULL AND activo
    GROUP BY numero_propiedad HAVING count(*) > 1
  ) d;

  IF v_dups > 0 THEN
    RAISE EXCEPTION
      'Hay % numero(s) de propiedad repetidos entre activos sueltos y activos; el indice unico no se puede crear. Resolver antes de reintentar.',
      v_dups;
  END IF;
END
$guard$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_prop_sin_edificio_numero
  ON public.propiedades (numero_propiedad)
  WHERE id_edificio_modelo IS NULL AND activo;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. Reporte: ninguna propiedad existente pierde su vínculo
-- ═══════════════════════════════════════════════════════════════════════════════
DO $reporte$
DECLARE
  v_nullable text;
  v_sueltas  bigint;
BEGIN
  SELECT is_nullable INTO v_nullable
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'propiedades'
    AND column_name = 'id_edificio_modelo';

  IF v_nullable <> 'YES' THEN
    RAISE EXCEPTION 'id_edificio_modelo sigue siendo NOT NULL: el ALTER no surtio efecto.';
  END IF;

  SELECT count(*) INTO v_sueltas
  FROM public.propiedades WHERE id_edificio_modelo IS NULL;

  RAISE NOTICE
    'propiedades.id_edificio_modelo ahora admite NULL. Propiedades sin edificio/modelo: % (esperado 0 justo despues de aplicar).',
    v_sueltas;
END
$reporte$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT is_nullable FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='propiedades'
--     AND column_name='id_edificio_modelo';
--   -- esperado: YES
--
--   SELECT indexdef FROM pg_indexes
--   WHERE schemaname='public' AND indexname='uq_prop_sin_edificio_numero';
--   -- esperado: UNIQUE ... (numero_propiedad) WHERE id_edificio_modelo IS NULL AND activo
--
--   SELECT count(*) AS sin_edificio_modelo
--   FROM public.propiedades WHERE id_edificio_modelo IS NULL;
--   -- esperado: 0 justo despues de aplicar
--
-- Las dos FK duplicadas hacia edificios_modelos (fk_propiedades_edificio_modelo y
-- propiedades_id_edificio_modelo_fkey, ambas ON UPDATE CASCADE ON DELETE RESTRICT) siguen
-- ahi: el documento las detecta pero decide no tocarlas, y este archivo respeta eso.
