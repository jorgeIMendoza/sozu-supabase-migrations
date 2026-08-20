-- Estados de lead de descarte: el catálogo declara cuáles cerraron el lead, y las RPC de
-- Prospectos del Portal Agente pueden cortarlos server-side.
--
-- Contexto: reporte de Keity Enid Galindo Bojorges. Medido en prod el 2026-08-20 — de sus
-- 1,047 leads con atribución activa, 897 están en un estado de descarte y 150 siguen en
-- juego. El corte tiene que ser server-side: filtrar en el navegador rompería el total y la
-- paginación de 20260819160000_agente_prospectos_paginado.
--
-- Se marcan por CLAVE, no por id: el catálogo se administra desde Configuración > Estados de
-- lead y los ids pueden diferir entre ambientes.

BEGIN;

-- 1) El catálogo declara qué estado es de descarte.
ALTER TABLE public.crm_estados_lead
  ADD COLUMN IF NOT EXISTS es_descarte boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.crm_estados_lead.es_descarte IS
  'true = el lead se cerró/descartó (no sigue en juego). La lista de Prospectos del Portal '
  'Agente los oculta por defecto y los muestra cuando el usuario filtra por ese estado.';

-- Semilla. Compra futura (compra_futura) y Tiempo de entrega (tiempo_entrega) quedan activos
-- a propósito: son espera, no cierre.
DO $seed$
DECLARE
  v_claves text[] := ARRAY['fuera_presupuesto','sin_respuesta_7','asesor_inmobiliario',
                           'registro_error','proveedor','fuera_area'];
  v_faltan text;
BEGIN
  UPDATE public.crm_estados_lead
     SET es_descarte = true
   WHERE clave = ANY(v_claves)
     AND es_descarte IS DISTINCT FROM true;

  -- No abortamos si el catálogo del ambiente no tiene alguna clave: la columna ya quedó y el
  -- estado se marca desde Configuración. Tumbar el deploy no cerraría nada.
  SELECT string_agg(c, ', ')
    INTO v_faltan
    FROM unnest(v_claves) c
   WHERE NOT EXISTS (SELECT 1 FROM public.crm_estados_lead el WHERE el.clave = c);

  IF v_faltan IS NOT NULL THEN
    RAISE WARNING 'crm_estados_lead: claves ausentes en este ambiente, sin marcar: %', v_faltan;
  END IF;
END
$seed$;

-- 2) get_agente_prospectos v3: mismo alcance y misma paginación que la v2, con corte opcional
--    de los estados de descarte. Base = definición viva en prod (md5 4f29505a…).
CREATE OR REPLACE FUNCTION public.get_agente_prospectos(
  p_search       text    DEFAULT NULL,
  p_estatus      integer DEFAULT NULL,
  p_proyecto     integer DEFAULT NULL,   -- -1 = solo leads sin desarrollo
  p_auth_user_id uuid    DEFAULT NULL,
  p_limit        integer DEFAULT 50,
  p_offset       integer DEFAULT 0,
  p_solo_activos boolean DEFAULT false   -- true = excluye crm_estados_lead.es_descarte
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
    LEFT JOIN public.crm_estados_lead el0
      ON el0.id = a.id_estatus_lead
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
      -- Un lead sin estado (alta del Portal Agente sin atribución) sigue en juego:
      -- ocultarlo esconderia un prospecto legitimo. Y el filtro explícito de estado gana
      -- sobre el corte: pedir «Asesor inmobiliario» tiene que mostrarlo, no una lista vacía.
      AND (
        NOT coalesce(p_solo_activos, false)
        OR p_estatus IS NOT NULL
        OR a.id_estatus_lead IS NULL
        OR NOT coalesce(el0.es_descarte, false)
      )
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
                    'es_descarte',            coalesce(el.es_descarte, false),
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

COMMENT ON FUNCTION public.get_agente_prospectos(text,integer,integer,uuid,integer,integer,boolean) IS
  'Página de prospectos del agente. p_proyecto: NULL = todos, -1 = solo sin desarrollo, N = ese '
  'proyecto. p_solo_activos = true excluye los estados con crm_estados_lead.es_descarte (los leads '
  'sin estado siempre entran, y p_estatus explícito gana sobre el corte). total_personas = '
  'universo filtrado antes del LIMIT.';

-- La firma nueva es un objeto nuevo: nace con EXECUTE para anon por DEFAULT PRIVILEGES.
REVOKE ALL ON FUNCTION public.get_agente_prospectos(text,integer,integer,uuid,integer,integer,boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_agente_prospectos(text,integer,integer,uuid,integer,integer,boolean)
  TO authenticated, service_role;

-- CREATE OR REPLACE con un parámetro más NO reemplaza la v2: crea un overload, y entonces
-- toda llamada de 6 argumentos queda ambigua (42725). La v2 se va; la v3 la cubre por default.
DROP FUNCTION IF EXISTS public.get_agente_prospectos(text,integer,integer,uuid,integer,integer);

-- 3) Facetas con el mismo corte, para que los conteos del filtro cuadren con la lista.
CREATE OR REPLACE FUNCTION public.get_agente_prospectos_facetas(
  p_auth_user_id uuid    DEFAULT NULL,
  p_solo_activos boolean DEFAULT false
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
  LEFT JOIN public.crm_estados_lead el    ON el.id = a.id_estatus_lead
  LEFT JOIN public.proyectos pr           ON pr.id = er.id_proyecto
  JOIN public.personas per                ON per.id = er.id_persona AND per.activo
  WHERE er.activo
    AND er.id_tipo_entidad = 7
    AND (
      (v_auth    IS NOT NULL AND a.id_propietario         = v_auth)
      OR (v_persona IS NOT NULL AND er.id_persona_duena_lead = v_persona)
    )
    AND (
      NOT coalesce(p_solo_activos, false)
      OR a.id_estatus_lead IS NULL
      OR NOT coalesce(el.es_descarte, false)
    )
  GROUP BY er.id_proyecto, pr.nombre
  -- «Sin desarrollo» al final, el resto alfabético.
  ORDER BY (er.id_proyecto IS NULL), coalesce(pr.nombre, 'Sin desarrollo');
END;
$function$;

COMMENT ON FUNCTION public.get_agente_prospectos_facetas(uuid,boolean) IS
  'Desarrollos con prospectos del agente (mismo predicado de dueño y mismo corte de descartes '
  'que get_agente_prospectos). id_proyecto NULL = Sin desarrollo, se pide con p_proyecto = -1.';

REVOKE ALL ON FUNCTION public.get_agente_prospectos_facetas(uuid,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_agente_prospectos_facetas(uuid,boolean) TO authenticated, service_role;

-- Misma razón que arriba: la de 1 argumento queda ambigua contra la de 2.
DROP FUNCTION IF EXISTS public.get_agente_prospectos_facetas(uuid);

-- ---------------------------------------------------------------------------
-- 4. Verificación (aborta la migración si algo no quedó como se espera)
-- ---------------------------------------------------------------------------
DO $verify$
DECLARE
  v_prospectos regprocedure :=
    'public.get_agente_prospectos(text,integer,integer,uuid,integer,integer,boolean)'::regprocedure;
  v_facetas    regprocedure :=
    'public.get_agente_prospectos_facetas(uuid,boolean)'::regprocedure;
  v_n int;
BEGIN
  -- La columna del catálogo existe y es NOT NULL: la lista no puede quedar con un tercer
  -- estado «no sé si es descarte».
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'crm_estados_lead'
       AND column_name = 'es_descarte' AND is_nullable = 'NO'
  ) THEN
    RAISE EXCEPTION 'crm_estados_lead.es_descarte no quedó como boolean NOT NULL.';
  END IF;

  -- Toda clave de descarte presente en el catálogo quedó marcada.
  SELECT count(*) INTO v_n
    FROM public.crm_estados_lead
   WHERE clave IN ('fuera_presupuesto','sin_respuesta_7','asesor_inmobiliario',
                   'registro_error','proveedor','fuera_area')
     AND NOT es_descarte;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'quedaron % estados de descarte sin marcar.', v_n;
  END IF;

  -- Ni Compra futura ni Tiempo de entrega son cierre: marcarlos esconderia leads en espera.
  IF EXISTS (SELECT 1 FROM public.crm_estados_lead
              WHERE clave IN ('compra_futura','tiempo_entrega') AND es_descarte) THEN
    RAISE EXCEPTION 'compra_futura/tiempo_entrega quedaron marcados como descarte.';
  END IF;

  -- Una sola firma por función: un overload con parámetro por default vuelve ambigua
  -- (42725) la llamada corta que sigue haciendo el front.
  SELECT count(*) INTO v_n
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('get_agente_prospectos','get_agente_prospectos_facetas');
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'se esperaban 2 firmas (una por función), hay %.', v_n;
  END IF;

  -- El corte llegó a la definición viva.
  IF position('p_solo_activos' in pg_get_functiondef(v_prospectos)) = 0
     OR position('es_descarte'  in pg_get_functiondef(v_prospectos)) = 0 THEN
    RAISE EXCEPTION 'get_agente_prospectos no quedó con el corte de descartes.';
  END IF;
  IF position('es_descarte' in pg_get_functiondef(v_facetas)) = 0 THEN
    RAISE EXCEPTION 'get_agente_prospectos_facetas no quedó con el corte de descartes.';
  END IF;

  -- Firma nueva = objeto nuevo: nace con EXECUTE para anon por DEFAULT PRIVILEGES.
  IF has_function_privilege('anon', v_prospectos, 'EXECUTE')
     OR has_function_privilege('public', v_prospectos, 'EXECUTE')
     OR has_function_privilege('anon', v_facetas, 'EXECUTE')
     OR has_function_privilege('public', v_facetas, 'EXECUTE') THEN
    RAISE EXCEPTION 'las RPC de prospectos quedaron ejecutables sin sesión.';
  END IF;
  IF NOT has_function_privilege('authenticated', v_prospectos, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_facetas, 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated no puede ejecutar las RPC: Prospectos quedaría vacío.';
  END IF;
END
$verify$;

COMMIT;

-- ---------------------------------------------------------------------------
-- Rollback
-- ---------------------------------------------------------------------------
--   -- re-aplicar las definiciones v2 (get_agente_prospectos 4f29505a,
--   -- get_agente_prospectos_facetas b8a802ff) de 20260819160000_agente_prospectos_paginado.sql,
--   -- y luego:
--   DROP FUNCTION IF EXISTS public.get_agente_prospectos(text,integer,integer,uuid,integer,integer,boolean);
--   DROP FUNCTION IF EXISTS public.get_agente_prospectos_facetas(uuid,boolean);
--   ALTER TABLE public.crm_estados_lead DROP COLUMN IF EXISTS es_descarte;
--
-- Sin riesgo de datos: las dos funciones son STABLE y no escriben, y ningún lead se borra ni
-- se archiva. Revertir devuelve Prospectos a la lista dominada por descartes.
