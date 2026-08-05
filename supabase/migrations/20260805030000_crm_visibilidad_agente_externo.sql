-- Visibilidad del rol "Agente Externo" (ej. Stephen) en Contactos: SOLO ve sus leads
-- (origen='agente_externo'). Se fuerza SERVER-SIDE en el RPC get_crm_contactos_agrupados,
-- para que NO sea bypasseable desde el front. Env-agnostico: identifica el rol por NOMBRE
-- (los rol_id difieren dev/prod). Idempotente, sin BEGIN/COMMIT.
--
-- Impersonation ("Ver como"): es solo front (auth.uid() sigue siendo el admin real), por eso
-- el RPC recibe p_force_agente_externo: el front lo manda TRUE cuando un admin impersona a un
-- Agente Externo. El parametro SOLO AGREGA el filtro, nunca lo quita -> el Agente Externo real
-- no puede bypassearlo (su auth.uid lo fuerza igual).
--
-- OJO orden de merge: esta migracion va a dev ANTES que el front (el front pasa el parametro
-- nuevo; si el RPC viejo no lo tiene, PostgREST truena por firma).

-- ─── Helper: ¿el usuario actual (auth.uid) tiene rol "Agente Externo"? ─────────
-- SECURITY DEFINER para leer usuarios/roles sin depender del RLS del que consulta.
-- auth.uid() sigue devolviendo el uid del CALLER (SECURITY DEFINER no cambia el JWT).
CREATE OR REPLACE FUNCTION public.crm_current_user_is_agente_externo()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.usuarios u
    JOIN public.roles r ON r.id = u.rol_id
    WHERE u.auth_user_id = auth.uid()
      AND u.activo = true
      AND r.nombre = 'Agente Externo'
  );
$$;

GRANT EXECUTE ON FUNCTION public.crm_current_user_is_agente_externo() TO authenticated, anon;

-- ─── RPC de contactos agrupados: +param p_force_agente_externo + restriccion ───
-- Cambia la firma (nuevo parametro) -> DROP de la firma vieja (10 args) + CREATE (11 args).
DROP FUNCTION IF EXISTS public.get_crm_contactos_agrupados(
    integer[], integer, text, text, integer, text, uuid, boolean, integer, integer);

CREATE OR REPLACE FUNCTION public.get_crm_contactos_agrupados(
    p_tipos integer[] DEFAULT ARRAY[2, 7],
    p_proyecto integer DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_fuente text DEFAULT NULL,
    p_categoria integer DEFAULT NULL,
    p_estatus text DEFAULT NULL,
    p_owner uuid DEFAULT NULL,
    p_unassigned boolean DEFAULT false,
    p_limit integer DEFAULT 25,
    p_offset integer DEFAULT 0,
    p_force_agente_externo boolean DEFAULT false)
RETURNS TABLE(id_entidad bigint, id_persona integer, otros_count integer, total_personas integer)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH base AS (
    SELECT e.id, e.id_persona, e.id_tipo_entidad, e.fecha_creacion,
           a.estatus_lead, a.meta_leadgen_id, a.id_propietario
    FROM public.entidades_relacionadas e
    JOIN public.personas p ON p.id = e.id_persona AND p.activo = true
    LEFT JOIN public.crm_leads_atribucion a ON a.id_entidad_relacionada = e.id AND a.activo = true
    WHERE e.activo = true
      AND e.id_tipo_entidad = ANY (p_tipos)
      AND (p_proyecto IS NULL OR e.id_proyecto = p_proyecto)
      AND (p_search IS NULL OR p_search = '' OR
           p.nombre_legal    ILIKE '%' || p_search || '%' OR
           p.nombre_comercial ILIKE '%' || p_search || '%' OR
           p.email           ILIKE '%' || p_search || '%' OR
           p.telefono        ILIKE '%' || p_search || '%')
      AND (p_estatus IS NULL OR COALESCE(a.estatus_lead, 'nuevo') = p_estatus)
      AND (p_categoria IS NULL OR EXISTS (
            SELECT 1 FROM public.entidades_relacionadas_categorias ec
            WHERE ec.id_entidad_relacionada = e.id AND ec.id_categoria = p_categoria AND ec.activo = true))
      AND (p_fuente IS NULL
           OR (p_fuente = 'meta'   AND a.meta_leadgen_id IS NOT NULL)
           OR (p_fuente = 'manual' AND a.meta_leadgen_id IS NULL))
      AND (p_owner IS NULL OR a.id_propietario = p_owner)
      AND (p_unassigned = false OR a.id_propietario IS NULL)
      -- Rol "Agente Externo": solo ve sus leads (origen='agente_externo'). Aplica al externo
      -- real (via auth.uid) o al admin que lo impersona (via p_force_agente_externo=true).
      -- El parametro solo AGREGA el filtro; el externo real no puede quitarlo.
      AND (a.origen = 'agente_externo'
           OR (NOT public.crm_current_user_is_agente_externo() AND NOT p_force_agente_externo))
  ),
  ranked AS (
    SELECT b.*,
           row_number() OVER (PARTITION BY b.id_persona
                              ORDER BY (b.id_tipo_entidad = 2) DESC, b.fecha_creacion DESC) AS rn,
           count(*)      OVER (PARTITION BY b.id_persona) AS ent_persona
    FROM base b
  )
  SELECT r.id::bigint,
         r.id_persona,
         (r.ent_persona - 1)::int   AS otros_count,
         (count(*) OVER ())::int     AS total_personas
  FROM ranked r
  WHERE r.rn = 1
  ORDER BY r.fecha_creacion DESC
  LIMIT p_limit OFFSET p_offset;
$function$;

GRANT EXECUTE ON FUNCTION public.get_crm_contactos_agrupados(
    integer[], integer, text, text, integer, text, uuid, boolean, integer, integer, boolean)
    TO authenticated, anon;
