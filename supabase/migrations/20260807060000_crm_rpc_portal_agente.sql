-- Homologación CRM ↔ Portal Agente — 06: RPC del Portal Agente + permisos de menú
-- Fecha: 2026-08-07
-- REQUIERE: 01 (id_estatus_lead), 02, 03 (pipeline canónico) y 05 (fn_crm_etapa).
--           El 04 no es obligatorio, pero sin él la mitad de los leads no tiene
--           `id_propietario` y las RPC devuelven menos filas de las esperadas.
--
-- Expone al Portal Agente exactamente lo suyo. Toda la regla de visibilidad («el agente solo
-- ve lo suyo») vive en la RPC, no en el front: las cinco funciones son SECURITY DEFINER y
-- filtran por el `auth.uid()` de quien llama. `p_auth_user_id` solo sirve para impersonación y
-- está protegido: si difiere de `auth.uid()` y el llamante no puede impersonar, lanza 42501.
--
-- ─── Verificado read-only contra prod (tzmhgfjmddkfyffkkmto, 2026-08-07) ──────
--   * Los helpers de RLS existen: `current_puede`, `current_puede_tabla`,
--     `current_puede_impersonar`, `get_current_user_persona_id`, `can_access_agent_owned_lead`.
--   * `categorias_producto` y `productos_servicios.id_categoria` existen (el `tipo` de unidad).
--   * `crm_estados_lead` tiene clave, nombre, color, orden, activo.
--   * `crm_negocios` tiene `trg_crm_negocios_updated_at`, así que `fecha_actualizacion` sí se
--     mueve y `dias_en_etapa` tiene sentido — con la salvedad de que CUALQUIER update la
--     reinicia (una recotización, por ejemplo), no solo el cambio de etapa.
--   * Submenús del portal: Inicio 67, Inventario 68, Prospectos 87, **Pipeline 69**,
--     Comisiones 70, Perfil 71.
--
-- ─── Cuatro correcciones respecto al documento ───────────────────────────────
-- 1. EL ARCHIVO ABORTABA EN SU PROPIO SELF-VERIFY. `fn_agente_actual` no lleva REVOKE ni
--    GRANT, así que nace con EXECUTE para PUBLIC (comprobado en prod: `crm_sync_estatus_lead_id`
--    quedó con `=X/postgres, anon=X/postgres` justo por eso). El self-verify recorre las CINCO
--    funciones —incluida ésa— y falla si `anon` puede ejecutarlas: la migración se tumba sola.
--    Aquí `fn_agente_actual` recibe el mismo trato que las demás.
-- 2. REASIGNAR UN LEAD NO MOVÍA SUS NEGOCIOS. `get_agente_negocios` y `set_negocio_etapa`
--    filtran por `crm_negocios.id_usuario_propietario`, que el 05 llena con el creador de la
--    oferta y que NADIE actualiza cuando el CRM reasigna el lead. Con la fuente única acordada
--    (`crm_leads_atribucion.id_propietario`), el agente nuevo no vería el negocio y el anterior
--    seguiría moviéndolo. Las dos funciones aceptan ahora cualquiera de los dos dueños.
--    PENDIENTE de decidir: un trigger que propague la reasignación a `id_usuario_propietario`
--    para que la columna deje de mentir. Va en el 07/08 según cómo quede la bitácora.
-- 3. `id_entidad_relacionada` ES bigint, no integer. `set_lead_estatus` lo declaraba integer.
--    Por PostgREST llega como número JSON y hoy los ids caben, pero la firma queda alineada
--    con la columna.
-- 4. `get_agente_prospectos` PAGINABA SIN ORDEN GARANTIZADO: el `ORDER BY` vivía dentro del CTE
--    con LIMIT y el SELECT externo no lo repetía, así que el orden de la página quedaba a
--    criterio del planner. Se ordena también afuera.
--
-- Nota sobre el DML de menús: en prod **Prospectos (87) y Pipeline (69) ya tienen el permiso 3**
-- concedido y disponible, así que esos INSERT son no-op. Se conservan porque dev puede no
-- tenerlos y porque son idempotentes.
--
-- Sin BEGIN/COMMIT (el CI envuelve cada migración en transacción).

-- ─────────────────────────────────────────────────────────────────────
-- 1. Resolver el agente que llama (con excepción de impersonación)
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_agente_actual(p_auth_user_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_auth_user_id IS NOT NULL AND p_auth_user_id <> auth.uid() THEN
    IF NOT public.current_puede_impersonar() THEN
      RAISE EXCEPTION 'No autorizado para consultar prospectos de otro agente'
        USING ERRCODE = '42501';
    END IF;
    RETURN p_auth_user_id;
  END IF;
  RETURN auth.uid();
END;
$$;

-- ─────────────────────────────────────────────────────────────────────
-- 2. Lista de prospectos del agente: una fila por persona, con sus unidades
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_agente_prospectos(
  p_search       text    DEFAULT NULL,
  p_estatus      integer DEFAULT NULL,
  p_proyecto     integer DEFAULT NULL,
  p_auth_user_id uuid    DEFAULT NULL,
  p_limit        integer DEFAULT 50,
  p_offset       integer DEFAULT 0
)
RETURNS TABLE (
  id_persona      integer,
  nombre          text,
  email           text,
  telefono        text,
  total_personas  bigint,
  proyectos       jsonb
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_auth uuid := public.fn_agente_actual(p_auth_user_id);
BEGIN
  RETURN QUERY
  WITH mis_leads AS (
    SELECT er.id, er.id_persona, er.id_proyecto, a.id_estatus_lead
    FROM public.entidades_relacionadas er
    JOIN public.crm_leads_atribucion a
      ON a.id_entidad_relacionada = er.id AND a.activo
    WHERE er.activo
      AND er.id_tipo_entidad = 7
      AND a.id_propietario = v_auth
      AND (p_proyecto IS NULL OR er.id_proyecto = p_proyecto)
      AND (p_estatus  IS NULL OR a.id_estatus_lead = p_estatus)
  ),
  filtrados AS (
    SELECT l.*, per.nombre_legal, per.nombre_comercial, per.email, per.telefono
    FROM mis_leads l
    JOIN public.personas per ON per.id = l.id_persona AND per.activo
    WHERE p_search IS NULL OR p_search = '' OR (
         per.nombre_legal     ILIKE '%' || p_search || '%'
      OR per.nombre_comercial ILIKE '%' || p_search || '%'
      OR per.email            ILIKE '%' || p_search || '%'
      OR per.telefono         ILIKE '%' || p_search || '%')
  ),
  personas_pagina AS (
    SELECT f.id_persona,
           min(coalesce(f.nombre_legal, f.nombre_comercial)) AS nombre,
           min(f.email)    AS email,
           min(f.telefono) AS telefono,
           count(*) OVER () AS total
    FROM filtrados f
    GROUP BY f.id_persona
    ORDER BY 2
    LIMIT p_limit OFFSET p_offset
  )
  SELECT pp.id_persona, pp.nombre, pp.email, pp.telefono, pp.total,
         (
           SELECT jsonb_agg(jsonb_build_object(
                    'id_entidad_relacionada', l.id,
                    'id_proyecto',            l.id_proyecto,
                    'proyecto',               pr.nombre,
                    'id_estatus_lead',        l.id_estatus_lead,
                    'estatus',                el.nombre,
                    'estatus_clave',          el.clave,
                    'estatus_color',          el.color,
                    'unidades', coalesce((
                      SELECT jsonb_agg(jsonb_build_object(
                               'id_negocio',    n.id,
                               'id_oferta',     n.id_oferta,
                               'unidad',        coalesce(p.numero_propiedad, ps.nombre),
                               'tipo',          CASE WHEN n.id_propiedad IS NOT NULL THEN 'Propiedad'
                                                     ELSE coalesce(cp.nombre, 'Producto') END,
                               'ofertas_count', n.ofertas_count,
                               'valor',         n.valor,
                               'etapa',         e.nombre,
                               'etapa_clave',   e.clave,
                               'etapa_orden',   e.orden,
                               'automatica',    e.hecho_disparador IS NOT NULL,
                               'es_cliente',    e.orden >= 70 AND e.orden <> 99)
                             ORDER BY e.orden DESC)
                      FROM public.crm_negocios n
                      LEFT JOIN public.crm_pipeline_etapas e  ON e.id  = n.id_etapa
                      LEFT JOIN public.propiedades p          ON p.id  = n.id_propiedad
                      LEFT JOIN public.productos_servicios ps ON ps.id = n.id_producto
                      LEFT JOIN public.categorias_producto cp ON cp.id = ps.id_categoria
                      WHERE n.activo AND n.id_entidad_relacionada = l.id
                    ), '[]'::jsonb))
                  ORDER BY pr.nombre)
           FROM mis_leads l
           LEFT JOIN public.proyectos pr        ON pr.id = l.id_proyecto
           LEFT JOIN public.crm_estados_lead el ON el.id = l.id_estatus_lead
           WHERE l.id_persona = pp.id_persona
         ) AS proyectos
  FROM personas_pagina pp
  ORDER BY pp.nombre;        -- el LIMIT vive en el CTE: sin esto el orden de la página no está garantizado
END;
$$;

-- ─────────────────────────────────────────────────────────────────────
-- 3. Tablero «Negocios»
--    Dueño = el del negocio O el de la atribución (ver corrección 2): mientras
--    `id_usuario_propietario` no se actualice al reasignar, filtrar solo por él
--    escondería el negocio del agente nuevo.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_agente_negocios(p_auth_user_id uuid DEFAULT NULL)
RETURNS TABLE (
  id_negocio    integer,
  nombre        text,
  proyecto      text,
  unidad        text,
  tipo          text,
  persona       text,
  persona_email text,
  valor         numeric,
  etapa_clave   text,
  etapa_nombre  text,
  etapa_orden   integer,
  automatica    boolean,
  dias_en_etapa integer
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_auth uuid := public.fn_agente_actual(p_auth_user_id);
BEGIN
  RETURN QUERY
  SELECT n.id, n.nombre, pr.nombre,
         coalesce(p.numero_propiedad, ps.nombre),
         CASE WHEN n.id_propiedad IS NOT NULL THEN 'Propiedad' ELSE coalesce(cp.nombre, 'Producto') END,
         coalesce(per.nombre_legal, per.nombre_comercial),
         per.email,
         n.valor, e.clave, e.nombre, e.orden,
         e.hecho_disparador IS NOT NULL,
         greatest(0, (current_date - n.fecha_actualizacion::date))::integer
  FROM public.crm_negocios n
  JOIN public.crm_pipeline_etapas e       ON e.id  = n.id_etapa
  JOIN public.crm_pipelines pl            ON pl.id = n.id_pipeline AND pl.clave = 'ventas_sozu'
  LEFT JOIN public.propiedades p          ON p.id  = n.id_propiedad
  LEFT JOIN public.productos_servicios ps ON ps.id = n.id_producto
  LEFT JOIN public.categorias_producto cp ON cp.id = ps.id_categoria
  LEFT JOIN public.edificios_modelos em   ON em.id = p.id_edificio_modelo
  LEFT JOIN public.edificios ed           ON ed.id = em.id_edificio
  LEFT JOIN public.proyectos pr           ON pr.id = coalesce(ed.id_proyecto, ps.id_proyecto)
  LEFT JOIN public.entidades_relacionadas er ON er.id = n.id_entidad_relacionada
  LEFT JOIN public.personas per           ON per.id = er.id_persona
  LEFT JOIN public.crm_leads_atribucion a ON a.id_entidad_relacionada = er.id AND a.activo
  WHERE n.activo
    AND (n.id_usuario_propietario = v_auth OR a.id_propietario = v_auth)
  ORDER BY e.orden, n.fecha_actualizacion DESC;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────
-- 4. El agente edita el estado de SU lead
--    Escribe `id_estatus_lead`, la misma columna que usa el CRM: una sola fuente.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_lead_estatus(
  p_id_entidad_relacionada bigint,
  p_id_estatus_lead        integer
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_auth  uuid := auth.uid();
  v_dueno uuid;
BEGIN
  -- El catálogo es administrable en runtime desde CRM > Configuración: se valida contra la
  -- tabla, nunca contra una lista fija.
  IF NOT EXISTS (SELECT 1 FROM public.crm_estados_lead WHERE id = p_id_estatus_lead AND activo) THEN
    RAISE EXCEPTION 'Estado de lead inválido: %', p_id_estatus_lead USING ERRCODE = '22023';
  END IF;

  SELECT a.id_propietario INTO v_dueno
  FROM public.crm_leads_atribucion a
  WHERE a.id_entidad_relacionada = p_id_entidad_relacionada AND a.activo;

  IF v_dueno IS DISTINCT FROM v_auth AND NOT public.current_puede_impersonar() THEN
    RAISE EXCEPTION 'Este prospecto no te pertenece' USING ERRCODE = '42501';
  END IF;

  UPDATE public.crm_leads_atribucion
  SET id_estatus_lead = p_id_estatus_lead
  WHERE id_entidad_relacionada = p_id_entidad_relacionada AND activo;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────
-- 5. El agente mueve SOLO las etapas manuales de SUS negocios
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_negocio_etapa(
  p_id_negocio  integer,
  p_clave_etapa text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_auth     uuid := auth.uid();
  v_es_dueno boolean;
  v_id_etapa integer := public.fn_crm_etapa(p_clave_etapa);
  v_hecho    text;
BEGIN
  IF v_id_etapa IS NULL THEN
    RAISE EXCEPTION 'Etapa inexistente: %', p_clave_etapa USING ERRCODE = '22023';
  END IF;

  SELECT hecho_disparador INTO v_hecho
  FROM public.crm_pipeline_etapas WHERE id = v_id_etapa;

  IF v_hecho IS NOT NULL THEN
    RAISE EXCEPTION 'La etapa "%" la mueve el sistema (%), no se puede asignar a mano',
      p_clave_etapa, v_hecho USING ERRCODE = '42501';
  END IF;

  -- Mismo criterio de dueño que get_agente_negocios (corrección 2).
  SELECT EXISTS (
    SELECT 1
    FROM public.crm_negocios n
    LEFT JOIN public.crm_leads_atribucion a
      ON a.id_entidad_relacionada = n.id_entidad_relacionada AND a.activo
    WHERE n.id = p_id_negocio
      AND (n.id_usuario_propietario = v_auth OR a.id_propietario = v_auth)
  ) INTO v_es_dueno;

  IF NOT v_es_dueno AND NOT public.current_puede_impersonar() THEN
    RAISE EXCEPTION 'Este negocio no te pertenece' USING ERRCODE = '42501';
  END IF;

  UPDATE public.crm_negocios SET id_etapa = v_id_etapa WHERE id = p_id_negocio;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────
-- 6. Grants. Sin esto el front recibe 403 en .rpc(); sin el REVOKE, `anon` las
--    ejecuta (las funciones nuevas nacen con EXECUTE para PUBLIC).
-- ─────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.fn_agente_actual(uuid)                                            FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_agente_prospectos(text,integer,integer,uuid,integer,integer)  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_agente_negocios(uuid)                                         FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_lead_estatus(bigint,integer)                                  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_negocio_etapa(integer,text)                                   FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.fn_agente_actual(uuid)                                           TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_agente_prospectos(text,integer,integer,uuid,integer,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_agente_negocios(uuid)                                        TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_lead_estatus(bigint,integer)                                 TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_negocio_etapa(integer,text)                                  TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- 7. Menús y permisos
--    «Pipeline» choca con el vocabulario del CRM (allá un pipeline es un tablero de etapas).
--    Se renombra a «Negocios»; la ruta NO cambia, así que no hay que tocar App.tsx ni las
--    policies que referencian la vista.
-- ─────────────────────────────────────────────────────────────────────
UPDATE public.submenus
SET nombre = 'Negocios'
WHERE vista_front_end = '/admin/agent/pipeline' AND nombre <> 'Negocios';

-- Prospectos y Negocios deben OFRECER el permiso 3 (actualizar): el agente ahora edita el
-- estado de su lead y arrastra etapas manuales. En prod ambos ya lo tienen: no-op.
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, 3, true
FROM public.submenus s
WHERE s.vista_front_end IN ('/admin/agent/prospectos', '/admin/agent/pipeline')
  AND NOT EXISTS (SELECT 1 FROM public.submenus_permisos_disponibles d
                  WHERE d.submenu_id = s.id AND d.permiso_id = 3);

-- Se asigna a los roles que YA leen esos submenús: no se inventan roles nuevos.
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT sp.submenu_id, 3, sp.rol_id, true
FROM public.submenus_permisos sp
JOIN public.submenus s ON s.id = sp.submenu_id
WHERE s.vista_front_end IN ('/admin/agent/prospectos', '/admin/agent/pipeline')
  AND sp.permiso_id = 1 AND sp.activo
  AND NOT EXISTS (SELECT 1 FROM public.submenus_permisos x
                  WHERE x.submenu_id = sp.submenu_id AND x.permiso_id = 3 AND x.rol_id = sp.rol_id);

-- ─────────────────────────────────────────────────────────────────────
-- 8. Self-verifying
-- ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.fn_agente_actual(uuid)',
    'public.get_agente_prospectos(text,integer,integer,uuid,integer,integer)',
    'public.get_agente_negocios(uuid)',
    'public.set_lead_estatus(bigint,integer)',
    'public.set_negocio_etapa(integer,text)'
  ] LOOP
    IF to_regprocedure(f) IS NULL THEN RAISE EXCEPTION 'Falta la función %', f; END IF;
    IF NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'authenticated no puede ejecutar % (el front recibiría 403)', f;
    END IF;
    IF has_function_privilege('anon', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'anon puede ejecutar %: revocar', f;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM public.submenus WHERE vista_front_end = '/admin/agent/pipeline' AND nombre <> 'Negocios') THEN
    RAISE EXCEPTION 'El submenú del tablero no quedó renombrado a Negocios';
  END IF;
END $$;

-- Rollback:
--   DROP FUNCTION IF EXISTS public.get_agente_prospectos(text,integer,integer,uuid,integer,integer);
--   DROP FUNCTION IF EXISTS public.get_agente_negocios(uuid);
--   DROP FUNCTION IF EXISTS public.set_lead_estatus(bigint,integer);
--   DROP FUNCTION IF EXISTS public.set_negocio_etapa(integer,text);
--   DROP FUNCTION IF EXISTS public.fn_agente_actual(uuid);
--   UPDATE public.submenus SET nombre = 'Pipeline' WHERE vista_front_end = '/admin/agent/pipeline';
--   -- Los permisos 3 NO se borran en el rollback: en prod ya existían antes de esta migración.
