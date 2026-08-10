-- Comisión total independiente por canal, por proyecto
-- Fecha: 2026-08-10
-- Origen: Ejecuciones/ejecusiones.md, Anexo 5
--
-- ─── El hallazgo ──────────────────────────────────────────────────────────────
-- La Comisión Total del menú Comisiones NUNCA se ha persistido. El front la lee y escribe
-- en `comisiones_motor_config` (`fetchMotorConfigReal` / `updateMotorConfigRemoto` en
-- useMotorComisionesSync.ts), pero esa tabla no existe — confirmado read-only contra
-- producción el 2026-08-10, `to_regclass('public.comisiones_motor_config')` devuelve NULL:
--
--   PGRST205 Could not find the table 'public.comisiones_motor_config' in the schema cache
--
-- Como el front trata `tableMissing` como "no es error", se leía NULL, caía al default de
-- 6% y cualquier cambio se perdía al recargar o al cambiar de proyecto. El indicador de
-- "Falta por dispersar" se calculaba siempre contra 6% fijo, no contra un valor guardado.
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- La Comisión Total deja de ser un valor único que afecta por igual a todos los canales.
-- Cada canal define su propia comisión total, y ese valor puede variar por desarrollo.
--
-- ─── Decisiones ───────────────────────────────────────────────────────────────
-- · Tabla nueva por `(id_proyecto, id_canal)`. El motor ya es por proyecto
--   (`comisiones_reglas` lo es), así que la comisión total del canal pertenece a la
--   configuración del desarrollo. Ponerla como columna global en `comisiones_canales`
--   habría hecho que editarla dentro de Daiku cambiara también Monócolo — un efecto
--   colateral invisible para quien la captura.
-- · NO se crea `comisiones_motor_config`. La tabla que el front esperaba nunca existió y
--   su razón de ser (un solo total por proyecto) es justo lo que se está eliminando.
-- · `UNIQUE (id_proyecto, id_canal)` NO parcial, para que PostgREST pueda inferirla en el
--   `on_conflict` del upsert — mismo criterio que `comisiones_reglas_persona_uq`
--   (20260809050000).
-- · Se siembran los valores actuales con 6%, el valor con el que se venía calculando en
--   pantalla. Sin esa siembra, al entrar quedarían todos los canales en 0% y el resumen
--   marcaría "excedido" en cada uno por su comisión externa.
-- · Rango 0–100 con CHECK: un porcentaje fuera de ese rango no es un dato válido, y el
--   remanente del canal se calcula a partir de él.
-- · `numeric(6,2)`, la misma precisión que `comisiones_canales.comision_externa_pct` y
--   `comisiones_reglas.porcentaje` — el anexo decía `numeric` a secas, pero mezclar
--   precisiones en una resta entre columnas del mismo dominio pide problemas.
-- · Reutiliza `public.set_fecha_actualizacion()`, la misma convención que el resto de las
--   migraciones de este bloque.
--
-- Idempotente: CREATE ... IF NOT EXISTS, DROP POLICY/TRIGGER IF EXISTS y la siembra
-- guardada por NOT EXISTS. Sin BEGIN/COMMIT (el CI envuelve cada archivo).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. La configuración del canal dentro del proyecto
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.comisiones_canal_config (
  id                  bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_proyecto         integer      NOT NULL REFERENCES public.proyectos (id),
  id_canal            bigint       NOT NULL REFERENCES public.comisiones_canales (id),
  comision_total_pct  numeric(6,2) NOT NULL DEFAULT 0,
  activo              boolean      NOT NULL DEFAULT true,
  fecha_creacion      timestamptz  NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT comisiones_canal_config_pct_chk
    CHECK (comision_total_pct >= 0 AND comision_total_pct <= 100)
);

COMMENT ON TABLE public.comisiones_canal_config IS
  'Comision total por canal y por proyecto, en % sobre el precio de venta final. '
  'Sustituye al total unico por proyecto que el front intentaba leer de '
  'comisiones_motor_config (tabla que nunca existio): cada canal define su propio '
  'porcentaje y puede variar entre desarrollos.';
COMMENT ON COLUMN public.comisiones_canal_config.comision_total_pct IS
  'Comision total del canal sobre el precio de venta final. De aqui se resta la '
  'comision externa del canal para obtener la comision a dispersar entre comisionistas.';
COMMENT ON COLUMN public.comisiones_canal_config.activo IS
  'Baja logica, coherente con el resto del dominio de comisiones. El front lee solo activas.';

-- No parcial: PostgREST debe poder inferirla para el on_conflict del upsert.
CREATE UNIQUE INDEX IF NOT EXISTS comisiones_canal_config_proyecto_canal_uq
  ON public.comisiones_canal_config (id_proyecto, id_canal);

CREATE INDEX IF NOT EXISTS idx_comisiones_canal_config_proyecto
  ON public.comisiones_canal_config (id_proyecto);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. fecha_actualizacion automática
-- ═══════════════════════════════════════════════════════════════════════════════
DROP TRIGGER IF EXISTS trg_comisiones_canal_config_upd ON public.comisiones_canal_config;
CREATE TRIGGER trg_comisiones_canal_config_upd
  BEFORE UPDATE ON public.comisiones_canal_config
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. RLS + GRANTS
--    Mismo patrón que el resto del dominio de comisiones, pero SIN `anon`: las default
--    privileges de Supabase sobre `public` conceden a `anon` todos los privilegios en
--    cada tabla nueva. Hoy RLS lo frenaría (no hay policy para anon), pero el GRANT
--    quedaría como trampa para la primera policy permisiva que llegue. Se revoca
--    explícitamente, mismo criterio que 20260806100000 y 20260809000000.
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.comisiones_canal_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS comisiones_canal_config_rls_auth ON public.comisiones_canal_config;
CREATE POLICY comisiones_canal_config_rls_auth
  ON public.comisiones_canal_config
  FOR ALL TO authenticated
  USING ((SELECT auth.uid()) IS NOT NULL)
  WITH CHECK ((SELECT auth.uid()) IS NOT NULL);

REVOKE ALL PRIVILEGES ON TABLE public.comisiones_canal_config FROM anon;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.comisiones_canal_config
  TO authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. Siembra: conserva el 6% con el que se venía calculando en pantalla, para los
--    proyectos que ya tienen motor configurado. Idempotente.
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO public.comisiones_canal_config (id_proyecto, id_canal, comision_total_pct)
SELECT p.id_proyecto, c.id, 6
FROM (SELECT DISTINCT id_proyecto FROM public.comisiones_reglas) p
CROSS JOIN public.comisiones_canales c
WHERE c.activo
  AND NOT EXISTS (
    SELECT 1 FROM public.comisiones_canal_config x
    WHERE x.id_proyecto = p.id_proyecto AND x.id_canal = c.id
  );

DO $reporte$
DECLARE
  v_filas bigint;
BEGIN
  SELECT count(*) INTO v_filas FROM public.comisiones_canal_config;
  RAISE NOTICE 'comisiones_canal_config: % fila(s) tras la siembra.', v_filas;
END
$reporte$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT column_name, data_type, is_nullable, column_default
--   FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='comisiones_canal_config'
--   ORDER BY ordinal_position;
--
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid='public.comisiones_canal_config'::regclass ORDER BY conname;
--
--   SELECT indexname, indexdef FROM pg_indexes
--   WHERE schemaname='public' AND tablename='comisiones_canal_config' ORDER BY indexname;
--   -- comisiones_canal_config_proyecto_canal_uq debe salir SIN clausula WHERE
--
-- RLS + policy + trigger + `anon` sin GRANT:
--   SELECT c.relrowsecurity AS rls,
--          (SELECT count(*) FROM pg_policies p
--           WHERE p.tablename='comisiones_canal_config') AS policies
--   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
--   WHERE n.nspname='public' AND c.relname='comisiones_canal_config';
--
--   SELECT table_name, grantee, privilege_type FROM information_schema.role_table_grants
--   WHERE table_schema='public' AND table_name='comisiones_canal_config'
--     AND grantee='anon';   -- esperado: 0 filas
--
-- Resultado de la siembra y remanente por canal:
--   SELECT pr.nombre AS proyecto, ca.nombre AS canal,
--          cc.comision_total_pct, ca.comision_externa_pct,
--          cc.comision_total_pct - ca.comision_externa_pct AS a_dispersar
--   FROM public.comisiones_canal_config cc
--   JOIN public.proyectos pr ON pr.id = cc.id_proyecto
--   JOIN public.comisiones_canales ca ON ca.id = cc.id_canal
--   WHERE cc.activo ORDER BY pr.nombre, ca.nombre;
--   -- esperado: 12 filas (Daiku 1453 y Monocolo 1902 x 6 canales activos), todas al 6%
--
-- ─── El catálogo de canales DIVERGE entre entornos ────────────────────────────
-- Verificado read-only el 2026-08-10. La siembra funciona igual en ambos porque cruza por
-- id de canal activo, pero los UAT del anexo que hablan de "id_canal = 1 / Inmobiliaria
-- Nueva" NO aplican a producción, donde el canal 1 es "Wallking":
--
--   id | Preview (segun el anexo)         | Produccion (real)
--   ---+----------------------------------+---------------------------------
--   1  | Inmobiliaria Nueva       2.00    | Wallking              0.00
--   2  | Asesor Independiente     2.00    | Agente Independiente  2.00
--   3  | Embajador                1.00    | Embajador             0.50
--   4  | Referido                 0.50    | Socio                 1.00
--   5  | Canal Interno Marketing  0.00    | Canal Inbound         0.00
--   6  | Inmobiliaria Consolidada 4.00    | Inmobiliaria          4.00
--
-- En ambos son 6 canales activos y 2 proyectos con reglas, asi que la siembra deja
-- 12 filas en los dos entornos.
--
-- Nota sobre la siembra al 6%: `comisiones_canales` ya tiene una columna
-- `comision_base_pct` que podria parecer mejor semilla, pero en produccion vale
-- exactamente lo mismo que `comision_externa_pct` en los 6 canales, asi que sembrar con
-- ella dejaria "a dispersar" en 0% en todos. El 6% reproduce lo que la pantalla venia
-- mostrando, que es el objetivo de la siembra.
--
-- ─── Front dependiente de este DDL (repo sozu-admin) ──────────────────────────
-- types/simulator.ts (MotorConfig.channelTotals), useMotorComisionesSync.ts (lee/escribe
-- comisiones_canal_config en vez de comisiones_motor_config), SimulatorContext.tsx,
-- CommissionsTab.tsx y MotorComisionesReadOnly.tsx. Mientras el DDL no se ejecute, la
-- pantalla arranca con los canales en 0% y avisa: nada se rompe, pero tampoco se puede
-- guardar el porcentaje.
