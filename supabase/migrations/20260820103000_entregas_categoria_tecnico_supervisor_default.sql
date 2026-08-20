-- Entregas: técnico y supervisor default por categoría (herencia lógica)
-- Fecha: 2026-08-20
-- Origen: Ejecuciones/ejecusiones.md
--
-- ─── Qué hace ─────────────────────────────────────────────────────────────────
-- Permite asignar un tecnico y un supervisor default a nivel CATEGORIA del checklist de
-- Entregas, que se heredan a todos sus items salvo que el item tenga asignacion propia.
-- Extiende el patron ya vigente a nivel item (entregas_checklist_items.id_supervisor_er /
-- id_tecnico_er -> entidades_relacionadas).
--
-- NO se propaga fisicamente ningun valor a los items. La resolucion ocurre en lectura:
--   tecnico_efectivo(item)    = item.id_tecnico_er    ?? categoria.id_tecnico_default_er
--   supervisor_efectivo(item) = item.id_supervisor_er ?? categoria.id_supervisor_default_er
--
-- ═══════════════════════════════════════════════════════════════════════════════
-- EL PREREQUISITO QUE EL DOCUMENTO NO PUDO VERIFICAR: SI ESTA EN PRODUCCION
-- ═══════════════════════════════════════════════════════════════════════════════
-- El documento avisa que no pudo comprobar produccion —el OAuth del MCP de Supabase no se
-- completo en esa sesion— y deja una instruccion tajante: si la infraestructura base de
-- julio (responsables_entregas) no esta aplicada en PRD, DETENER y no aplicar este DDL,
-- porque depende de ella via FK.
--
-- Se ejecuto esa verificacion contra produccion el 2026-08-20 y las cuatro columnas SI
-- estan:
--
--   entidades_relacionadas.es_supervisor_entregas    boolean NOT NULL
--   entidades_relacionadas.es_tecnico_entregas       boolean NOT NULL
--   entregas_checklist_items.id_supervisor_er        bigint  NULL
--   entregas_checklist_items.id_tecnico_er           bigint  NULL
--
-- Asi que el prerequisito esta cubierto y este DDL puede promoverse. De paso: produccion
-- tiene 4 tecnicos y 2 supervisores habilitados (el documento reporta 2 y 1 en DEV).
--
-- ─── Por qué la bitácora necesita cambiar ─────────────────────────────────────
-- `entregas_checklist_log.id_checklist_item` es NOT NULL: la tabla se diseño solo para
-- eventos de item. Usar "el primer item de la categoria" como sustituto —descartado
-- explicitamente por el propietario del producto— generaria una fila de auditoria que
-- apunta a un item que no fue el que cambio. Auditoria semanticamente falsa.
--
-- Extension minima: la FK del item pasa a nullable, entra `id_categoria`, y
-- `tipo_entidad_afectada` con un CHECK que obliga a que exactamente una de las dos FK este
-- poblada segun el tipo.
--
-- Verificado en produccion: las 357 filas historicas del log tienen id_checklist_item
-- poblado y ninguna lo trae en NULL, asi que toman el DEFAULT 'ITEM' y cumplen el CHECK sin
-- necesidad de migrar datos. El codigo actual, que inserta con id_checklist_item y sin
-- tipo_entidad_afectada, sigue siendo valido: cae en el default.
--
-- Tambien se comprobo que sobre esas dos tablas no hay vistas dependientes; el unico
-- trigger es trg_entregas_checklist_log_upd, de fecha_actualizacion, al que el DROP NOT NULL
-- no afecta.
--
-- ─── Compatibilidad ──────────────────────────────────────────────────────────
-- Columnas nuevas nullable y sin default de negocio: categorias e items existentes siguen
-- funcionando igual. No se hace backfill desde `responsable`/`cargo` (TEXT libre, sin
-- correspondencia garantizada con entidades_relacionadas); esas columnas se conservan
-- intactas para una limpieza separada.
--
-- `tipo_evento` es TEXT libre, sin CHECK de dominio, asi que los valores nuevos
-- ASIGNACION_TECNICO_CATEGORIA y ASIGNACION_SUPERVISOR_CATEGORIA no requieren DDL.
--
-- Idempotente: ADD COLUMN / CREATE INDEX IF NOT EXISTS y los CHECK guardados por nombre.
-- Sin BEGIN/COMMIT (el CI envuelve cada archivo, y un COMMIT explicito dejaria fuera el
-- registro en schema_migrations).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 0. Guard: no aplicar sin la infraestructura base de julio
--    Es la misma comprobación que el documento pide hacer a mano antes de promover; aquí
--    va dentro de la migración para que el CI la haga siempre, en cualquier ambiente.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $guard$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND (
      (table_name = 'entregas_checklist_items' AND column_name IN ('id_supervisor_er', 'id_tecnico_er'))
      OR (table_name = 'entidades_relacionadas' AND column_name IN ('es_supervisor_entregas', 'es_tecnico_entregas'))
    );

  IF v_n <> 4 THEN
    RAISE EXCEPTION
      'Falta la infraestructura base de responsables de entregas: se esperaban 4 columnas (id_supervisor_er, id_tecnico_er, es_supervisor_entregas, es_tecnico_entregas) y hay %. Aplicar primero ese cambio: este DDL depende de entidades_relacionadas via FK.',
      v_n;
  END IF;
END
$guard$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. entregas_checklist_categorias: los defaults de la categoría
--    Se nombran `..._default_er` y no `id_tecnico_er` a secas para que no se confundan con
--    las columnas homónimas de entregas_checklist_items al leer código o depurar joins.
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.entregas_checklist_categorias
  ADD COLUMN IF NOT EXISTS id_tecnico_default_er    bigint
    REFERENCES public.entidades_relacionadas (id),
  ADD COLUMN IF NOT EXISTS id_supervisor_default_er bigint
    REFERENCES public.entidades_relacionadas (id);

CREATE INDEX IF NOT EXISTS idx_eccat_tecnico_default_er
  ON public.entregas_checklist_categorias (id_tecnico_default_er)
  WHERE id_tecnico_default_er IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_eccat_supervisor_default_er
  ON public.entregas_checklist_categorias (id_supervisor_default_er)
  WHERE id_supervisor_default_er IS NOT NULL;

COMMENT ON COLUMN public.entregas_checklist_categorias.id_tecnico_default_er IS
  'Tecnico default de la categoria (entidades_relacionadas.id, es_tecnico_entregas = true). '
  'Se hereda a todo item de la categoria cuyo id_tecnico_er sea NULL. NO se propaga '
  'fisicamente: la resolucion es en lectura, '
  'tecnico_efectivo(item) = item.id_tecnico_er ?? categoria.id_tecnico_default_er.';

COMMENT ON COLUMN public.entregas_checklist_categorias.id_supervisor_default_er IS
  'Supervisor default de la categoria (entidades_relacionadas.id, '
  'es_supervisor_entregas = true). Misma regla de herencia que id_tecnico_default_er, para '
  'supervisor_efectivo.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. entregas_checklist_log: eventos de categoría, sin item ficticio
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.entregas_checklist_log
  ALTER COLUMN id_checklist_item DROP NOT NULL;

ALTER TABLE public.entregas_checklist_log
  ADD COLUMN IF NOT EXISTS id_categoria bigint
    REFERENCES public.entregas_checklist_categorias (id),
  ADD COLUMN IF NOT EXISTS tipo_entidad_afectada text NOT NULL DEFAULT 'ITEM';

-- Los CHECK van con guarda por nombre: ADD CONSTRAINT no admite IF NOT EXISTS.
DO $dominio$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_ecl_tipo_entidad_afectada'
      AND conrelid = 'public.entregas_checklist_log'::regclass
  ) THEN
    ALTER TABLE public.entregas_checklist_log
      ADD CONSTRAINT chk_ecl_tipo_entidad_afectada
      CHECK (tipo_entidad_afectada IN ('ITEM', 'CATEGORIA'));
  END IF;
END
$dominio$;

DO $exclusiva$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_ecl_entidad_exclusiva'
      AND conrelid = 'public.entregas_checklist_log'::regclass
  ) THEN
    ALTER TABLE public.entregas_checklist_log
      ADD CONSTRAINT chk_ecl_entidad_exclusiva
      CHECK (
        (tipo_entidad_afectada = 'ITEM'
          AND id_checklist_item IS NOT NULL AND id_categoria IS NULL)
        OR
        (tipo_entidad_afectada = 'CATEGORIA'
          AND id_categoria IS NOT NULL AND id_checklist_item IS NULL)
      );
  END IF;
END
$exclusiva$;

CREATE INDEX IF NOT EXISTS idx_entregas_checklist_log_categoria
  ON public.entregas_checklist_log (id_categoria)
  WHERE id_categoria IS NOT NULL;

COMMENT ON COLUMN public.entregas_checklist_log.tipo_entidad_afectada IS
  'ITEM = evento sobre entregas_checklist_items (id_checklist_item poblado). '
  'CATEGORIA = evento sobre entregas_checklist_categorias (id_categoria poblado, para la '
  'asignacion de tecnico/supervisor default). Exactamente una de las dos FK debe estar '
  'poblada segun este valor (chk_ecl_entidad_exclusiva).';

COMMENT ON COLUMN public.entregas_checklist_log.id_categoria IS
  'Categoria afectada cuando tipo_entidad_afectada = CATEGORIA. Existe para no tener que '
  'inventar un item ficticio: apuntar al "primer item de la categoria" produciria una fila '
  'de auditoria que señala a un item que no cambio.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. Guard de cierre
-- ═══════════════════════════════════════════════════════════════════════════════
DO $cierre$
DECLARE
  v_cols      int;
  v_checks    int;
  v_nullable  text;
  v_incumplen bigint;
BEGIN
  SELECT count(*) INTO v_cols
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND (
      (table_name = 'entregas_checklist_categorias'
        AND column_name IN ('id_tecnico_default_er', 'id_supervisor_default_er'))
      OR (table_name = 'entregas_checklist_log'
        AND column_name IN ('id_categoria', 'tipo_entidad_afectada'))
    );
  IF v_cols <> 4 THEN
    RAISE EXCEPTION 'Se esperaban las 4 columnas nuevas y hay %.', v_cols;
  END IF;

  SELECT is_nullable INTO v_nullable
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'entregas_checklist_log'
    AND column_name = 'id_checklist_item';
  IF v_nullable <> 'YES' THEN
    RAISE EXCEPTION 'id_checklist_item sigue siendo NOT NULL: un evento de categoria no podria registrarse.';
  END IF;

  SELECT count(*) INTO v_checks
  FROM pg_constraint
  WHERE conrelid = 'public.entregas_checklist_log'::regclass
    AND conname IN ('chk_ecl_tipo_entidad_afectada', 'chk_ecl_entidad_exclusiva');
  IF v_checks <> 2 THEN
    RAISE EXCEPTION 'Se esperaban los 2 CHECK de la bitacora y hay %.', v_checks;
  END IF;

  -- Aserto sobre el historico: ninguna fila deberia violar la exclusividad. Si el CHECK se
  -- creo, Postgres ya lo garantizo; queda como constancia del conteo.
  SELECT count(*) INTO v_incumplen
  FROM public.entregas_checklist_log
  WHERE NOT (
    (tipo_entidad_afectada = 'ITEM' AND id_checklist_item IS NOT NULL AND id_categoria IS NULL)
    OR (tipo_entidad_afectada = 'CATEGORIA' AND id_categoria IS NOT NULL AND id_checklist_item IS NULL)
  );

  RAISE NOTICE
    'Entregas: defaults de categoria listos, bitacora acepta eventos de categoria, % fila(s) historica(s) incumplen (esperado 0).',
    v_incumplen;
END
$cierre$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT column_name, data_type, is_nullable FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='entregas_checklist_categorias'
--     AND column_name IN ('id_tecnico_default_er','id_supervisor_default_er');
--
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid='public.entregas_checklist_log'::regclass AND contype='c' ORDER BY conname;
--
-- Nada existente cambia de comportamiento:
--   SELECT count(*) FILTER (WHERE id_tecnico_default_er IS NOT NULL)    AS con_tecnico,
--          count(*) FILTER (WHERE id_supervisor_default_er IS NOT NULL) AS con_supervisor
--   FROM public.entregas_checklist_categorias;
--   -- esperado: 0 y 0 justo despues de aplicar
--
--   SELECT tipo_entidad_afectada, count(*) FROM public.entregas_checklist_log
--   GROUP BY 1;
--   -- esperado: solo ITEM, con las 357 filas historicas
--
-- El CHECK rechaza las combinaciones invalidas (probar en transaccion con ROLLBACK):
--   BEGIN;
--     INSERT INTO public.entregas_checklist_log (id_entrega, tipo_evento, tipo_entidad_afectada)
--     VALUES (1, 'ASIGNACION_TECNICO_CATEGORIA', 'CATEGORIA');
--     -- esperado: ERROR 23514, falta id_categoria
--   ROLLBACK;
--
-- ─── Fuera de alcance, documentado en el propio requerimiento ─────────────────
-- Los handlers de item (handleAsignarSupervisor / handleAsignarTecnico en
-- EntregaDetalle.tsx) no llaman a insertLog, asi que la asignacion a nivel item hoy no
-- queda en bitacora. Es una brecha previa a este cambio y corregirla seria un refactor no
-- pedido; queda anotada para una iteracion futura.
--
-- ─── Front dependiente ────────────────────────────────────────────────────────
-- La resolucion tecnico_efectivo / supervisor_efectivo vive en lectura, asi que el front
-- debe hacer el COALESCE del item con su categoria. Mientras no lo haga, las columnas
-- nuevas quedan en NULL y todo se comporta como hoy.
