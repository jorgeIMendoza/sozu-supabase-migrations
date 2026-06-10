-- Mediciones de uso de portales — Fase 1: tablas de tracking + RPCs.
-- Fecha: 2026-06-10
--
-- Sistema genérico de mediciones de acceso, navegación y CTAs para los 12 portales.
-- El front (Fase 2, usePortalTracking) llama register_portal_session() al montar el
-- Layout, registrar_evento_portal() por evento (page_view/menu_click/submenu_click/
-- cta_click) y close_portal_session() al logout/unload. Dashboards (Fase 4) leen vía
-- usuarios_online_por_portal / visitas_historicas_por_portal / accesos_por_menu /
-- accesos_por_cta.
--
-- Seguridad: ambas tablas con RLS habilitado y SIN policies → ni authenticated ni anon
-- pueden tocarlas directo; todo acceso pasa por las RPC SECURITY DEFINER (grants a
-- authenticated al final). Idempotente: CREATE TABLE/INDEX IF NOT EXISTS + CREATE OR
-- REPLACE FUNCTION.

-- ───────────────────────────────────────────────────────────────────────────
-- 1. Tablas
-- ───────────────────────────────────────────────────────────────────────────

-- 1.1 portal_sesiones — una fila por sesión de usuario en un portal.
--   * online:    sesion_fin IS NULL AND ultima_actividad > now() - interval '15 min'
--   * únicos:    COUNT(DISTINCT id_usuario)
--   * duración:  COALESCE(sesion_fin, ultima_actividad) - sesion_inicio
CREATE TABLE IF NOT EXISTS public.portal_sesiones (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_usuario          uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  email_usuario       text NOT NULL,
  portal              text NOT NULL,
  sesion_inicio       timestamptz NOT NULL DEFAULT now(),
  sesion_fin          timestamptz NULL,
  ultima_actividad    timestamptz NOT NULL DEFAULT now(),
  user_agent          text NULL,
  activo              boolean NOT NULL DEFAULT true,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT portal_sesiones_portal_check CHECK (portal IN (
    'admin','clientes','agentes','inmobiliarias','embajadores',
    'cobranza','escrituracion','alta-direccion','juridico','notaria',
    'crm','condominio'
  ))
);

CREATE INDEX IF NOT EXISTS idx_portal_sesiones_portal_activa
  ON public.portal_sesiones (portal) WHERE sesion_fin IS NULL;
CREATE INDEX IF NOT EXISTS idx_portal_sesiones_usuario_portal
  ON public.portal_sesiones (id_usuario, portal);
CREATE INDEX IF NOT EXISTS idx_portal_sesiones_ultima_actividad
  ON public.portal_sesiones (ultima_actividad DESC);
CREATE INDEX IF NOT EXISTS idx_portal_sesiones_inicio
  ON public.portal_sesiones (sesion_inicio DESC);

ALTER TABLE public.portal_sesiones ENABLE ROW LEVEL SECURITY;
-- Sin policies → acceso sólo via RPC SECURITY DEFINER.

-- 1.2 portal_eventos — log genérico de navegación y CTAs.
--   page_view (ruta, id_submenu) · menu_click (id_menu) ·
--   submenu_click (id_menu, id_submenu) · cta_click (cta_nombre, data-cta)
CREATE TABLE IF NOT EXISTS public.portal_eventos (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_sesion       uuid NULL REFERENCES public.portal_sesiones(id) ON DELETE SET NULL,
  id_usuario      uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  email_usuario   text NULL,
  portal          text NOT NULL,
  tipo_evento     text NOT NULL,
  id_menu         integer NULL REFERENCES public.menus(id) ON DELETE SET NULL,
  id_submenu      integer NULL REFERENCES public.submenus(id) ON DELETE SET NULL,
  cta_nombre      text NULL,
  ruta            text NULL,
  metadatos       jsonb NULL,
  fecha_creacion  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT portal_eventos_tipo_check CHECK (tipo_evento IN (
    'page_view','menu_click','submenu_click','cta_click'
  ))
);

CREATE INDEX IF NOT EXISTS idx_portal_eventos_portal_fecha
  ON public.portal_eventos (portal, fecha_creacion DESC);
CREATE INDEX IF NOT EXISTS idx_portal_eventos_tipo_portal
  ON public.portal_eventos (tipo_evento, portal);
CREATE INDEX IF NOT EXISTS idx_portal_eventos_menu
  ON public.portal_eventos (id_menu) WHERE id_menu IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_portal_eventos_submenu
  ON public.portal_eventos (id_submenu) WHERE id_submenu IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_portal_eventos_cta
  ON public.portal_eventos (portal, cta_nombre, fecha_creacion DESC)
  WHERE cta_nombre IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_portal_eventos_usuario
  ON public.portal_eventos (id_usuario, fecha_creacion DESC);
CREATE INDEX IF NOT EXISTS idx_portal_eventos_sesion
  ON public.portal_eventos (id_sesion);

ALTER TABLE public.portal_eventos ENABLE ROW LEVEL SECURITY;
-- Sin policies → acceso sólo via RPC SECURITY DEFINER.

-- ───────────────────────────────────────────────────────────────────────────
-- 2. RPCs de escritura (SECURITY DEFINER)
-- ───────────────────────────────────────────────────────────────────────────

-- Idempotente: si ya hay una sesión activa del usuario en el portal con
-- ultima_actividad reciente (<30 min), la reutiliza como heartbeat. Si no,
-- crea una nueva. Devuelve el id de la sesión activa.
CREATE OR REPLACE FUNCTION public.register_portal_session(
  p_portal text,
  p_user_agent text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id    uuid := auth.uid();
  v_email      text;
  v_session_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No authenticated user';
  END IF;

  SELECT email INTO v_email FROM auth.users WHERE id = v_user_id;

  -- Reusar sesión activa reciente (heartbeat 30 min).
  SELECT id INTO v_session_id
  FROM public.portal_sesiones
  WHERE id_usuario = v_user_id
    AND portal = p_portal
    AND sesion_fin IS NULL
    AND ultima_actividad > now() - interval '30 minutes'
  ORDER BY ultima_actividad DESC
  LIMIT 1;

  IF v_session_id IS NOT NULL THEN
    UPDATE public.portal_sesiones
       SET ultima_actividad = now(),
           fecha_actualizacion = now()
     WHERE id = v_session_id;
    RETURN v_session_id;
  END IF;

  INSERT INTO public.portal_sesiones (id_usuario, email_usuario, portal, user_agent)
  VALUES (v_user_id, v_email, p_portal, p_user_agent)
  RETURNING id INTO v_session_id;

  RETURN v_session_id;
END;
$$;

-- Heartbeat puntual (sin crear sesión nueva).
CREATE OR REPLACE FUNCTION public.touch_portal_session(p_session_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.portal_sesiones
     SET ultima_actividad = now(),
         fecha_actualizacion = now()
   WHERE id = p_session_id AND sesion_fin IS NULL;
END;
$$;

-- Cerrar la sesión (logout o pageunload).
CREATE OR REPLACE FUNCTION public.close_portal_session(p_session_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.portal_sesiones
     SET sesion_fin = now(),
         ultima_actividad = now(),
         fecha_actualizacion = now()
   WHERE id = p_session_id AND sesion_fin IS NULL;
END;
$$;

-- Registrar evento (page_view/menu_click/submenu_click/cta_click). Cualquier
-- evento cuenta como heartbeat de la sesión.
CREATE OR REPLACE FUNCTION public.registrar_evento_portal(
  p_session_id uuid,
  p_portal text,
  p_tipo_evento text,
  p_id_menu integer DEFAULT NULL,
  p_id_submenu integer DEFAULT NULL,
  p_cta_nombre text DEFAULT NULL,
  p_ruta text DEFAULT NULL,
  p_metadatos jsonb DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id  uuid := auth.uid();
  v_email    text;
  v_event_id bigint;
BEGIN
  IF v_user_id IS NOT NULL THEN
    SELECT email INTO v_email FROM auth.users WHERE id = v_user_id;
  END IF;

  INSERT INTO public.portal_eventos (
    id_sesion, id_usuario, email_usuario, portal, tipo_evento,
    id_menu, id_submenu, cta_nombre, ruta, metadatos
  ) VALUES (
    p_session_id, v_user_id, v_email, p_portal, p_tipo_evento,
    p_id_menu, p_id_submenu, p_cta_nombre, p_ruta, p_metadatos
  )
  RETURNING id INTO v_event_id;

  IF p_session_id IS NOT NULL THEN
    UPDATE public.portal_sesiones
       SET ultima_actividad = now()
     WHERE id = p_session_id AND sesion_fin IS NULL;
  END IF;

  RETURN v_event_id;
END;
$$;

-- ───────────────────────────────────────────────────────────────────────────
-- 3. RPCs de lectura para dashboards (SECURITY DEFINER)
--    Quién ve los dashboards se controla por menú/submenú (sólo Super Admin
--    tiene permisos sobre las vistas de Mediciones — ver migración de menús).
-- ───────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.usuarios_online_por_portal(
  p_minutos_inactividad integer DEFAULT 15
) RETURNS TABLE (portal text, usuarios_online bigint, sesiones_activas bigint)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    portal,
    COUNT(DISTINCT id_usuario) AS usuarios_online,
    COUNT(*) AS sesiones_activas
  FROM public.portal_sesiones
  WHERE sesion_fin IS NULL
    AND ultima_actividad > now() - make_interval(mins => p_minutos_inactividad)
  GROUP BY portal
  ORDER BY usuarios_online DESC;
$$;

CREATE OR REPLACE FUNCTION public.visitas_historicas_por_portal(
  p_desde timestamptz DEFAULT NULL,
  p_hasta timestamptz DEFAULT NULL
) RETURNS TABLE (
  portal text,
  usuarios_unicos bigint,
  total_sesiones bigint,
  duracion_promedio_min numeric,
  primera_sesion timestamptz,
  ultima_sesion timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    portal,
    COUNT(DISTINCT id_usuario) AS usuarios_unicos,
    COUNT(*) AS total_sesiones,
    ROUND(
      AVG(EXTRACT(EPOCH FROM (COALESCE(sesion_fin, ultima_actividad) - sesion_inicio)) / 60)::numeric,
      1
    ) AS duracion_promedio_min,
    MIN(sesion_inicio) AS primera_sesion,
    MAX(sesion_inicio) AS ultima_sesion
  FROM public.portal_sesiones
  WHERE (p_desde IS NULL OR sesion_inicio >= p_desde)
    AND (p_hasta IS NULL OR sesion_inicio <  p_hasta)
  GROUP BY portal
  ORDER BY usuarios_unicos DESC;
$$;

CREATE OR REPLACE FUNCTION public.accesos_por_menu(
  p_portal text,
  p_desde timestamptz DEFAULT NULL,
  p_hasta timestamptz DEFAULT NULL
) RETURNS TABLE (
  id_menu integer,
  menu_nombre text,
  id_submenu integer,
  submenu_nombre text,
  vista_front_end text,
  accesos bigint,
  usuarios_unicos bigint,
  ultimo_acceso timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    pe.id_menu,
    m.nombre AS menu_nombre,
    pe.id_submenu,
    s.nombre AS submenu_nombre,
    s.vista_front_end,
    COUNT(*) AS accesos,
    COUNT(DISTINCT pe.id_usuario) AS usuarios_unicos,
    MAX(pe.fecha_creacion) AS ultimo_acceso
  FROM public.portal_eventos pe
  LEFT JOIN public.menus    m ON m.id = pe.id_menu
  LEFT JOIN public.submenus s ON s.id = pe.id_submenu
  WHERE pe.portal = p_portal
    AND pe.tipo_evento IN ('menu_click','submenu_click','page_view')
    AND (p_desde IS NULL OR pe.fecha_creacion >= p_desde)
    AND (p_hasta IS NULL OR pe.fecha_creacion <  p_hasta)
  GROUP BY pe.id_menu, m.nombre, pe.id_submenu, s.nombre, s.vista_front_end
  ORDER BY accesos DESC;
$$;

CREATE OR REPLACE FUNCTION public.accesos_por_cta(
  p_portal text,
  p_desde timestamptz DEFAULT NULL,
  p_hasta timestamptz DEFAULT NULL,
  p_id_submenu integer DEFAULT NULL
) RETURNS TABLE (
  cta_nombre text,
  id_submenu integer,
  submenu_nombre text,
  clicks bigint,
  usuarios_unicos bigint,
  ultimo_click timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    pe.cta_nombre,
    pe.id_submenu,
    s.nombre AS submenu_nombre,
    COUNT(*) AS clicks,
    COUNT(DISTINCT pe.id_usuario) AS usuarios_unicos,
    MAX(pe.fecha_creacion) AS ultimo_click
  FROM public.portal_eventos pe
  LEFT JOIN public.submenus s ON s.id = pe.id_submenu
  WHERE pe.portal = p_portal
    AND pe.tipo_evento = 'cta_click'
    AND pe.cta_nombre IS NOT NULL
    AND (p_desde IS NULL OR pe.fecha_creacion >= p_desde)
    AND (p_hasta IS NULL OR pe.fecha_creacion <  p_hasta)
    AND (p_id_submenu IS NULL OR pe.id_submenu = p_id_submenu)
  GROUP BY pe.cta_nombre, pe.id_submenu, s.nombre
  ORDER BY clicks DESC;
$$;

-- ───────────────────────────────────────────────────────────────────────────
-- 4. Grants — authenticated puede llamar todas las RPC
-- ───────────────────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION public.register_portal_session(text, text)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.touch_portal_session(uuid)                   TO authenticated;
GRANT EXECUTE ON FUNCTION public.close_portal_session(uuid)                   TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_evento_portal(uuid, text, text, integer, integer, text, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.usuarios_online_por_portal(integer)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.visitas_historicas_por_portal(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accesos_por_menu(text, timestamptz, timestamptz)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.accesos_por_cta(text, timestamptz, timestamptz, integer) TO authenticated;

-- Recarga del schema cache de PostgREST para exponer las nuevas RPC a supabase-js.
NOTIFY pgrst, 'reload schema';
