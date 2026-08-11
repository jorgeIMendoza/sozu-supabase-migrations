-- Personal: empleados de SOZU vs colaboradores del Grupo Investimento
-- Fecha: 2026-08-11
-- Origen: Ejecuciones/ejecusiones.md
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- El personal de la organizacion se clasifica en dos perfiles, porque solo uno representa
-- costo para SOZU:
--
--   perfil                         sueldo lo paga   costo fijo de SOZU   puede comisionar
--   ------------------------------ ---------------- -------------------- ----------------
--   empleado_sozu                  SOZU             SI                   si
--   colaborador_investimento       Investimento     NO                   si, como bono
--
-- Los colaboradores de Investimento dan servicio y soporte en areas administrativas,
-- fiscales, financieras y legales. Se registran porque en algunos casos reciben comisiones
-- como bono por ese soporte, pero SOZU no paga su sueldo: su costo no puede sumar al costo
-- fijo de la operacion.
--
-- ─── Por qué importa ──────────────────────────────────────────────────────────
-- Verificado read-only contra produccion el 2026-08-11: 15 personas activas, 13 con rol
-- vinculado, costo total mensual $300,000.00. Hoy esa cifra incluye a todos por igual
-- porque no existe forma de distinguir quien es de SOZU y quien de Investimento, y es la
-- que alimenta ademas de Roles y Sueldos el costo por proyecto, el Organigrama y los
-- Financieros via la derivacion a roleAssignments del simulador. Si parte de esas 15
-- personas resulta ser de Investimento, el costo fijo de SOZU esta sobreestimado en todas
-- esas vistas.
--
-- ─── Decisiones ───────────────────────────────────────────────────────────────
-- · Columna `text` con CHECK, no un booleano `es_empleado_sozu`. Un booleano obliga a leer
--   "no empleado" como "es de Investimento", inferencia que deja de ser cierta en cuanto
--   aparezca un tercer perfil (un prestador externo, otra empresa del grupo). El texto se
--   autodocumenta al leer la tabla. Mismo criterio que `roles_organizacionales.pertenece_a`
--   y `.tipo`.
-- · `DEFAULT 'empleado_sozu'` y `NOT NULL`: las 15 filas existentes quedan como empleados
--   directos, que es exactamente el comportamiento de hoy. EL COSTO FIJO NO CAMBIA AL
--   EJECUTAR ESTE DDL. La reclasificacion es una decision de negocio que se toma desde la
--   pantalla, no algo que el DDL deba adivinar.
-- · El costo de Investimento se EXCLUYE de los agregados de SOZU, no se pone en cero. Los
--   campos de costo siguen capturables porque el dato existe y sirve de referencia —cuanto
--   vale ese soporte—, pero no suma al costo fijo, ni al costo por proyecto, ni a la
--   estructura que el simulador manda a Organigrama y Financieros. Ponerlos en cero
--   destruiria informacion; excluirlos del calculo la conserva y arregla la cifra.
-- · Los colaboradores de Investimento SI pueden comisionar: no se filtran en Comisiones.
--   El bono por soporte es justo la razon por la que se registran. Lo unico que cambia es
--   de que lado cae su costo.
-- · No se crea una tabla de "empresas del grupo". Con dos perfiles conocidos y sin mas
--   atributos que administrar por empresa, seria estructura sin uso. Si mas adelante se
--   necesitan datos de la empresa (RFC, contacto, contrato), ese es el momento de crearla
--   y migrar el `text` a FK.
--
-- Aditivo e idempotente: ADD COLUMN / CREATE INDEX IF NOT EXISTS y DROP CONSTRAINT IF
-- EXISTS antes del ADD. Sin BEGIN/COMMIT (el CI envuelve cada archivo).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. El perfil de la persona
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.personal_organizacional
  ADD COLUMN IF NOT EXISTS tipo_personal text NOT NULL DEFAULT 'empleado_sozu';

ALTER TABLE public.personal_organizacional
  DROP CONSTRAINT IF EXISTS personal_organizacional_tipo_chk;
ALTER TABLE public.personal_organizacional
  ADD CONSTRAINT personal_organizacional_tipo_chk
    CHECK (tipo_personal IN ('empleado_sozu', 'colaborador_investimento'));

COMMENT ON COLUMN public.personal_organizacional.tipo_personal IS
  'empleado_sozu = empleado directo, su costo ES costo fijo de SOZU. '
  'colaborador_investimento = colaborador del Grupo Investimento que da servicio y soporte '
  '(administrativo, fiscal, financiero, legal); SOZU NO paga su sueldo, asi que su costo '
  'NO suma al costo fijo, al costo por proyecto ni a la estructura del simulador. Ambos '
  'perfiles pueden comisionar: al colaborador la comision es un bono por el soporte.';

CREATE INDEX IF NOT EXISTS idx_personal_organizacional_tipo
  ON public.personal_organizacional (tipo_personal);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Reporte: el costo fijo no se mueve con este DDL
-- ═══════════════════════════════════════════════════════════════════════════════
DO $reporte$
DECLARE
  v_sozu_n     bigint;
  v_sozu_c     numeric;
  v_inv_n      bigint;
  v_inv_c      numeric;
BEGIN
  SELECT count(*) FILTER (WHERE tipo_personal = 'empleado_sozu'),
         COALESCE(sum(costo_total) FILTER (WHERE tipo_personal = 'empleado_sozu'), 0),
         count(*) FILTER (WHERE tipo_personal = 'colaborador_investimento'),
         COALESCE(sum(costo_total) FILTER (WHERE tipo_personal = 'colaborador_investimento'), 0)
  INTO v_sozu_n, v_sozu_c, v_inv_n, v_inv_c
  FROM public.personal_organizacional
  WHERE activo;

  RAISE NOTICE
    'personal activo: % empleado(s) de SOZU (costo %), % colaborador(es) de Investimento (costo %). Reclasificar desde la pantalla.',
    v_sozu_n, v_sozu_c, v_inv_n, v_inv_c;
END
$reporte$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT column_name, data_type, is_nullable, column_default
--   FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='personal_organizacional'
--   ORDER BY ordinal_position;
--
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid='public.personal_organizacional'::regclass
--     AND conname='personal_organizacional_tipo_chk';
--
-- Nada cambia de entrada — todas quedan como empleados de SOZU:
--   SELECT tipo_personal, count(*) AS personas, sum(costo_total) AS costo
--   FROM public.personal_organizacional WHERE activo
--   GROUP BY tipo_personal ORDER BY tipo_personal;
--   -- esperado tras el ALTER: empleado_sozu = 15 personas, 300000.00
--
-- Costo fijo REAL de SOZU una vez reclasificado el personal:
--   SELECT
--     sum(costo_total) FILTER (WHERE tipo_personal='empleado_sozu')            AS costo_sozu,
--     sum(costo_total) FILTER (WHERE tipo_personal='colaborador_investimento') AS costo_investimento,
--     sum(costo_total)                                                         AS costo_registrado
--   FROM public.personal_organizacional WHERE activo;
--
-- Colaboradores de Investimento que ademas comisionan (el caso del bono):
--   SELECT p.nombre, p.tipo_personal, count(r.id) AS reglas_de_comision
--   FROM public.personal_organizacional p
--   JOIN public.comisiones_reglas r ON r.id_personal = p.id
--   WHERE p.activo AND p.tipo_personal='colaborador_investimento'
--   GROUP BY p.nombre, p.tipo_personal ORDER BY p.nombre;
--
-- ─── Lo que este DDL NO garantiza ─────────────────────────────────────────────
-- La exclusion del costo de Investimento vive ENTERAMENTE en el front: la columna
-- clasifica, pero nada en la base impide que una consulta sume `costo_total` sin filtrar
-- por `tipo_personal` y vuelva a sobreestimar el costo fijo. Cualquier vista, RPC o
-- reporte que agregue costo de personal debe filtrar
-- `tipo_personal = 'empleado_sozu'` explicitamente. Si mas adelante los consumidores se
-- multiplican, el lugar natural para blindarlo es una vista que ya traiga el filtro
-- aplicado, en vez de repetir la condicion en cada llamador.
--
-- ─── Front dependiente de este DDL (repo sozu-admin) ──────────────────────────
-- useDirectorioPuestos.ts (campo y filtros), DirectorioPuestosTab.tsx (selector, KPIs y
-- costo por proyecto) y useEstructuraRealSimulador.ts (excluir Investimento de
-- roleAssignments). Mientras el DDL no se ejecute, el front trata a todo el personal como
-- empleado de SOZU: la pantalla sigue funcionando exactamente como hoy.
