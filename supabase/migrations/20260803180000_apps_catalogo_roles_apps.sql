-- Catálogo de apps administrables y asignación por rol.
-- -----------------------------------------------------------------------------
-- Motivación: 20260803000000_roles_apps_json_accesos introdujo roles.apps (jsonb)
-- para no ir agregando una columna booleana por app. Resolvió el escalado del
-- almacenamiento, pero el CATÁLOGO de apps seguía viviendo en el front, en una
-- constante hardcodeada (ADMIN_APPS en RolesPermisos.tsx): dar de alta una app
-- nueva exigía desplegar código.
--
-- Esta migración lleva el catálogo a la base de datos y la asignación a una
-- tabla puente, siguiendo el mismo patrón que ya usan estatus y reportes
-- (estatus_disponibilidad + roles_estatus_disponibilidad):
--
--   apps        → catálogo. Alta de app nueva = INSERT, sin desplegar nada.
--   roles_apps  → qué apps administra cada rol. Con FK, así un slug mal escrito
--                 deja de ser posible, y "qué roles administran la app X" pasa a
--                 ser una consulta trivial.
--
-- Compatibilidad — nada de lo que hoy lee accesos por app cambia de contrato:
--   * get_current_user_profile() sigue devolviendo `apps jsonb` con la misma
--     forma {"administrar":[...]} y sigue devolviendo administrar_app_clientes.
--     Ambos pasan a DERIVARSE de roles_apps.
--   * roles.apps y roles.administrar_app_clientes se conservan y quedan
--     sincronizadas por trigger, para cualquier lector directo de tabla que no
--     controlemos (app Flutter de clientes, edge functions, n8n).
--   * Ambas columnas se eliminan en una migración posterior, una vez confirmado
--     que ningún consumidor las lee.
-- -----------------------------------------------------------------------------

-- 1. Catálogo de apps ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.apps (
  id                  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  slug                text        NOT NULL UNIQUE,
  nombre              text        NOT NULL,
  descripcion         text,
  orden               integer     NOT NULL DEFAULT 100,
  activo              boolean     NOT NULL DEFAULT true,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT apps_slug_formato CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);

COMMENT ON TABLE  public.apps       IS 'Catálogo de apps administrables desde un rol. Alta de app nueva = INSERT aquí, sin cambios de código.';
COMMENT ON COLUMN public.apps.slug  IS 'Identificador estable usado por el backend y los clientes externos. Inmutable en la práctica.';
COMMENT ON COLUMN public.apps.orden IS 'Orden de presentación en el selector de Roles y Permisos.';

-- 2. Asignación rol -> app ----------------------------------------------------
CREATE TABLE IF NOT EXISTS public.roles_apps (
  id_rol              integer     NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  id_app              integer     NOT NULL REFERENCES public.apps(id)  ON DELETE CASCADE,
  activo              boolean     NOT NULL DEFAULT true,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id_rol, id_app)
);

COMMENT ON TABLE public.roles_apps IS 'Qué apps puede administrar cada rol. Fuente de verdad; roles.apps y roles.administrar_app_clientes se derivan de aquí por trigger.';

CREATE INDEX IF NOT EXISTS roles_apps_id_app_idx ON public.roles_apps (id_app) WHERE activo;

-- 3. Semilla del catálogo -----------------------------------------------------
-- id es GENERATED ALWAYS: se omite de la lista de columnas, sin
-- OVERRIDING SYSTEM VALUE (no necesitamos ids determinísticos).
INSERT INTO public.apps (slug, nombre, descripcion, orden)
VALUES
  ('clientes', 'App de clientes', 'Acceso y gestión de la app y el portal de clientes', 10),
  ('agentes',  'App de agentes',  'Acceso y gestión de la app y el portal de agentes',  20)
ON CONFLICT (slug) DO NOTHING;

-- 4. Backfill -----------------------------------------------------------------
-- Se unen las dos fuentes vigentes para que ningún rol pierda un acceso actual.
INSERT INTO public.roles_apps (id_rol, id_app, activo)
SELECT DISTINCT r.id, a.id, true
FROM public.roles r
JOIN public.apps  a
  ON a.slug = ANY (
       COALESCE(
         ARRAY(SELECT jsonb_array_elements_text(r.apps -> 'administrar')),
         ARRAY[]::text[]
       )
     )
UNION
SELECT r.id, a.id, true
FROM public.roles r
JOIN public.apps  a ON a.slug = 'clientes'
WHERE r.administrar_app_clientes IS TRUE
ON CONFLICT (id_rol, id_app) DO NOTHING;

-- 5. Sincronía hacia las columnas legacy --------------------------------------
-- Se hace en BD y no desde el front para que no dependa de que la UI se acuerde
-- de escribirlas. Recalcula el rol completo, así que es idempotente y tolera
-- INSERT, UPDATE y DELETE por igual.
CREATE OR REPLACE FUNCTION public.sync_roles_apps_legacy()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rol   integer := COALESCE(NEW.id_rol, OLD.id_rol);
  v_slugs jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(a.slug ORDER BY a.slug), '[]'::jsonb)
    INTO v_slugs
  FROM public.roles_apps ra
  JOIN public.apps a ON a.id = ra.id_app
  WHERE ra.id_rol = v_rol
    AND ra.activo
    AND a.activo;

  UPDATE public.roles
     SET apps = jsonb_set(COALESCE(apps, '{}'::jsonb), '{administrar}', v_slugs, true),
         administrar_app_clientes = (v_slugs ? 'clientes'),
         fecha_actualizacion = now()
   WHERE id = v_rol;

  RETURN COALESCE(NEW, OLD);
END;
$function$;

DROP TRIGGER IF EXISTS trg_sync_roles_apps_legacy ON public.roles_apps;
CREATE TRIGGER trg_sync_roles_apps_legacy
AFTER INSERT OR UPDATE OR DELETE ON public.roles_apps
FOR EACH ROW EXECUTE FUNCTION public.sync_roles_apps_legacy();

-- 6. RLS y grants -------------------------------------------------------------
ALTER TABLE public.apps       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roles_apps ENABLE ROW LEVEL SECURITY;

-- Lectura para cualquier autenticado: la consume el selector de Roles y Permisos.
DROP POLICY IF EXISTS apps_select_auth ON public.apps;
CREATE POLICY apps_select_auth ON public.apps
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS roles_apps_select_auth ON public.roles_apps;
CREATE POLICY roles_apps_select_auth ON public.roles_apps
  FOR SELECT TO authenticated USING (true);

-- Escritura: mismo criterio que protege la pantalla de Roles y Permisos.
DROP POLICY IF EXISTS apps_write_admin ON public.apps;
CREATE POLICY apps_write_admin ON public.apps
  FOR ALL TO authenticated
  USING (public.user_has_permission('/admin/roles-permisos', 'actualizar'))
  WITH CHECK (public.user_has_permission('/admin/roles-permisos', 'actualizar'));

DROP POLICY IF EXISTS roles_apps_write_admin ON public.roles_apps;
CREATE POLICY roles_apps_write_admin ON public.roles_apps
  FOR ALL TO authenticated
  USING (public.user_has_permission('/admin/roles-permisos', 'actualizar'))
  WITH CHECK (public.user_has_permission('/admin/roles-permisos', 'actualizar'));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.apps       TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.roles_apps TO authenticated;

-- 7. get_current_user_profile: derivar de roles_apps --------------------------
-- Sin esto la migración no tendría efecto sobre los consumidores: el RPC seguiría
-- leyendo roles.apps. El tipo de retorno NO cambia respecto de
-- 20260803000000_roles_apps_json_accesos, así que no hace falta DROP; se usa
-- CREATE OR REPLACE. El cuerpo parte de esa versión vigente y solo cambia el
-- origen de `apps` y de administrar_app_clientes.
CREATE OR REPLACE FUNCTION public.get_current_user_profile()
 RETURNS TABLE(
   email text,
   nombre text,
   rol_id integer,
   rol_nombre text,
   debe_cambiar_password boolean,
   id_persona integer,
   activo boolean,
   ver_todos_prospectos_compradores boolean,
   ver_filtros_avanzados_eliminados boolean,
   id_notario integer,
   notaria_nombre text,
   id_perfil_juridico bigint,
   perfil_juridico_nombre text,
   puede_impersonar boolean,
   administrar_app_clientes boolean,
   id_banco integer,
   banco_nombre text,
   apps jsonb
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  WITH apps_rol AS (
    SELECT COALESCE(jsonb_agg(a.slug ORDER BY a.slug), '[]'::jsonb) AS slugs
    FROM public.usuarios u2
    JOIN public.roles_apps ra ON ra.id_rol = u2.rol_id AND ra.activo
    JOIN public.apps       a  ON a.id      = ra.id_app AND a.activo
    WHERE u2.email = auth.email()
  )
  SELECT
    u.email::TEXT,
    u.nombre::TEXT,
    u.rol_id::INTEGER,
    r.nombre::TEXT                           AS rol_nombre,
    u.debe_cambiar_password::BOOLEAN,
    u.id_persona::INTEGER,
    u.activo::BOOLEAN,
    -- Flag EFECTIVO: usuario OR rol, espejo de can_view_all_prospects().
    (COALESCE(u.ver_todos_prospectos_compradores, false)
       OR COALESCE(r.ver_todos_prospectos_compradores, false))::BOOLEAN
                                             AS ver_todos_prospectos_compradores,
    COALESCE(r.ver_filtros_avanzados_eliminados, true)::BOOLEAN AS ver_filtros_avanzados_eliminados,
    u.id_notario::INTEGER,
    n.notaria::TEXT                          AS notaria_nombre,
    j.id::BIGINT                             AS id_perfil_juridico,
    j.nombre_completo::TEXT                  AS perfil_juridico_nombre,
    COALESCE(r.puede_impersonar, false)::BOOLEAN AS puede_impersonar,
    -- Derivado de roles_apps (fuente de verdad). Se conserva el OR con las
    -- columnas legacy por si un rol se editara por fuera de roles_apps.
    ((SELECT slugs FROM apps_rol) ? 'clientes'
       OR COALESCE((r.apps -> 'administrar') ? 'clientes', false)
       OR COALESCE(r.administrar_app_clientes, false))::BOOLEAN AS administrar_app_clientes,
    u.id_banco::INTEGER,
    b.nombre::TEXT                           AS banco_nombre,
    -- Mismo contrato de siempre: {"administrar":[...]}.
    jsonb_build_object('administrar', (SELECT slugs FROM apps_rol)) AS apps
  FROM public.usuarios u
  JOIN  public.roles    r ON r.id  = u.rol_id
  LEFT JOIN public.notarios n
         ON n.id     = u.id_notario
        AND n.activo = TRUE
  LEFT JOIN public.perfiles_juridicos j
         ON j.email  = u.email
        AND j.activo = TRUE
  LEFT JOIN public.bancos b
         ON b.id     = u.id_banco
  WHERE u.email  = auth.email()
    AND u.activo = TRUE
  LIMIT 1;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_current_user_profile() TO anon, authenticated, service_role;
