-- Incentivos: escalón por comisionista + cambio a cálculo marginal
-- Fecha: 2026-08-11
-- Origen: Ejecuciones/ejecusiones.md — "Incentivos: escalón por comisionista y cálculo marginal"
--
-- ─── Dos correcciones sobre lo ya ejecutado en 20260811020000 ─────────────────
-- 1. El cálculo es MARGINAL, no retroactivo. Cada venta se paga con el porcentaje del
--    tramo en el que cae y las ventas anteriores CONSERVAN el suyo. Con escalones 3/5/7:
--    ventas 1-2 a la base, 3-4 al escalón de 3, 5-6 al de 5, 7+ al de 7.
-- 2. La escalera puede definirse POR COMISIONISTA, no solo por canal, así el porcentaje y
--    los objetivos se ajustan por Canal, por Proyecto y por Comisionista.
--
-- ─── Por qué el modelo anterior era incorrecto ────────────────────────────────
-- 20260811020000 documentó el efecto como RETROACTIVO al mes. Se validó contra el Excel
-- con el que la operación calcula esto hoy (precio promedio 5,549,827.31; tramos
-- 0.35% / 0.35% / 0.70% / 0.70% / 0.90%) y los diez acumulados del Excel coinciden
-- exactamente con el cálculo marginal, con ninguno retroactivo:
--
--   Venta | % tramo | Acumulado marginal | Excel
--   ------+---------+--------------------+------------
--     1   |  0.35%  |      19,424.40     |  19,424.40
--     2   |  0.35%  |      38,848.79     |  38,848.79
--     3   |  0.70%  |      77,697.58     |  77,697.58
--     4   |  0.70%  |     116,546.37     | 116,546.37
--     5   |  0.90%  |     166,494.82     | 166,494.82
--    10   |  0.90%  |     416,237.05     | 416,237.05
--
-- Ese Excel también confirma el segundo punto: tiene una escalera distinta por
-- comisionista (Vendedor/CSR Sr., CSR Jr., Marketing & Contenido).
--
-- OJO — ESTO CAMBIA CUANTO SE PAGA. La BD solo guarda la política; el cálculo vive en el
-- front y en los reportes. Los 3 escalones ya capturados no se tocan, pero pasan a
-- liquidarse por tramos en vez de retroactivamente, lo que da un importe MENOR. Es la
-- corrección buscada —el Excel de operación es la fuente de verdad— pero conviene que
-- quien revise sepa que el cambio de dinero lo produce el front, no este DDL.
--
-- ─── Auditoría (verificado read-only contra producción el 2026-08-11) ─────────
-- · `comisiones_metas_escalon` ya existe con 3 escalones capturados: proyecto 1902
--   (Monócolo), canal 1 (Wallking), metas 3 -> +20%, 5 -> +30%, 7 -> +40%, las tres
--   activas. Este archivo es un ALTER, no un CREATE.
-- · La tabla NO tiene `id_personal`.
-- · `comisiones_metas_escalon_uq (id_proyecto, id_canal, ventas_meta)` existe como INDICE
--   PURO, no respaldando una constraint — confirmado con pg_constraint.conindid. Aun así
--   el drop de la sección 3 detecta ambos casos, porque `DROP INDEX` falla si el índice
--   respalda una constraint.
--
-- ─── Decisiones ───────────────────────────────────────────────────────────────
-- · `id_personal` NULLABLE es la clave del modelo: NULL = escalón DEL CANAL, aplica a
--   todos sus comisionistas; con valor = escalón propio de esa persona. Mismo patrón de
--   override que `personal_proyectos.id_rol` (20260810010000) y los porcentajes de
--   `comisiones_canal_config` (20260811030000): lo general vive arriba, la excepción abajo.
-- · La escalera efectiva de una persona se resuelve por umbral (MERGE), no por reemplazo.
--   Si el canal define 3/5/7 y la persona solo define su propio 5, hereda el 3 y el 7 del
--   canal. Reemplazar la escalera completa obligaría a recapturar todo para cambiar un
--   tramo y produciría escaleras divergentes difíciles de auditar.
-- · Se sustituye la unicidad no parcial por DOS índices parciales. La actual
--   `(id_proyecto, id_canal, ventas_meta)` impediría que una persona tenga su propio
--   escalón para una meta que el canal ya definió — justo lo que se necesita. Los nuevos
--   separan el nivel canal del nivel persona, y son parciales sobre `activo`, así que un
--   escalón dado de baja no bloquea volver a crear el mismo tramo.
-- · Al ser parciales, PostgREST no puede inferirlos para `on_conflict`, así que el front
--   no puede usar `upsert`. YA NO LO USA: `useMetasEscalon.ts` en la rama dev de
--   sozu-admin hace `insert` para altas y `update` por `id` para ediciones, y trae el
--   fallback para cuando `id_personal` todavía no existe. Verificado antes de escribir
--   esta migración — no hay riesgo de romper el guardado, a diferencia de 20260809050000.
-- · `ON DELETE CASCADE` en `id_personal`: si alguna vez se borra físicamente una persona,
--   sus escalones propios se van con ella. La baja normal es lógica y no toca estas filas.
--
-- Idempotente: ADD COLUMN / CREATE INDEX IF NOT EXISTS, y el drop del índice viejo solo
-- actúa si lo encuentra. No modifica ningún dato. Sin BEGIN/COMMIT (el CI envuelve cada
-- archivo).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. El override por comisionista
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.comisiones_metas_escalon
  ADD COLUMN IF NOT EXISTS id_personal bigint
    REFERENCES public.personal_organizacional (id) ON DELETE CASCADE;

COMMENT ON COLUMN public.comisiones_metas_escalon.id_personal IS
  'NULL = escalon DEL CANAL: aplica a todos sus comisionistas. Con valor = escalon propio '
  'de esa persona, que sobrescribe el del canal para esa misma meta. La escalera efectiva '
  'de una persona se resuelve por umbral: hereda los tramos del canal que no haya '
  'redefinido.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. La política pasa de retroactiva a marginal (solo documentación: la BD guarda
--    la política, el cálculo vive en el front y los reportes)
-- ═══════════════════════════════════════════════════════════════════════════════
COMMENT ON TABLE public.comisiones_metas_escalon IS
  'Escalera de incentivos por metas de cierre mensual, por proyecto y canal, con override '
  'opcional por comisionista. El contador es del CANAL completo en el mes. El calculo es '
  'MARGINAL POR TRAMOS: cada venta se paga con el porcentaje del tramo en el que cae y las '
  'ventas anteriores conservan el suyo. Con escalones 3/5/7, las ventas 1-2 van a la base, '
  '3-4 al escalon de 3, 5-6 al de 5 y 7+ al de 7.';

COMMENT ON COLUMN public.comisiones_metas_escalon.incremento_pct IS
  'Incremento expresado como PORCENTAJE DE LA COMISION BASE, no en puntos porcentuales: '
  'con base 1.0% e incremento_pct = 20, el tramo paga 1.2%. Aplica el escalon del tramo, '
  'no la suma de escalones, y solo a las ventas de ese tramo.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. Fuera la unicidad no parcial
--    Se detecta si respalda una constraint: en ese caso DROP INDEX falla y hay que ir por
--    ALTER TABLE ... DROP CONSTRAINT. En producción es un índice puro, pero un entorno
--    creado desde otra ruta podría tenerlo como constraint.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $drop_uq$
DECLARE
  v_oid oid;
  v_con text;
BEGIN
  v_oid := to_regclass('public.comisiones_metas_escalon_uq');

  IF v_oid IS NULL THEN
    RAISE NOTICE 'comisiones_metas_escalon_uq no existe: ya migrado.';
    RETURN;
  END IF;

  SELECT conname INTO v_con FROM pg_constraint WHERE conindid = v_oid;

  IF v_con IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.comisiones_metas_escalon DROP CONSTRAINT %I', v_con);
    RAISE NOTICE 'Eliminada la unicidad no parcial (respaldaba la constraint %).', v_con;
  ELSE
    EXECUTE 'DROP INDEX public.comisiones_metas_escalon_uq';
    RAISE NOTICE 'Eliminado el indice unico no parcial comisiones_metas_escalon_uq.';
  END IF;
END
$drop_uq$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. Guard self-verifying antes de los índices nuevos
--    Si los datos ya violaran alguna de las dos unicidades, el CREATE UNIQUE INDEX
--    fallaría con un error críptico. Se aborta antes, diciendo cuántas y de qué nivel.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $guard$
DECLARE
  v_dup_canal   bigint;
  v_dup_persona bigint;
BEGIN
  SELECT count(*) INTO v_dup_canal FROM (
    SELECT 1 FROM public.comisiones_metas_escalon
    WHERE id_personal IS NULL AND activo
    GROUP BY id_proyecto, id_canal, ventas_meta HAVING count(*) > 1
  ) d;

  SELECT count(*) INTO v_dup_persona FROM (
    SELECT 1 FROM public.comisiones_metas_escalon
    WHERE id_personal IS NOT NULL AND activo
    GROUP BY id_proyecto, id_canal, id_personal, ventas_meta HAVING count(*) > 1
  ) d;

  IF v_dup_canal > 0 THEN
    RAISE EXCEPTION
      'Hay % combinaciones (proyecto, canal, meta) repetidas entre escalones activos del canal. Resolver antes de reintentar el deploy.',
      v_dup_canal;
  END IF;

  IF v_dup_persona > 0 THEN
    RAISE EXCEPTION
      'Hay % combinaciones (proyecto, canal, persona, meta) repetidas entre escalones activos por comisionista. Resolver antes de reintentar el deploy.',
      v_dup_persona;
  END IF;
END
$guard$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. Las dos unicidades, separadas por nivel y parciales sobre `activo`
-- ═══════════════════════════════════════════════════════════════════════════════
-- Nivel canal: una sola definicion por meta.
CREATE UNIQUE INDEX IF NOT EXISTS comisiones_metas_escalon_canal_uq
  ON public.comisiones_metas_escalon (id_proyecto, id_canal, ventas_meta)
  WHERE id_personal IS NULL AND activo;

-- Nivel comisionista: una sola definicion por persona y meta.
CREATE UNIQUE INDEX IF NOT EXISTS comisiones_metas_escalon_persona_uq
  ON public.comisiones_metas_escalon (id_proyecto, id_canal, id_personal, ventas_meta)
  WHERE id_personal IS NOT NULL AND activo;

CREATE INDEX IF NOT EXISTS idx_comisiones_metas_escalon_personal
  ON public.comisiones_metas_escalon (id_personal);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. Reporte
-- ═══════════════════════════════════════════════════════════════════════════════
DO $reporte$
DECLARE
  v_total  bigint;
  v_canal  bigint;
  v_persona bigint;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE id_personal IS NULL),
         count(*) FILTER (WHERE id_personal IS NOT NULL)
  INTO v_total, v_canal, v_persona
  FROM public.comisiones_metas_escalon WHERE activo;

  RAISE NOTICE
    'comisiones_metas_escalon: % escalon(es) activo(s) — % del canal, % por comisionista.',
    v_total, v_canal, v_persona;
END
$reporte$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT column_name, data_type, is_nullable FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='comisiones_metas_escalon'
--   ORDER BY ordinal_position;
--
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid='public.comisiones_metas_escalon'::regclass ORDER BY conname;
--   -- esperado: aparece ..._id_personal_fkey ... ON DELETE CASCADE
--
--   SELECT indexname, indexdef FROM pg_indexes
--   WHERE schemaname='public' AND tablename='comisiones_metas_escalon' ORDER BY indexname;
--   -- esperado: ya NO existe comisiones_metas_escalon_uq; si existen
--   --   ..._canal_uq   (WHERE id_personal IS NULL AND activo)
--   --   ..._persona_uq (WHERE id_personal IS NOT NULL AND activo)
--
-- Los 3 escalones existentes siguen siendo del canal, sin persona asignada:
--   SELECT count(*) AS total,
--          count(*) FILTER (WHERE id_personal IS NULL)     AS del_canal,
--          count(*) FILTER (WHERE id_personal IS NOT NULL) AS por_comisionista
--   FROM public.comisiones_metas_escalon WHERE activo;
--   -- esperado: total = del_canal = 3, por_comisionista = 0
--
-- ─── La resolución de la escalera efectiva, por umbral (merge) ────────────────
-- Para una persona, cada tramo toma su escalón propio si existe y el del canal si no:
--
--   SELECT m.ventas_meta,
--          COALESCE(propio.incremento_pct, m.incremento_pct) AS incremento_efectivo,
--          (propio.incremento_pct IS NOT NULL) AS es_override
--   FROM public.comisiones_metas_escalon m
--   LEFT JOIN public.comisiones_metas_escalon propio
--          ON propio.id_proyecto = m.id_proyecto
--         AND propio.id_canal    = m.id_canal
--         AND propio.ventas_meta = m.ventas_meta
--         AND propio.id_personal = $3
--         AND propio.activo
--   WHERE m.id_proyecto = $1 AND m.id_canal = $2
--     AND m.id_personal IS NULL AND m.activo
--   ORDER BY m.ventas_meta;
--
-- Y el pago de la venta N es el incremento del tramo en el que cae — el mayor
-- `ventas_meta <= N` —, aplicado SOLO a esa venta:
--
--   comision_de_la_venta_N = comision_base * (1 + incremento_del_tramo(N) / 100)
--
-- ─── Front (repo sozu-admin) ──────────────────────────────────────────────────
-- `useMetasEscalon.ts` y `BrokerIncentivesTab.tsx` YA están en la rama dev: usan `insert` y
-- `update` por `id` (no `upsert`), manejan `id_personal` con fallback para cuando la
-- columna todavía no existe, e implementan el desglose marginal. Es decir el front va
-- ADELANTADO a la base: hoy, sin este DDL, un escalón por comisionista fallaría con 23505
-- por la unicidad no parcial. Este archivo alinea la base con el front, y no rompe nada en
-- el camino.
