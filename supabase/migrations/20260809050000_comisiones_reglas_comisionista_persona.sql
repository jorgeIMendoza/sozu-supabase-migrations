-- Comisionistas por canal: la fila de comisión pasa de rol a persona
-- Fecha: 2026-08-09
-- Origen: Ejecuciones/ejecusiones.md, Anexo 4
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- En el menú Comisiones, cada canal dejaba de poder listar personas: la fila era
-- canal × rol × proyecto, con `UNIQUE (id_canal, id_rol, id_proyecto)`. Esa unicidad es
-- justo lo que impedía tener DOS asesores distintos en el mismo canal — ambas filas
-- colisionaban en el mismo `id_rol`.
--
-- Se agrega `id_personal` y la unicidad se mueve de rol a persona:
--   antes:  UNIQUE (id_canal, id_rol, id_proyecto)
--   ahora:  UNIQUE (id_proyecto, id_canal, id_personal)
--
-- `id_rol` NO se elimina: todo el motor de cálculo (`calculations.ts`,
-- `useComisionesValidacion`, el panel de Alta Dirección) agrupa los pagos por rol, y
-- `comisiones_reglas.id_rol` guarda los ids del catálogo del simulador (`role-asesor`),
-- no los de `roles_organizacionales`. Pasa a derivarse del rol de la persona en vez de
-- elegirse a mano, así que un cambio de rol en la ficha se refleja aquí.
--
-- ─── ⚠ Este DDL rompe el front viejo: deben desplegarse juntos ────────────────
-- `insertReglasComisionRemotas` (repo sozu-admin) hace upsert con
-- `onConflict: "id_canal,id_rol,id_proyecto"`. Esta migración elimina esa unicidad, así
-- que PostgREST ya no puede inferirla y "Guardar cambios" en Comisiones empieza a fallar.
-- El front debe cambiar el onConflict a `id_proyecto,id_canal,id_personal` en el mismo
-- deploy. Con el DDL puesto y el front viejo, el guardado de reglas queda roto.
--
-- ─── Decisiones ───────────────────────────────────────────────────────────────
-- · El índice de persona NO es parcial, aunque `id_personal` sea nullable. Es deliberado:
--   PostgREST necesita inferir el índice para el `on_conflict` del upsert y no puede
--   hacerlo con un índice parcial (Postgres exigiría repetir el predicado en el
--   ON CONFLICT). Como Postgres considera distintos los NULL entre sí, las filas
--   heredadas no chocan.
-- · Las filas heredadas no se borran ni se les inventa una persona: quedan con
--   `id_personal IS NULL` y la pantalla las marca como "Sin comisionista asignado". Su
--   porcentaje capturado se conserva. Para que no se dupliquen mientras tanto, un índice
--   PARCIAL mantiene su unicidad por rol — ese sí puede ser parcial porque nunca
--   participa en un upsert.
-- · `ON DELETE CASCADE`: si algún día se borra físicamente una persona, sus comisiones se
--   van con ella. La baja normal es lógica (`activo = false` en la ficha) y no toca estas
--   filas: un comisionista dado de baja conserva su histórico de comisiones.
-- · La constraint vieja se localiza por su DEFINICIÓN, no por su nombre. En dev y prod se
--   llama `comisiones_reglas_canal_rol_proyecto_key`, pero un `DROP CONSTRAINT IF EXISTS`
--   por nombre sería un no-op silencioso si en algún entorno se llamara distinto, y la
--   restricción seguiría bloqueando dos personas del mismo rol sin que nadie se entere.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS y el DROP dinámico
-- solo actúa si encuentra la constraint. Sin BEGIN/COMMIT (el CI envuelve cada archivo).
--
-- Requiere `personal_organizacional`, creada en 20260809000000.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. El comisionista
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.comisiones_reglas
  ADD COLUMN IF NOT EXISTS id_personal bigint
    REFERENCES public.personal_organizacional (id) ON DELETE CASCADE;

COMMENT ON COLUMN public.comisiones_reglas.id_personal IS
  'Comisionista: persona de personal_organizacional que cobra este porcentaje en el '
  'canal. NULL = fila heredada del modelo anterior (comision por rol, sin persona '
  'asignada todavia).';
COMMENT ON COLUMN public.comisiones_reglas.id_rol IS
  'Rol del simulador (texto, ej. role-asesor). Se deriva del rol de la persona; se '
  'conserva porque el motor de calculo agrupa los pagos por rol.';
COMMENT ON COLUMN public.comisiones_reglas.porcentaje IS
  'Porcentaje de comision a dispersar al comisionista sobre el precio de venta final.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Fuera la unicidad por rol — localizada por definición, no por nombre
-- ═══════════════════════════════════════════════════════════════════════════════
DO $drop_uq$
DECLARE
  v_conname text;
BEGIN
  SELECT c.conname
  INTO v_conname
  FROM pg_constraint c
  WHERE c.conrelid = 'public.comisiones_reglas'::regclass
    AND c.contype  = 'u'
    -- exactamente las tres columnas id_canal, id_rol, id_proyecto, en cualquier orden
    AND (
      SELECT array_agg(a.attname::text ORDER BY a.attname)
      FROM unnest(c.conkey) k
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k
    ) = ARRAY['id_canal','id_proyecto','id_rol']
  LIMIT 1;

  IF v_conname IS NULL THEN
    RAISE NOTICE 'No hay constraint UNIQUE sobre (id_canal, id_rol, id_proyecto): ya migrado.';
  ELSE
    EXECUTE format('ALTER TABLE public.comisiones_reglas DROP CONSTRAINT %I', v_conname);
    RAISE NOTICE 'Eliminada la unicidad por rol: %.', v_conname;
  END IF;
END
$drop_uq$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. Guard self-verifying antes de los índices nuevos
--    Si los datos ya violaran alguna de las dos unicidades, el CREATE INDEX fallaría con
--    un error críptico. Se aborta antes, diciendo cuántas filas y de qué tipo.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $guard$
DECLARE
  v_dup_persona bigint;
  v_dup_legacy  bigint;
BEGIN
  SELECT count(*) INTO v_dup_persona FROM (
    SELECT 1 FROM public.comisiones_reglas
    WHERE id_personal IS NOT NULL
    GROUP BY id_proyecto, id_canal, id_personal HAVING count(*) > 1
  ) d;

  SELECT count(*) INTO v_dup_legacy FROM (
    SELECT 1 FROM public.comisiones_reglas
    WHERE id_personal IS NULL
    GROUP BY id_proyecto, id_canal, id_rol HAVING count(*) > 1
  ) d;

  IF v_dup_persona > 0 THEN
    RAISE EXCEPTION
      'Hay % combinaciones (proyecto, canal, persona) repetidas en comisiones_reglas. Resolver antes de reintentar el deploy.',
      v_dup_persona;
  END IF;

  IF v_dup_legacy > 0 THEN
    RAISE EXCEPTION
      'Hay % combinaciones (proyecto, canal, rol) repetidas entre las filas heredadas (id_personal IS NULL). Resolver antes de reintentar el deploy.',
      v_dup_legacy;
  END IF;
END
$guard$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. La nueva unicidad: una persona no se repite en el mismo canal del mismo proyecto
--    NO parcial a proposito — ver la nota de decisiones sobre PostgREST.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE UNIQUE INDEX IF NOT EXISTS comisiones_reglas_persona_uq
  ON public.comisiones_reglas (id_proyecto, id_canal, id_personal);

-- Filas heredadas (sin persona): conservan su unicidad por rol.
CREATE UNIQUE INDEX IF NOT EXISTS comisiones_reglas_rol_legacy_uq
  ON public.comisiones_reglas (id_proyecto, id_canal, id_rol)
  WHERE id_personal IS NULL;

CREATE INDEX IF NOT EXISTS idx_comisiones_reglas_personal
  ON public.comisiones_reglas (id_personal);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. Cuántas filas quedan pendientes de asignar comisionista
-- ═══════════════════════════════════════════════════════════════════════════════
DO $reporte$
DECLARE
  v_total bigint;
  v_sin   bigint;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE id_personal IS NULL)
  INTO v_total, v_sin
  FROM public.comisiones_reglas;

  RAISE NOTICE
    'comisiones_reglas: % filas, % sin comisionista asignado (se muestran en la UI como "Sin comisionista asignado").',
    v_total, v_sin;
END
$reporte$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid = 'public.comisiones_reglas'::regclass ORDER BY conname;
--   -- esperado: ya NO aparece la UNIQUE (id_canal, id_rol, id_proyecto);
--   --           si aparece comisiones_reglas_id_personal_fkey ... ON DELETE CASCADE
--
--   SELECT indexname, indexdef FROM pg_indexes
--   WHERE schemaname='public' AND tablename='comisiones_reglas' ORDER BY indexname;
--   -- esperado: comisiones_reglas_persona_uq (SIN WHERE) y
--   --           comisiones_reglas_rol_legacy_uq (WHERE id_personal IS NULL)
--
-- Ninguna fila se perdió; todas quedan heredadas hasta asignarles persona:
--   SELECT count(*) AS total,
--          count(*) FILTER (WHERE id_personal IS NULL)     AS sin_comisionista,
--          count(*) FILTER (WHERE id_personal IS NOT NULL) AS con_comisionista
--   FROM public.comisiones_reglas;
--
-- OJO — el conteo difiere por entorno (verificado read-only el 2026-08-09):
--   · Preview/dev: 60 filas (según el anexo).
--   · Producción: 128 filas, 2 proyectos, 6 canales, 13 roles distintos.
--   En ambos, tras la migración: sin_comisionista = total, con_comisionista = 0.
--
-- Nota sobre `activo`: la tabla tiene una columna `activo` que el anexo no considera. Los
-- índices nuevos NO la filtran, igual que la constraint que sustituyen. Es lo correcto
-- para un upsert: reactivar a una persona en un canal donde ya tuvo una regla debe
-- ACTUALIZAR esa fila, no crear una segunda.
--
-- ─── Front que debe ir en el MISMO deploy (repo sozu-admin) ───────────────────
-- · useMotorComisionesSync.ts — mapear id_personal y cambiar el onConflict del upsert a
--   `id_proyecto,id_canal,id_personal`. Sin esto, guardar reglas falla.
-- · types/simulator.ts (CommissionRule.personalId), SimulatorContext.tsx, CommissionsTab.tsx.
