-- crm_last_activity_by_er — última actividad (nota/tarea/cita) por contacto.
-- Soporta el "semáforo de interacción" del módulo de Negocios: el tablero necesita, para
-- cientos/miles de negocios a la vez, la fecha de la última actividad de cada contacto. Hacerlo
-- desde el cliente con .in(...) topa con el límite de 1000 filas de PostgREST y trunca; esta
-- función agrega por contacto en el servidor (un solo GROUP BY), exacta y sin traer miles de filas.
--
-- SECURITY INVOKER: respeta la RLS del usuario que llama (misma visibilidad que las lecturas
-- directas del tablero). STABLE (solo lee). Recibe los id_entidad_relacionada de los negocios
-- visibles y regresa una fila por contacto con su last_activity_at.

BEGIN;

CREATE OR REPLACE FUNCTION public.crm_last_activity_by_er(p_er_ids bigint[])
RETURNS TABLE (id_entidad_relacionada bigint, last_activity_at timestamptz)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT a.id_entidad_relacionada, MAX(a.fecha_creacion) AS last_activity_at
  FROM (
    SELECT id_entidad_relacionada, fecha_creacion FROM public.crm_notas
      WHERE activo = true AND id_entidad_relacionada = ANY(p_er_ids)
    UNION ALL
    SELECT id_entidad_relacionada, fecha_creacion FROM public.crm_tareas
      WHERE activo = true AND id_entidad_relacionada = ANY(p_er_ids)
    UNION ALL
    SELECT id_entidad_relacionada, fecha_creacion FROM public.crm_citas
      WHERE activo = true AND id_entidad_relacionada = ANY(p_er_ids)
  ) a
  GROUP BY a.id_entidad_relacionada;
$$;

REVOKE ALL ON FUNCTION public.crm_last_activity_by_er(bigint[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.crm_last_activity_by_er(bigint[]) TO authenticated;

COMMENT ON FUNCTION public.crm_last_activity_by_er(bigint[]) IS
  'Última actividad (máx. fecha_creacion de notas/tareas/citas) por id_entidad_relacionada. Para el semáforo de interacción del módulo de Negocios.';

COMMIT;
