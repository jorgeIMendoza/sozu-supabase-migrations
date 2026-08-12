-- Escenarios de comisión por proyecto: conjunto de ventas ligadas a un canal
-- Fecha: 2026-08-12
-- Origen: Ejecuciones/ejecusiones.md
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- Un escenario es un conjunto de ventas de un proyecto, cada una ligada a un Canal de
-- Venta, sobre el que se concilia la comision. Permite elegir el proyecto, agregar tantas
-- ventas como se quiera con su canal, guardar / modificar / eliminar escenarios, y ver el
-- desglose (comision total, dispersado externamente, total dispersado y remanente) mas las
-- ventas que lo conforman.
--
-- ─── Estado verificado read-only contra produccion el 2026-08-12 ──────────────
-- · Ninguna tabla de escenarios existe: los actuales viven en localStorage
--   (SimulatorContext) con un modelo distinto — mezcla de canales en porcentajes, unidades
--   mensuales y modo de comision. Nada que migrar; ambas tablas nacen vacias.
-- · Ya existe todo lo necesario para conciliar: comisiones_canal_config (comision total y
--   externa por proyecto y canal, mas min/max), comisiones_reglas (comisionistas y su
--   porcentaje base) y comisiones_metas_escalon (escalera de incentivos con ventas_meta,
--   incremento_pct y override por comisionista via id_personal).
--
-- LOS ESCENARIOS DEL SIMULADOR NO SE ELIMINAN. Los consumen ~20 archivos (ResultsTab,
-- FinancialSimulatorTab, DistributionSimulatorTab, MonthlyFlowTab, DashboardTab,
-- ExecutiveDashboardTab, CommissionSimulatorTab, BenchmarkTab, CompetitividadTab...).
-- Borrarlos romperia Financieros, Distribucion, Flujo Comercial y los comparadores. Este
-- menu pasa al modelo nuevo; esas pantallas siguen leyendo el catalogo local hasta que se
-- migren una por una.
--
-- ─── Decisiones ───────────────────────────────────────────────────────────────
-- · Dos tablas: el escenario y sus ventas. Una venta es una FILA con su canal, no un
--   contador por canal. Es lo que permite que el orden importe: la escalera de incentivos
--   es MARGINAL, asi que la tercera venta de un canal paga distinto que la primera.
-- · `orden` explicito, no se confia en el `id`. El escenario se edita —se agregan y quitan
--   ventas— y depender del id autogenerado haria imposible reordenar sin recrear filas.
-- · El canal referencia el catalogo MAESTRO (comisiones_canales), no la configuracion por
--   proyecto. La membresia del canal en el proyecto puede cambiar despues de guardar el
--   escenario; si el canal se quita del proyecto, el escenario conserva su historia y la
--   pantalla lo marca, en vez de perder la venta.
-- · No se guarda ningun importe ni porcentaje calculado. El escenario guarda solo la
--   hipotesis; la comision se recalcula al abrirlo con la configuracion vigente. Congelar
--   los montos crearia dos fuentes que se desincronizan en cuanto alguien ajuste un
--   porcentaje. La contrapartida es explicita: un escenario guardado hoy puede dar otro
--   numero maniana si cambia la politica, y eso es deseable en una herramienta de analisis.
-- · ON DELETE CASCADE en las ventas: borrar el escenario se lleva sus ventas. Aqui si es
--   borrado fisico y no baja logica, porque una venta suelta sin escenario no significa
--   nada. El escenario en cambio usa baja logica (`activo`) para no perder analisis
--   historicos por un clic.
-- · Unicidad del nombre por proyecto, case-insensitive y parcial sobre `activo`: dos
--   escenarios activos del mismo desarrollo no pueden llamarse igual, pero un nombre
--   liberado por una baja se puede reutilizar.
--
-- Idempotente: CREATE ... IF NOT EXISTS y DROP POLICY/TRIGGER IF EXISTS.
-- Sin BEGIN/COMMIT (el CI envuelve cada archivo).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. EL ESCENARIO
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.comisiones_escenarios (
  id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_proyecto         integer     NOT NULL REFERENCES public.proyectos (id),
  nombre              text        NOT NULL,
  descripcion         text,
  activo              boolean     NOT NULL DEFAULT true,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT comisiones_escenarios_nombre_chk CHECK (btrim(nombre) <> '')
);

COMMENT ON TABLE public.comisiones_escenarios IS
  'Escenario de analisis de comision de un proyecto. Guarda SOLO la hipotesis (que ventas '
  'y en que canal, en comisiones_escenario_ventas); la comision se recalcula al abrirlo '
  'con la configuracion vigente de canales, comisionistas e incentivos. No se congelan '
  'importes: crearia una segunda fuente que se desincroniza.';
COMMENT ON COLUMN public.comisiones_escenarios.activo IS
  'Baja logica: un escenario dado de baja conserva su historia y su nombre queda libre.';

-- Dos escenarios activos del mismo proyecto no pueden llamarse igual.
CREATE UNIQUE INDEX IF NOT EXISTS comisiones_escenarios_nombre_uq
  ON public.comisiones_escenarios (id_proyecto, lower(btrim(nombre)))
  WHERE activo;

CREATE INDEX IF NOT EXISTS idx_comisiones_escenarios_proyecto
  ON public.comisiones_escenarios (id_proyecto);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. LAS VENTAS DEL ESCENARIO
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.comisiones_escenario_ventas (
  id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_escenario        bigint      NOT NULL
                        REFERENCES public.comisiones_escenarios (id) ON DELETE CASCADE,
  orden               integer     NOT NULL,
  id_canal            bigint      NOT NULL REFERENCES public.comisiones_canales (id),
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT comisiones_escenario_ventas_orden_chk CHECK (orden > 0)
);

COMMENT ON TABLE public.comisiones_escenario_ventas IS
  'Una fila = una venta del escenario, ligada a un Canal de Venta. El `orden` es explicito '
  'porque la escalera de incentivos es MARGINAL: la tercera venta de un canal paga distinto '
  'que la primera, asi que el orden determina el tramo. El canal referencia el catalogo '
  'maestro, no la configuracion por proyecto, para que quitar el canal del proyecto no '
  'destruya el escenario.';
COMMENT ON COLUMN public.comisiones_escenario_ventas.orden IS
  'Posicion de la venta dentro del escenario (1-based). El tramo de incentivo se resuelve '
  'por el ordinal de la venta DENTRO DE SU CANAL, no por este orden global.';

-- El orden no se repite dentro de un escenario.
CREATE UNIQUE INDEX IF NOT EXISTS comisiones_escenario_ventas_orden_uq
  ON public.comisiones_escenario_ventas (id_escenario, orden);

CREATE INDEX IF NOT EXISTS idx_comisiones_escenario_ventas_escenario
  ON public.comisiones_escenario_ventas (id_escenario);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. fecha_actualizacion automática
-- ═══════════════════════════════════════════════════════════════════════════════
DROP TRIGGER IF EXISTS trg_comisiones_escenarios_upd ON public.comisiones_escenarios;
CREATE TRIGGER trg_comisiones_escenarios_upd
  BEFORE UPDATE ON public.comisiones_escenarios
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

DROP TRIGGER IF EXISTS trg_comisiones_escenario_ventas_upd ON public.comisiones_escenario_ventas;
CREATE TRIGGER trg_comisiones_escenario_ventas_upd
  BEFORE UPDATE ON public.comisiones_escenario_ventas
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. RLS + GRANTS
--    Mismo patrón que el resto del dominio de comisiones, pero SIN `anon`: las default
--    privileges de Supabase sobre `public` conceden a `anon` todos los privilegios en cada
--    tabla nueva. Hoy RLS lo frenaría (no hay policy para anon), pero el GRANT quedaría
--    como trampa para la primera policy permisiva que llegue. Mismo criterio que
--    20260806100000, 20260809000000 y 20260810000000.
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.comisiones_escenarios       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comisiones_escenario_ventas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS comisiones_escenarios_rls_auth ON public.comisiones_escenarios;
CREATE POLICY comisiones_escenarios_rls_auth
  ON public.comisiones_escenarios FOR ALL TO authenticated
  USING ((SELECT auth.uid()) IS NOT NULL)
  WITH CHECK ((SELECT auth.uid()) IS NOT NULL);

DROP POLICY IF EXISTS comisiones_escenario_ventas_rls_auth ON public.comisiones_escenario_ventas;
CREATE POLICY comisiones_escenario_ventas_rls_auth
  ON public.comisiones_escenario_ventas FOR ALL TO authenticated
  USING ((SELECT auth.uid()) IS NOT NULL)
  WITH CHECK ((SELECT auth.uid()) IS NOT NULL);

REVOKE ALL PRIVILEGES ON TABLE public.comisiones_escenarios       FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.comisiones_escenario_ventas FROM anon;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.comisiones_escenarios, public.comisiones_escenario_ventas
  TO authenticated, service_role;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT table_name, column_name, data_type, is_nullable, column_default
--   FROM information_schema.columns
--   WHERE table_schema='public'
--     AND table_name IN ('comisiones_escenarios','comisiones_escenario_ventas')
--   ORDER BY table_name, ordinal_position;
--
--   SELECT conrelid::regclass AS tabla, conname, pg_get_constraintdef(oid)
--   FROM pg_constraint
--   WHERE conrelid IN ('public.comisiones_escenarios'::regclass,
--                      'public.comisiones_escenario_ventas'::regclass)
--   ORDER BY 1, 2;
--   -- esperado: ..._id_escenario_fkey ... ON DELETE CASCADE
--
--   SELECT tablename, indexname, indexdef FROM pg_indexes
--   WHERE schemaname='public'
--     AND tablename IN ('comisiones_escenarios','comisiones_escenario_ventas')
--   ORDER BY 1, 2;
--
-- RLS + policies + triggers + `anon` sin GRANT:
--   SELECT c.relname, c.relrowsecurity AS rls,
--          (SELECT count(*) FROM pg_policies p WHERE p.tablename = c.relname) AS policies
--   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--   WHERE n.nspname='public'
--     AND c.relname IN ('comisiones_escenarios','comisiones_escenario_ventas');
--
--   SELECT table_name, grantee, privilege_type FROM information_schema.role_table_grants
--   WHERE table_schema='public'
--     AND table_name IN ('comisiones_escenarios','comisiones_escenario_ventas')
--     AND grantee='anon';   -- esperado: 0 filas
--
-- Ambas nacen vacias:
--   SELECT (SELECT count(*) FROM public.comisiones_escenarios)       AS escenarios,
--          (SELECT count(*) FROM public.comisiones_escenario_ventas) AS ventas;
--   -- esperado: 0 y 0
--
-- Ordinal de cada venta DENTRO de su canal — es lo que define el tramo de incentivo:
--   SELECT ev.orden, ca.nombre AS canal,
--          row_number() OVER (PARTITION BY ev.id_canal ORDER BY ev.orden) AS ordinal_en_canal
--   FROM public.comisiones_escenario_ventas ev
--   JOIN public.comisiones_escenarios e ON e.id = ev.id_escenario
--   JOIN public.comisiones_canales ca ON ca.id = ev.id_canal
--   WHERE e.id = $1 ORDER BY ev.orden;
--
-- ═══════════════════════════════════════════════════════════════════════════════
-- DOS PUNTOS QUE EL DOCUMENTO NO RESUELVE — leer antes de construir el front
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- 1) NO HAY DONDE GUARDAR EL IMPORTE DE LA VENTA.
--    El objetivo pide ver el desglose "con porcentaje y monto", pero la venta solo guarda
--    `orden` y `id_canal`, y no existe una fuente de la que derivar el monto: `proyectos`
--    no tiene precio ni ticket promedio (solo `precio_m2_actual`), y ni
--    comisiones_canal_config ni comisiones_metas_escalon guardan importes. Con este
--    esquema la pantalla solo puede mostrar PORCENTAJES.
--    Si el monto debe salir de la BD, la venta necesita su propio precio:
--        ALTER TABLE public.comisiones_escenario_ventas
--          ADD COLUMN precio_venta numeric(14,2)
--          CHECK (precio_venta IS NULL OR precio_venta >= 0);
--    Se dejo FUERA a proposito: anadirla cambia el contrato con el front y es una decision
--    de producto, no del DDL. La alternativa es que el front aporte un precio de referencia
--    desde la configuracion local del simulador, con la limitacion de que entonces todas
--    las ventas del escenario valdrian lo mismo.
--
-- 2) REORDENAR VENTAS EXIGE REEMPLAZAR EL SET COMPLETO.
--    `comisiones_escenario_ventas_orden_uq` es un indice unico INMEDIATO, asi que un
--    intercambio de posiciones fila por fila (o un `UPDATE ... SET orden = orden + 1`)
--    choca con el duplicado a mitad del statement. El front debe guardar reordenamientos
--    como DELETE de las ventas del escenario + INSERT del set completo, dentro de la misma
--    transaccion. Si se prefiere permitir el swap in-place, la unicidad tendria que ser una
--    constraint DEFERRABLE INITIALLY DEFERRED en lugar de un indice — con la contrapartida
--    de que el error de duplicado aparece al COMMIT y no en la fila, lo que cambia el UAT
--    del documento (caso 4 espera 23505 al insertar).
--
-- ─── Front dependiente de este DDL (repo sozu-admin) ──────────────────────────
-- Un hook nuevo de escenarios y ScenariosTab.tsx. Mientras el DDL no se ejecute, la
-- pantalla detecta la ausencia de las tablas y avisa en vez de romperse.
