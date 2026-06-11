-- Mediciones · Drill-down de usuarios por portal.
-- Fecha: 2026-06-10
--
-- Extiende la Fase 1 de Mediciones (20260610000002) con una RPC que devuelve el
-- detalle por usuario de un portal dado, acotado por rango de fechas opcional.
-- Permite a Alta Dirección (página "Uso por portal"): ver quién está online, el
-- listado de usuarios únicos del periodo y filtrar inactivos para contactarlos.
--
-- Notas:
--   * esta_online se evalúa al momento de la consulta (sesion_fin IS NULL y
--     ultima_actividad < 15 min), igual que usuarios_online_por_portal.
--   * dias_desde_ultima_actividad se calcula contra now() (no contra p_hasta).
--   * nombre_usuario viene de usuarios por email; si no existe ahí queda NULL y
--     el front usa el email como fallback.
-- Idempotente (CREATE OR REPLACE). Requiere portal_sesiones (Fase 1) ya aplicada.

CREATE OR REPLACE FUNCTION public.usuarios_actividad_por_portal(
  p_portal text,
  p_desde timestamptz DEFAULT NULL,
  p_hasta timestamptz DEFAULT NULL
) RETURNS TABLE (
  id_usuario                   uuid,
  email_usuario                text,
  nombre_usuario               text,
  primera_sesion               timestamptz,
  ultima_actividad             timestamptz,
  total_sesiones               bigint,
  duracion_total_min           numeric,
  esta_online                  boolean,
  dias_desde_ultima_actividad  integer
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ps.id_usuario,
    MAX(ps.email_usuario)                                            AS email_usuario,
    MAX(u.nombre)                                                    AS nombre_usuario,
    MIN(ps.sesion_inicio)                                            AS primera_sesion,
    MAX(ps.ultima_actividad)                                         AS ultima_actividad,
    COUNT(*)                                                         AS total_sesiones,
    ROUND(
      SUM(
        EXTRACT(EPOCH FROM (COALESCE(ps.sesion_fin, ps.ultima_actividad) - ps.sesion_inicio)) / 60
      )::numeric,
      1
    )                                                                AS duracion_total_min,
    BOOL_OR(
      ps.sesion_fin IS NULL AND ps.ultima_actividad > now() - interval '15 minutes'
    )                                                                AS esta_online,
    EXTRACT(DAY FROM (now() - MAX(ps.ultima_actividad)))::int        AS dias_desde_ultima_actividad
  FROM public.portal_sesiones ps
  LEFT JOIN public.usuarios u ON u.email = ps.email_usuario
  WHERE ps.portal = p_portal
    AND (p_desde IS NULL OR ps.sesion_inicio >= p_desde)
    AND (p_hasta IS NULL OR ps.sesion_inicio <  p_hasta)
  GROUP BY ps.id_usuario
  ORDER BY MAX(ps.ultima_actividad) DESC;
$$;

GRANT EXECUTE ON FUNCTION public.usuarios_actividad_por_portal(text, timestamptz, timestamptz)
  TO authenticated;

-- Recarga del schema cache de PostgREST para exponer la RPC a supabase-js.
NOTIFY pgrst, 'reload schema';
