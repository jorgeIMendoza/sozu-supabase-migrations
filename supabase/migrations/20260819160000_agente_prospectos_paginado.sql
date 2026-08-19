-- Portal Agente: prospectos con búsqueda, filtro y paginación del lado de la base.
-- Fecha: 2026-08-19
--
-- Continúa 03_alcance_agente_impersonacion_y_duplicados. Cierra el ticket de Keity Enid
-- Galindo Bojorges (12 ago 2026): «en el portal de agentes veo todos los registros del crm».
--
-- El ALCANCE ya quedó correcto en eea4c391 (15 ago, en main): la RPC filtra por dueño y la
-- impersonación viaja con el auth_user_id del agente. Lo que queda es el CORTE SILENCIOSO:
-- el front pedía p_limit = 500 sin paginar y filtraba en memoria, así que un agente con más
-- de 500 prospectos nunca alcanzaba a los de la cola —la búsqueda solo miraba el trozo ya
-- descargado— y no tenía forma de saber que faltaban filas.
--
-- Verificado read-only en prod (tzmhgfjmddkfyffkkmto) el 2026-08-19:
--   · Leads tipo 7 activos: 4,226; de ellos 2,587 (61%) sin proyecto.
--   · Leads activos con atribución activa: 4,117.
--   · Keity (keity.galindo@sozu.com, rol 30): 1,047 leads sobre 1,039 personas, 4
--     desarrollos, 1,016 de ellos sin proyecto. Con página de 500, la mitad de su cartera
--     era inalcanzable.
--   · El caso más cargado no es el reportado: manuel.nava@sozu.com (rol 9) tiene 1,700
--     leads. El argumento para paginar es más fuerte, no menos.
--   · Ninguna entidad tiene 2 atribuciones activas -> el LEFT JOIN no duplica filas.
--   · No existe ningún proyecto con id negativo (min(id) = 2) -> el centinela -1 no colisiona.
--   · personas: 5,188 filas. No necesita trigramas: el ILIKE sobre esa tabla es barato y
--     pg_trgm no está instalado.
--
-- Los tres huecos que cierra:
--   1. «Sin desarrollo» no se podía filtrar: p_proyecto IS NULL significa «todos», así que
--      no había forma de pedir solo los leads sin proyecto, que son el 61%.
--   2. El selector de desarrollos se armaba con la página visible, así que los desarrollos
--      del agente que no salían en esas 25 filas desaparecían del filtro.
--   3. ORDER BY 2 sin desempate: dos personas con el mismo nombre pueden intercambiarse
--      entre página 1 y página 2, y el agente ve una fila repetida y otra perdida.

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Anclaje contra la definición viva
-- ---------------------------------------------------------------------------
DO $anchor$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.oid = 'public.get_agente_prospectos(text,integer,integer,uuid,integer,integer)'::regprocedure;

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'public.get_agente_prospectos(...) no existe con la firma esperada: esta migración la reemplaza, no la crea.';
  END IF;

  -- v1 = el filtro de proyecto sin centinela. v2 = ya migrada (re-aplicación).
  IF position('AND (p_proyecto IS NULL OR er.id_proyecto = p_proyecto)' in v_def) = 0
     AND position('p_proyecto = -1' in v_def) = 0 THEN
    RAISE EXCEPTION 'La definición viva de get_agente_prospectos no es la esperada: hay drift sin revisar. Abortando para no pisarlo.';
  END IF;
END
$anchor$;

-- ---------------------------------------------------------------------------
-- 1. Índices para el predicado de dueño
-- ---------------------------------------------------------------------------
-- Con la paginación la consulta pasa a correr en cada tecleo (el front debouncea 350 ms).
-- Hoy crm_leads_atribucion no tiene índice por id_propietario, y entidades_relacionadas
-- solo tiene el de dueño para id_tipo_entidad = 19, no para el 7.
--
-- Sin CONCURRENTLY a propósito: el CI aplica cada migración dentro de una transacción y
-- CREATE INDEX CONCURRENTLY no puede correr ahí. Las dos tablas son chicas (1.5 MB y
-- 1.7 MB, 4,185 y 7,368 filas), así que el lock es de milisegundos.
CREATE INDEX IF NOT EXISTS idx_crm_leads_atr_propietario
  ON public.crm_leads_atribucion (id_propietario)
  WHERE activo = true;

CREATE INDEX IF NOT EXISTS idx_entrel_t7_dueno
  ON public.entidades_relacionadas (id_persona_duena_lead)
  WHERE id_tipo_entidad = 7 AND activo = true;

-- ---------------------------------------------------------------------------
-- 2. get_agente_prospectos v2
-- ---------------------------------------------------------------------------
-- Mismo alcance y mismo contrato de salida. Tres cambios sobre la definición viva:
-- centinela de «Sin desarrollo», desempate por id_persona en el CTE y el mismo desempate
-- en el ORDER BY final.
CREATE OR REPLACE FUNCTION public.get_agente_prospectos(
  p_search       text    DEFAULT NULL,
  p_estatus      integer DEFAULT NULL,
  p_proyecto     integer DEFAULT NULL,   -- -1 = solo leads sin desarrollo
  p_auth_user_id uuid    DEFAULT NULL,
  p_limit        integer DEFAULT 50,
  p_offset       integer DEFAULT 0
)
RETURNS TABLE(
  id_persona     integer,
  nombre         text,
  email          text,
  telefono       text,
  total_personas bigint,
  proyectos      jsonb
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  -- fn_agente_actual exige current_puede_impersonar() para aceptar un uid ajeno.
  v_auth    uuid    := public.fn_agente_actual(p_auth_user_id);
  v_persona integer := public.fn_persona_de_auth_user(v_auth);
BEGIN
  -- Sin identidad no hay cartera: nunca devolver "todo" por un uid nulo.
  IF v_auth IS NULL AND v_persona IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH mis_leads AS (
    SELECT er.id, er.id_persona, er.id_proyecto, a.id_estatus_lead
    FROM public.entidades_relacionadas er
    -- LEFT: el lead dado de alta en el Portal Agente puede no tener atribución.
    -- Verificado: ninguna entidad tiene 2 atribuciones activas, no duplica filas.
    LEFT JOIN public.crm_leads_atribucion a
      ON a.id_entidad_relacionada = er.id AND a.activo
    WHERE er.activo
      AND er.id_tipo_entidad = 7
      -- Suyo por atribución (alta desde el CRM) o por dueño de la entidad
      -- (alta desde el Portal Agente). La propiedad del lead vive en las dos.
      AND (
        (v_auth    IS NOT NULL AND a.id_propietario         = v_auth)
        OR (v_persona IS NOT NULL AND er.id_persona_duena_lead = v_persona)
      )
      -- p_proyecto NULL = todos; -1 = solo los que no tienen desarrollo (61% de los leads).
      -- El centinela no colisiona: no existe ningún proyecto con id negativo.
      AND (
        p_proyecto IS NULL
        OR (p_proyecto = -1 AND er.id_proyecto IS NULL)
        OR (p_proyecto <> -1 AND er.id_proyecto = p_proyecto)
      )
      -- Filtrar por estatus deja fuera los leads sin atribución: no tienen estatus.
      -- Se conserva el comportamiento actual: es filtro explícito del usuario, no el
      -- estado por omisión.
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
    -- Desempate por id_persona: sin él, dos homónimos pueden cruzarse entre páginas
    -- y el agente ve una fila repetida y otra perdida.
    ORDER BY 2 NULLS LAST, 1
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
  -- Mismo criterio que el CTE. El LIMIT vive allá arriba: sin repetir el orden aquí, el de
  -- la página no está garantizado.
  ORDER BY pp.nombre NULLS LAST, pp.id_persona;
END;
$function$;

COMMENT ON FUNCTION public.get_agente_prospectos(text,integer,integer,uuid,integer,integer) IS
  'Página de prospectos del agente (leads tipo 7 suyos por atribución o por id_persona_duena_lead). '
  'p_proyecto: NULL = todos, -1 = solo sin desarrollo, N = ese proyecto. total_personas = universo '
  'filtrado antes del LIMIT. Impersonación validada en fn_agente_actual.';

-- ---------------------------------------------------------------------------
-- 3. Facetas para el selector de desarrollos
-- ---------------------------------------------------------------------------
-- Mismo predicado de dueño que get_agente_prospectos, para que el filtro ofrezca TODOS los
-- desarrollos del agente sin traerse la cartera completa.
CREATE OR REPLACE FUNCTION public.get_agente_prospectos_facetas(
  p_auth_user_id uuid DEFAULT NULL
)
RETURNS TABLE(
  id_proyecto integer,
  proyecto    text,
  prospectos  bigint
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_auth    uuid    := public.fn_agente_actual(p_auth_user_id);
  v_persona integer := public.fn_persona_de_auth_user(v_auth);
BEGIN
  IF v_auth IS NULL AND v_persona IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT er.id_proyecto,
         coalesce(pr.nombre, 'Sin desarrollo')::text AS proyecto,
         count(DISTINCT er.id_persona)               AS prospectos
  FROM public.entidades_relacionadas er
  LEFT JOIN public.crm_leads_atribucion a ON a.id_entidad_relacionada = er.id AND a.activo
  LEFT JOIN public.proyectos pr           ON pr.id = er.id_proyecto
  JOIN public.personas per                ON per.id = er.id_persona AND per.activo
  WHERE er.activo
    AND er.id_tipo_entidad = 7
    AND (
      (v_auth    IS NOT NULL AND a.id_propietario         = v_auth)
      OR (v_persona IS NOT NULL AND er.id_persona_duena_lead = v_persona)
    )
  GROUP BY er.id_proyecto, pr.nombre
  -- «Sin desarrollo» al final, el resto alfabético.
  ORDER BY (er.id_proyecto IS NULL), coalesce(pr.nombre, 'Sin desarrollo');
END;
$function$;

COMMENT ON FUNCTION public.get_agente_prospectos_facetas(uuid) IS
  'Desarrollos con prospectos del agente (mismo predicado de dueño que get_agente_prospectos), '
  'para poblar el filtro sin paginar. id_proyecto NULL = Sin desarrollo, se pide con p_proyecto = -1.';

-- El pg_default_acl de este proyecto concede EXECUTE nominal a anon, authenticated y
-- service_role en cada función nueva de public: revocar PUBLIC no alcanza a anon, hay que
-- nombrarlo. La función devuelve solo la cartera del llamador, pero es SECURITY DEFINER y
-- sin sesión no tiene nada que hacer.
REVOKE ALL ON FUNCTION public.get_agente_prospectos_facetas(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_agente_prospectos_facetas(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Auto-verificación
-- ---------------------------------------------------------------------------
DO $verify$
DECLARE
  v_faltan text;
  v_oid    oid := 'public.get_agente_prospectos_facetas(uuid)'::regprocedure;
BEGIN
  -- Los dos índices quedaron.
  SELECT string_agg(x.nombre, ', ' ORDER BY x.nombre) INTO v_faltan
  FROM (VALUES ('idx_crm_leads_atr_propietario'), ('idx_entrel_t7_dueno')) AS x(nombre)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_indexes i WHERE i.schemaname = 'public' AND i.indexname = x.nombre
  );
  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'Faltan índices: %', v_faltan;
  END IF;

  -- Las dos funciones quedan STABLE SECURITY DEFINER con search_path fijado.
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text)
    INTO v_faltan
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('get_agente_prospectos', 'get_agente_prospectos_facetas')
    AND (p.prosecdef IS NOT TRUE OR p.provolatile <> 's' OR p.proconfig IS NULL);
  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'Estas funciones no quedaron STABLE SECURITY DEFINER con search_path: %', v_faltan;
  END IF;

  -- El centinela quedó en la definición viva.
  IF position('p_proyecto = -1' in pg_get_functiondef(
       'public.get_agente_prospectos(text,integer,integer,uuid,integer,integer)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'get_agente_prospectos no quedó con el centinela de «Sin desarrollo».';
  END IF;

  -- anon no puede llamar a las facetas; authenticated sí.
  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('public', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'get_agente_prospectos_facetas quedó ejecutable sin sesión.';
  END IF;
  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated no puede ejecutar get_agente_prospectos_facetas: el filtro del portal quedaría vacío.';
  END IF;
END
$verify$;

COMMIT;

-- ---------------------------------------------------------------------------
-- Rollback
-- ---------------------------------------------------------------------------
--   DROP FUNCTION IF EXISTS public.get_agente_prospectos_facetas(uuid);
--   DROP INDEX  IF EXISTS public.idx_crm_leads_atr_propietario;
--   DROP INDEX  IF EXISTS public.idx_entrel_t7_dueno;
--   -- y re-aplicar la definición v1 de get_agente_prospectos (eea4c391).
--
-- Sin riesgo de datos: las dos funciones son STABLE y no escriben. Revertir devuelve el
-- filtro «Sin desarrollo» a inexistente y la paginación a orden no determinista.
