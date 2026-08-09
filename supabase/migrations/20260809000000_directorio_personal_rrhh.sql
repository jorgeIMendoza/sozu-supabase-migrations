-- Directorio de Personal — modelo de Administración de Recurso Humano
-- Fecha: 2026-08-09
-- Origen: Ejecuciones/ejecusiones.md
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- El submenú "Directorio de Personal" (Portal Estructura de Comisiones,
-- /admin/portal-estructura-comisiones/directorio, submenus.id = 368) modelaba hoy
-- "puestos" como filas rol + proyecto + sueldo, con el ocupante como texto secundario
-- (`puestos_organizacionales`). Se sustituye por un modelo RRHH en tres pasos:
--
--   1. La PERSONA existe por sí sola          -> personal_organizacional
--   2. Se vincula con UN rol de la empresa    -> personal_organizacional.id_rol (nullable)
--   3. Se vincula con N proyectos que atiende -> personal_proyectos (con % de asignación)
--
-- El costo fijo mensual deja de ser atributo de la fila "puesto+proyecto" y pasa a ser
-- atributo de la persona. El costo por proyecto se DERIVA:
--   costo_persona = sueldo_base * (1 + prestaciones_pct/100) + bono_fijo
--   costo_proyecto = costo_persona * asignacion_pct / 100
--
-- ─── Decisiones de diseño ─────────────────────────────────────────────────────
-- · El rol es una COLUMNA en la persona, no una tabla puente: el requerimiento es un
--   rol por persona. Una puente dejaría ambiguo qué rol aplica al calcular comisión.
--   Si mañana hace falta rol distinto por proyecto, se agrega `id_rol` a
--   `personal_proyectos` como override — no se rompe este modelo.
-- · `id_rol` es NULLABLE: el alta (paso 1) ocurre antes de la vinculación (paso 2).
-- · La compensación vive en la persona, no en la asignación: una persona tiene un
--   sueldo aunque atienda tres proyectos.
-- · Baja lógica con rastro (`activo=false` + `fecha_baja` + `motivo_baja`). No se borra
--   personal: el histórico de costo debe poder reconstruirse.
-- · `puestos_organizacionales` NO se elimina; se marca deprecada vía COMMENT ON. Su
--   borrado es decisión posterior, tras validar en Preview y Producción.
--
-- ─── Notas de tipos (verificado contra el esquema vivo) ───────────────────────
-- · usuarios.PK = email (no id) -> email_usuario es text REFERENCES usuarios(email).
-- · proyectos.id es INTEGER (no bigint) -> id_proyecto integer para que el FK coincida.
-- · roles_organizacionales.id es BIGINT.
-- · numeric(12,2) / numeric(5,2) replican las precisiones de puestos_organizacionales,
--   para que la migración de datos no redondee distinto al origen.
--
-- Idempotente: CREATE ... IF NOT EXISTS, DROP POLICY/TRIGGER IF EXISTS y la migración de
-- datos va guardada por "personal_organizacional está vacía". Sin BEGIN/COMMIT (el CI
-- envuelve cada archivo en su propia transacción).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. LA PERSONA — alta, baja y modificación del personal de la organización
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.personal_organizacional (
  id                  bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre              text          NOT NULL,
  email_usuario       text          REFERENCES public.usuarios (email),
  email_contacto      text,
  telefono            text,
  id_rol              bigint        REFERENCES public.roles_organizacionales (id),
  sueldo_base         numeric(12,2) NOT NULL DEFAULT 0,
  bono_fijo           numeric(12,2) NOT NULL DEFAULT 0,
  prestaciones_pct    numeric(5,2)  NOT NULL DEFAULT 0,
  fecha_ingreso       date,
  fecha_baja          date,
  motivo_baja         text,
  activo              boolean       NOT NULL DEFAULT true,
  fecha_creacion      timestamptz   NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT personal_organizacional_nombre_chk
    CHECK (btrim(nombre) <> ''),
  CONSTRAINT personal_organizacional_montos_chk
    CHECK (sueldo_base >= 0 AND bono_fijo >= 0 AND prestaciones_pct >= 0),
  -- Una persona activa no puede arrastrar fecha de baja.
  CONSTRAINT personal_organizacional_baja_chk
    CHECK (activo = false OR fecha_baja IS NULL),
  CONSTRAINT personal_organizacional_fechas_chk
    CHECK (fecha_baja IS NULL OR fecha_ingreso IS NULL OR fecha_baja >= fecha_ingreso)
);

-- Un usuario del sistema no puede tener dos fichas de personal.
CREATE UNIQUE INDEX IF NOT EXISTS personal_organizacional_email_usuario_uq
  ON public.personal_organizacional (email_usuario)
  WHERE email_usuario IS NOT NULL;

CREATE INDEX IF NOT EXISTS personal_organizacional_id_rol_idx
  ON public.personal_organizacional (id_rol);
CREATE INDEX IF NOT EXISTS personal_organizacional_activo_idx
  ON public.personal_organizacional (activo);

COMMENT ON TABLE public.personal_organizacional IS
  'Directorio de Personal (RRHH) del Portal Estructura de Comisiones. Una fila = una '
  'persona de la organizacion. El rol es opcional (se vincula en un segundo paso) y los '
  'proyectos que atiende viven en personal_proyectos. La compensacion es atributo de la '
  'persona; el costo por proyecto se deriva del % de asignacion.';
COMMENT ON COLUMN public.personal_organizacional.email_usuario IS
  'Cuenta del sistema (usuarios.email) cuando la persona ya tiene acceso. NULL si aun no.';
COMMENT ON COLUMN public.personal_organizacional.id_rol IS
  'Rol organizacional (roles_organizacionales). NULL = alta sin rol vinculado todavia.';
COMMENT ON COLUMN public.personal_organizacional.sueldo_base IS
  'Compensacion mensual bruta. Costo total = sueldo_base * (1 + prestaciones_pct/100) + bono_fijo.';
COMMENT ON COLUMN public.personal_organizacional.motivo_baja IS
  'Texto libre del motivo de la baja logica. Solo tiene sentido con activo = false.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. VINCULACIÓN CON PROYECTOS — a qué proyectos da servicio la persona
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.personal_proyectos (
  id                  bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_personal         bigint       NOT NULL
                        REFERENCES public.personal_organizacional (id) ON DELETE CASCADE,
  id_proyecto         integer      NOT NULL REFERENCES public.proyectos (id),
  asignacion_pct      numeric(5,2) NOT NULL DEFAULT 100,
  fecha_inicio        date,
  fecha_fin           date,
  activo              boolean      NOT NULL DEFAULT true,
  fecha_creacion      timestamptz  NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT personal_proyectos_pct_chk
    CHECK (asignacion_pct > 0 AND asignacion_pct <= 100),
  CONSTRAINT personal_proyectos_fechas_chk
    CHECK (fecha_fin IS NULL OR fecha_inicio IS NULL OR fecha_fin >= fecha_inicio)
);

-- Una persona no puede estar vinculada dos veces al mismo proyecto (vigente).
CREATE UNIQUE INDEX IF NOT EXISTS personal_proyectos_persona_proyecto_uq
  ON public.personal_proyectos (id_personal, id_proyecto)
  WHERE activo;

CREATE INDEX IF NOT EXISTS personal_proyectos_id_personal_idx
  ON public.personal_proyectos (id_personal);
CREATE INDEX IF NOT EXISTS personal_proyectos_id_proyecto_idx
  ON public.personal_proyectos (id_proyecto);

COMMENT ON TABLE public.personal_proyectos IS
  'Vinculacion persona <-> proyectos a los que da servicio. asignacion_pct prorratea el '
  'costo mensual de la persona entre los proyectos que atiende.';
COMMENT ON COLUMN public.personal_proyectos.asignacion_pct IS
  'Porcentaje del costo de la persona imputado a este proyecto (0 < pct <= 100).';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. fecha_actualizacion automática
--    Se reutiliza el helper que ya existe en la DB (20260519000001_create_demandas),
--    que ya trae `SET search_path` endurecido. No se crea una función nueva.
-- ═══════════════════════════════════════════════════════════════════════════════
DROP TRIGGER IF EXISTS trg_personal_organizacional_upd ON public.personal_organizacional;
CREATE TRIGGER trg_personal_organizacional_upd
  BEFORE UPDATE ON public.personal_organizacional
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

DROP TRIGGER IF EXISTS trg_personal_proyectos_upd ON public.personal_proyectos;
CREATE TRIGGER trg_personal_proyectos_upd
  BEFORE UPDATE ON public.personal_proyectos
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. RLS + GRANTS
--    Mismo patrón de policy que roles_/puestos_organizacionales, PERO sin `anon`:
--    estas tablas guardan sueldos y datos de contacto del personal, y las default
--    privileges de Supabase le conceden a `anon` todos los privilegios sobre cualquier
--    tabla nueva de `public`. Hoy RLS lo frenaría (no hay policy para anon), pero el
--    GRANT quedaría puesto como trampa para la primera policy permisiva que llegue.
--    Se revoca explícitamente — mismo criterio que 20260806100000.
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.personal_organizacional ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.personal_proyectos      ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS personal_organizacional_rls_auth ON public.personal_organizacional;
CREATE POLICY personal_organizacional_rls_auth
  ON public.personal_organizacional
  FOR ALL TO authenticated
  USING ((SELECT auth.uid()) IS NOT NULL)
  WITH CHECK ((SELECT auth.uid()) IS NOT NULL);

DROP POLICY IF EXISTS personal_proyectos_rls_auth ON public.personal_proyectos;
CREATE POLICY personal_proyectos_rls_auth
  ON public.personal_proyectos
  FOR ALL TO authenticated
  USING ((SELECT auth.uid()) IS NOT NULL)
  WITH CHECK ((SELECT auth.uid()) IS NOT NULL);

REVOKE ALL PRIVILEGES ON TABLE public.personal_organizacional FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.personal_proyectos      FROM anon;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.personal_organizacional, public.personal_proyectos
  TO authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. MIGRACIÓN de datos desde puestos_organizacionales
--    Preserva el costo mensual ya capturado. Los puestos sin ocupante quedan como
--    'Por definir #<id>' para renombrarlos o darlos de baja desde la UI.
--    Guardada por "la tabla destino está vacía" -> correr dos veces no duplica.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $mig$
DECLARE
  r            record;
  v_id_persona bigint;
  v_email      text;
  v_nombre     text;
  v_migrados   int := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM public.personal_organizacional) THEN
    RAISE NOTICE 'personal_organizacional ya tiene datos: migracion omitida.';
    RETURN;
  END IF;

  FOR r IN
    SELECT p.*, u.nombre AS nombre_usuario
    FROM public.puestos_organizacionales p
    LEFT JOIN public.usuarios u ON u.email = p.email_usuario
    WHERE p.activo
    ORDER BY p.id
  LOOP
    -- El email solo se conserva si no lo tomó ya un puesto anterior: el índice único
    -- parcial rechazaría el segundo y abortaría toda la migración.
    v_email := r.email_usuario;
    IF v_email IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.personal_organizacional WHERE email_usuario = v_email
    ) THEN
      RAISE NOTICE 'Puesto % : email % ya migrado en otra ficha, se migra sin usuario ligado.',
        r.id, v_email;
      v_email := NULL;
    END IF;

    v_nombre := COALESCE(
      NULLIF(btrim(r.nombre_ocupante), ''),
      NULLIF(btrim(r.nombre_usuario), ''),
      'Por definir #' || r.id::text
    );

    INSERT INTO public.personal_organizacional (
      nombre, email_usuario, id_rol,
      sueldo_base, bono_fijo, prestaciones_pct, fecha_ingreso, activo
    )
    VALUES (
      v_nombre, v_email, r.id_rol,
      r.sueldo_base, r.bono_fijo, r.prestaciones_pct, r.fecha_inicio, true
    )
    RETURNING id INTO v_id_persona;

    IF r.id_proyecto IS NOT NULL THEN
      INSERT INTO public.personal_proyectos (
        id_personal, id_proyecto, asignacion_pct, fecha_inicio
      )
      VALUES (v_id_persona, r.id_proyecto, 100, r.fecha_inicio);
    END IF;

    v_migrados := v_migrados + 1;
  END LOOP;

  RAISE NOTICE 'Migracion completada: % puesto(s) -> personal_organizacional.', v_migrados;
END
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. Deprecación de la tabla anterior (NO se borra: se conserva el histórico)
-- ═══════════════════════════════════════════════════════════════════════════════
COMMENT ON TABLE public.puestos_organizacionales IS
  'DEPRECADA 2026-08-09. Sustituida por personal_organizacional + personal_proyectos '
  '(modelo RRHH: persona -> rol -> proyectos). El front deja de leerla. Se conserva solo '
  'como respaldo de la migracion; evaluar su borrado tras validar en Produccion.';

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
-- Estructura, identity, constraints e índices:
--   SELECT conrelid::regclass AS tabla, conname, pg_get_constraintdef(oid)
--   FROM pg_constraint
--   WHERE conrelid IN ('public.personal_organizacional'::regclass,
--                      'public.personal_proyectos'::regclass)
--   ORDER BY 1, 2;
--
--   SELECT tablename, indexname, indexdef FROM pg_indexes
--   WHERE schemaname='public'
--     AND tablename IN ('personal_organizacional','personal_proyectos') ORDER BY 1,2;
--
-- RLS activo + 1 policy por tabla, y `anon` sin GRANT:
--   SELECT c.relname, c.relrowsecurity,
--          (SELECT count(*) FROM pg_policies p WHERE p.tablename = c.relname) AS policies
--   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--   WHERE n.nspname='public'
--     AND c.relname IN ('personal_organizacional','personal_proyectos');
--
--   SELECT table_name, grantee, privilege_type FROM information_schema.role_table_grants
--   WHERE table_schema='public'
--     AND table_name IN ('personal_organizacional','personal_proyectos')
--     AND grantee='anon';   -- esperado: 0 filas
--
-- Resultado de la migración de datos — el costo total debe coincidir con el previo:
--   SELECT
--     (SELECT count(*) FROM public.puestos_organizacionales WHERE activo) AS puestos_previos,
--     (SELECT count(*) FROM public.personal_organizacional  WHERE activo) AS personal_migrado,
--     (SELECT COALESCE(sum(sueldo_base*(1+prestaciones_pct/100)+bono_fijo),0)
--        FROM public.puestos_organizacionales WHERE activo) AS costo_previo,
--     (SELECT COALESCE(sum(sueldo_base*(1+prestaciones_pct/100)+bono_fijo),0)
--        FROM public.personal_organizacional WHERE activo)  AS costo_migrado;
--
-- OJO — el resultado esperado NO es el mismo en cada entorno:
--   · Preview (VPS 45.232.252.100:5433): 2 puestos activos, costo 52000.00.
--   · Producción (verificado read-only el 2026-08-09): 1 fila, 0 activas, costo 0.
--     En prod la migración reporta "0 puesto(s)" y el directorio arranca vacío.
--     Eso es correcto, no un fallo del deploy.
--
-- ─── Front dependiente ────────────────────────────────────────────────────────
-- src/hooks/usePortalEstructuraComisiones/useDirectorioPuestos.ts y
-- src/components/admin/portal-estructura-comisiones/tabs/DirectorioPuestosTab.tsx
-- (repo sozu-admin). Hoy siguen leyendo `puestos_organizacionales`; esta migración no
-- los rompe (la tabla vieja sigue viva con sus datos). El cambio del front al nuevo
-- modelo va en su propio PR. No se requieren INSERTs de menús/permisos: el submenú
-- "Directorio de Personal" ya existe (submenus.id = 368) y la ruta no cambia.
