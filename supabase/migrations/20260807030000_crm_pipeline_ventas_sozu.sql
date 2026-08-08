-- Homologación CRM ↔ Portal Agente — 03: pipeline canónico «Ventas SOZU»
-- Fecha: 2026-08-07
--
-- Un pipeline único para la venta de unidades SOZU, con etapas de CLAVE ESTABLE y con la
-- distinción explícita entre lo que mueve el agente y lo que mueve un hecho duro del sistema
-- (oferta, apartado pagado, estatus de la propiedad). Es lo que hace que el tablero
-- «Negocios» del Portal Agente y la vista Negocios del CRM muestren lo mismo.
--
-- Tres columnas nuevas en `crm_pipeline_etapas`:
--   clave             slug estable; el front referencia esto, nunca el id ni el nombre.
--   hecho_disparador  NULL = la mueve el agente; con valor = la mueve el sistema y el front
--                     la pinta bloqueada.
--   color             clases del chip, para que la paleta también viva en la BD y cambiarla
--                     no exija deploy.
--
-- No se borra ni se migra ningún pipeline heredado: siguen vivos con su histórico y lo único
-- que cambia es que **todo negocio nuevo nace en el canónico**. Mover los históricos es
-- decisión posterior del CRM.
--
-- `ganado` es `vendida`, no `apartado_pagado`: el apartado es compromiso, no cierre (75%).
-- La probabilidad refleja el embudo real medido, no el 50% plano heredado.
-- `perdido` queda SIN `hecho_disparador` para que el agente pueda cerrarla a mano; el 05 la
-- dispara además desde `ofertas_no_avance`. Es la única etapa con las dos vías.
--
-- ─── Verificado read-only contra prod (tzmhgfjmddkfyffkkmto, 2026-08-07) ──────
--   * `crm_pipelines` NO tiene `clave`; `crm_pipeline_etapas` no tiene `clave`,
--     `hecho_disparador` ni `color`. Ninguna de las cuatro columnas existe todavía.
--   * No hay pipeline llamado «Ventas SOZU».
--   * Tipos y defaults compatibles con los INSERT: `crm_pipelines.orden` integer NOT NULL
--     DEFAULT 100, `crm_pipeline_etapas.probabilidad` numeric NOT NULL DEFAULT 0, y el `id`
--     de ambas es IDENTITY (no se fija).
--   * Los índices únicos son parciales sobre `clave`: al crearse, todas las filas viejas
--     tienen `clave` NULL y quedan fuera, así que no pueden fallar.
--   * **10 pipelines, no 9**: apareció «APP Monócolo CAFÉ BROKERS» (id 10) con 31 negocios
--     activos, posterior a la auditoría del documento. Reparto actual de los 1,972 negocios
--     activos: Daiku 1,512 · Bottura Muebles 186 · Margot 119 · Onboarding Externos 75 ·
--     Monócolo F&F 41 · APP Monócolo CAFÉ BROKERS 31 · Industrial 7 · Inquilinos 1.
--   * **«Etapa test» ya no existe** (0 filas con «test» o «prueba» en el nombre, en las 60
--     etapas de la base). El UPDATE de limpieza se conserva porque dev puede tener drift,
--     pero en prod hoy no toca nada.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS, INSERT ... WHERE NOT EXISTS por clave, CREATE INDEX
-- IF NOT EXISTS. Sin BEGIN/COMMIT (el CI envuelve cada migración en transacción).

-- ─────────────────────────────────────────────────────────────────────
-- 1. Columnas
-- ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.crm_pipelines
  ADD COLUMN IF NOT EXISTS clave text;

ALTER TABLE public.crm_pipeline_etapas
  ADD COLUMN IF NOT EXISTS clave            text,
  ADD COLUMN IF NOT EXISTS hecho_disparador text,
  ADD COLUMN IF NOT EXISTS color            text;

COMMENT ON COLUMN public.crm_pipelines.clave IS
  'Slug estable del pipeline. El canónico de venta de unidades es ''ventas_sozu''.';
COMMENT ON COLUMN public.crm_pipeline_etapas.clave IS
  'Slug estable de la etapa. El front referencia esto, nunca el id ni el nombre.';
COMMENT ON COLUMN public.crm_pipeline_etapas.hecho_disparador IS
  'NULL = la mueve el agente. Con valor = la mueve un trigger del sistema y el front la bloquea.';
COMMENT ON COLUMN public.crm_pipeline_etapas.color IS
  'Clases de color del chip en el front (mismo patrón que crm_estados_lead.color). La BD manda: cambiar el color aquí lo cambia en el portal sin tocar código.';

-- ─────────────────────────────────────────────────────────────────────
-- 2. Pipeline canónico
-- ─────────────────────────────────────────────────────────────────────
INSERT INTO public.crm_pipelines (nombre, clave, id_proyecto, orden, activo)
SELECT 'Ventas SOZU', 'ventas_sozu', NULL, 0, true
WHERE NOT EXISTS (SELECT 1 FROM public.crm_pipelines WHERE clave = 'ventas_sozu');

-- ─────────────────────────────────────────────────────────────────────
-- 3. Etapas canónicas
--    6 manuales (hasta Negociando, más Cierre perdido) y 4 disparadas por el sistema.
-- ─────────────────────────────────────────────────────────────────────
INSERT INTO public.crm_pipeline_etapas
  (id_pipeline, nombre, clave, orden, probabilidad, es_ganado, es_perdido, hecho_disparador, color, activo)
SELECT p.id, v.nombre, v.clave, v.orden, v.prob, v.ganado, v.perdido, v.hecho, v.color, true
FROM public.crm_pipelines p
CROSS JOIN (VALUES
  ('Nuevo',               'nuevo',             10,   5.00, false, false, NULL,                  'bg-gray-100 text-gray-700'),
  ('Contactado',          'contactado',        20,  10.00, false, false, NULL,                  'bg-sky-100 text-sky-800'),
  ('Cita programada',     'cita_programada',   30,  20.00, false, false, NULL,                  'bg-blue-100 text-blue-800'),
  ('Asistió a la cita',   'cita_asistida',     40,  30.00, false, false, NULL,                  'bg-indigo-100 text-indigo-800'),
  ('Negociando',          'negociando',        50,  40.00, false, false, NULL,                  'bg-violet-100 text-violet-800'),
  ('Oferta enviada',      'oferta_enviada',    60,  50.00, false, false, 'oferta_activa',       'bg-amber-100 text-amber-800'),
  ('Apartado pagado',     'apartado_pagado',   70,  75.00, false, false, 'apartado_aplicado',   'bg-orange-100 text-orange-800'),
  ('Enganche y contrato', 'enganche_contrato', 80,  90.00, false, false, 'propiedad_vendida',   'bg-teal-100 text-teal-800'),
  ('Cierre ganado',       'ganado',            90, 100.00, true,  false, 'propiedad_liquidada', 'bg-emerald-100 text-emerald-800'),
  ('Cierre perdido',      'perdido',           99,   0.00, false, true,  NULL,                  'bg-red-100 text-red-700')
) AS v(nombre, clave, orden, prob, ganado, perdido, hecho, color)
WHERE p.clave = 'ventas_sozu'
  AND NOT EXISTS (
    SELECT 1 FROM public.crm_pipeline_etapas e
    WHERE e.id_pipeline = p.id AND e.clave = v.clave);

CREATE UNIQUE INDEX IF NOT EXISTS crm_pipelines_clave_uk
  ON public.crm_pipelines (clave) WHERE clave IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS crm_pipeline_etapas_clave_uk
  ON public.crm_pipeline_etapas (id_pipeline, clave) WHERE clave IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────
-- 4. Limpieza: desactivar «Etapa test» solo si no tiene negocios activos.
--    En prod ya no existe; se conserva por si dev la tiene.
-- ─────────────────────────────────────────────────────────────────────
UPDATE public.crm_pipeline_etapas e
SET activo = false
WHERE e.activo
  AND e.nombre ILIKE 'etapa test'
  AND NOT EXISTS (SELECT 1 FROM public.crm_negocios n WHERE n.activo AND n.id_etapa = e.id);

-- ─────────────────────────────────────────────────────────────────────
-- 5. Self-verifying
-- ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_pipeline int; v_etapas int; v_auto int;
BEGIN
  SELECT count(*) INTO v_pipeline FROM public.crm_pipelines WHERE clave = 'ventas_sozu' AND activo;
  IF v_pipeline <> 1 THEN
    RAISE EXCEPTION 'Se esperaba exactamente 1 pipeline activo ventas_sozu, hay %', v_pipeline;
  END IF;

  SELECT count(*), count(*) FILTER (WHERE e.hecho_disparador IS NOT NULL)
    INTO v_etapas, v_auto
  FROM public.crm_pipeline_etapas e
  JOIN public.crm_pipelines p ON p.id = e.id_pipeline
  WHERE p.clave = 'ventas_sozu' AND e.activo;

  IF v_etapas <> 10 THEN RAISE EXCEPTION 'El pipeline ventas_sozu tiene % etapas activas, se esperaban 10', v_etapas; END IF;
  IF v_auto  <> 4  THEN RAISE EXCEPTION 'El pipeline ventas_sozu tiene % etapas automáticas, se esperaban 4', v_auto; END IF;

  IF NOT EXISTS (SELECT 1 FROM public.crm_pipeline_etapas e
                 JOIN public.crm_pipelines p ON p.id = e.id_pipeline
                 WHERE p.clave='ventas_sozu' AND e.clave='ganado' AND e.es_ganado) THEN
    RAISE EXCEPTION 'La etapa ganado no quedó marcada como es_ganado';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.crm_pipeline_etapas e
                 JOIN public.crm_pipelines p ON p.id = e.id_pipeline
                 WHERE p.clave='ventas_sozu' AND e.clave='perdido' AND e.es_perdido) THEN
    RAISE EXCEPTION 'La etapa perdido no quedó marcada como es_perdido';
  END IF;
END $$;

-- Rollback (falla si el 05 ya creó negocios apuntando a estas etapas: revertir el 05 antes):
--   DELETE FROM public.crm_pipeline_etapas
--   WHERE id_pipeline IN (SELECT id FROM public.crm_pipelines WHERE clave = 'ventas_sozu');
--   DELETE FROM public.crm_pipelines WHERE clave = 'ventas_sozu';
--   DROP INDEX IF EXISTS public.crm_pipeline_etapas_clave_uk;
--   DROP INDEX IF EXISTS public.crm_pipelines_clave_uk;
--   ALTER TABLE public.crm_pipeline_etapas
--     DROP COLUMN IF EXISTS clave,
--     DROP COLUMN IF EXISTS hecho_disparador,
--     DROP COLUMN IF EXISTS color;          -- el documento omitía esta
--   ALTER TABLE public.crm_pipelines DROP COLUMN IF EXISTS clave;
--
-- Validación posterior:
--   SELECT e.orden, e.clave, e.nombre, e.probabilidad, e.es_ganado, e.es_perdido, e.hecho_disparador
--   FROM public.crm_pipeline_etapas e JOIN public.crm_pipelines p ON p.id = e.id_pipeline
--   WHERE p.clave = 'ventas_sozu' AND e.activo ORDER BY e.orden;      -- esperado: 10 filas
