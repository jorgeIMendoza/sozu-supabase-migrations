-- Incentivos por metas de cierre mensual, por proyecto y canal
-- Fecha: 2026-08-11
-- Origen: Ejecuciones/ejecusiones.md — "Incentivos por metas de cierre mensual"
--         (extraído del Anexo 8 de 20260809_directorio_personal_rrhh.md)
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- Reemplaza la lógica de Incentivos Dinámicos, que no se opera, por la real: la comisión
-- sube cuando el canal alcanza metas de ventas en el mes.
--
--   1. Se definen metas de cierre por mes para cada canal: 3 ventas, 5 ventas, 7 ventas...
--   2. Cada meta alcanzada incrementa un PORCENTAJE SOBRE LA COMISION BASE del
--      comisionista (+20%, +40%, +60% de su base — NO puntos porcentuales).
--   3. El contador es del CANAL COMPLETO: al alcanzar la meta sube el porcentaje de TODOS
--      los comisionistas de ese canal, hayan vendido mucho o poco.
--   4. El efecto es RETROACTIVO al mes: alcanzada la meta, todas las ventas del mes se
--      liquidan al porcentaje nuevo.
--
-- ─── Auditoría (verificado read-only contra producción el 2026-08-11) ─────────
-- El módulo actual es 100% front, sin respaldo en base de datos. No existe ninguna tabla
-- de incentivos, metas o escalones: buscando `%incentivo%`, `%meta%` y `%escalon%` en
-- information_schema.tables los únicos resultados son `crm_meta_capi_eventos` y
-- `crm_meta_conversion_stages`, del CRM de Meta Ads, sin relación.
--
-- La configuración vivía en localStorage (VolumeRule, SaleAmountRule, DownPaymentRule).
-- NO HAY DATOS QUE MIGRAR: al no estar en BD, retirar esas reglas no destruye nada
-- capturado por el negocio.
--
-- ─── Decisiones ───────────────────────────────────────────────────────────────
-- · Una fila = un escalón de un canal en un proyecto. La escalera vive en
--   `(id_proyecto, id_canal)` porque todo el motor es por proyecto y los canales ya se
--   configuran por desarrollo. Un canal puede escalar distinto en Daiku que en Monócolo.
-- · `incremento_pct` es un porcentaje SOBRE la comisión base, no puntos porcentuales. Con
--   base 1.0% e incremento_pct = 20, el efectivo es 1.2%, no 21%. Va en el COMMENT porque
--   es la confusión más probable al leer la tabla.
-- · El escalón aplicable es el MAYOR alcanzado, no la suma. Con metas 3/5/7 y 6 ventas
--   aplica el de 5 (+40%), no 3+5 (+60%). Sumarlos haría crecer la escalera más rápido de
--   lo pactado y volvería el costo difícil de anticipar. La BD guarda la política; la
--   resolución del escalón es un `max(incremento_pct) WHERE ventas_meta <= ventas_mes`.
-- · `UNIQUE (id_proyecto, id_canal, ventas_meta)` evita dos escalones para la misma
--   cantidad de ventas, que sería ambiguo. NO parcial: PostgREST debe poder inferirlo para
--   el on_conflict del upsert, mismo criterio que `comisiones_reglas_persona_uq`
--   (20260809050000) y `comisiones_canal_config_proyecto_canal_uq` (20260810000000).
-- · NO se guarda el resultado mensual, se calcula. Las ventas del mes ya viven en
--   `propiedades` / `cuentas_cobranza`; duplicarlas en una tabla de "logros" crearía una
--   segunda fuente que se desincroniza. Esta tabla guarda SOLO la política.
-- · Baja lógica (`activo`): retirar un escalón conserva el histórico de la política con la
--   que se liquidaron meses anteriores.
-- · `numeric(6,2)` en `incremento_pct`, la precisión del resto del dominio de comisiones
--   (`comisiones_canales.comision_externa_pct`, `comisiones_reglas.porcentaje`,
--   `comisiones_canal_config.comision_total_pct`). El documento decía `numeric` a secas.
--
-- Idempotente: CREATE ... IF NOT EXISTS, DROP POLICY/TRIGGER IF EXISTS. Nace vacía, así
-- que no altera ninguna liquidación. Sin BEGIN/COMMIT (el CI envuelve cada archivo).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. La escalera de metas
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.comisiones_metas_escalon (
  id                  bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_proyecto         integer      NOT NULL REFERENCES public.proyectos (id),
  id_canal            bigint       NOT NULL REFERENCES public.comisiones_canales (id),
  ventas_meta         integer      NOT NULL,
  incremento_pct      numeric(6,2) NOT NULL DEFAULT 0,
  activo              boolean      NOT NULL DEFAULT true,
  fecha_creacion      timestamptz  NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT comisiones_metas_escalon_ventas_chk
    CHECK (ventas_meta > 0 AND ventas_meta <= 1000),
  CONSTRAINT comisiones_metas_escalon_incremento_chk
    CHECK (incremento_pct >= 0 AND incremento_pct <= 1000)
);

COMMENT ON TABLE public.comisiones_metas_escalon IS
  'Escalera de incentivos por metas de cierre mensual. Una fila = un escalon de un canal '
  'en un proyecto. El contador es del CANAL completo en el mes: al alcanzar la meta sube '
  'la comision de TODOS los comisionistas de ese canal, y el efecto es RETROACTIVO al mes '
  '(todas las ventas del mes se liquidan al porcentaje nuevo).';
COMMENT ON COLUMN public.comisiones_metas_escalon.ventas_meta IS
  'Numero de ventas del canal en el mes que dispara este escalon (3, 5, 7...).';
COMMENT ON COLUMN public.comisiones_metas_escalon.incremento_pct IS
  'Incremento expresado como PORCENTAJE DE LA COMISION BASE, no en puntos porcentuales: '
  'con base 1.0% e incremento_pct = 20, la comision efectiva es 1.2%. Aplica el escalon '
  'MAYOR alcanzado, no la suma de los escalones.';
COMMENT ON COLUMN public.comisiones_metas_escalon.activo IS
  'Baja logica: retirar un escalon conserva el historico de la politica con la que se '
  'liquidaron meses anteriores.';

-- Dos escalones para la misma cantidad de ventas serian ambiguos.
-- No parcial: PostgREST debe poder inferirlo para el on_conflict del upsert.
CREATE UNIQUE INDEX IF NOT EXISTS comisiones_metas_escalon_uq
  ON public.comisiones_metas_escalon (id_proyecto, id_canal, ventas_meta);

CREATE INDEX IF NOT EXISTS idx_comisiones_metas_escalon_proyecto_canal
  ON public.comisiones_metas_escalon (id_proyecto, id_canal);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. fecha_actualizacion automática
-- ═══════════════════════════════════════════════════════════════════════════════
DROP TRIGGER IF EXISTS trg_comisiones_metas_escalon_upd ON public.comisiones_metas_escalon;
CREATE TRIGGER trg_comisiones_metas_escalon_upd
  BEFORE UPDATE ON public.comisiones_metas_escalon
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. RLS + GRANTS
--    Mismo patrón que el resto del dominio de comisiones, pero SIN `anon`: las default
--    privileges de Supabase sobre `public` conceden a `anon` todos los privilegios en
--    cada tabla nueva. Hoy RLS lo frenaría (no hay policy para anon), pero el GRANT
--    quedaría como trampa para la primera policy permisiva que llegue. Mismo criterio
--    que 20260806100000, 20260809000000 y 20260810000000.
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.comisiones_metas_escalon ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS comisiones_metas_escalon_rls_auth ON public.comisiones_metas_escalon;
CREATE POLICY comisiones_metas_escalon_rls_auth
  ON public.comisiones_metas_escalon
  FOR ALL TO authenticated
  USING ((SELECT auth.uid()) IS NOT NULL)
  WITH CHECK ((SELECT auth.uid()) IS NOT NULL);

REVOKE ALL PRIVILEGES ON TABLE public.comisiones_metas_escalon FROM anon;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.comisiones_metas_escalon
  TO authenticated, service_role;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT column_name, data_type, is_nullable, column_default
--   FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='comisiones_metas_escalon'
--   ORDER BY ordinal_position;
--
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid='public.comisiones_metas_escalon'::regclass ORDER BY conname;
--
--   SELECT indexname, indexdef FROM pg_indexes
--   WHERE schemaname='public' AND tablename='comisiones_metas_escalon' ORDER BY indexname;
--   -- comisiones_metas_escalon_uq debe salir SIN clausula WHERE
--
-- RLS + policy + trigger + `anon` sin GRANT:
--   SELECT c.relrowsecurity AS rls,
--          (SELECT count(*) FROM pg_policies p
--           WHERE p.tablename='comisiones_metas_escalon') AS policies
--   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
--   WHERE n.nspname='public' AND c.relname='comisiones_metas_escalon';
--
--   SELECT table_name, grantee, privilege_type FROM information_schema.role_table_grants
--   WHERE table_schema='public' AND table_name='comisiones_metas_escalon'
--     AND grantee='anon';   -- esperado: 0 filas
--
-- La tabla nace vacia: sin escalones la comision es la base y nada cambia:
--   SELECT count(*) AS escalones FROM public.comisiones_metas_escalon;   -- esperado: 0
--
-- ─── La resolución del escalón, para que el front y los reportes coincidan ────
-- Dado un proyecto, un canal y las ventas del mes, el incremento aplicable es el del
-- escalon MAYOR alcanzado. En SQL:
--
--   SELECT COALESCE(max(e.incremento_pct), 0) AS incremento_pct
--   FROM public.comisiones_metas_escalon e
--   WHERE e.id_proyecto = $1 AND e.id_canal = $2 AND e.activo
--     AND e.ventas_meta <= $3;
--
--   comision_efectiva = comision_base * (1 + incremento_pct / 100)
--
-- Con escalera 3/5/7 -> +20/+40/+60 y base 1.0%:
--   0 ventas -> 1.0 · 2 -> 1.0 · 3 -> 1.2 · 4 -> 1.2 · 6 -> 1.4 · 7 -> 1.6 · 12 -> 1.6
--
-- ─── Front dependiente de este DDL (repo sozu-admin) ──────────────────────────
-- Un hook nuevo de metas y BrokerIncentivesTab.tsx. Mientras el DDL no se ejecute, la
-- pantalla detecta la ausencia de la tabla y muestra el aviso correspondiente en vez de
-- romperse.
--
-- OJO: `broker-incentives.ts` y `broker-calculations.ts` NO se eliminan del repositorio.
-- `AgentPortalTab` (Simulador de Ingresos) importa `calculateBrokerCommission` y
-- `DEFAULT_BROKER_CONFIG` de ese mismo modulo. Se retira su uso de la pantalla de
-- Incentivos Dinamicos, que es lo solicitado, y esa otra pantalla queda intacta.
