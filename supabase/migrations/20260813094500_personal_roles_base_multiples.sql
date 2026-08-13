-- Roles base múltiples por persona
-- Fecha: 2026-08-13
-- Origen: Ejecuciones/ejecusiones.md
--
-- Timestamp con hora real (094500) y no redondo, para no repetir la colision de prefijos
-- del 2026-08-12 entre 20260812010000_crm_crear_contacto_upsert_fix.sql y
-- 20260812183000_tipos_documento_cancelaciones_devoluciones.sql: los 14 digitos son la PK
-- de supabase_migrations.schema_migrations, asi que dos archivos del mismo dia con hora
-- redonda tumban el deploy del segundo.
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- Una persona puede tener mas de un rol base, sin alterar como se reparten hoy el costo y
-- la comision. Hasta ahora `personal_organizacional.id_rol` era un solo rol base y la
-- unica forma de tener otro era por proyecto (`personal_proyectos.id_rol`), lo que deja
-- fuera el caso real: alguien que en SOZU Central es a la vez Director y responsable de
-- Marketing, sin que ninguno cuelgue de un proyecto.
--
-- Decision de negocio: HAY UN ROL PRINCIPAL Y LOS DEMAS SON INFORMATIVOS.
-- `personal_organizacional.id_rol` sigue siendo el principal y es el unico que rige costo,
-- comision y organigrama. Los adicionales se registran y se muestran, pero no reparten
-- dinero.
--
-- ─── Decisiones ───────────────────────────────────────────────────────────────
-- · Tabla nueva y no columnas `id_rol_2`, `id_rol_3`: esas fijan un tope arbitrario y
--   obligan a tocar el esquema cada vez que alguien acumule un rol mas. La relacion es N:M.
-- · El principal se queda donde esta. Hay 141 reglas de comision (verificado read-only
--   contra produccion; el documento decia 130), el organigrama y el costo por proyecto que
--   resuelven el rol con rolEfectivo() — rol del proyecto y, si no hay, el base. Mover el
--   principal a la tabla nueva obligaria a reescribir todo eso para una funcionalidad que
--   es informativa. Este diseño es ADITIVO: si nadie captura roles adicionales, el sistema
--   se comporta exactamente igual que hoy.
-- · La tabla guarda SOLO los adicionales. El conjunto de roles base de una persona es
--   {personal_organizacional.id_rol} U personal_roles. Un trigger rechaza insertar el
--   principal como adicional para que no aparezca duplicado.
-- · Indice unico PARCIAL sobre `activo`: un rol adicional no se repite mientras este
--   vigente, pero una baja no bloquea volver a asignarlo despues.
--
-- ─── Riesgo asumido (del propio requerimiento) ────────────────────────────────
-- Un rol adicional no participa en el reparto de costo. Si mas adelante se quiere repartir
-- el costo entre roles, esta tabla ya tiene donde colgar el porcentaje, pero ese cambio si
-- tocaria el motor de costos.
--
-- Idempotente: CREATE ... IF NOT EXISTS, CREATE OR REPLACE FUNCTION y DROP
-- TRIGGER/POLICY IF EXISTS. Sin BEGIN/COMMIT (el CI envuelve cada archivo).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Los roles adicionales
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.personal_roles (
  id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_personal         bigint      NOT NULL
                        REFERENCES public.personal_organizacional (id) ON DELETE CASCADE,
  id_rol              bigint      NOT NULL REFERENCES public.roles_organizacionales (id),
  activo              boolean     NOT NULL DEFAULT true,
  fecha_fin           date,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now(),
  -- Un rol vigente no puede arrastrar fecha de fin, mismo criterio que
  -- personal_organizacional_baja_chk.
  CONSTRAINT personal_roles_baja_chk CHECK (activo = false OR fecha_fin IS NULL)
);

COMMENT ON TABLE public.personal_roles IS
  'Roles base ADICIONALES de una persona. El rol principal vive en '
  'personal_organizacional.id_rol y es el unico que rige costo, comision y organigrama: '
  'los adicionales son informativos y no reparten dinero. El conjunto de roles base de una '
  'persona es {personal_organizacional.id_rol} UNION personal_roles.';
COMMENT ON COLUMN public.personal_roles.activo IS
  'Baja logica del rol adicional. La baja libera el indice unico parcial, asi que el mismo '
  'rol se puede volver a asignar despues.';
COMMENT ON COLUMN public.personal_roles.fecha_fin IS
  'Fecha en que el rol adicional dejo de aplicar. Solo tiene sentido con activo = false.';

-- Un mismo rol adicional no se repite mientras esté vigente. Parcial sobre `activo` para
-- que una baja no bloquee volver a asignarlo después.
CREATE UNIQUE INDEX IF NOT EXISTS personal_roles_persona_rol_uq
  ON public.personal_roles (id_personal, id_rol) WHERE activo;

CREATE INDEX IF NOT EXISTS personal_roles_id_personal_idx
  ON public.personal_roles (id_personal);
CREATE INDEX IF NOT EXISTS personal_roles_id_rol_idx
  ON public.personal_roles (id_rol);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. El principal no se guarda como adicional: sería el mismo rol dos veces
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.personal_roles_no_duplica_principal()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF NEW.activo AND EXISTS (
    SELECT 1 FROM public.personal_organizacional p
    WHERE p.id = NEW.id_personal AND p.id_rol = NEW.id_rol
  ) THEN
    RAISE EXCEPTION
      'El rol % ya es el rol principal de la persona %', NEW.id_rol, NEW.id_personal
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.personal_roles_no_duplica_principal() IS
  'Impide registrar como rol adicional el que ya es rol principal de la persona. Solo '
  'vigila el lado de personal_roles: cambiar personal_organizacional.id_rol a un rol que '
  'la persona ya tiene como adicional NO se bloquea aqui (ver nota al final del archivo).';

DROP TRIGGER IF EXISTS trg_personal_roles_no_duplica_principal ON public.personal_roles;
CREATE TRIGGER trg_personal_roles_no_duplica_principal
  BEFORE INSERT OR UPDATE ON public.personal_roles
  FOR EACH ROW EXECUTE FUNCTION public.personal_roles_no_duplica_principal();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. fecha_actualizacion automática
--    El documento no la incluía, pero la tabla tiene baja lógica (UPDATE de `activo`) y
--    todas sus hermanas del dominio —personal_organizacional, personal_proyectos,
--    comisiones_*— llevan `fecha_actualizacion` con este mismo trigger. Sin ella, una baja
--    no deja rastro de cuándo ocurrió.
-- ═══════════════════════════════════════════════════════════════════════════════
DROP TRIGGER IF EXISTS trg_personal_roles_upd ON public.personal_roles;
CREATE TRIGGER trg_personal_roles_upd
  BEFORE UPDATE ON public.personal_roles
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. RLS + GRANTS
--    Se alinea al patrón verificado en las tablas hermanas en producción:
--    policy `(SELECT auth.uid()) IS NOT NULL` para `authenticated`, y GRANT a
--    `authenticated` Y `service_role`. El documento proponía `USING (true)` y GRANT solo a
--    `authenticated`; lo primero rompe la consistencia del dominio y lo segundo dejaría sin
--    privilegios a cualquier proceso que corra con service_role.
--
--    SIN `anon`: las default privileges de Supabase sobre `public` le conceden todos los
--    privilegios en cada tabla nueva. Hoy RLS lo frenaría (no hay policy para anon), pero
--    el GRANT quedaría como trampa para la primera policy permisiva que llegue. Mismo
--    criterio que 20260806100000, 20260809000000, 20260810000000 y 20260812000000.
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.personal_roles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS personal_roles_rw ON public.personal_roles;
DROP POLICY IF EXISTS personal_roles_rls_auth ON public.personal_roles;
CREATE POLICY personal_roles_rls_auth
  ON public.personal_roles
  FOR ALL TO authenticated
  USING ((SELECT auth.uid()) IS NOT NULL)
  WITH CHECK ((SELECT auth.uid()) IS NOT NULL);

REVOKE ALL PRIVILEGES ON TABLE public.personal_roles FROM anon;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.personal_roles
  TO authenticated, service_role;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT column_name, data_type, is_nullable, column_default
--   FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='personal_roles'
--   ORDER BY ordinal_position;
--
--   SELECT indexname, indexdef FROM pg_indexes
--   WHERE schemaname='public' AND tablename='personal_roles' ORDER BY indexname;
--   -- personal_roles_persona_rol_uq debe llevar WHERE activo
--
--   SELECT tgname, pg_get_triggerdef(oid) FROM pg_trigger
--   WHERE tgrelid='public.personal_roles'::regclass AND NOT tgisinternal;
--   -- esperado: trg_personal_roles_no_duplica_principal y trg_personal_roles_upd
--
-- RLS + policy + `anon` sin GRANT:
--   SELECT relrowsecurity FROM pg_class WHERE oid='public.personal_roles'::regclass;
--   SELECT polname, polcmd FROM pg_policy WHERE polrelid='public.personal_roles'::regclass;
--
--   SELECT table_name, grantee, privilege_type FROM information_schema.role_table_grants
--   WHERE table_schema='public' AND table_name='personal_roles' AND grantee='anon';
--   -- esperado: 0 filas
--
-- Nace vacia, asi que nada cambia:
--   SELECT count(*) FROM public.personal_roles;   -- esperado: 0
--
-- Conjunto completo de roles base de una persona (principal + adicionales):
--   SELECT 'principal' AS clase, r.nombre
--   FROM public.personal_organizacional p
--   JOIN public.roles_organizacionales r ON r.id = p.id_rol
--   WHERE p.id = $1
--   UNION ALL
--   SELECT 'adicional', r.nombre
--   FROM public.personal_roles pr
--   JOIN public.roles_organizacionales r ON r.id = pr.id_rol
--   WHERE pr.id_personal = $1 AND pr.activo;
--
-- ═══════════════════════════════════════════════════════════════════════════════
-- DOS COSAS QUE LA BASE NO RESUELVE — para quien construya el front
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- 1) EL TRIGGER SOLO VIGILA UN LADO.
--    Rechaza insertar como adicional el rol que ya es principal, pero NO impide el camino
--    inverso: cambiar `personal_organizacional.id_rol` a un rol que la persona ya tiene
--    como adicional vigente deja el mismo rol contado dos veces. No se añade un trigger en
--    personal_organizacional a proposito: bloquearia una edicion legitima del rol principal
--    y romperia la pantalla de personal. Al cambiar el rol principal, el front debe dar de
--    baja el adicional que coincida:
--
--      UPDATE public.personal_roles
--      SET activo = false, fecha_fin = current_date
--      WHERE id_personal = $1 AND id_rol = $2 AND activo;
--
-- 2) LA BAJA DE LA PERSONA NO CASCADEA SOLA.
--    El diagnostico habla de "replicar el comportamiento de personal_proyectos", y ese
--    comportamiento es filtrar en la LECTURA, no un trigger: personal_proyectos tampoco
--    desactiva sus filas cuando la persona se da de baja. Toda consulta de roles
--    adicionales debe exigir las dos banderas —`p.activo AND pr.activo`— o los roles
--    reapareceran si la persona se reactiva.
--
-- ─── Front dependiente de este DDL (repo sozu-admin) ──────────────────────────
-- Antes de ejecutarlo el modulo funciona igual que hoy: el hook detecta que la tabla no
-- existe (probe graceful, patron #6 de CLAUDE.md), devuelve lista vacia y la UI muestra un
-- aviso en lugar del editor de roles adicionales. Ninguna persona pierde su rol y ningun
-- calculo cambia.
