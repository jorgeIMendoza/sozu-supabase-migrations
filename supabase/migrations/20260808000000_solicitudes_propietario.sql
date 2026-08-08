-- Onboarding público de propietarios (reventa) — persistencia de solicitudes.
--
-- Contexto: el flujo público "Registrar mi propiedad" (propietarios.sozu.com →
-- /registrar-propiedad) recopila, ANTES de que el solicitante tenga sesión, la
-- unidad a reclamar, sus datos (extraídos de CURP/CSF) y los documentos que sube.
-- Hoy el front lo guarda en localStorage (mock). Esta migración crea la tabla
-- donde una Edge Function con service_role persistirá cada solicitud, y desde la
-- cual el Portal Condominio (rol "Admin de condominio") la revisa y aprueba.
--
-- Alcance de ESTA migración = solo la capa de persistencia (tabla + RLS + índices
-- + touch de fecha_actualizacion). NO incluye, a propósito:
--   · el seed de submenú del Portal Condominio (va cuando exista la pantalla React
--     que lo consume, junto con sus INSERT de menús/permisos — regla de CLAUDE.md
--     del front: el menú se siembra con su <Route>);
--   · la lógica de aprobación / reasignación de titularidad (irá como RPC en una
--     migración posterior, una vez decidido el modelo de reventa: reasignar
--     propiedades.id_entidad_relacionada_dueno vs. encadenar cuenta de cobranza).
--
-- Diseño: se sigue la convención del molde public.bancos_solicitudes (estatus text
-- + fecha_envio / fecha_creacion / fecha_actualizacion / activo / consentimiento_
-- datos). El id es GENERATED ALWAYS AS IDENTITY (igual que el molde): la Edge
-- Function nunca fija id. La detección de rol es POR NOMBRE porque los ids de rol
-- difieren entre dev y prod (mismo criterio que create-user / portalHostAccess /
-- la política de UPDATE del Portal Bancos).

-- ── 1. Tabla ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.solicitudes_propietario (
  id                      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_id                 text        NOT NULL UNIQUE,               -- "SOZU-XXXXXX" visible al solicitante
  id_propiedad            bigint      NOT NULL REFERENCES public.propiedades(id),
  id_entidad_relacionada  bigint      REFERENCES public.entidades_relacionadas(id), -- solicitante (tipo "Propietario")
  id_persona              integer     REFERENCES public.personas(id),
  id_usuario_solicitante  uuid,                                      -- auth.users si ya se creó cuenta
  email                   text        NOT NULL,
  tipo_persona            text        NOT NULL CHECK (tipo_persona IN ('fisica','moral')),
  tipo_compra             text        CHECK (tipo_compra IN ('contado','credito')),
  antiguedad_compra       text        CHECK (antiguedad_compra IN ('reciente','antiguo')),
  nivel                   smallint    NOT NULL DEFAULT 0 CHECK (nivel BETWEEN 0 AND 2),
  estatus                 text        NOT NULL DEFAULT 'pendiente'
                            CHECK (estatus IN ('pendiente','en_revision','aprobada_n1','aprobada_n2','rechazada')),
  verificacion            jsonb,                                     -- snapshot de los cruces del front (nombre, etc.)
  ruteo                   text[]      NOT NULL DEFAULT '{}',         -- p.ej. {Administración,Cobranza}
  revisado_por            uuid,                                      -- auth.uid() del admin que resolvió
  fecha_revision          timestamptz,
  comentario_revision     text,
  consentimiento_datos    boolean     NOT NULL DEFAULT false,
  fecha_consentimiento    timestamptz,
  activo                  boolean     NOT NULL DEFAULT true,
  fecha_envio             timestamptz NOT NULL DEFAULT now(),
  fecha_creacion          timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.solicitudes_propietario IS
  'Solicitudes del onboarding público de propietarios (reventa). Las inserta una Edge Function con service_role (pre-login) y las revisa el Portal Condominio.';

CREATE INDEX IF NOT EXISTS idx_solic_prop_estatus
  ON public.solicitudes_propietario (estatus) WHERE activo;
CREATE INDEX IF NOT EXISTS idx_solic_prop_propiedad
  ON public.solicitudes_propietario (id_propiedad);
CREATE INDEX IF NOT EXISTS idx_solic_prop_usuario
  ON public.solicitudes_propietario (id_usuario_solicitante);

-- ── 2. Touch de fecha_actualizacion ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tg_solicitudes_propietario_touch()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.fecha_actualizacion := now();
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_solicitudes_propietario_touch ON public.solicitudes_propietario;
CREATE TRIGGER trg_solicitudes_propietario_touch
  BEFORE UPDATE ON public.solicitudes_propietario
  FOR EACH ROW EXECUTE FUNCTION public.tg_solicitudes_propietario_touch();

-- ── 3. Helper de rol (SECURITY DEFINER; detección por nombre) ───────────────────
-- true si el usuario autenticado revisa solicitudes: "Admin de condominio" (rol 27
-- en dev) o "Super Administrador" (rol 1). Se consulta por nombre porque los ids de
-- rol difieren entre ambientes. Es SECURITY DEFINER para que la política no dependa
-- de que el usuario tenga SELECT sobre usuarios/roles.
CREATE OR REPLACE FUNCTION public.current_user_is_condominio_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.usuarios u
    JOIN public.roles r ON r.id = u.rol_id
    WHERE u.auth_user_id = auth.uid()
      AND u.activo = true
      AND (
        lower(btrim(r.nombre)) = 'admin de condominio'
        OR lower(btrim(r.nombre)) LIKE 'super admin%'
      )
  );
$function$;

COMMENT ON FUNCTION public.current_user_is_condominio_admin() IS
  'true si el usuario autenticado revisa solicitudes de propietario (Admin de condominio o Super Administrador). Detección por nombre: los ids de rol difieren entre ambientes.';

REVOKE ALL ON FUNCTION public.current_user_is_condominio_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_is_condominio_admin() TO authenticated, service_role;

-- ── 4. RLS ──────────────────────────────────────────────────────────────────────
-- El INSERT lo hace la Edge Function con service_role, que BYPASSA RLS: no se abre
-- INSERT ni a anon ni a authenticated. El solicitante ve su propia solicitud (cuando
-- ya tiene cuenta); el área de condominio ve y gestiona todas. Sin DELETE: el baja
-- lógica es vía activo=false (UPDATE).
ALTER TABLE public.solicitudes_propietario ENABLE ROW LEVEL SECURITY;

GRANT SELECT, UPDATE ON public.solicitudes_propietario TO authenticated;
GRANT ALL            ON public.solicitudes_propietario TO service_role;

DROP POLICY IF EXISTS solic_prop_admin_all ON public.solicitudes_propietario;
CREATE POLICY solic_prop_admin_all ON public.solicitudes_propietario
  AS PERMISSIVE FOR ALL TO authenticated
  USING      (public.current_user_is_condominio_admin())
  WITH CHECK (public.current_user_is_condominio_admin());

DROP POLICY IF EXISTS solic_prop_owner_read ON public.solicitudes_propietario;
CREATE POLICY solic_prop_owner_read ON public.solicitudes_propietario
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (id_usuario_solicitante = auth.uid());
