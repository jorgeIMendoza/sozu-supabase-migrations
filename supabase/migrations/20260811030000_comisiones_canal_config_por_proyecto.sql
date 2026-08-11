-- Canales de Venta por proyecto: membresía + porcentajes propios
-- Fecha: 2026-08-11
-- Origen: Ejecuciones/ejecusiones.md — "Canales de Venta por proyecto"
--         (extraído del Anexo 7 de 20260809_directorio_personal_rrhh.md)
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- En Canales de Venta se debe poder agregar, quitar y modificar canales POR PROYECTO,
-- sobre los desarrollos comercializados por SOZU. Hasta ahora el catálogo era global: los
-- 6 canales aplicaban por igual a todos los desarrollos, con la misma comisión externa y
-- los mismos topes.
--
-- Modelo: catálogo maestro + membresía y porcentajes por proyecto. El canal se crea una
-- vez (nombre, código, categoría, banderas) y cada proyecto decide si aplica y con qué
-- porcentajes.
--
-- ─── Por qué extiende una tabla en vez de crear otra ──────────────────────────
-- `comisiones_canal_config` (20260810000000) ya ES la tabla `(id_proyecto, id_canal)` que
-- hace falta, y ya trae `activo`. Crear una segunda tabla de membresía dejaría dos filas
-- por canal y proyecto que habría que mantener sincronizadas.
--
-- ─── Decisiones ───────────────────────────────────────────────────────────────
-- · `activo` pasa a significar MEMBRESIA: true = el canal aplica a ese proyecto. Quitar un
--   canal de un proyecto es `activo = false`, no borrar la fila: se conserva el porcentaje
--   capturado por si se vuelve a habilitar, y las reglas históricas de `comisiones_reglas`
--   siguen teniendo contexto.
-- · Sin fila = el canal no aplica al proyecto. Se distingue de `activo = false` solo en
--   matiz (nunca se habilitó vs se deshabilitó); el front trata ambos como "no aplica".
-- · Los porcentajes por proyecto son NULLABLE y significan "hereda del catálogo". Así un
--   proyecto que no necesita variación no obliga a recapturar nada, y cambiar el catálogo
--   maestro sigue propagándose a quien no tenga override. Mismo criterio que
--   `personal_proyectos.id_rol` (20260810010000).
-- · NO se agrega `id_proyecto` a `comisiones_canales`. Duplicar "Inmobiliaria" una vez por
--   desarrollo fragmentaría el catálogo, obligaría a cruzar por nombre para comparar
--   canales entre proyectos, y multiplicaría el mantenimiento de código, categoría y
--   banderas.
-- · Los topes se validan entre sí cuando ambos están capturados: `min <= max`. NO se fuerza
--   que la externa caiga dentro del rango, porque los topes describen el margen de
--   negociación y la externa es el valor vigente; forzarlo bloquearía capturas legítimas
--   durante un ajuste. (De hecho el catálogo maestro de producción ya lo violaría — ver la
--   nota del final.)
-- · `numeric(6,2)` en los tres porcentajes, la misma precisión que sus equivalentes del
--   catálogo maestro `comisiones_canales`. El documento decía `numeric` a secas, y mezclar
--   precisiones en un COALESCE entre override y catálogo pide problemas.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS, DROP CONSTRAINT IF EXISTS antes de cada ADD, y
-- CREATE INDEX IF NOT EXISTS. No modifica ningún dato: las columnas nacen NULL, es decir
-- "heredar", que es el comportamiento actual. Sin BEGIN/COMMIT (el CI envuelve cada archivo).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Los porcentajes propios del proyecto (NULL = heredar del catálogo maestro)
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.comisiones_canal_config
  ADD COLUMN IF NOT EXISTS comision_externa_pct numeric(6,2),
  ADD COLUMN IF NOT EXISTS comision_min_pct     numeric(6,2),
  ADD COLUMN IF NOT EXISTS comision_max_pct     numeric(6,2);

COMMENT ON TABLE public.comisiones_canal_config IS
  'Configuracion de cada Canal de Venta PARA UN PROYECTO: si aplica (activo) y sus '
  'porcentajes. Los porcentajes NULL heredan del catalogo maestro comisiones_canales. '
  'comisiones_canales sigue siendo el catalogo global (nombre, codigo, categoria, '
  'banderas); aqui vive lo que varia por desarrollo.';
COMMENT ON COLUMN public.comisiones_canal_config.activo IS
  'Membresia: true = el canal aplica a este proyecto. false = se quito del proyecto; se '
  'conserva la fila para no perder los porcentajes ni el contexto historico.';
COMMENT ON COLUMN public.comisiones_canal_config.comision_externa_pct IS
  'Comision externa del canal en este proyecto. NULL = hereda '
  'comisiones_canales.comision_externa_pct.';
COMMENT ON COLUMN public.comisiones_canal_config.comision_min_pct IS
  'Tope minimo negociable en este proyecto. NULL = hereda del catalogo maestro.';
COMMENT ON COLUMN public.comisiones_canal_config.comision_max_pct IS
  'Tope maximo negociable en este proyecto. NULL = hereda del catalogo maestro.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Rango válido para los porcentajes capturados
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.comisiones_canal_config
  DROP CONSTRAINT IF EXISTS comisiones_canal_config_pcts_chk;
ALTER TABLE public.comisiones_canal_config
  ADD CONSTRAINT comisiones_canal_config_pcts_chk CHECK (
    (comision_externa_pct IS NULL OR (comision_externa_pct >= 0 AND comision_externa_pct <= 100))
    AND (comision_min_pct IS NULL OR (comision_min_pct >= 0 AND comision_min_pct <= 100))
    AND (comision_max_pct IS NULL OR (comision_max_pct >= 0 AND comision_max_pct <= 100))
  );

-- Los topes, cuando ambos existen, deben ser coherentes.
ALTER TABLE public.comisiones_canal_config
  DROP CONSTRAINT IF EXISTS comisiones_canal_config_topes_chk;
ALTER TABLE public.comisiones_canal_config
  ADD CONSTRAINT comisiones_canal_config_topes_chk CHECK (
    comision_min_pct IS NULL OR comision_max_pct IS NULL
    OR comision_min_pct <= comision_max_pct
  );

CREATE INDEX IF NOT EXISTS idx_comisiones_canal_config_canal
  ON public.comisiones_canal_config (id_canal);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. Reporte del estado resultante
-- ═══════════════════════════════════════════════════════════════════════════════
DO $reporte$
DECLARE
  v_filas      bigint;
  v_aplican    bigint;
  v_overrides  bigint;
  v_proy_conf  bigint;
  v_proy_sozu  bigint;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE activo),
         count(*) FILTER (WHERE comision_externa_pct IS NOT NULL
                             OR comision_min_pct IS NOT NULL
                             OR comision_max_pct IS NOT NULL),
         count(DISTINCT id_proyecto)
  INTO v_filas, v_aplican, v_overrides, v_proy_conf
  FROM public.comisiones_canal_config;

  SELECT count(DISTINCT pr.id) INTO v_proy_sozu
  FROM public.entidades_relacionadas er
  JOIN public.proyectos pr ON pr.id = er.id_proyecto
  WHERE er.id_tipo_entidad = 5 AND er.activo AND pr.activo;

  RAISE NOTICE
    'comisiones_canal_config: % fila(s), % activa(s), % con porcentaje propio, en % proyecto(s).',
    v_filas, v_aplican, v_overrides, v_proy_conf;

  IF v_proy_conf < v_proy_sozu THEN
    RAISE WARNING
      'Hay % proyecto(s) comercializado(s) por SOZU y solo % con canales configurados. Al pasar `activo` a significar membresia, los % proyecto(s) sin filas quedan SIN NINGUN canal en la pantalla. Habilitar los canales que correspondan desde Canales de Venta.',
      v_proy_sozu, v_proy_conf, v_proy_sozu - v_proy_conf;
  END IF;
END
$reporte$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT column_name, data_type, is_nullable FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='comisiones_canal_config'
--   ORDER BY ordinal_position;
--
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid='public.comisiones_canal_config'::regclass ORDER BY conname;
--
-- Nada cambia de entrada: todos los canales configurados siguen aplicando y heredando:
--   SELECT count(*) AS filas,
--          count(*) FILTER (WHERE activo) AS aplican,
--          count(*) FILTER (WHERE comision_externa_pct IS NOT NULL) AS con_externa_propia,
--          count(*) FILTER (WHERE comision_min_pct IS NOT NULL
--                             OR comision_max_pct IS NOT NULL)      AS con_topes_propios
--   FROM public.comisiones_canal_config;
--   -- esperado tras el ALTER: filas = aplican = 12, los dos overrides en 0
--
-- Vista efectiva — qué ve cada proyecto (override si existe, catálogo si no):
--   SELECT pr.nombre AS proyecto, ca.nombre AS canal, cc.activo AS aplica,
--          COALESCE(cc.comision_externa_pct, ca.comision_externa_pct) AS externa_efectiva,
--          (cc.comision_externa_pct IS NOT NULL) AS externa_es_override,
--          cc.comision_total_pct
--   FROM public.comisiones_canal_config cc
--   JOIN public.proyectos pr ON pr.id = cc.id_proyecto
--   JOIN public.comisiones_canales ca ON ca.id = cc.id_canal
--   ORDER BY pr.nombre, ca.nombre;
--
-- ═══════════════════════════════════════════════════════════════════════════════
-- PENDIENTE DE DECISION — 4 de los 6 proyectos SOZU quedarian sin canales
-- ═══════════════════════════════════════════════════════════════════════════════
-- Verificado read-only contra produccion el 2026-08-11:
--
--   Proyectos comercializados por SOZU y activos (id_tipo_entidad = 5): 6
--     2 Bottura · 1453 Daiku · 1743 Margot · 1902 Monocolo · 1746 Mutuo Vive · 9 Productos
--   Proyectos con filas en comisiones_canal_config: 2 (Daiku y Monocolo, 12 filas)
--
-- El documento afirma que "la extension no cambia nada de entrada" porque las 12 filas
-- cubren los 6 canales x 2 proyectos. Eso es cierto PARA ESOS DOS. Pero el comportamiento
-- actual es que el catalogo es GLOBAL: los 6 canales aplican a TODOS los desarrollos. Al
-- convertir `activo` en membresia, los otros 4 proyectos SOZU (Bottura, Margot, Mutuo
-- Vive, Productos) pasan de "todos los canales" a NINGUN canal, porque no tienen filas.
--
-- No hay regresion de datos: esos 4 proyectos tampoco tienen reglas en
-- `comisiones_reglas`, asi que su motor esta vacio de todas formas. Pero al elegirlos en
-- Canales de Venta no aparecera nada hasta que se habiliten a mano.
--
-- Esta migracion NO los siembra, para no ampliar el alcance de lo pedido; el bloque de la
-- seccion 3 lo reporta con RAISE WARNING. Si se prefiere preservar el comportamiento
-- global, esta es la siembra (heredando todos los porcentajes, y con el 6% de total que
-- uso la siembra original de 20260810000000):
--
--   INSERT INTO public.comisiones_canal_config (id_proyecto, id_canal, comision_total_pct)
--   SELECT p.id, c.id, 6
--   FROM (SELECT DISTINCT pr.id
--         FROM public.entidades_relacionadas er
--         JOIN public.proyectos pr ON pr.id = er.id_proyecto
--         WHERE er.id_tipo_entidad = 5 AND er.activo AND pr.activo) p
--   CROSS JOIN public.comisiones_canales c
--   WHERE c.activo
--     AND NOT EXISTS (SELECT 1 FROM public.comisiones_canal_config x
--                     WHERE x.id_proyecto = p.id AND x.id_canal = c.id);
--   -- dejaria 36 filas (6 proyectos x 6 canales)
--
-- ─── Los topes del catálogo maestro estan en cero ─────────────────────────────
-- En produccion los 6 canales tienen comision_min_pct = comision_max_pct = 0.00, mientras
-- comision_externa_pct va de 0 a 4. Como NULL hereda del catalogo, el "margen de
-- negociacion" efectivo heredado es 0-0 en todos los canales de todos los proyectos. No es
-- un problema de esta migracion — y confirma por que el CHECK no fuerza que la externa
-- caiga dentro del rango: el propio catalogo maestro lo violaria hoy. Conviene capturar
-- topes reales, en el catalogo o por proyecto, antes de que la UI los muestre como limites.
--
-- ─── Front dependiente de este DDL (repo sozu-admin) ──────────────────────────
-- useMotorComisionesSync.ts (lee/escribe los porcentajes por proyecto), un derivador de
-- "canales efectivos del proyecto", ChannelsTab.tsx y CommissionsTab.tsx. Mientras el DDL
-- no se ejecute, el front detecta la ausencia de las columnas y trata todos los canales
-- como heredados y aplicables: la pantalla sigue funcionando como hoy.
