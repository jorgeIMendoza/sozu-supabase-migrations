-- =============================================================================
-- Estándar RLS base — TANDA 0: catálogo + helpers + seed
--
-- Regla base (Eduardo, 2026-07-29): acceso si (a) es dueño del registro, o
-- (b) su rol tiene el permiso correspondiente en un submenú ACTIVO de menú
-- ACTIVO declarado para esa tabla, o (c) su rol puede impersonar.
-- Mapeo comando → permiso: SELECT→leer, INSERT→crear, UPDATE→actualizar,
-- DELETE→eliminar.
--
-- Esta migración NO cambia ninguna policy: solo deja la infraestructura para que
-- cada tabla se cierre después copiando la plantilla del documento 06. El
-- comportamiento del panel queda idéntico.
--
-- Verificado read-only contra prod el 2026-07-29:
--   · rls_tablas_submenus no existe; current_puede_tabla / current_puede no existen.
--   · permisos: 1=leer, 2=crear, 3=actualizar, 4=eliminar (los ids del seed son
--     correctos), más 5=aprobar, 6=exportar, 8=generar_oferta,
--     9=generar_oferta_digital.
--   · user_has_permission ya exige s.activo y m.activo: el requisito de "menú
--     activo" no hay que repetirlo en cada policy.
--   · Inventario real (el del documento quedó desfasado por la PR de seguridad y
--     el drop de las 46 tablas legacy): 241 tablas, 97 sin RLS, 524 policies,
--     216 abiertas (true/true), 20 policies con anon.
--
-- Correcciones respecto al documento:
--   a) El seed apuntaba a '/admin/personas' y '/admin/entidades', que NO EXISTEN
--      como submenús. El JOIN las habría omitido en silencio: 11 filas en lugar
--      de las 17 declaradas. Aquí:
--        · '/admin/entidades' → '/admin/entidades-legales' (submenú 12).
--        · '/admin/personas'  → no tiene equivalente. La tabla personas se toca
--          desde 15 submenús (9 del menú Personas: Dueños, Prospectos,
--          Compradores, Residentes, Agentes, Vendedores, Representantes Legales,
--          Administradores, Representantes Comerciales; y 6 del menú Entidades).
--          Declarar solo una sería arbitrario, así que se siembran las tres rutas
--          verificadas y el inventario completo queda como paso previo explícito
--          de la tanda 1: sin él, la rama (b) negaría a Dueños, Residentes,
--          Agentes, Vendedores y Representantes en cuanto se cierre personas.
--      El seed ya no puede fallar en silencio: el bloque self-verifying aborta si
--      alguna tabla del catálogo queda con cero filas.
--   b) Se agrega REVOKE ALL ... FROM anon sobre el catálogo. Supabase tiene
--      default privileges que otorgan ALL a anon/authenticated/service_role en
--      las tablas nuevas de public, así que revocar solo INSERT/UPDATE/DELETE
--      habría dejado a anon con SELECT sobre el mapeo de permisos.
--   c) Sin BEGIN/COMMIT (supabase db push ya transacciona) y las policies se
--      crean con DROP POLICY IF EXISTS delante, porque CREATE POLICY no es
--      idempotente y rompería un re-run del CI.
--   d) El REVOKE de los helpers va FROM PUBLIC, anon. Igual que en las tablas,
--      pg_default_acl del esquema public otorga EXECUTE a anon en toda función
--      nueva, y revocar a PUBLIC no toca ese grant directo al rol. Con el patrón
--      del documento, current_puede_tabla y current_puede habrían quedado
--      ejecutables por anon. service_role conserva su EXECUTE.
--
-- Nota sobre los UAT del documento: UAT-2 y UAT-3 hacen UPDATE de submenus
-- dentro de BEGIN/ROLLBACK. No se ejecutaron: son escrituras contra prod y este
-- rol es read-only. Quedan para el entorno desechable o para Eduardo.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0.1 Catálogo tabla → submenú/permiso. Es DATOS: se edita con INSERT/UPDATE,
--     sin DDL ni redeploy.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.rls_tablas_submenus (
  id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tabla          text    NOT NULL,
  submenu_id     integer NOT NULL REFERENCES public.submenus(id),
  permiso_id     integer NOT NULL REFERENCES public.permisos(id),
  activo         boolean NOT NULL DEFAULT true,
  fecha_creacion timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rls_tablas_submenus_uq UNIQUE (tabla, submenu_id, permiso_id)
);

CREATE INDEX IF NOT EXISTS idx_rls_tablas_submenus_lookup
  ON public.rls_tablas_submenus (tabla, permiso_id) WHERE activo;

COMMENT ON TABLE public.rls_tablas_submenus IS
  'Mapeo tabla → submenú/permiso que legitima el acceso. Lo consume '
  'current_puede_tabla(). Una tabla puede declarar N submenús. Lo administra el '
  'equipo de datos, no la app: authenticated solo lee.';

ALTER TABLE public.rls_tablas_submenus ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rls_tablas_submenus_select ON public.rls_tablas_submenus;
CREATE POLICY rls_tablas_submenus_select ON public.rls_tablas_submenus
  FOR SELECT TO authenticated USING (true);

-- Las default privileges de Supabase otorgan ALL a anon/authenticated en las
-- tablas nuevas de public: hay que revocar explícitamente.
REVOKE ALL ON public.rls_tablas_submenus FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.rls_tablas_submenus FROM authenticated;
GRANT SELECT ON public.rls_tablas_submenus TO authenticated;

-- -----------------------------------------------------------------------------
-- 0.2 Helper canónico de la rama (b).
--     STABLE y sin referencias a la fila → Postgres lo evalúa una vez por
--     statement (InitPlan), no por registro.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.current_puede_tabla(_tabla text, _permiso text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.usuarios u
    JOIN public.rls_tablas_submenus rts
      ON rts.tabla = _tabla AND rts.activo = true
    JOIN public.submenus s
      ON s.id = rts.submenu_id AND s.activo = true
    JOIN public.menus m
      ON m.id = s.menu_id AND m.activo = true
    JOIN public.submenus_permisos sp
      ON sp.submenu_id = s.id
     AND sp.rol_id = u.rol_id
     AND sp.permiso_id = rts.permiso_id
     AND sp.activo = true
    JOIN public.permisos perm
      ON perm.id = sp.permiso_id AND perm.nombre = _permiso
    WHERE u.auth_user_id = auth.uid()
      AND u.activo = true
  );
$function$;

COMMENT ON FUNCTION public.current_puede_tabla(text, text) IS
  'Rama (b) de la regla base RLS: el rol del usuario tiene <_permiso> en algún submenú '
  'ACTIVO (menú ACTIVO) declarado para <_tabla> en rls_tablas_submenus. '
  'STABLE y row-independent: se evalúa una vez por statement.';

REVOKE ALL ON FUNCTION public.current_puede_tabla(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_puede_tabla(text, text) TO authenticated;

-- Regla completa para tablas sin noción de dueño.
CREATE OR REPLACE FUNCTION public.current_puede(_tabla text, _permiso text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.current_puede_tabla(_tabla, _permiso)
      OR public.current_puede_impersonar();
$function$;

COMMENT ON FUNCTION public.current_puede(text, text) IS
  'Regla base sin rama de dueño: permiso de menú activo O impersonar. '
  'Para tablas sin dueño identificable (catálogos operativos, tablas puente).';

REVOKE ALL ON FUNCTION public.current_puede(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_puede(text, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 0.3 Seed del catálogo para las tablas ya intervenidas.
--     Solo rutas verificadas contra prod. No cambia ninguna policy.
-- -----------------------------------------------------------------------------
INSERT INTO public.rls_tablas_submenus (tabla, submenu_id, permiso_id, activo)
SELECT v.tabla, s.id, v.permiso_id, true
FROM (VALUES
  -- personas: pantallas verificadas que la leen y editan.
  -- Falta el inventario completo (15 submenús la tocan); es el paso previo de la tanda 1.
  ('personas',          '/admin/compradores',       1),
  ('personas',          '/admin/compradores',       3),
  ('personas',          '/admin/prospectos',        1),
  -- OJO: 'personas' × /admin/prospectos × actualizar (3) NO se declara a
  -- propósito. Ese submenú da 'actualizar' al rol 3 Agente Inmobiliario, que
  -- tiene 321 usuarios activos y no puede impersonar. La rama (b) es
  -- row-independent, así que declararlo convertiría a cada agente externo en
  -- editor de TODO el padrón (compradores ajenos, staff, dueños) en lugar de
  -- solo sus leads, que es lo que hoy contiene la rama id_persona_duena_lead.
  ('personas',          '/admin/entidades-legales', 1),
  ('personas',          '/admin/entidades-legales', 3),
  -- compradores
  ('compradores',       '/admin/compradores',       1),
  ('compradores',       '/admin/compradores',       2),
  ('compradores',       '/admin/compradores',       3),
  ('compradores',       '/admin/compradores',       4),
  ('compradores',       '/admin/cuentas-cobranza',  1),
  -- cuentas_bancarias
  ('cuentas_bancarias', '/admin/compradores',       1),
  ('cuentas_bancarias', '/admin/compradores',       3)
) AS v(tabla, ruta, permiso_id)
JOIN public.submenus s ON s.vista_front_end = v.ruta
ON CONFLICT (tabla, submenu_id, permiso_id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Self-verifying: aborta el CI si el catálogo, los helpers o el seed no quedaron
-- bien, o si esta tanda tocó alguna policy (no debe).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_n     integer;
  v_tabla text;
BEGIN
  -- Helpers: STABLE, SECURITY DEFINER, authenticated sí, anon no.
  FOREACH v_tabla IN ARRAY ARRAY['public.current_puede_tabla(text, text)',
                                 'public.current_puede(text, text)']
  LOOP
    IF to_regprocedure(v_tabla) IS NULL THEN
      RAISE EXCEPTION 'Falta el helper %', v_tabla;
    END IF;
    IF (SELECT provolatile FROM pg_proc WHERE oid = to_regprocedure(v_tabla)) <> 's' THEN
      RAISE EXCEPTION '% no quedó STABLE: se evaluaría por fila', v_tabla;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(v_tabla)) THEN
      RAISE EXCEPTION '% quedó sin SECURITY DEFINER', v_tabla;
    END IF;
    IF NOT has_function_privilege('authenticated', to_regprocedure(v_tabla), 'EXECUTE') THEN
      RAISE EXCEPTION 'authenticated no puede ejecutar %', v_tabla;
    END IF;
    IF has_function_privilege('anon', to_regprocedure(v_tabla), 'EXECUTE') THEN
      RAISE EXCEPTION 'anon quedó con EXECUTE sobre %', v_tabla;
    END IF;
  END LOOP;

  -- Catálogo: RLS encendida, authenticated solo lee, anon nada.
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.rls_tablas_submenus'::regclass) THEN
    RAISE EXCEPTION 'rls_tablas_submenus quedó sin RLS';
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.rls_tablas_submenus', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated no puede leer el catálogo: current_puede_tabla es SECURITY DEFINER, pero el panel necesita listarlo';
  END IF;
  IF has_table_privilege('authenticated', 'public.rls_tablas_submenus', 'INSERT')
     OR has_table_privilege('authenticated', 'public.rls_tablas_submenus', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.rls_tablas_submenus', 'DELETE') THEN
    RAISE EXCEPTION 'authenticated puede escribir el catálogo de permisos';
  END IF;
  IF has_table_privilege('anon', 'public.rls_tablas_submenus', 'SELECT') THEN
    RAISE EXCEPTION 'anon puede leer el catálogo de permisos';
  END IF;

  -- Seed: ninguna de las tres tablas puede quedar sin filas (eso significaría
  -- que las rutas del seed no existen y la rama (b) negaría a todos).
  FOREACH v_tabla IN ARRAY ARRAY['personas', 'compradores', 'cuentas_bancarias']
  LOOP
    SELECT count(*) INTO v_n
    FROM public.rls_tablas_submenus WHERE tabla = v_tabla AND activo = true;
    IF v_n = 0 THEN
      RAISE EXCEPTION 'El seed dejó % sin ninguna fila en el catálogo', v_tabla;
    END IF;
  END LOOP;

  SELECT count(*) INTO v_n FROM public.rls_tablas_submenus WHERE activo = true;
  RAISE NOTICE 'rls_tablas_submenus: % filas activas', v_n;

  -- Todas las filas deben apuntar a submenú y menú activos, o la declaración es
  -- letra muerta (caso del submenú 31 /admin/legal/contratos).
  SELECT count(*) INTO v_n
  FROM public.rls_tablas_submenus rts
  JOIN public.submenus s ON s.id = rts.submenu_id
  JOIN public.menus m    ON m.id = s.menu_id
  WHERE rts.activo AND (s.activo = false OR m.activo = false);
  IF v_n > 0 THEN
    RAISE WARNING '% filas del catálogo apuntan a submenú o menú inactivo: esa rama (b) nunca dará true', v_n;
  END IF;

  -- Tanda 0 no toca policies: nada debe usar todavía current_puede_tabla.
  SELECT count(*) INTO v_n
  FROM pg_policies
  WHERE schemaname = 'public'
    AND coalesce(qual, '') || coalesce(with_check, '') LIKE '%current_puede_tabla%';
  IF v_n > 0 THEN
    RAISE EXCEPTION 'La tanda 0 no debe cambiar policies, y % ya usan current_puede_tabla', v_n;
  END IF;
END
$$;
