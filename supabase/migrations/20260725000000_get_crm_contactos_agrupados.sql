-- Lista de Contactos del CRM AGRUPADA POR PERSONA.
-- Problema: el CRM pintaba una fila por `entidades_relacionadas`, y una persona puede
-- tener varias (una por compra=comprador tipo 2, una por proyecto=prospecto tipo 7).
-- Resultado: la misma persona salía N veces (en dev, 1701 entidades = 1116 personas).
-- Este RPC devuelve UNA fila por persona: su entidad "principal" (prioriza Cliente/tipo 2,
-- luego la más reciente) + cuántas OTRAS entidades tiene (para desplegarlas en el front).
-- Aplica todos los filtros de la lista y pagina correctamente por PERSONA.

CREATE OR REPLACE FUNCTION public.get_crm_contactos_agrupados(
  p_tipos       int[]   DEFAULT ARRAY[2, 7],  -- 2=comprador, 7=prospecto
  p_proyecto    int     DEFAULT NULL,
  p_search      text    DEFAULT NULL,         -- nombre / correo / teléfono
  p_fuente      text    DEFAULT NULL,         -- 'meta' | 'manual' | NULL(todas)
  p_categoria   int     DEFAULT NULL,
  p_estatus     text    DEFAULT NULL,         -- estatus_lead exacto
  p_owner       uuid    DEFAULT NULL,         -- "Mis contactos" (id_propietario)
  p_unassigned  boolean DEFAULT false,        -- "Contactos no asignados"
  p_limit       int     DEFAULT 25,
  p_offset      int     DEFAULT 0
)
RETURNS TABLE (id_entidad bigint, id_persona int, otros_count int, total_personas int)
LANGUAGE sql
STABLE
AS $$
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
$$;

GRANT EXECUTE ON FUNCTION public.get_crm_contactos_agrupados(int[], int, text, text, int, text, uuid, boolean, int, int) TO authenticated;
