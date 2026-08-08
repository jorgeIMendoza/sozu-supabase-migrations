-- Homologación CRM ↔ Portal Agente — 02: crm_negocios al grano de la unidad
-- Fecha: 2026-08-07
--
-- Hoy un negocio significa «esta persona en este proyecto», porque `entidades_relacionadas`
-- no tiene `id_propiedad`. Por eso no se puede expresar «comprador del 411 y prospecto del
-- 412». Este archivo le da a `crm_negocios` las columnas que lo atan a la UNIDAD.
--
-- Solo estructura + saneo mínimo. **Los negocios los crea el 05**, no este archivo: aquí
-- ningún negocio recibe unidad.
--
-- ─── Decisiones heredadas del documento, que se sostienen contra prod ─────────
--   * La llave del negocio es (contacto, unidad), no la oferta: una unidad se recotiza N
--     veces y con la oferta como llave habría miles de negocios en vez de uno por unidad.
--     `id_oferta` es la oferta representativa y por eso NO entra en los únicos.
--   * Los únicos son parciales y exigen `id_entidad_relacionada IS NOT NULL`: hay pares
--     (persona, unidad) cuyo lead no tiene entidad tipo 7 en ese proyecto. El 05 crea el
--     contacto faltante ANTES del negocio, para que la llave siempre esté completa.
--   * `requiere_triage` marca lo que necesita intervención humana —sin contacto, o colgado
--     de una entidad tipo 2 sin equivalente—, NO «sin oferta»: un negocio sin oferta es el
--     estado normal de algo que todavía no cotiza, y marcarlo llenaría la pantalla de
--     Asignación con casi todo el universo.
--   * `ofertas_count` arranca en 0: un negocio sin oferta no puede declarar que tiene una.
--   * NO se crean índices para `id_entidad_relacionada` ni `id_usuario_propietario`: ya
--     existen como `idx_crm_negocios_er` e `idx_crm_negocios_propietario`.
--
-- ─── Verificado read-only contra prod (tzmhgfjmddkfyffkkmto, 2026-08-07) ──────
--   * Ninguna de las 5 columnas existe todavía. `id_pipeline` e `id_etapa` son NOT NULL, así
--     que todo INSERT debe traerlos (importa para el 05 y para el UAT).
--   * Tipos confirmados: `propiedades.id` y `entidades_relacionadas.id` son bigint;
--     `ofertas.id` y `productos_servicios.id` son integer.
--   * 1,972 negocios activos: 1,279 sobre entidad tipo 7, **20 sobre tipo 2**, 673 sin
--     ninguna liga a contacto, 0 colgados de otro tipo de entidad. (El documento traía
--     1,943 / 19 / 662 del 3-ago; la base creció, el reparto no cambió.)
--   * De los 20 sobre tipo 2: **3** tienen exactamente una entidad tipo 7 equivalente y se
--     reapuntan; **17** no tienen ninguna y se quedan, marcados para triage. Cero ambiguos.
--   * Triage esperado tras este archivo: 673 + 17 = **690**.
--   * Los únicos parciales no pueden fallar al crearse: `id_propiedad` e `id_producto` nacen
--     en NULL y el índice excluye NULL.
--
-- ─── Corrección al paso 3 del documento ──────────────────────────────────────
-- El documento emparejaba proyectos con `er7.id_proyecto IS NOT DISTINCT FROM er2.id_proyecto`.
-- En prod, **17 de esas 20 entidades tipo 2 tienen `id_proyecto` NULL**, y hay **2,275
-- entidades tipo 7 activas también con proyecto NULL**: `IS NOT DISTINCT FROM` hace que
-- NULL empate con NULL, así que un negocio podría reapuntarse a una entidad tipo 7 que no es
-- «su equivalente en ese proyecto», sino otra fila sin proyecto de la misma persona. Hoy no
-- pasa por azar (esas 17 personas no tienen tipo 7 sin proyecto), no por diseño.
-- Aquí se exige proyecto real en ambos lados. Resultado idéntico hoy —3 reapuntes, 17 se
-- quedan— y sin la trampa.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS y UPDATEs convergentes.
-- Sin BEGIN/COMMIT (el CI envuelve cada migración en transacción).

-- ─────────────────────────────────────────────────────────────────────
-- 1. Columnas del grano de unidad
-- ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.crm_negocios
  ADD COLUMN IF NOT EXISTS id_propiedad     bigint  REFERENCES public.propiedades(id),
  ADD COLUMN IF NOT EXISTS id_producto      integer REFERENCES public.productos_servicios(id),
  ADD COLUMN IF NOT EXISTS id_oferta        integer REFERENCES public.ofertas(id),
  ADD COLUMN IF NOT EXISTS ofertas_count    integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS requiere_triage  boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.crm_negocios.id_propiedad IS
  'Unidad del negocio. Junto con id_entidad_relacionada es la LLAVE del negocio. NULL si es de producto.';
COMMENT ON COLUMN public.crm_negocios.id_producto IS
  'Producto (bodega/estacionamiento/paquete) del negocio. Alternativa a id_propiedad.';
COMMENT ON COLUMN public.crm_negocios.id_oferta IS
  'Oferta representativa: la más avanzada y, a igualdad, la más reciente. NO es llave: una unidad se recotiza N veces.';
COMMENT ON COLUMN public.crm_negocios.ofertas_count IS
  'Ofertas activas sobre esta unidad. 0 = negocio sin cotizar todavía. Lo mantiene el trigger del archivo 05.';
COMMENT ON COLUMN public.crm_negocios.requiere_triage IS
  'true = negocio heredado sin liga confiable a contacto. Se resuelve a mano en CRM > Asignación. NO significa "sin oferta".';

-- ─────────────────────────────────────────────────────────────────────
-- 2. Llave real: un negocio activo por (contacto, unidad)
-- ─────────────────────────────────────────────────────────────────────
CREATE UNIQUE INDEX IF NOT EXISTS crm_negocios_unidad_uk
  ON public.crm_negocios (id_entidad_relacionada, id_propiedad)
  WHERE activo AND id_propiedad IS NOT NULL AND id_entidad_relacionada IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS crm_negocios_producto_uk
  ON public.crm_negocios (id_entidad_relacionada, id_producto)
  WHERE activo AND id_producto IS NOT NULL AND id_entidad_relacionada IS NOT NULL;

CREATE INDEX IF NOT EXISTS crm_negocios_oferta_idx
  ON public.crm_negocios (id_oferta) WHERE activo AND id_oferta IS NOT NULL;
CREATE INDEX IF NOT EXISTS crm_negocios_propiedad_idx
  ON public.crm_negocios (id_propiedad) WHERE activo;
CREATE INDEX IF NOT EXISTS crm_negocios_triage_idx
  ON public.crm_negocios (requiere_triage) WHERE activo AND requiere_triage;

-- ─────────────────────────────────────────────────────────────────────
-- 3. Reapuntar los negocios colgados de una entidad tipo 2 (3 casos en prod).
--    Solo cuando la persona tiene EXACTAMENTE una entidad tipo 7 activa en ESE proyecto,
--    con proyecto real en ambos lados (ver «Corrección al paso 3» arriba).
-- ─────────────────────────────────────────────────────────────────────
WITH candidatos AS (
  SELECT n.id AS id_negocio, min(er7.id) AS id_er7
  FROM public.crm_negocios n
  JOIN public.entidades_relacionadas er2
    ON er2.id = n.id_entidad_relacionada AND er2.id_tipo_entidad = 2
  JOIN public.entidades_relacionadas er7
    ON er7.activo AND er7.id_tipo_entidad = 7
   AND er7.id_persona  = er2.id_persona
   AND er2.id_proyecto IS NOT NULL
   AND er7.id_proyecto = er2.id_proyecto
  WHERE n.activo
  GROUP BY n.id
  HAVING count(*) = 1          -- una sola entidad tipo 7 candidata
)
UPDATE public.crm_negocios n
SET id_entidad_relacionada = c.id_er7
FROM candidatos c
WHERE n.id = c.id_negocio;

-- ─────────────────────────────────────────────────────────────────────
-- 4. Triage: solo lo que de verdad necesita intervención humana (690 en prod)
--      · 673 negocios sin contacto
--      · 17 que siguen sobre una entidad tipo 2 sin equivalente tipo 7
--    Corre DESPUÉS del paso 3, para no marcar los 3 que sí se reapuntaron.
-- ─────────────────────────────────────────────────────────────────────
UPDATE public.crm_negocios n
SET requiere_triage = true
WHERE n.activo
  AND NOT n.requiere_triage
  AND (
    n.id_entidad_relacionada IS NULL
    OR EXISTS (SELECT 1 FROM public.entidades_relacionadas er
               WHERE er.id = n.id_entidad_relacionada AND er.id_tipo_entidad = 2)
  );

-- ─────────────────────────────────────────────────────────────────────
-- 5. Self-verifying: aborta si la estructura o los datos quedaron a medias
-- ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_cols int; v_t2_sin_flag bigint; v_sin_contacto_sin_flag bigint;
BEGIN
  SELECT count(*) INTO v_cols FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'crm_negocios'
    AND column_name IN ('id_propiedad','id_producto','id_oferta','ofertas_count','requiere_triage');
  IF v_cols <> 5 THEN
    RAISE EXCEPTION 'Faltan columnas en crm_negocios (encontradas %/5)', v_cols;
  END IF;

  IF to_regclass('public.crm_negocios_unidad_uk')   IS NULL
  OR to_regclass('public.crm_negocios_producto_uk') IS NULL THEN
    RAISE EXCEPTION 'Faltan los índices únicos de unidad/producto';
  END IF;

  -- Los que siguen sobre entidad tipo 2 son los que no tenían equivalente: se aceptan,
  -- pero TIENEN que quedar marcados para triage.
  SELECT count(*) INTO v_t2_sin_flag
  FROM public.crm_negocios n
  JOIN public.entidades_relacionadas er ON er.id = n.id_entidad_relacionada
  WHERE n.activo AND er.id_tipo_entidad = 2 AND NOT n.requiere_triage;
  IF v_t2_sin_flag > 0 THEN
    RAISE EXCEPTION 'Hay % negocios sobre entidad tipo 2 sin requiere_triage', v_t2_sin_flag;
  END IF;

  SELECT count(*) INTO v_sin_contacto_sin_flag
  FROM public.crm_negocios
  WHERE activo AND id_entidad_relacionada IS NULL AND NOT requiere_triage;
  IF v_sin_contacto_sin_flag > 0 THEN
    RAISE EXCEPTION 'Hay % negocios sin contacto que no quedaron marcados para triage', v_sin_contacto_sin_flag;
  END IF;
END $$;

-- No se verifica «no hay dos negocios activos sobre la misma unidad»: lo garantiza
-- crm_negocios_unidad_uk, que se acaba de crear y habría abortado la migración.

-- Rollback:
--   ALTER TABLE public.crm_negocios
--     DROP COLUMN IF EXISTS id_oferta,
--     DROP COLUMN IF EXISTS id_propiedad,
--     DROP COLUMN IF EXISTS id_producto,
--     DROP COLUMN IF EXISTS ofertas_count,
--     DROP COLUMN IF EXISTS requiere_triage;
--   Los índices caen con las columnas. El reapunte de los 3 negocios de tipo 2 no se
--   revierte: corrige un dato incorrecto.
--
-- Validación posterior:
--   SELECT count(*) activos,
--          count(*) FILTER (WHERE id_entidad_relacionada IS NULL) sin_contacto,
--          count(*) FILTER (WHERE requiere_triage)                en_triage,
--          count(*) FILTER (WHERE id_propiedad IS NOT NULL)       con_unidad
--   FROM public.crm_negocios WHERE activo;   -- esperado: 1972 · 673 · 690 · 0
