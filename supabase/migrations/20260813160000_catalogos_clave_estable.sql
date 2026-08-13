-- =============================================================================
-- Catálogos: `clave` estable para que el código no dependa del id ni del nombre
-- =============================================================================
-- Hoy el código referencia los catálogos de dos formas, y las dos se rompen:
--
--   · Por id — se rompe entre entornos. Los ids de `tipos_documento` divergieron:
--       nombre                                 prod   dev
--       Identificación oficial                   53    59
--       Convenio de Embajador firmado            54    58
--       Datos bancarios                          55    60
--       Nota de crédito                          66    71
--       Evidencia de devolución                  67    72
--       Comprobante de transferencia al cliente  68    73
--       Otros documentos                         69    74
--       Beneficiario Controlador                 64    (no existe)
--       Verificacion Antilavado                  65    (no existe)
--     `antilavadoService.ts` cablea `id_tipo_documento = 65`, que en dev no existe.
--     No es un riesgo futuro: ya está roto.
--
--   · Por nombre — se rompe con un rename, y el nombre es texto de UI: lleva acentos,
--     mayúsculas y erratas vivas ("Verificacion Antilavado", "Factura de comision de
--     venta Sozu"). Corregir una errata no debería tumbar el front.
--
-- La salida es la tercera: una `clave` inmutable, separada del id (que es interno de la
-- BD y de sus FKs) y del `nombre` (que es texto de UI y puede cambiar). El código
-- referencia la clave y deja de importarle el id.
--
-- Esta migración NO realinea los ids divergentes: eso toca `documentos` y va aparte,
-- con su propio mapeo y su propia decisión.
--
-- ─── Verificado read-only el 2026-08-13 ──────────────────────────────────────
-- · Ni `tipos_documento` ni `tipos_relacion` tienen columna clave/codigo/slug.
-- · `tipos_documento` lo referencian por FK `documentos` y
--   `tabla_carga_documentos_propiedades_n8n`; el id se queda como está.
-- · La extensión `unaccent` NO está instalada, así que las claves se asignan a mano por
--   llave natural, no se autogeneran desde el nombre.
-- · prod tiene 63 tipos de documento, dev 61.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1. La columna
-- -----------------------------------------------------------------------------
ALTER TABLE public.tipos_documento ADD COLUMN IF NOT EXISTS clave text;
ALTER TABLE public.tipos_relacion  ADD COLUMN IF NOT EXISTS clave text;

-- Formato cerrado: A-Z, dígitos y guion bajo. Sin acentos, sin espacios, sin minúsculas.
-- Así la clave nunca hereda los problemas del nombre.
ALTER TABLE public.tipos_documento DROP CONSTRAINT IF EXISTS tipos_documento_clave_formato;
ALTER TABLE public.tipos_documento
  ADD CONSTRAINT tipos_documento_clave_formato
  CHECK (clave IS NULL OR clave ~ '^[A-Z][A-Z0-9_]*$');

ALTER TABLE public.tipos_relacion DROP CONSTRAINT IF EXISTS tipos_relacion_clave_formato;
ALTER TABLE public.tipos_relacion
  ADD CONSTRAINT tipos_relacion_clave_formato
  CHECK (clave IS NULL OR clave ~ '^[A-Z][A-Z0-9_]*$');

-- UNIQUE parcial: permite que convivan filas sin clave mientras se termina el backfill,
-- pero dos filas nunca comparten la misma.
CREATE UNIQUE INDEX IF NOT EXISTS tipos_documento_clave_uniq
  ON public.tipos_documento (clave) WHERE clave IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS tipos_relacion_clave_uniq
  ON public.tipos_relacion (clave) WHERE clave IS NOT NULL;

COMMENT ON COLUMN public.tipos_documento.clave IS
  'Identificador estable para el código. Inmutable una vez asignado. Es el ÚNICO '
  'contrato con el backend: el id es interno de la BD y difiere entre entornos, y el '
  'nombre es texto de UI y puede cambiar.';
COMMENT ON COLUMN public.tipos_relacion.clave IS
  'Identificador estable para el código. Inmutable una vez asignado. Ver tipos_documento.clave.';

-- -----------------------------------------------------------------------------
-- §2. Inmutabilidad
-- -----------------------------------------------------------------------------
-- Sin esto la clave es solo otro nombre: alguien la "corrige" y rompe el código igual.
-- Se puede asignar (NULL → valor) pero nunca cambiar ni borrar.
CREATE OR REPLACE FUNCTION public.fn_clave_catalogo_inmutable()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.clave IS NOT NULL AND NEW.clave IS DISTINCT FROM OLD.clave THEN
    RAISE EXCEPTION
      'La clave de catálogo es inmutable: % ya tiene clave "%" y no puede pasar a "%". '
      'Para retirar un elemento se usa activo = false, no se recicla su clave.',
      TG_TABLE_NAME, OLD.clave, NEW.clave
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_clave_catalogo_inmutable() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_clave_catalogo_inmutable() FROM anon;
REVOKE ALL ON FUNCTION public.fn_clave_catalogo_inmutable() FROM authenticated;

DROP TRIGGER IF EXISTS trg_tipos_documento_clave_inmutable ON public.tipos_documento;
CREATE TRIGGER trg_tipos_documento_clave_inmutable
  BEFORE UPDATE ON public.tipos_documento
  FOR EACH ROW EXECUTE FUNCTION public.fn_clave_catalogo_inmutable();

DROP TRIGGER IF EXISTS trg_tipos_relacion_clave_inmutable ON public.tipos_relacion;
CREATE TRIGGER trg_tipos_relacion_clave_inmutable
  BEFORE UPDATE ON public.tipos_relacion
  FOR EACH ROW EXECUTE FUNCTION public.fn_clave_catalogo_inmutable();

-- -----------------------------------------------------------------------------
-- §3. Backfill de las claves que el código necesita hoy
-- -----------------------------------------------------------------------------
-- Se ancla por nombre —única llave natural disponible ahora mismo— y solo esta vez.
-- A partir de aquí el ancla es la clave. Cada UPDATE es idempotente (`clave IS NULL`) y
-- no falla si la fila no existe en ese entorno: en dev faltan 'Beneficiario Controlador'
-- y 'Verificacion Antilavado', y esta migración no los inventa.
--
-- Las claves NO se autogeneran desde el nombre a propósito: `unaccent` no está instalada
-- y, sobre todo, una clave derivada del nombre volvería a moverse cuando el nombre cambie.
DO $backfill$
DECLARE
  v_par text[];
  v_mapa text[][] := ARRAY[
    -- [nombre exacto en el catálogo, clave]
    ['Constancia de situación fiscal',                                  'CSF'],
    ['Frente INE',                                                      'INE_FRENTE'],
    ['Reverso INE',                                                     'INE_REVERSO'],
    ['INE completo (frente y reverso)',                                 'INE_COMPLETO'],
    ['Identificación oficial',                                          'IDENTIFICACION_OFICIAL'],
    ['CURP',                                                            'CURP'],
    ['Acta de nacimiento',                                              'ACTA_NACIMIENTO'],
    ['Comprobante de domicilio',                                        'COMPROBANTE_DOMICILIO'],
    ['Acta constitutiva',                                               'ACTA_CONSTITUTIVA'],
    ['Poder notarial representante legal',                              'PODER_NOTARIAL_REP_LEGAL'],
    ['Reformas, modificaciones y protocolizaciones posteriores al acta constitutiva',
                                                                        'REFORMAS_ACTA'],
    ['Otros documentos',                                                'OTROS_DOCUMENTOS'],
    ['Datos bancarios',                                                 'DATOS_BANCARIOS'],
    ['Beneficiario Controlador',                                        'BENEFICIARIO_CONTROLADOR'],
    ['Verificacion Antilavado',                                         'VERIFICACION_ANTILAVADO'],
    ['Factura XML',                                                     'FACTURA_XML'],
    ['Factura PDF',                                                     'FACTURA_PDF'],
    ['Factura de comisión externa',                                     'FACTURA_COMISION_EXTERNA'],
    ['Archivo de notificación al SAT',                                  'SAT_ARCHIVO_NOTIFICACION'],
    ['Acuse de notificación al SAT',                                    'SAT_ACUSE_NOTIFICACION'],
    ['Proyecto de escritura',                                           'PROYECTO_ESCRITURA'],
    ['Escritura',                                                       'ESCRITURA'],
    ['Brochure',                                                        'BROCHURE'],
    ['Ficha Técnica',                                                   'FICHA_TECNICA'],
    ['Contrato firmado completamente',                                  'CONTRATO_FIRMADO_COMPLETO'],
    ['Contrato firmado por cliente',                                    'CONTRATO_FIRMADO_CLIENTE'],
    ['Comprobante de pago',                                             'COMPROBANTE_PAGO'],
    ['Nota de crédito',                                                 'NOTA_CREDITO'],
    ['Evidencia de devolución',                                         'EVIDENCIA_DEVOLUCION'],
    ['Comprobante de transferencia al cliente',                         'TRANSFERENCIA_AL_CLIENTE']
  ];
  v_puestas int := 0;
  v_faltan  text := '';
BEGIN
  FOREACH v_par SLICE 1 IN ARRAY v_mapa
  LOOP
    UPDATE public.tipos_documento
       SET clave = v_par[2]
     WHERE nombre = v_par[1]
       AND clave IS NULL;

    IF FOUND THEN
      v_puestas := v_puestas + 1;
    ELSIF NOT EXISTS (SELECT 1 FROM public.tipos_documento WHERE nombre = v_par[1]) THEN
      v_faltan := v_faltan || v_par[1] || '; ';
    END IF;
  END LOOP;

  RAISE NOTICE 'tipos_documento: % claves asignadas', v_puestas;

  IF v_faltan <> '' THEN
    RAISE NOTICE 'tipos_documento: estos nombres no existen en este entorno y quedan sin clave → %', v_faltan;
  END IF;
END;
$backfill$;

UPDATE public.tipos_relacion SET clave = 'REPRESENTANTE_LEGAL'
 WHERE nombre = 'Representante Legal' AND clave IS NULL;

UPDATE public.tipos_relacion SET clave = 'ACCIONISTA'
 WHERE nombre = 'Accionista' AND clave IS NULL;

-- -----------------------------------------------------------------------------
-- §4. Self-verifying: las claves que el código va a usar ya tienen que existir
-- -----------------------------------------------------------------------------
DO $check$
DECLARE
  v_falta text;
BEGIN
  SELECT string_agg(c, ', ')
    INTO v_falta
  FROM unnest(ARRAY['CSF', 'OTROS_DOCUMENTOS', 'REFORMAS_ACTA', 'ACTA_CONSTITUTIVA']) c
  WHERE NOT EXISTS (SELECT 1 FROM public.tipos_documento t WHERE t.clave = c);

  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Faltan claves obligatorias en tipos_documento: %', v_falta;
  END IF;

  SELECT string_agg(c, ', ')
    INTO v_falta
  FROM unnest(ARRAY['REPRESENTANTE_LEGAL', 'ACCIONISTA']) c
  WHERE NOT EXISTS (SELECT 1 FROM public.tipos_relacion t WHERE t.clave = c);

  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Faltan claves obligatorias en tipos_relacion: %', v_falta;
  END IF;
END;
$check$;

COMMIT;

-- =============================================================================
-- Verificación (read-only, correr después del deploy)
-- =============================================================================
-- SELECT clave, id, nombre FROM public.tipos_documento WHERE clave IS NOT NULL ORDER BY clave;
-- SELECT clave, id, nombre FROM public.tipos_relacion  WHERE clave IS NOT NULL ORDER BY clave;
--
-- -- Lo que falta por catalogar (se va llenando conforme el código lo necesite):
-- SELECT id, nombre FROM public.tipos_documento WHERE clave IS NULL ORDER BY id;
--
-- -- La clave no se puede cambiar (esperado: 23514):
-- --   UPDATE public.tipos_documento SET clave = 'OTRA' WHERE clave = 'CSF';
--
-- Siguiente paso, en otra migración: cuando ya no quede ninguna fila con clave NULL,
-- pasar la columna a NOT NULL y cambiar el índice parcial por un UNIQUE normal.
-- =============================================================================
