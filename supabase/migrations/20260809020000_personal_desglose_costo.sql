-- Directorio de Personal — desglose real del costo de la persona
-- Fecha: 2026-08-09
-- Origen: Ejecuciones/ejecusiones.md (revisión con desglose de costo)
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- 20260809000000 creó `personal_organizacional` con la compensación heredada del modelo
-- de puestos: sueldo_base + bono_fijo + prestaciones_pct. Esa terna no corresponde a
-- cómo la empresa realmente gasta en una persona. Se sustituye por el desglose:
--
--   costo_nominal        capturado  Parte que va en nomina formal
--   costo_externo        capturado  Parte pagada fuera de nomina (asimilados, honorarios,
--                                   facturacion)
--   costo_social         capturado  Cargas patronales (IMSS, INFONAVIT, SAR, ISN)
--   costo_total          DERIVADO   nominal + externo + social — costo real para la empresa
--   sueldo_base_recibido capturado  Neto que recibe la persona, ya descontados costos
--                                   e impuestos
--
-- El costo por proyecto pasa a derivarse de `costo_total`:
--   costo_proyecto = costo_total * asignacion_pct / 100
--
-- ─── Por qué esta migración va encima y no reescribe la anterior ──────────────
-- 20260809000000 ya se aplicó a dev (deploy-dev del 2026-08-09 16:59Z, tras el merge del
-- PR #557). Reescribir un archivo ya desplegado dejaría el checksum de
-- supabase_migrations.schema_migrations fuera de sincronía y rompería el CI. Se apila.
--
-- ─── Decisiones ───────────────────────────────────────────────────────────────
-- · `costo_total` es GENERATED ALWAYS ... STORED, no un campo capturado ni un cálculo
--   repetido en el front: así es imposible que las partes y el total se desincronicen, y
--   cualquier reporte suma `costo_total` directamente en SQL. PostgreSQL rechaza
--   escribirla (SQLSTATE 428C9), por lo que el hook nunca debe enviarla.
-- · `sueldo_base_recibido` se CAPTURA, no se deriva: restar "costos e impuestos" exige
--   conocer el esquema de pago de cada persona (nómina, asimilado, honorarios) y su tasa
--   efectiva de retención; derivarlo con un porcentaje único produciría cifras falsas.
--   Es NULLABLE — NULL significa "aún no capturado", distinto de "recibe $0". El único
--   invariante que sí se puede afirmar, y se valida en BD, es que el neto recibido no
--   puede exceder el costo total de la persona.
-- · El CHECK escribe la suma explícita en vez de referenciar `costo_total`: una columna
--   generada no puede usarse dentro de un CHECK de su propia tabla.
--
-- ─── Sobre el DROP de las columnas viejas ─────────────────────────────────────
-- Es irreversible, por eso el backfill corre ANTES y un guard aborta toda la transacción
-- si el costo total no cuadra contra el modelo anterior. Si algo no cuadra, el CI falla
-- y NADA se pierde: el DROP nunca llega a ejecutarse.
--
-- Idempotente: ADD/DROP COLUMN IF [NOT] EXISTS, DROP CONSTRAINT IF EXISTS antes de cada
-- ADD CONSTRAINT, y el backfill guardado por "las columnas viejas todavía existen".
-- Sin BEGIN/COMMIT (el CI envuelve cada archivo).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Columnas capturadas del desglose
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.personal_organizacional
  ADD COLUMN IF NOT EXISTS costo_nominal        numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS costo_externo        numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS costo_social         numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS sueldo_base_recibido numeric(12,2);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Backfill desde el modelo anterior
--    nominal = sueldo_base + bono_fijo   (todo lo que iba como sueldo)
--    externo = 0                         (el modelo previo no lo distinguia)
--    social  = sueldo_base * prestaciones_pct / 100
--    sueldo_base_recibido queda NULL: es un dato nuevo, debe capturarse en la UI.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $bf$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'personal_organizacional'
      AND column_name  = 'sueldo_base'
  ) THEN
    RAISE NOTICE 'Columnas del modelo anterior ya no existen: backfill omitido.';
    RETURN;
  END IF;

  -- Solo toca las fichas que aún no tienen desglose capturado.
  EXECUTE $q$
    UPDATE public.personal_organizacional
    SET costo_nominal = sueldo_base + bono_fijo,
        costo_externo = 0,
        costo_social  = round(sueldo_base * prestaciones_pct / 100, 2)
    WHERE costo_nominal = 0 AND costo_externo = 0 AND costo_social = 0
  $q$;

  RAISE NOTICE 'Backfill de desglose de costo aplicado.';
END
$bf$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. costo_total — DERIVADA, la calcula PostgreSQL
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.personal_organizacional
  ADD COLUMN IF NOT EXISTS costo_total numeric(12,2)
    GENERATED ALWAYS AS (costo_nominal + costo_externo + costo_social) STORED;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. Guard self-verifying: el costo total no puede haber cambiado con el backfill.
--    Si no cuadra, aborta y el DROP de la sección 5 no llega a ejecutarse.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $chk$
DECLARE
  v_previo numeric;
  v_nuevo  numeric;
  v_filas  bigint;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'personal_organizacional'
      AND column_name  = 'sueldo_base'
  ) THEN
    RETURN;   -- ya migrado en una corrida anterior
  END IF;

  EXECUTE $q$
    SELECT COALESCE(sum(sueldo_base * (1 + prestaciones_pct / 100) + bono_fijo), 0), count(*)
    FROM public.personal_organizacional
  $q$ INTO v_previo, v_filas;

  SELECT COALESCE(sum(costo_total), 0) INTO v_nuevo FROM public.personal_organizacional;

  -- Tolerancia de un centavo por fila: el backfill redondea costo_social a 2 decimales.
  IF abs(v_previo - v_nuevo) > 0.01 * (v_filas + 1) THEN
    RAISE EXCEPTION
      'Backfill de costo no cuadra: modelo anterior = %, costo_total = % (% filas). Se aborta sin dropear columnas.',
      v_previo, v_nuevo, v_filas;
  END IF;

  RAISE NOTICE 'Cuadre verificado: % filas, costo total % preservado.', v_filas, v_nuevo;
END
$chk$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. Fuera el modelo anterior de compensación
--    El CHECK viejo referencia las columnas que se van, así que cae primero.
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.personal_organizacional
  DROP CONSTRAINT IF EXISTS personal_organizacional_montos_chk;

ALTER TABLE public.personal_organizacional
  DROP COLUMN IF EXISTS sueldo_base,
  DROP COLUMN IF EXISTS bono_fijo,
  DROP COLUMN IF EXISTS prestaciones_pct;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. Constraints del modelo nuevo
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.personal_organizacional
  ADD CONSTRAINT personal_organizacional_montos_chk
    CHECK (costo_nominal >= 0 AND costo_externo >= 0 AND costo_social >= 0);

-- El neto recibido no puede exceder el costo total de la persona. Se escribe la suma
-- explicita porque un CHECK no puede referenciar una columna generada de su propia tabla.
ALTER TABLE public.personal_organizacional
  DROP CONSTRAINT IF EXISTS personal_organizacional_recibido_chk;
ALTER TABLE public.personal_organizacional
  ADD CONSTRAINT personal_organizacional_recibido_chk
    CHECK (sueldo_base_recibido IS NULL
           OR (sueldo_base_recibido >= 0
               AND sueldo_base_recibido <= costo_nominal + costo_externo + costo_social));

-- ═══════════════════════════════════════════════════════════════════════════════
-- 7. Documentación
-- ═══════════════════════════════════════════════════════════════════════════════
COMMENT ON COLUMN public.personal_organizacional.costo_nominal IS
  'Parte del costo que va en nomina formal.';
COMMENT ON COLUMN public.personal_organizacional.costo_externo IS
  'Parte del costo pagada fuera de nomina (asimilados, honorarios, facturacion).';
COMMENT ON COLUMN public.personal_organizacional.costo_social IS
  'Cargas sociales a cargo de la empresa (IMSS patronal, INFONAVIT, SAR, ISN).';
COMMENT ON COLUMN public.personal_organizacional.costo_total IS
  'DERIVADA (GENERATED STORED) = nominal + externo + social. Costo real total de la '
  'persona para la empresa. No se inserta ni se actualiza: la calcula PostgreSQL '
  '(escribirla devuelve SQLSTATE 428C9).';
COMMENT ON COLUMN public.personal_organizacional.sueldo_base_recibido IS
  'Neto que recibe la persona ya descontados costos e impuestos. Se captura; no se '
  'deriva, porque la retencion depende del esquema de pago de cada persona. '
  'NULL = aun no capturado, distinto de recibe 0.';

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
-- Estructura resultante — deben aparecer las 5 columnas nuevas y NO sueldo_base,
-- bono_fijo ni prestaciones_pct:
--   SELECT column_name, data_type, is_nullable, is_generated, generation_expression
--   FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='personal_organizacional'
--   ORDER BY ordinal_position;
--
-- costo_total siempre cuadra con sus partes (aserto documental, imposible por definicion):
--   SELECT count(*) AS filas_inconsistentes FROM public.personal_organizacional
--   WHERE costo_total <> costo_nominal + costo_externo + costo_social;   -- esperado: 0
--
-- Costo migrado por ficha:
--   SELECT id, nombre, costo_nominal, costo_externo, costo_social, costo_total,
--          sueldo_base_recibido
--   FROM public.personal_organizacional WHERE activo ORDER BY id;
--
-- OJO — el resultado esperado difiere por entorno:
--   · dev/Preview: 2 fichas migradas de puestos_organizacionales, cada una con
--     costo_nominal=20000, costo_externo=0, costo_social=6000, costo_total=26000 y
--     sueldo_base_recibido=NULL. Total 52000, el mismo que antes del cambio.
--   · Producción (verificado read-only el 2026-08-09): 0 puestos activos, asi que
--     personal_organizacional esta vacia y no hay nada que backfillear. Correcto.
--
-- Contrato para el front: al insertar o actualizar NUNCA enviar `costo_total` — es
-- generada y PostgreSQL rechaza la escritura con 428C9.
