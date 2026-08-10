-- Infraestructura de la App de Agentes: push, notificaciones, version gate y
-- alta de la app `agentes` en los accesos por rol.
-- Fecha: 2026-08-10
--
-- ─── Qué crea ─────────────────────────────────────────────────────────────────
-- Espejo, tabla por tabla, de lo que ya sostiene la app de clientes:
--
--   push_tokens_agente        ← push_tokens_cliente        (20260708040000)
--   push_preferencias_agente  ← push_preferencias_cliente  (20260715030000)
--   notificaciones_agente     ← notificaciones_cliente     (20260625010000
--                                 + RLS/realtime de 20260709030000)
--   app_agente_config         ← app_cliente_config         (20260713040000
--                                 + seed del version gate de 20260728060000)
--
-- Y el vínculo rol → app `agentes` en `roles_apps`, que es lo que habilita el
-- modo admin / impersonación del portal de agentes (edge functions:
-- _shared/agente.ts → appsAdministra(rolApps, 'agentes')).
--
-- ─── Divergencias deliberadas respecto de las tablas de cliente ───────────────
-- 1. La columna de identidad es `email_agente` (no `email_cliente`), y es
--    `usuarios.email` — el mismo que compara la policy de RLS contra
--    auth.jwt()->>'email' y el que ya usa el portal para comisiones y ofertas.
-- 2. Se aplica la convención de toda tabla nueva del proyecto —`activo`,
--    `fecha_creacion`, `fecha_actualizacion` + trigger set_fecha_actualizacion()
--    BEFORE UPDATE— también donde la tabla de cliente NO la cumple:
--      · push_preferencias_cliente usa `updated_at` y no tiene trigger;
--        push_preferencias_agente usa `fecha_actualizacion` con trigger.
--      · app_cliente_config no tiene `activo` ni `fecha_creacion` ni trigger;
--        app_agente_config sí. La edge `agente-app-version` filtra activo=true.
--    No se toca ninguna tabla de cliente: homologarlas es otro cambio, con sus
--    propios consumidores que revisar.
-- 3. `notificaciones_agente.categoria` NO puede ser la lista del cliente
--    (pagos/mantenimiento/construccion/entrega…): el agente no recibe avisos de
--    obra, recibe avisos de su negocio. Se usa el vocabulario del portal de
--    agentes (comisiones, ofertas, leads, citas, documentos, capacitacion,
--    general). El set de `tipo` sí se conserva idéntico.
--
-- ─── Lo que esta migración NO hace (a propósito) ──────────────────────────────
-- No crea el trigger de dispatch de push (el equivalente de
-- trg_notificaciones_cliente_push → notificar_push_cliente → edge
-- `notificaciones-push`). La edge de dispatch hoy solo entiende
-- notificaciones_cliente y push_tokens_cliente; encender el trigger antes de
-- extenderla dispararía llamadas que no envían nada. Va en el cambio que toque
-- la edge de dispatch.
--
-- Idempotente: CREATE ... IF NOT EXISTS, DROP TRIGGER/POLICY IF EXISTS +
-- CREATE, INSERT ... ON CONFLICT DO NOTHING, guard en la publicación realtime.
-- Envuelto en una sola transacción.

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 0. Función de auditoría (ya existe; CREATE OR REPLACE es idempotente)
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.set_fecha_actualizacion()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.fecha_actualizacion = NOW();
  RETURN NEW;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. push_tokens_agente — tokens FCM de dispositivo, por email del agente
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.push_tokens_agente (
  id                    bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  email_agente          text NOT NULL,
  token                 text NOT NULL,
  plataforma            text NOT NULL CHECK (plataforma IN ('android','ios','web')),
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT push_tokens_agente_pkey PRIMARY KEY (id),
  CONSTRAINT push_tokens_agente_token_key UNIQUE (token)
);

COMMENT ON TABLE public.push_tokens_agente IS
  'Tokens FCM de los dispositivos de los agentes (app de agentes). La escribe la '
  'edge agente-push-token; acceso solo vía service_role.';
COMMENT ON COLUMN public.push_tokens_agente.email_agente IS
  'usuarios.email del agente dueño del dispositivo (mismo criterio de identidad '
  'que notificaciones_agente.email_agente).';

-- El dispatch busca "tokens vivos de este agente": índice parcial por email.
CREATE INDEX IF NOT EXISTS idx_push_tokens_agente_email
  ON public.push_tokens_agente (email_agente)
  WHERE (activo = true);

-- Solo service_role (edge functions) toca esta tabla; RLS on sin policies.
ALTER TABLE public.push_tokens_agente ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS trg_push_tokens_agente_upd ON public.push_tokens_agente;
CREATE TRIGGER trg_push_tokens_agente_upd BEFORE UPDATE
  ON public.push_tokens_agente
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. push_preferencias_agente — el agente apaga/enciende sus push
-- ═══════════════════════════════════════════════════════════════════════════════
-- Sin fila = push activo (default true). Apagar la preferencia NO da de baja
-- tokens: el dispatch la consulta y omite el envío, así reactivar es instantáneo.
-- `id_persona` sin FK, igual que push_preferencias_cliente.
CREATE TABLE IF NOT EXISTS public.push_preferencias_agente (
  id_persona            bigint NOT NULL,
  push_activo           boolean NOT NULL DEFAULT true,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT push_preferencias_agente_pkey PRIMARY KEY (id_persona)
);

COMMENT ON TABLE public.push_preferencias_agente IS
  'Preferencia de push por agente (personas.id). Sin fila = push activo. La '
  'escribe la edge agente-push-token (pref_get/pref_set).';
COMMENT ON COLUMN public.push_preferencias_agente.push_activo IS
  'false = no enviar push a este agente. No da de baja sus tokens.';

ALTER TABLE public.push_preferencias_agente ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS trg_push_preferencias_agente_upd ON public.push_preferencias_agente;
CREATE TRIGGER trg_push_preferencias_agente_upd BEFORE UPDATE
  ON public.push_preferencias_agente
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. notificaciones_agente — centro de notificaciones del portal de agentes
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.notificaciones_agente (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_cuenta_cobranza  bigint REFERENCES public.cuentas_cobranza(id) ON DELETE CASCADE,
  email_agente        text NOT NULL,
  tipo                text NOT NULL CHECK (tipo IN ('urgente', 'accionable', 'informativa', 'exito')),
  categoria           text NOT NULL CHECK (categoria IN ('comisiones', 'ofertas', 'leads', 'citas', 'documentos', 'capacitacion', 'general')),
  titulo              text NOT NULL,
  descripcion         text NOT NULL,
  url_accion          text,
  etiqueta_accion     text,
  leida               boolean NOT NULL DEFAULT false,
  descartada          boolean NOT NULL DEFAULT false,
  fecha_lectura       timestamptz,
  fecha_descarte      timestamptz,
  metadata            jsonb,
  activo              boolean NOT NULL DEFAULT true,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.notificaciones_agente IS
  'Centro de notificaciones del portal/app de agentes. Espejo de '
  'notificaciones_cliente con identidad por email_agente y categorías del '
  'negocio del agente.';
COMMENT ON COLUMN public.notificaciones_agente.id_cuenta_cobranza IS
  'Cuenta de cobranza relacionada (opcional): la venta de la que habla el aviso.';

CREATE INDEX IF NOT EXISTS idx_notif_agente_email
  ON public.notificaciones_agente (email_agente)
  WHERE activo = true;

CREATE INDEX IF NOT EXISTS idx_notif_agente_cuenta
  ON public.notificaciones_agente (id_cuenta_cobranza)
  WHERE activo = true AND id_cuenta_cobranza IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_notif_agente_no_leida
  ON public.notificaciones_agente (email_agente, leida)
  WHERE activo = true AND descartada = false;

DROP TRIGGER IF EXISTS trg_notificaciones_agente_upd ON public.notificaciones_agente;
CREATE TRIGGER trg_notificaciones_agente_upd
  BEFORE UPDATE ON public.notificaciones_agente
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- 3b. Realtime (contador en vivo de la campana). Guard: ADD TABLE falla si ya
-- es miembro de la publicación.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'notificaciones_agente'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notificaciones_agente;
  END IF;
END $$;

-- 3c. RLS. Realtime respeta RLS: sin policies acotadas, los INSERT se
-- difundirían a TODOS los suscriptores (fuga). Mismas dos policies que
-- notificaciones_cliente, adaptadas al portal de agentes.
ALTER TABLE public.notificaciones_agente ENABLE ROW LEVEL SECURITY;

-- El agente SELECCIONA solo sus filas (esto acota el Realtime al dueño).
DROP POLICY IF EXISTS notif_agente_realtime_select ON public.notificaciones_agente;
CREATE POLICY notif_agente_realtime_select ON public.notificaciones_agente
  FOR SELECT
  USING (email_agente = (auth.jwt() ->> 'email'));

-- Staff = usuario activo que NO es usuario final de un portal (3 y 9 son los
-- agentes, 23 el cliente). Es el equivalente del `rol_id <> 23` de
-- notificaciones_cliente: el front admin escribe y lee esta tabla directo con la
-- sesión del navegador. service_role (edge functions) bypassa RLS.
DROP POLICY IF EXISTS notif_agente_staff_all ON public.notificaciones_agente;
CREATE POLICY notif_agente_staff_all ON public.notificaciones_agente
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid() AND u.rol_id NOT IN (3, 9, 23) AND u.activo
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid() AND u.rol_id NOT IN (3, 9, 23) AND u.activo
    )
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. app_agente_config — config general de la app de agentes (key/value)
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.app_agente_config (
  key                 text PRIMARY KEY,
  value               text NOT NULL,
  activo              boolean NOT NULL DEFAULT true,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.app_agente_config IS
  'Configuración general de la app de agentes (key/value); acceso sólo vía edge '
  'functions. La lee agente-app-version (version gate, con la anon key ANTES del login).';
COMMENT ON COLUMN public.app_agente_config.value IS
  'NOT NULL como en app_cliente_config: una key "sin valor" se guarda como '
  'cadena vacía, que la edge normaliza a null.';
COMMENT ON COLUMN public.app_agente_config.activo IS
  'false = la key se ignora, como si no existiera. agente-app-version filtra activo=true.';

ALTER TABLE public.app_agente_config ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS trg_app_agente_config_upd ON public.app_agente_config;
CREATE TRIGGER trg_app_agente_config_upd
  BEFORE UPDATE ON public.app_agente_config
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- 4b. Seed del version gate. Arranca ABIERTO: min_version y latest_version
-- vacíos (la edge los normaliza a null) y force_update='false', así el gate no
-- bloquea a nadie el día uno. Operarlo después es UPDATE de estas filas, sin
-- redeploy. ON CONFLICT DO NOTHING para no pisar lo ya operado.
INSERT INTO public.app_agente_config (key, value) VALUES
  ('min_version',       ''),
  ('latest_version',    ''),
  ('force_update',      'false'),
  ('android_store_url', ''),
  ('ios_store_url',     ''),
  ('update_message',    '')
ON CONFLICT (key) DO NOTHING;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. Alta de la app `agentes` en los accesos por rol
-- ═══════════════════════════════════════════════════════════════════════════════
-- El catálogo `apps` ya trae el slug 'agentes' (20260803180000, paso 3). Lo que
-- falta es el vínculo rol → app en `roles_apps`, que es la FUENTE DE VERDAD de
-- quién administra/impersona la app. El trigger trg_sync_roles_apps_legacy
-- propaga solo el INSERT a roles.apps ({"administrar":[...]}), que es lo que
-- leen _shared/agente.ts (authAgente / authAdminAgentes) y el front.
--
-- Criterio de a quién se le da: Super Administrador (1) + todo rol con
-- puede_impersonar = true (hoy 1, 2 y 30 según 20260710010000, pero se resuelve
-- por dato y no por lista para que un rol nuevo con el flag no quede fuera).
-- El INSERT es idempotente y NO revoca nada: un rol que ya tuviera el vínculo
-- queda como está.
--
-- El slug se resuelve por SELECT: si faltara en el catálogo el INSERT no
-- insertaría filas en silencio, así que se verifica explícitamente después.
INSERT INTO public.roles_apps (id_rol, id_app, activo)
SELECT r.id, a.id, true
FROM public.roles r
CROSS JOIN public.apps a
WHERE a.slug = 'agentes'
  AND (r.id = 1 OR r.puede_impersonar IS TRUE)
ON CONFLICT (id_rol, id_app) DO NOTHING;

DO $reporte$
DECLARE
  v_id_app integer;
  v_roles  bigint;
BEGIN
  SELECT id INTO v_id_app FROM public.apps WHERE slug = 'agentes';
  IF v_id_app IS NULL THEN
    RAISE EXCEPTION 'El slug "agentes" no existe en public.apps: se esperaba de la migración 20260803180000.';
  END IF;

  SELECT count(*) INTO v_roles
  FROM public.roles_apps WHERE id_app = v_id_app AND activo;

  RAISE NOTICE 'app "agentes" (id %): % rol(es) la administran.', v_id_app, v_roles;
END
$reporte$;

COMMIT;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   -- Tablas y convención de columnas
--   SELECT table_name, column_name, data_type, is_nullable, column_default
--   FROM information_schema.columns
--   WHERE table_schema = 'public'
--     AND table_name IN ('push_tokens_agente','push_preferencias_agente',
--                        'notificaciones_agente','app_agente_config')
--   ORDER BY table_name, ordinal_position;
--
--   -- Índices
--   SELECT tablename, indexname, indexdef FROM pg_indexes
--   WHERE schemaname = 'public'
--     AND tablename IN ('push_tokens_agente','push_preferencias_agente',
--                       'notificaciones_agente','app_agente_config')
--   ORDER BY tablename, indexname;
--
--   -- RLS y policies
--   SELECT relname, relrowsecurity FROM pg_class
--   WHERE relnamespace = 'public'::regnamespace
--     AND relname IN ('push_tokens_agente','push_preferencias_agente',
--                     'notificaciones_agente','app_agente_config');
--   SELECT policyname, cmd, qual, with_check FROM pg_policies
--   WHERE schemaname = 'public' AND tablename = 'notificaciones_agente';
--
--   -- Triggers BEFORE UPDATE
--   SELECT c.relname, t.tgname, p.proname FROM pg_trigger t
--   JOIN pg_class c ON c.oid = t.tgrelid
--   JOIN pg_proc  p ON p.oid = t.tgfoid
--   WHERE NOT t.tgisinternal AND c.relname LIKE '%_agente%' ORDER BY 1, 2;
--
--   -- Realtime
--   SELECT tablename FROM pg_publication_tables
--   WHERE pubname = 'supabase_realtime' AND tablename = 'notificaciones_agente';
--
--   -- Vínculo rol -> app y sincronía de roles.apps
--   SELECT r.id, r.nombre, r.puede_impersonar, r.apps -> 'administrar' AS administrar
--   FROM public.roles_apps ra
--   JOIN public.apps a ON a.id = ra.id_app AND a.slug = 'agentes'
--   JOIN public.roles r ON r.id = ra.id_rol
--   WHERE ra.activo ORDER BY r.id;
--
--   -- Seed del version gate (min_version y latest_version vacíos = gate abierto)
--   SELECT key, value, activo FROM public.app_agente_config ORDER BY key;
