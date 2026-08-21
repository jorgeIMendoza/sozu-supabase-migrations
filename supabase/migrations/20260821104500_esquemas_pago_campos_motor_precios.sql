-- esquemas_pago: los campos que el motor de Precios necesita
-- Fecha: 2026-08-21
-- Origen: Ejecuciones/ejecusiones.md
--
-- ─── Qué hace ─────────────────────────────────────────────────────────────────
-- Guarda en `esquemas_pago` seis atributos que el modulo de Precios ya usa para calcular
-- flujos y valor presente, y que hoy resuelve con un valor por omision en el codigo porque
-- la tabla no los tiene.
--
-- Mientras vivan en el codigo, dos esquemas identicos en la base se comportan igual aunque
-- el negocio quiera que uno sea de preventa y otro de post-entrega: esa distincion no se
-- puede capturar en ningun lado.
--
-- ─── Estado verificado read-only contra PRODUCCION el 2026-08-21 ──────────────
-- El documento audita Preview; produccion difiere en volumen, no en estructura:
--
--                              Preview (doc)   Produccion
--   filas                      1,102           1,119
--   inactivas                  19              24
--   esquemas de asignacion     47              60
--   triggers                   ninguno         ninguno
--
-- Ninguna de las seis columnas existe todavia. Las nueve columnas que toca el backfill son
-- NOT NULL y sin un solo nulo entre las activas, asi que el filtro de composicion no
-- descarta filas por aritmetica con NULL.
--
-- ─── El backfill, simulado antes de escribirlo ────────────────────────────────
-- Se corrio la consulta del documento contra produccion sin escribir nada:
--
--   189 esquemas a marcar como base, repartidos en 189 proyectos distintos
--   896 candidatos ofrecibles de 1,119 filas
--     0 marcados con id_proyecto NULL
--
-- Es exactamente uno por proyecto, y todo proyecto con esquemas activos queda cubierto. El
-- indice unico no puede reventar con estos datos.
--
-- Las 53 filas activas sin producto que NO suman 100% quedan sin marcar, que es lo
-- correcto: son los esquemas que crea el flujo de asignacion para dejar constancia de una
-- unidad concreta, no politica comercial.
--
-- ─── Decisiones del documento que se conservan ────────────────────────────────
-- · Se agregan columnas, no se modifica ninguna. Todas con DEFAULT, asi que las filas
--   existentes quedan validas sin tocarlas y ninguna aplicacion que hoy inserta se rompe.
-- · `es_base` necesita indice, no solo columna: "el esquema contra el que se comparan los
--   demas" es uno por proyecto y regimen, y sin la restriccion dos filas marcadas base
--   dejarian al comparador eligiendo por orden de lectura. Parcial sobre `activo` para que
--   desactivar el base no impida marcar otro.
-- · No se borra nada: `ofertas.id_esquema_pago_seleccionado` apunta aqui con ON DELETE SET
--   NULL, asi que un borrado en duro no falla — deja la oferta en nulo y se pierde con que
--   condiciones se cotizo. La baja es `activo = false`.
-- · El backfill es una heuristica reversible: marca el esquema sin descuento ni aumento y,
--   a empate, el de menor `orden`. Se corrige desde la pantalla marcando otro.
--
-- ─── Lo que se añade al DML del documento ─────────────────────────────────────
-- El backfill del documento no es seguro de reaplicar. Si alguien corrige el base desde la
-- pantalla y la migracion se vuelve a ejecutar, la heuristica marcaria de nuevo su
-- candidato y chocaria contra el indice unico con el base elegido a mano — o peor, lo
-- pisaria. Aqui va guardado por "no hay ningun base marcado todavia": corre una sola vez,
-- la primera, y despues no vuelve a opinar.
--
-- Sin BEGIN/COMMIT (el CI envuelve cada archivo, y un COMMIT explicito dejaria fuera el
-- registro en schema_migrations). Idempotente en los tres bloques.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Régimen comercial
--    El comparador ya separa preventa de post-entrega porque no son comparables entre sí;
--    la tabla no lo distinguía.
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.esquemas_pago
  ADD COLUMN IF NOT EXISTS tipo_esquema text NOT NULL DEFAULT 'preventa';

ALTER TABLE public.esquemas_pago
  DROP CONSTRAINT IF EXISTS esquemas_pago_tipo_esquema_chk;
ALTER TABLE public.esquemas_pago
  ADD CONSTRAINT esquemas_pago_tipo_esquema_chk
  CHECK (tipo_esquema IN ('preventa', 'post_entrega'));

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Mes en que arrancan las mensualidades, contado desde la firma
--    Con el enganche a 3 meses y las mensualidades desde el 1, los pagos se enciman: hoy
--    eso no se puede expresar.
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.esquemas_pago
  ADD COLUMN IF NOT EXISTS mes_inicio_mensualidades smallint NOT NULL DEFAULT 1;

ALTER TABLE public.esquemas_pago
  DROP CONSTRAINT IF EXISTS esquemas_pago_mes_inicio_chk;
ALTER TABLE public.esquemas_pago
  ADD CONSTRAINT esquemas_pago_mes_inicio_chk
  CHECK (mes_inicio_mensualidades >= 0);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. Esquema de referencia del proyecto: el que cobra el precio de lista
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.esquemas_pago
  ADD COLUMN IF NOT EXISTS es_base boolean NOT NULL DEFAULT false;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. Reparto de las mensualidades escalonadas
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.esquemas_pago
  ADD COLUMN IF NOT EXISTS modo_escalonamiento text NOT NULL DEFAULT 'lineal';

ALTER TABLE public.esquemas_pago
  DROP CONSTRAINT IF EXISTS esquemas_pago_modo_escalonamiento_chk;
ALTER TABLE public.esquemas_pago
  ADD CONSTRAINT esquemas_pago_modo_escalonamiento_chk
  CHECK (modo_escalonamiento IN ('lineal', 'tramos'));

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. Crecimiento de cada mensualidad en modo lineal
--    Topado en 100% para que un dedazo no genere una progresión absurda que nadie revisa
--    hasta que sale en una oferta.
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.esquemas_pago
  ADD COLUMN IF NOT EXISTS factor_crecimiento numeric(6,4) NOT NULL DEFAULT 0.05;

ALTER TABLE public.esquemas_pago
  DROP CONSTRAINT IF EXISTS esquemas_pago_factor_crecimiento_chk;
ALTER TABLE public.esquemas_pago
  ADD CONSTRAINT esquemas_pago_factor_crecimiento_chk
  CHECK (factor_crecimiento >= 0 AND factor_crecimiento <= 1);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. Para qué existe el esquema
--    Un nombre como "F3" no dice a quién va dirigido ni por qué se creó.
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.esquemas_pago
  ADD COLUMN IF NOT EXISTS descripcion text;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 7. Un solo esquema base por proyecto y régimen, solo entre los activos
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE UNIQUE INDEX IF NOT EXISTS esquemas_pago_un_base_por_regimen
  ON public.esquemas_pago (id_proyecto, tipo_esquema)
  WHERE es_base AND activo;

COMMENT ON COLUMN public.esquemas_pago.tipo_esquema IS
  'Regimen comercial: preventa (paga durante obra) o post_entrega (inmueble terminado).';
COMMENT ON COLUMN public.esquemas_pago.mes_inicio_mensualidades IS
  'Mes, contado desde la firma, en que arranca la primera mensualidad.';
COMMENT ON COLUMN public.esquemas_pago.es_base IS
  'Esquema de referencia del proyecto: el que cobra el precio de lista sin ajuste. Unico '
  'por proyecto y regimen entre los activos (esquemas_pago_un_base_por_regimen).';
COMMENT ON COLUMN public.esquemas_pago.modo_escalonamiento IS
  'lineal = crecimiento a tasa fija; tramos = pesos de tramos_mensualidad.';
COMMENT ON COLUMN public.esquemas_pago.factor_crecimiento IS
  'Crecimiento de cada mensualidad respecto a la anterior en modo lineal. 0.05 = 5%.';
COMMENT ON COLUMN public.esquemas_pago.descripcion IS
  'Para que existe el esquema y a quien va dirigido. Texto libre, opcional.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 8. Backfill de `es_base` — SOLO la primera vez
--    Sin esto ningun proyecto tiene referencia y el comparador vuelve a elegir por orden de
--    lectura. Va guardado: si ya hay bases marcados, no se toca nada, para que una
--    reaplicacion no pise una correccion hecha desde la pantalla ni choque contra el indice.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $backfill$
DECLARE
  v_ya      bigint;
  v_marcados bigint;
BEGIN
  SELECT count(*) INTO v_ya FROM public.esquemas_pago WHERE es_base;
  IF v_ya > 0 THEN
    RAISE NOTICE 'Ya hay % esquema(s) marcado(s) como base: backfill omitido.', v_ya;
    RETURN;
  END IF;

  WITH candidatos AS (
    SELECT e.id,
           row_number() OVER (
             PARTITION BY e.id_proyecto, e.tipo_esquema
             ORDER BY abs(e.porcentaje_descuento_aumento), e.orden, e.id
           ) AS puesto
    FROM public.esquemas_pago e
    WHERE e.activo
      AND e.id_producto IS NULL
      -- Solo esquemas ofrecibles: los de asignacion suman 0 y no son politica comercial.
      AND abs(e.porcentaje_enganche + e.porcentaje_mensualidades
              + e.porcentaje_entrega - 100) < 0.01
  )
  UPDATE public.esquemas_pago e
     SET es_base = true,
         -- La tabla no tiene trigger de fecha_actualizacion: se escribe a mano, igual que
         -- hace el modulo de Precios.
         fecha_actualizacion = CURRENT_TIMESTAMP
    FROM candidatos c
   WHERE c.id = e.id
     AND c.puesto = 1;

  GET DIAGNOSTICS v_marcados = ROW_COUNT;
  RAISE NOTICE 'Backfill de es_base: % esquema(s) marcado(s).', v_marcados;
END
$backfill$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 9. Guard de cierre
-- ═══════════════════════════════════════════════════════════════════════════════
DO $cierre$
DECLARE
  v_cols     int;
  v_checks   int;
  v_dupes    bigint;
  v_bases    bigint;
  v_proyectos bigint;
BEGIN
  SELECT count(*) INTO v_cols
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'esquemas_pago'
    AND column_name IN ('tipo_esquema', 'mes_inicio_mensualidades', 'es_base',
                        'modo_escalonamiento', 'factor_crecimiento', 'descripcion');
  IF v_cols <> 6 THEN
    RAISE EXCEPTION 'Se esperaban las 6 columnas nuevas y hay %.', v_cols;
  END IF;

  SELECT count(*) INTO v_checks
  FROM pg_constraint
  WHERE conrelid = 'public.esquemas_pago'::regclass AND contype = 'c'
    AND conname IN ('esquemas_pago_tipo_esquema_chk', 'esquemas_pago_mes_inicio_chk',
                    'esquemas_pago_modo_escalonamiento_chk',
                    'esquemas_pago_factor_crecimiento_chk');
  IF v_checks <> 4 THEN
    RAISE EXCEPTION 'Se esperaban los 4 CHECK de dominio y hay %.', v_checks;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'esquemas_pago_un_base_por_regimen'
  ) THEN
    RAISE EXCEPTION 'No quedo creado el indice esquemas_pago_un_base_por_regimen.';
  END IF;

  -- Aserto: el indice ya lo garantiza, pero deja constancia del conteo.
  SELECT count(*) INTO v_dupes FROM (
    SELECT 1 FROM public.esquemas_pago
    WHERE es_base AND activo
    GROUP BY id_proyecto, tipo_esquema HAVING count(*) > 1
  ) d;
  IF v_dupes > 0 THEN
    RAISE EXCEPTION 'Hay % combinacion(es) proyecto+regimen con mas de un base activo.', v_dupes;
  END IF;

  SELECT count(*), count(DISTINCT id_proyecto)
  INTO v_bases, v_proyectos
  FROM public.esquemas_pago WHERE es_base AND activo;

  RAISE NOTICE
    'esquemas_pago: 6 columnas, 4 CHECK, indice de base unico. % base(s) activo(s) en % proyecto(s).',
    v_bases, v_proyectos;
END
$cierre$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT column_name, data_type, is_nullable, column_default
--   FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='esquemas_pago'
--     AND column_name IN ('tipo_esquema','mes_inicio_mensualidades','es_base',
--                         'modo_escalonamiento','factor_crecimiento','descripcion')
--   ORDER BY column_name;
--   -- esperado: 6 filas, todas NOT NULL salvo descripcion
--
--   SELECT id_proyecto, tipo_esquema, count(*) AS bases
--   FROM public.esquemas_pago WHERE es_base AND activo
--   GROUP BY 1,2 HAVING count(*) > 1;
--   -- esperado: 0 filas
--
-- Resultado esperado del backfill en produccion, medido antes de aplicar:
--   189 bases en 189 proyectos, de 896 candidatos ofrecibles.
--
-- ─── Dos límites conocidos ────────────────────────────────────────────────────
-- 1) El indice usa (id_proyecto, tipo_esquema) y `id_proyecto` es nullable. Dos esquemas
--    sin proyecto marcados base NO colisionarian, porque en un indice unico los NULL se
--    consideran distintos. Hoy no importa: de los 119 esquemas sin proyecto, ninguno es
--    candidato del backfill, asi que quedan todos en false. Si alguna vez se marca base uno
--    sin proyecto, la unicidad no lo protege.
-- 2) El backfill solo corre si no hay ningun base. Eso lo hace seguro de reaplicar, pero
--    tambien significa que un proyecto creado despues de este deploy no recibe base
--    automatico: se marca desde la pantalla.
--
-- ─── Front ────────────────────────────────────────────────────────────────────
-- El modulo de Precios ya hace prueba de existencia de estas columnas: mientras no esten,
-- lee y escribe solo las que habia y deriva el resto. Al aplicarse, empieza a guardarlas
-- sin ningun cambio en el front.
