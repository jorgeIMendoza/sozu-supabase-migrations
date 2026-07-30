-- Módulo de Tareas del CRM: paginación + resolución de contacto/usuario SERVER-SIDE.
-- Antes el front cargaba 1000 tareas y resolvía nombres con múltiples .in() en el cliente
-- (con muchas tareas la URL de PostgREST reventaba → el contacto salía "—" y había lag).
-- Estos RPC hacen el JOIN + filtros + orden + paginación en una sola consulta.
-- SECURITY DEFINER porque el pool de tareas es transversal (todos ven todo) y el RLS de prod
-- es más estricto; SET search_path fijo por buenas prácticas.

-- ── Lista paginada de tareas (con nombre de contacto y de asignado) ──────────────
CREATE OR REPLACE FUNCTION public.get_crm_tareas(
  p_tab         text    DEFAULT 'all',   -- all | today | overdue | upcoming
  p_search      text    DEFAULT NULL,
  p_tipo        text    DEFAULT NULL,
  p_prioridad   text    DEFAULT NULL,
  p_asignado    uuid    DEFAULT NULL,    -- id_usuario_asignado exacto
  p_sin_asignar boolean DEFAULT false,   -- solo tareas sin asignar
  p_limit       int     DEFAULT 50,
  p_offset      int     DEFAULT 0
)
RETURNS TABLE (
  id int, titulo text, tipo text, prioridad text, estatus text, descripcion text,
  fecha_vencimiento timestamptz, fecha_recordatorio timestamptz, recurrencia text, fecha_creacion timestamptz,
  id_entidad_relacionada bigint, id_usuario_asignado uuid,
  contact_name text, assigned_name text, total_count bigint
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  WITH base AS (
    SELECT t.id, t.titulo, t.tipo, t.prioridad, t.estatus, t.descripcion,
           t.fecha_vencimiento, t.fecha_recordatorio, t.recurrencia, t.fecha_creacion,
           t.id_entidad_relacionada, t.id_usuario_asignado,
           COALESCE(NULLIF(btrim(p.nombre_legal), ''), NULLIF(btrim(p.nombre_comercial), '')) AS c_name,
           u.nombre AS a_name
    FROM public.crm_tareas t
    LEFT JOIN public.entidades_relacionadas e ON e.id = t.id_entidad_relacionada
    LEFT JOIN public.personas p ON p.id = e.id_persona
    LEFT JOIN public.usuarios u ON u.auth_user_id = t.id_usuario_asignado
    WHERE t.activo = true
      AND (p_tipo IS NULL OR t.tipo = p_tipo)
      AND (p_prioridad IS NULL OR t.prioridad = p_prioridad)
      AND (p_sin_asignar = false OR t.id_usuario_asignado IS NULL)
      AND (p_asignado IS NULL OR t.id_usuario_asignado = p_asignado)
      AND (p_search IS NULL OR p_search = '' OR
           t.titulo ILIKE '%' || p_search || '%' OR
           COALESCE(p.nombre_legal, '')    ILIKE '%' || p_search || '%' OR
           COALESCE(p.nombre_comercial, '') ILIKE '%' || p_search || '%')
      AND (
        p_tab = 'all'
        OR (t.estatus <> 'completada' AND t.fecha_vencimiento IS NOT NULL AND (
              (p_tab = 'today'    AND t.fecha_vencimiento::date = CURRENT_DATE)
           OR (p_tab = 'overdue'  AND t.fecha_vencimiento < date_trunc('day', now()))
           OR (p_tab = 'upcoming' AND t.fecha_vencimiento::date > CURRENT_DATE)
        ))
      )
  )
  SELECT b.id, b.titulo, b.tipo, b.prioridad, b.estatus, b.descripcion,
         b.fecha_vencimiento, b.fecha_recordatorio, b.recurrencia, b.fecha_creacion,
         b.id_entidad_relacionada, b.id_usuario_asignado,
         b.c_name AS contact_name, b.a_name AS assigned_name,
         count(*) OVER()::bigint AS total_count
  FROM base b
  ORDER BY
    CASE b.prioridad WHEN 'urgente' THEN 0 WHEN 'alta' THEN 1 WHEN 'normal' THEN 2 WHEN 'baja' THEN 3 ELSE 9 END,
    b.fecha_vencimiento ASC NULLS LAST
  LIMIT p_limit OFFSET p_offset;
$$;

GRANT EXECUTE ON FUNCTION public.get_crm_tareas(text, text, text, text, uuid, boolean, int, int) TO authenticated;

-- ── Conteos por pestaña (Todo / Vencen hoy / Atrasado / Próximamente) ───────────
CREATE OR REPLACE FUNCTION public.get_crm_tareas_conteos(
  p_search      text    DEFAULT NULL,
  p_tipo        text    DEFAULT NULL,
  p_prioridad   text    DEFAULT NULL,
  p_asignado    uuid    DEFAULT NULL,
  p_sin_asignar boolean DEFAULT false
)
RETURNS TABLE (all_count bigint, today_count bigint, overdue_count bigint, upcoming_count bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  WITH base AS (
    SELECT t.estatus, t.fecha_vencimiento
    FROM public.crm_tareas t
    LEFT JOIN public.entidades_relacionadas e ON e.id = t.id_entidad_relacionada
    LEFT JOIN public.personas p ON p.id = e.id_persona
    WHERE t.activo = true
      AND (p_tipo IS NULL OR t.tipo = p_tipo)
      AND (p_prioridad IS NULL OR t.prioridad = p_prioridad)
      AND (p_sin_asignar = false OR t.id_usuario_asignado IS NULL)
      AND (p_asignado IS NULL OR t.id_usuario_asignado = p_asignado)
      AND (p_search IS NULL OR p_search = '' OR
           t.titulo ILIKE '%' || p_search || '%' OR
           COALESCE(p.nombre_legal, '')    ILIKE '%' || p_search || '%' OR
           COALESCE(p.nombre_comercial, '') ILIKE '%' || p_search || '%')
  )
  SELECT
    count(*)::bigint,
    count(*) FILTER (WHERE estatus <> 'completada' AND fecha_vencimiento::date = CURRENT_DATE)::bigint,
    count(*) FILTER (WHERE estatus <> 'completada' AND fecha_vencimiento < date_trunc('day', now()))::bigint,
    count(*) FILTER (WHERE estatus <> 'completada' AND fecha_vencimiento::date > CURRENT_DATE)::bigint
  FROM base;
$$;

GRANT EXECUTE ON FUNCTION public.get_crm_tareas_conteos(text, text, text, uuid, boolean) TO authenticated;
