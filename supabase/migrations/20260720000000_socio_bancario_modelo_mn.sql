-- Socios Bancarios · Modelo M:N + rol + vínculo en usuarios + helpers + revisiones + permisos
-- Fecha: 2026-07-20
--
-- Formaliza la mitad "Admin de Socios Bancarios" de Ejecuciones/ejecutar.md, adaptada:
-- habilita el vínculo banco → desarrollos → usuarios que resuelve "Desarrollo no asignado"
-- del Portal Socio Bancario. Esta migración crea la ESTRUCTURA y el rol; la frontera RLS
-- de lectura del portal va en 20260720010000_socio_bancario_rls_scoping.sql.
--
-- Decisiones (confirmadas con el usuario 2026-07-20):
--   · M:N a nivel BANCO: socios_bancarios ↔ socio_bancario_desarrollos (un banco, N desarrollos).
--   · Los USUARIOS de banco viven en public.usuarios (rol 'Socio Bancario', id_persona NULL)
--     con nueva columna usuarios.id_socio_bancario. NO se crea tabla usuarios_socio_bancario:
--     así reutilizan el sistema de menús/permisos (usuarios.rol_id → submenus_permisos), la
--     auth (auth_user_id) y el flujo de invitación (patrón create-user). "Invitado" se deriva
--     como en el resto (email_confirmado=false / auth pendiente).
--   · Rol lector NUEVO 'Socio Bancario' (único con acceso al portal).
--   · Campos de control en español (activo, creado_por, fecha_creacion, revocado_por,
--     fecha_revocacion). auth_user_id se conserva: convención del esquema (usuarios.auth_user_id).
--
-- ids bigint GENERATED ALWAYS AS IDENTITY (convención de la casa). Idempotente:
-- CREATE TABLE/INDEX IF NOT EXISTS, ADD COLUMN IF NOT EXISTS, DROP TRIGGER/POLICY IF EXISTS,
-- INSERT ... WHERE NOT EXISTS, CREATE OR REPLACE FUNCTION. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

-- ================================================================
-- 1. Tablas del modelo M:N (banco ↔ desarrollos)
-- ================================================================
CREATE TABLE IF NOT EXISTS public.socios_bancarios (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre              text NOT NULL,
  razon_social        text,
  rfc                 text,
  activo              boolean NOT NULL DEFAULT true,   -- campo de control (revocado = false)
  creado_por          text,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now(),
  revocado_por        text,
  fecha_revocacion    timestamptz
);

DROP TRIGGER IF EXISTS trg_socios_bancarios_upd ON public.socios_bancarios;
CREATE TRIGGER trg_socios_bancarios_upd
  BEFORE UPDATE ON public.socios_bancarios
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- Asignación banco ↔ desarrollo (proyecto). Muchos a muchos.
CREATE TABLE IF NOT EXISTS public.socio_bancario_desarrollos (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_socio_bancario   bigint  NOT NULL REFERENCES public.socios_bancarios(id),
  id_desarrollo       integer NOT NULL REFERENCES public.proyectos(id),
  activo              boolean NOT NULL DEFAULT true,   -- campo de control (asignación vigente)
  creado_por          text,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now(),
  revocado_por        text,
  fecha_revocacion    timestamptz,
  UNIQUE (id_socio_bancario, id_desarrollo)
);
CREATE INDEX IF NOT EXISTS idx_sbd_socio
  ON public.socio_bancario_desarrollos (id_socio_bancario) WHERE activo;

DROP TRIGGER IF EXISTS trg_socio_bancario_desarrollos_upd ON public.socio_bancario_desarrollos;
CREATE TRIGGER trg_socio_bancario_desarrollos_upd
  BEFORE UPDATE ON public.socio_bancario_desarrollos
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- ================================================================
-- 1a. Vínculo del usuario de banco → su banco (en la tabla usuarios existente)
--     id_persona queda NULL para usuarios externos de banco.
-- ================================================================
ALTER TABLE public.usuarios
  ADD COLUMN IF NOT EXISTS id_socio_bancario bigint REFERENCES public.socios_bancarios(id);

COMMENT ON COLUMN public.usuarios.id_socio_bancario IS
  'Banco (socio bancario) al que pertenece el usuario. Scoping del Portal Socio Bancario. NULL para usuarios que no son de banco.';

CREATE INDEX IF NOT EXISTS idx_usuarios_socio_bancario
  ON public.usuarios (id_socio_bancario) WHERE id_socio_bancario IS NOT NULL;

-- ================================================================
-- 1c. Aceptación de invitación: al confirmar el email (primer login por magic
--     link), pasar usuarios.email_confirmado false → true. "Invitado" deja de
--     serlo automáticamente sin depender del front. Acotado a usuarios de banco
--     (id_socio_bancario IS NOT NULL) para no afectar otros flujos de login.
-- ================================================================
CREATE OR REPLACE FUNCTION public.sync_socio_email_confirmado() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Solo en la transición NULL → NOT NULL de email_confirmed_at.
  IF NEW.email_confirmed_at IS NOT NULL AND OLD.email_confirmed_at IS NULL THEN
    UPDATE public.usuarios
      SET email_confirmado = true,
          fecha_actualizacion = now()
      WHERE auth_user_id = NEW.id
        AND id_socio_bancario IS NOT NULL
        AND email_confirmado = false;
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_sync_socio_email_confirmado ON auth.users;
CREATE TRIGGER trg_sync_socio_email_confirmado
  AFTER UPDATE OF email_confirmed_at ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.sync_socio_email_confirmado();

-- ================================================================
-- 1b. Regla dura: id_desarrollo debe ser proyecto comercializado por SOZU
--     (entidades_relacionadas.id_tipo_entidad = 5 activo). Un CHECK no puede
--     hacer el join → trigger.
-- ================================================================
CREATE OR REPLACE FUNCTION public.assert_desarrollo_sozu() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.entidades_relacionadas er
    WHERE er.id_proyecto = NEW.id_desarrollo
      AND er.id_tipo_entidad = 5
      AND er.activo = true
  ) THEN
    RAISE EXCEPTION 'El desarrollo % no es comercializado por SOZU', NEW.id_desarrollo;
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_sbd_solo_sozu ON public.socio_bancario_desarrollos;
CREATE TRIGGER trg_sbd_solo_sozu
  BEFORE INSERT OR UPDATE ON public.socio_bancario_desarrollos
  FOR EACH ROW EXECUTE FUNCTION public.assert_desarrollo_sozu();

-- ================================================================
-- 2. Rol lector del portal (solo lectura)
-- ================================================================
INSERT INTO public.roles (nombre, es_rol_interno, activo)
SELECT 'Socio Bancario', false, true
WHERE NOT EXISTS (SELECT 1 FROM public.roles WHERE nombre = 'Socio Bancario');

-- ================================================================
-- 3. Helpers de scoping (SECURITY DEFINER evita recursión de RLS)
--    El socio se resuelve por usuarios.id_socio_bancario del usuario autenticado.
-- ================================================================
CREATE OR REPLACE FUNCTION public.current_socio_bancario_id()
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id_socio_bancario FROM public.usuarios
  WHERE auth_user_id = auth.uid() AND activo LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.socio_desarrollos_activos()
RETURNS SETOF integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT d.id_desarrollo FROM public.socio_bancario_desarrollos d
  WHERE d.id_socio_bancario = public.current_socio_bancario_id() AND d.activo;
$$;

CREATE OR REPLACE FUNCTION public.current_es_super_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.usuarios u
    WHERE u.auth_user_id = auth.uid() AND u.rol_id = 1
  );
$$;

GRANT EXECUTE ON FUNCTION public.current_socio_bancario_id()  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.socio_desarrollos_activos()  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.current_es_super_admin()     TO authenticated;

-- ================================================================
-- 4. RLS de las tablas admin (escritura/lectura SOLO Super Admin, rol 1)
--    Los socios NO leen estas tablas de administración.
-- ================================================================
ALTER TABLE public.socios_bancarios            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.socio_bancario_desarrollos  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sb_admin_all ON public.socios_bancarios;
CREATE POLICY sb_admin_all ON public.socios_bancarios
  FOR ALL TO authenticated
  USING (public.current_es_super_admin())
  WITH CHECK (public.current_es_super_admin());

DROP POLICY IF EXISTS sbd_admin_all ON public.socio_bancario_desarrollos;
CREATE POLICY sbd_admin_all ON public.socio_bancario_desarrollos
  FOR ALL TO authenticated
  USING (public.current_es_super_admin())
  WITH CHECK (public.current_es_super_admin());

-- ================================================================
-- 5. Expedientes: persistencia de acciones del banco (revisa, NO valida)
--    Tabla separada de la verificación interna de SOZU.
-- ================================================================
CREATE TABLE IF NOT EXISTS public.socio_bancario_revisiones (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_documento        bigint  REFERENCES public.documentos(id),
  id_cuenta_cobranza  bigint  REFERENCES public.cuentas_cobranza(id),
  id_proyecto         integer NOT NULL REFERENCES public.proyectos(id),
  correo_usuario      text NOT NULL,
  tipo                text NOT NULL CHECK (tipo IN ('revisado','observacion')),
  observacion         text,
  activo              boolean NOT NULL DEFAULT true,   -- campo de control
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sbr_proyecto ON public.socio_bancario_revisiones (id_proyecto);

DROP TRIGGER IF EXISTS trg_socio_bancario_revisiones_upd ON public.socio_bancario_revisiones;
CREATE TRIGGER trg_socio_bancario_revisiones_upd
  BEFORE UPDATE ON public.socio_bancario_revisiones
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

ALTER TABLE public.socio_bancario_revisiones ENABLE ROW LEVEL SECURITY;

-- Super Admin: todo. Socio: SELECT/INSERT solo de sus desarrollos activos.
DROP POLICY IF EXISTS sbr_admin_all ON public.socio_bancario_revisiones;
CREATE POLICY sbr_admin_all ON public.socio_bancario_revisiones
  FOR ALL TO authenticated
  USING (public.current_es_super_admin())
  WITH CHECK (public.current_es_super_admin());

DROP POLICY IF EXISTS sbr_socio_select ON public.socio_bancario_revisiones;
CREATE POLICY sbr_socio_select ON public.socio_bancario_revisiones
  FOR SELECT TO authenticated
  USING (id_proyecto IN (SELECT public.socio_desarrollos_activos()));

DROP POLICY IF EXISTS sbr_socio_insert ON public.socio_bancario_revisiones;
CREATE POLICY sbr_socio_insert ON public.socio_bancario_revisiones
  FOR INSERT TO authenticated
  WITH CHECK (id_proyecto IN (SELECT public.socio_desarrollos_activos()));

-- ================================================================
-- 6. Permisos del portal para el rol 'Socio Bancario' (solo LEER = permiso 1)
--    Rutas del portal ya dadas de alta en 20260716140000. Se asigna leer al rol
--    nuevo sobre esas 6 vistas. Match del rol por nombre (sin hardcodear id).
-- ================================================================
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, 1, (SELECT id FROM public.roles WHERE nombre = 'Socio Bancario'), true
FROM public.submenus s
WHERE s.vista_front_end LIKE '/admin/portal-socio-bancario/%'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id
      AND sp.permiso_id = 1
      AND sp.rol_id = (SELECT id FROM public.roles WHERE nombre = 'Socio Bancario')
  );
