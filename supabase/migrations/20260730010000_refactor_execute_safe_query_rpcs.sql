-- =============================================================================
-- Refactor de execute_safe_query → 7 RPCs específicas gateadas por rol/permiso
--
-- execute_safe_query recibe SQL arbitrario del navegador, es SECURITY DEFINER con
-- dueño postgres y salta todo RLS: darle EXECUTE a authenticated es SELECT libre
-- sobre el esquema completo para cualquier sesión con JWT (rol 23 incluido). La
-- decisión (2026-07-29) fue refactor y NO re-otorgar el GRANT. Aquí la query vive
-- en el servidor y el acceso se decide con el modelo que ya existe:
-- user_has_permission(ruta, permiso), current_puede_impersonar() y, para
-- reportes, user_can_access_report(id) sobre roles_reportes.
--
-- Las 7 funciones son independientes; se despliegan todas juntas porque una
-- función sin consumidor es inocua, y el frontend las va adoptando pantalla por
-- pantalla. Regla que sigue vigente: la RPC va a la BD ANTES del front que la usa.
--
-- Verificado read-only contra prod el 2026-07-29:
--   · Ninguna de las 7 existe con ninguna firma.
--   · Submenús: 38 /admin/cuentas-cobranza activo (10 roles con 'leer':
--     1,2,7,9,10,11,12,14,15,30); 31 /admin/legal/contratos activo=false;
--     42 /admin/configuracion-reportes activo pero SIN permisos configurados.
--   · 26 usuarios activos en roles con puede_impersonar.
--   · conceptos_pago 1..6 existen; tipos_entidad 4='Dueño Vendedor', 15='Aportante'.
--   · user_can_access_report(integer) existe, SECURITY DEFINER, abre a
--     'Super Administrador' y resuelve el resto por roles_reportes.
--   · Probado en PG 17 que los tres constructos de regex del documento funcionan:
--     lookbehind (?<!:), regexp_matches(...) AS m con m[1], y \M.
--   · execute_safe_query sigue en 'postgres | service_role'. No se toca.
--
-- Correcciones respecto al documento:
--   a) RPC 7 quedaba inejecutable. El gate era rol_id=1 AND
--      user_has_permission('/admin/configuracion-reportes','actualizar'), y ese
--      submenú no tiene NI UNA fila en submenus_permisos: la segunda condición es
--      false para todos, incluido Super Admin, así que el editor seguiría roto.
--      Es el mismo problema que el documento sí detectó para el submenú 31. Aquí
--      el gate de permiso se aplica solo si la matriz está configurada: mientras
--      esté vacía gobierna rol_id=1, y en cuanto se siembren permisos el gate
--      doble entra sin necesidad de otra migración.
--   b) Tres tipos de RETURNS TABLE no compilaban (42804 en la primera llamada):
--        RPC 2 id_entidad   integer → bigint (entidades_relacionadas.id)
--        RPC 4 cuenta_id    integer → bigint (cuentas_cobranza.id)
--        RPC 4 propiedad_id integer → bigint (propiedades.id)
--      Y p_ownership_entity_ids pasa a bigint[], el tipo de
--      propiedades.id_entidad_relacionada_dueno.
--   c) Sin BEGIN/COMMIT: supabase db push ya envuelve cada migración en una
--      transacción y anidarla cerraría la del CI antes de tiempo.
--   d) El REVOKE va FROM PUBLIC, anon — no solo FROM PUBLIC. pg_default_acl del
--      esquema public para funciones es 'anon=X | authenticated=X |
--      service_role=X', así que toda función NUEVA nace con EXECUTE para anon, y
--      revocar a PUBLIC no toca un grant hecho directamente al rol anon. Con el
--      patrón del documento las 7 RPCs habrían quedado ejecutables por anon:
--      lo detectó el bloque self-verifying en el deploy a dev (2026-07-30).
--      No afectaba a sync_conyuge_compradores porque ya existía y
--      CREATE OR REPLACE conserva la ACL. service_role conserva su EXECUTE.
--
-- RIESGO CONOCIDO, decisión de negocio pendiente (no se resuelve aquí):
--   run_reporte ejecuta reportes.query_sql como postgres, y la escritura de
--   `reportes` está gateada por is_admin_user() = rol_id IN (1, 2). O sea que
--   Administrador de Proyecto (rol 2, 2 usuarios activos) puede escribir su
--   propio SQL en un reporte y ejecutarlo saltándose RLS. Hoy no puede porque
--   ejecutarlo requería execute_safe_query, que está revocada. Si se quiere
--   cerrar, la policy de escritura de `reportes` debe pasar de is_admin_user()
--   a is_super_admin(); eso cambia quién administra reportes y va en su propia
--   migración.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Pre-condiciones: los helpers del gate tienen que existir, o las 7 funciones
-- quedarían rechazando a todo el mundo.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure('public.user_has_permission(text, text)') IS NULL
     OR to_regprocedure('public.current_puede_impersonar()') IS NULL
     OR to_regprocedure('public.user_can_access_report(integer)') IS NULL THEN
    RAISE EXCEPTION 'Faltan helpers de autorización (user_has_permission / current_puede_impersonar / user_can_access_report)';
  END IF;

  -- WARNING y no EXCEPTION: es expectativa del entorno, no invariante. En prod el
  -- submenú 38 está activo; si en dev no existe o está inactivo, las RPC 1-3
  -- quedan solo para puede_impersonar, que es degradación aceptable y no razón
  -- para tumbar el deploy.
  IF NOT EXISTS (
    SELECT 1 FROM public.submenus
    WHERE vista_front_end = '/admin/cuentas-cobranza' AND activo = true
  ) THEN
    RAISE WARNING 'El submenú /admin/cuentas-cobranza no está activo en este entorno: las RPC 1-3 solo responderán a puede_impersonar';
  END IF;
END
$$;

-- =============================================================================
-- RPC 1 — get_valor_por_proyecto
-- Reemplaza src/pages/admin/Pagos.tsx:304
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_valor_por_proyecto(
  p_proyecto_ids          integer[] DEFAULT NULL,   -- NULL = sin restricción de proyecto
  p_ownership_entity_ids  bigint[]  DEFAULT NULL    -- NULL = sin filtro por dueño
)
RETURNS TABLE (
  id_proyecto          integer,
  proyecto_nombre      text,
  total_propiedades    bigint,
  valor_total_proyecto numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT (public.user_has_permission('/admin/cuentas-cobranza', 'leer')
          OR public.current_puede_impersonar()) THEN
    RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT pv.id_proyecto,
         pv.proyecto_nombre,
         COUNT(DISTINCT pv.prop_id) AS total_propiedades,
         SUM(pv.valor_propiedad)    AS valor_total_proyecto
  FROM (
    SELECT DISTINCT ON (prop.id)
      p.id           AS id_proyecto,
      p.nombre::text AS proyecto_nombre,
      prop.id        AS prop_id,
      CASE WHEN cc.id IS NOT NULL AND cc.activo = true
           THEN cc.precio_final
           ELSE COALESCE(prop.precio_lista, 0)
      END            AS valor_propiedad
    FROM proyectos p
    JOIN entidades_relacionadas er
      ON er.id_proyecto = p.id AND er.activo = true AND er.id_tipo_entidad IN (4, 15)
    JOIN propiedades prop
      ON prop.id_entidad_relacionada_dueno = er.id AND prop.activo = true
    LEFT JOIN ofertas o
      ON o.id_propiedad = prop.id AND o.activo = true AND o.id_producto IS NULL
    LEFT JOIN cuentas_cobranza cc
      ON cc.id_oferta = o.id AND cc.id_cuenta_cobranza_padre IS NULL AND cc.activo = true
    WHERE p.activo = true
      AND (p_proyecto_ids IS NULL OR p.id = ANY(p_proyecto_ids))
      AND (p_ownership_entity_ids IS NULL
           OR prop.id_entidad_relacionada_dueno = ANY(p_ownership_entity_ids))
    ORDER BY prop.id, cc.id DESC NULLS LAST
  ) pv
  GROUP BY pv.id_proyecto, pv.proyecto_nombre
  ORDER BY valor_total_proyecto DESC;
END;
$function$;

COMMENT ON FUNCTION public.get_valor_por_proyecto(integer[], bigint[]) IS
  'Valor total por proyecto (precio_final de cuentas activas, precio_lista si no hay cuenta). '
  'Gate: submenú /admin/cuentas-cobranza permiso leer, o puede_impersonar. '
  'Reemplaza execute_safe_query en src/pages/admin/Pagos.tsx.';

REVOKE ALL ON FUNCTION public.get_valor_por_proyecto(integer[], bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_valor_por_proyecto(integer[], bigint[]) TO authenticated;

-- =============================================================================
-- RPC 2 — get_project_owner_breakdown
-- Reemplaza src/components/admin/ProjectCollectionSummaryDialog.tsx:68
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_project_owner_breakdown(
  p_cuenta_ids  bigint[],
  p_proyecto_id integer
)
RETURNS TABLE (
  id_entidad      bigint,
  dueno_nombre    text,
  tipo_entidad    text,
  id_tipo_entidad integer,
  cuentas_count   bigint,
  total_colocado  numeric,
  total_cobrado   numeric,
  valor_proyecto  numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT (public.user_has_permission('/admin/cuentas-cobranza', 'leer')
          OR public.current_puede_impersonar()) THEN
    RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501';
  END IF;

  IF p_cuenta_ids IS NULL OR array_length(p_cuenta_ids, 1) IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT oa.id_entidad,
         oa.dueno_nombre,
         oa.tipo_entidad,
         oa.id_tipo_entidad,
         COUNT(oa.cuenta_id)             AS cuentas_count,
         SUM(oa.precio_final)            AS total_colocado,
         SUM(oa.total_pagado)            AS total_cobrado,
         COALESCE(oap.valor_proyecto, 0) AS valor_proyecto
  FROM (
    SELECT er.id                AS id_entidad,
           p.nombre_legal::text AS dueno_nombre,
           te.nombre::text      AS tipo_entidad,
           er.id_tipo_entidad,
           cc.id                AS cuenta_id,
           cc.precio_final,
           COALESCE(pagos.total_pagado, 0) AS total_pagado
    FROM cuentas_cobranza cc
    JOIN ofertas o                 ON cc.id_oferta = o.id
    JOIN propiedades prop          ON o.id_propiedad = prop.id
    JOIN entidades_relacionadas er ON prop.id_entidad_relacionada_dueno = er.id
    JOIN personas p                ON er.id_persona = p.id
    JOIN tipos_entidad te          ON er.id_tipo_entidad = te.id
    LEFT JOIN (
      SELECT ap2.id_cuenta_cobranza, SUM(apl2.monto) AS total_pagado
      FROM aplicaciones_pago apl2
      JOIN acuerdos_pago ap2 ON apl2.id_acuerdo_pago = ap2.id
      WHERE apl2.activo = true AND apl2.es_multa = false AND ap2.activo = true
      GROUP BY ap2.id_cuenta_cobranza
    ) pagos ON pagos.id_cuenta_cobranza = cc.id
    WHERE cc.id = ANY(p_cuenta_ids)
      AND cc.activo = true
      AND o.id_producto IS NULL
  ) oa
  LEFT JOIN (
    SELECT er2.id AS id_entidad,
           SUM(CASE WHEN cc2.id IS NOT NULL AND cc2.activo = true
                    THEN cc2.precio_final
                    ELSE COALESCE(prop2.precio_lista, 0)
               END) AS valor_proyecto
    FROM entidades_relacionadas er2
    JOIN propiedades prop2 ON prop2.id_entidad_relacionada_dueno = er2.id AND prop2.activo = true
    LEFT JOIN ofertas o2 ON o2.id_propiedad = prop2.id AND o2.activo = true AND o2.id_producto IS NULL
    LEFT JOIN cuentas_cobranza cc2 ON cc2.id_oferta = o2.id AND cc2.id_cuenta_cobranza_padre IS NULL
    WHERE er2.id_proyecto = p_proyecto_id
      AND er2.activo = true
      AND er2.id_tipo_entidad IN (4, 15)
    GROUP BY er2.id
  ) oap ON oa.id_entidad = oap.id_entidad
  GROUP BY oa.id_entidad, oa.dueno_nombre, oa.tipo_entidad, oa.id_tipo_entidad, oap.valor_proyecto
  ORDER BY total_colocado DESC;
END;
$function$;

COMMENT ON FUNCTION public.get_project_owner_breakdown(bigint[], integer) IS
  'Desglose por dueño de las cuentas de un proyecto. Gate: /admin/cuentas-cobranza leer o puede_impersonar.';

REVOKE ALL ON FUNCTION public.get_project_owner_breakdown(bigint[], integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_project_owner_breakdown(bigint[], integer) TO authenticated;

-- =============================================================================
-- RPC 3 — get_project_collection_totals
-- Reemplaza ProjectCollectionSummaryDialog.tsx:154 y :175 en una sola llamada.
-- Devuelve { "acuerdos": [{categoria,total_monto}], "pagado": [{categoria,total_pagado}] }
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_project_collection_totals(
  p_cuenta_ids bigint[]
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_acuerdos jsonb;
  v_pagado   jsonb;
BEGIN
  IF NOT (public.user_has_permission('/admin/cuentas-cobranza', 'leer')
          OR public.current_puede_impersonar()) THEN
    RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501';
  END IF;

  IF p_cuenta_ids IS NULL OR array_length(p_cuenta_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('acuerdos', '[]'::jsonb, 'pagado', '[]'::jsonb);
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('categoria', t.categoria, 'total_monto', t.total_monto)), '[]'::jsonb)
  INTO v_acuerdos
  FROM (
    SELECT CASE WHEN id_concepto IN (1,2,4,5,6) THEN 'durante_obra'
                WHEN id_concepto = 3            THEN 'contraentrega'
                ELSE 'otro' END AS categoria,
           SUM(monto)           AS total_monto
    FROM acuerdos_pago
    WHERE id_cuenta_cobranza = ANY(p_cuenta_ids)
      AND activo = true
    GROUP BY 1
  ) t;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('categoria', t.categoria, 'total_pagado', t.total_pagado)), '[]'::jsonb)
  INTO v_pagado
  FROM (
    SELECT CASE WHEN ap.id_concepto IN (1,2,4,5,6) THEN 'durante_obra'
                WHEN ap.id_concepto = 3            THEN 'contraentrega'
                ELSE 'otro' END AS categoria,
           SUM(apl.monto)       AS total_pagado
    FROM aplicaciones_pago apl
    JOIN acuerdos_pago ap ON apl.id_acuerdo_pago = ap.id
    WHERE ap.id_cuenta_cobranza = ANY(p_cuenta_ids)
      AND apl.activo = true
      AND apl.es_multa = false
      AND ap.activo = true
    GROUP BY 1
  ) t;

  RETURN jsonb_build_object('acuerdos', v_acuerdos, 'pagado', v_pagado);
END;
$function$;

COMMENT ON FUNCTION public.get_project_collection_totals(bigint[]) IS
  'Totales de acuerdos y aplicaciones por categoría (durante_obra/contraentrega/otro) '
  'para un set de cuentas. Gate: /admin/cuentas-cobranza leer o puede_impersonar.';

REVOKE ALL ON FUNCTION public.get_project_collection_totals(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_project_collection_totals(bigint[]) TO authenticated;

-- =============================================================================
-- RPC 4 — get_contratos_pendientes
-- Reemplaza src/pages/admin/legal/Contratos.tsx:89
-- El submenú 31 (/admin/legal/contratos) está activo=false y user_has_permission
-- exige s.activo = true, así que un gate por esa ruta daría false siempre. Gate
-- por puede_impersonar (26 usuarios activos); la rama por permiso entra sola en
-- cuanto el submenú se reactive.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_contratos_pendientes()
RETURNS TABLE (
  cuenta_id        bigint,
  precio_final     numeric,
  contrato_draft   text,
  oferta_id        integer,
  propiedad_id     bigint,
  numero_propiedad text,
  edificio         text,
  modelo           text,
  proyecto_id      integer,
  proyecto         text,
  dueno            text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT (public.current_puede_impersonar()
          OR public.user_has_permission('/admin/legal/contratos', 'leer')) THEN
    RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT DISTINCT
    cc.id                        AS cuenta_id,
    cc.precio_final,
    cc.contrato_draft::text,
    o.id                         AS oferta_id,
    p.id                         AS propiedad_id,
    p.numero_propiedad::text,
    ed.nombre::text              AS edificio,
    m.nombre::text               AS modelo,
    proy.id                      AS proyecto_id,
    proy.nombre::text            AS proyecto,
    per_dueno.nombre_legal::text AS dueno
  FROM cuentas_cobranza cc
  JOIN ofertas o                       ON cc.id_oferta = o.id
  JOIN propiedades p                   ON o.id_propiedad = p.id
  JOIN estatus_disponibilidad est      ON p.id_estatus_disponibilidad = est.id
  JOIN edificios_modelos em            ON p.id_edificio_modelo = em.id
  JOIN edificios ed                    ON em.id_edificio = ed.id
  JOIN modelos m                       ON em.id_modelo = m.id
  JOIN entidades_relacionadas er_dueno ON p.id_entidad_relacionada_dueno = er_dueno.id
  JOIN proyectos proy                  ON er_dueno.id_proyecto = proy.id
  JOIN personas per_dueno              ON er_dueno.id_persona = per_dueno.id
  WHERE cc.activo = true
    AND o.activo = true
    AND p.activo = true
    AND o.id_propiedad IS NOT NULL
    AND est.id IN (4, 5)
    AND NOT EXISTS (
      SELECT 1 FROM documentos doc
      WHERE doc.id_cuenta_cobranza = cc.id
        AND doc.id_tipo_documento = 18
        AND doc.activo = true
    )
    AND NOT EXISTS (
      SELECT 1 FROM compradores comp
      WHERE comp.id_cuenta_cobranza = cc.id
        AND comp.activo = true
        AND comp.id_persona IS NOT NULL
        AND (
          EXISTS (
            SELECT 1 FROM documentos dnv
            WHERE dnv.id_persona = comp.id_persona
              AND dnv.id_estatus_verificacion != 2
              AND dnv.activo = true
              AND dnv.id_cuenta_cobranza IS NULL
          )
          OR NOT EXISTS (
            SELECT 1 FROM documentos dv
            WHERE dv.id_persona = comp.id_persona
              AND dv.id_estatus_verificacion = 2
              AND dv.activo = true
              AND dv.id_cuenta_cobranza IS NULL
          )
        )
    )
    AND EXISTS (
      SELECT 1 FROM compradores comp2
      WHERE comp2.id_cuenta_cobranza = cc.id
        AND comp2.activo = true
    )
  ORDER BY cuenta_id DESC;
END;
$function$;

COMMENT ON FUNCTION public.get_contratos_pendientes() IS
  'Cuentas en estatus 4/5 sin contrato firmado (doc 18) y con compradores documentados. '
  'Gate: puede_impersonar, o permiso leer en /admin/legal/contratos (submenú hoy inactivo). '
  'Reemplaza execute_safe_query en legal/Contratos.tsx.';

REVOKE ALL ON FUNCTION public.get_contratos_pendientes() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_contratos_pendientes() TO authenticated;

-- =============================================================================
-- RPC 5 — run_reporte
-- Reemplaza ReporteViewer.tsx:344 y :387. El SQL sale de reportes.query_sql
-- (servidor), nunca del navegador. Los filtros llegan como jsonb y se interpolan
-- con quote_literal: eso cierra la inyección de applyFiltersToQuery, que hoy
-- concatena `'${valor}'` a mano.
-- Replica la semántica de applyFiltersToQuery (ReporteViewer.tsx:58-129).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.run_reporte(
  p_reporte_id integer,
  p_filtros    jsonb   DEFAULT '{}'::jsonb,
  p_max_rows   integer DEFAULT 50000
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sql           text;
  v_filtros_cfg   jsonb;
  v_placeholder   text;
  v_condition     text;
  v_filtro_nombre text;
  v_valor         text;
  v_tipo          text;
  v_needs_quotes  boolean;
  v_in_list       text;
  v_replaced      text;
  v_result        jsonb;
  v_rec           record;
BEGIN
  -- Gate por reporte (rol → roles_reportes; Super Admin abierto).
  IF NOT public.user_can_access_report(p_reporte_id) THEN
    RAISE EXCEPTION 'No autorizado para el reporte %', p_reporte_id USING ERRCODE = '42501';
  END IF;

  SELECT r.query_sql, COALESCE(r.filtros_configuracion, '[]'::jsonb)
  INTO v_sql, v_filtros_cfg
  FROM reportes r
  WHERE r.id = p_reporte_id AND r.activo = true;

  IF v_sql IS NULL THEN
    RAISE EXCEPTION 'Reporte % no existe o está inactivo', p_reporte_id USING ERRCODE = '22023';
  END IF;

  -- 1. Quitar comentarios de línea antes de normalizar espacios.
  v_sql := regexp_replace(v_sql, '--[^\n]*', '', 'g');

  -- 2. Resolver cada placeholder {{ … :filtro … }}.
  FOR v_rec IN
    SELECT m[1] AS condition
    FROM regexp_matches(v_sql, '\{\{([^}]+)\}\}', 'g') AS m
  LOOP
    v_condition   := v_rec.condition;
    v_placeholder := '{{' || v_condition || '}}';

    v_filtro_nombre := (regexp_match(v_condition, ':(\w+)'))[1];

    IF v_filtro_nombre IS NULL THEN
      CONTINUE;   -- placeholder sin filtro: se deja tal cual, igual que el front
    END IF;

    v_valor := NULLIF(p_filtros ->> v_filtro_nombre, '');

    IF v_valor IS NULL THEN
      v_sql := replace(v_sql, v_placeholder, '');
      CONTINUE;
    END IF;

    -- ¿el filtro es de texto? (tipo declarado en filtros_configuracion)
    SELECT f ->> 'tipo' INTO v_tipo
    FROM jsonb_array_elements(v_filtros_cfg) f
    WHERE f ->> 'nombre' = v_filtro_nombre
    LIMIT 1;

    v_needs_quotes := COALESCE(v_tipo IN ('text', 'date', 'daterange'), false)
                      OR v_valor !~ '^-?\d+(\.\d+)?$';

    IF position(',' IN v_valor) > 0 THEN
      -- multi-valor → IN (…)
      SELECT string_agg(
               CASE WHEN v_needs_quotes THEN quote_literal(btrim(x)) ELSE btrim(x) END, ','
             )
      INTO v_in_list
      FROM unnest(string_to_array(v_valor, ',')) AS x;

      v_replaced := replace(v_condition, '= :' || v_filtro_nombre, 'IN (' || v_in_list || ')');
      v_replaced := replace(v_replaced,  '=:'  || v_filtro_nombre, 'IN (' || v_in_list || ')');
    ELSE
      v_replaced := replace(
        v_condition,
        ':' || v_filtro_nombre,
        CASE WHEN v_needs_quotes THEN quote_literal(v_valor) ELSE v_valor END
      );
    END IF;

    v_sql := replace(v_sql, v_placeholder, v_replaced);
  END LOOP;

  -- 3. Normalizar espacios y limpiar sintaxis colgante (mismo orden que el front).
  v_sql := btrim(regexp_replace(v_sql, '\s+', ' ', 'g'));
  v_sql := regexp_replace(v_sql, 'WHERE\s+AND',   'WHERE', 'gi');
  v_sql := regexp_replace(v_sql, 'WHERE\s+OR',    'WHERE', 'gi');
  v_sql := regexp_replace(v_sql, 'AND\s+AND',     'AND',   'gi');
  v_sql := regexp_replace(v_sql, 'OR\s+OR',       'OR',    'gi');
  v_sql := regexp_replace(v_sql, 'AND\s+ORDER',   'ORDER', 'gi');
  v_sql := regexp_replace(v_sql, 'AND\s+GROUP',   'GROUP', 'gi');
  v_sql := regexp_replace(v_sql, 'AND\s+LIMIT',   'LIMIT', 'gi');
  v_sql := regexp_replace(v_sql, 'WHERE\s+ORDER', 'ORDER', 'gi');
  v_sql := regexp_replace(v_sql, 'WHERE\s+GROUP', 'GROUP', 'gi');
  v_sql := regexp_replace(v_sql, 'WHERE\s+LIMIT', 'LIMIT', 'gi');
  v_sql := regexp_replace(v_sql, '\s+AND\s*$',    '',      'gi');
  v_sql := regexp_replace(v_sql, '\s+OR\s*$',     '',      'gi');
  v_sql := regexp_replace(v_sql, '\s+WHERE\s*$',  '',      'gi');
  v_sql := btrim(v_sql);
  v_sql := regexp_replace(v_sql, ';\s*$', '');

  -- 4. Defensa en profundidad: la plantilla vive en la BD, pero si alguien guardó
  --    algo que no es SELECT/WITH, no se ejecuta.
  IF upper(v_sql) !~ '\mSELECT\s' AND upper(v_sql) !~ '\mWITH\s' THEN
    RAISE EXCEPTION 'La plantilla del reporte % no es una consulta SELECT/WITH', p_reporte_id
      USING ERRCODE = '42601';
  END IF;
  IF position(';' IN v_sql) > 0 THEN
    RAISE EXCEPTION 'La plantilla del reporte % contiene múltiples sentencias', p_reporte_id
      USING ERRCODE = '42601';
  END IF;

  IF upper(v_sql) NOT LIKE '%LIMIT%' THEN
    v_sql := v_sql || ' LIMIT ' || GREATEST(1, LEAST(p_max_rows, 50000));
  END IF;

  EXECUTE format('SELECT COALESCE(jsonb_agg(row_to_json(t)), ''[]''::jsonb) FROM (%s) t', v_sql)
  INTO v_result;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$function$;

COMMENT ON FUNCTION public.run_reporte(integer, jsonb, integer) IS
  'Ejecuta reportes.query_sql del reporte indicado aplicando filtros server-side con '
  'quote_literal. Gate: user_can_access_report (roles_reportes). El SQL nunca viene del '
  'cliente. OJO: la escritura de reportes.query_sql está gateada por is_admin_user() '
  '(roles 1 y 2), así que quien pueda editar un reporte decide qué SQL corre como postgres. '
  'Reemplaza execute_safe_query en ReporteViewer.tsx.';

REVOKE ALL ON FUNCTION public.run_reporte(integer, jsonb, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.run_reporte(integer, jsonb, integer) TO authenticated;

-- =============================================================================
-- RPC 6 — get_reporte_filtro_opciones
-- Reemplaza ReporteViewer.tsx:475. El SQL sale de
-- reportes.filtros_configuracion[].query_opciones (servidor).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_reporte_filtro_opciones(
  p_reporte_id    integer,
  p_filtro_nombre text,
  p_filtros       jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_query   text;
  v_key     text;
  v_valor   text;
  v_in_list text;
  v_result  jsonb;
BEGIN
  IF NOT public.user_can_access_report(p_reporte_id) THEN
    RAISE EXCEPTION 'No autorizado para el reporte %', p_reporte_id USING ERRCODE = '42501';
  END IF;

  SELECT f ->> 'query_opciones'
  INTO v_query
  FROM reportes r
  CROSS JOIN jsonb_array_elements(COALESCE(r.filtros_configuracion, '[]'::jsonb)) f
  WHERE r.id = p_reporte_id
    AND r.activo = true
    AND f ->> 'nombre' = p_filtro_nombre
  LIMIT 1;

  IF v_query IS NULL OR btrim(v_query) = '' THEN
    RETURN '[]'::jsonb;
  END IF;

  -- Sustituir :placeholders con los filtros ya seleccionados.
  FOR v_key IN SELECT jsonb_object_keys(p_filtros) LOOP
    v_valor := NULLIF(p_filtros ->> v_key, '');
    CONTINUE WHEN v_valor IS NULL;

    IF position(',' IN v_valor) > 0 THEN
      SELECT string_agg(
               CASE WHEN btrim(x) ~ '^-?\d+$' THEN btrim(x) ELSE quote_literal(btrim(x)) END, ','
             )
      INTO v_in_list
      FROM unnest(string_to_array(v_valor, ',')) AS x;

      v_query := regexp_replace(v_query, ':' || v_key || '\M', '(' || v_in_list || ')', 'g');
    ELSE
      v_query := regexp_replace(
        v_query, ':' || v_key || '\M',
        CASE WHEN v_valor ~ '^-?\d+(\.\d+)?$' THEN v_valor ELSE quote_literal(v_valor) END,
        'g'
      );
    END IF;
  END LOOP;

  -- Si quedan placeholders sin resolver, no se ejecuta (igual que el front).
  IF v_query ~ '(?<!:):\w+' THEN
    RETURN '[]'::jsonb;
  END IF;

  v_query := btrim(regexp_replace(regexp_replace(v_query, '--[^\n]*', '', 'g'), '\s+', ' ', 'g'));
  v_query := regexp_replace(v_query, ';\s*$', '');

  IF upper(v_query) !~ '\mSELECT\s' AND upper(v_query) !~ '\mWITH\s' THEN
    RAISE EXCEPTION 'query_opciones del filtro % no es SELECT/WITH', p_filtro_nombre
      USING ERRCODE = '42601';
  END IF;
  IF position(';' IN v_query) > 0 THEN
    RAISE EXCEPTION 'query_opciones del filtro % contiene múltiples sentencias', p_filtro_nombre
      USING ERRCODE = '42601';
  END IF;

  IF upper(v_query) NOT LIKE '%LIMIT%' THEN
    v_query := v_query || ' LIMIT 1000';
  END IF;

  EXECUTE format('SELECT COALESCE(jsonb_agg(row_to_json(t)), ''[]''::jsonb) FROM (%s) t', v_query)
  INTO v_result;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$function$;

COMMENT ON FUNCTION public.get_reporte_filtro_opciones(integer, text, jsonb) IS
  'Opciones de un filtro select/multiselect de un reporte. El SQL sale de '
  'reportes.filtros_configuracion[].query_opciones. Gate: user_can_access_report.';

REVOKE ALL ON FUNCTION public.get_reporte_filtro_opciones(integer, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_reporte_filtro_opciones(integer, text, jsonb) TO authenticated;

-- =============================================================================
-- RPC 7 — validar_query_reporte   (EXCEPCIÓN DOCUMENTADA)
-- Reemplaza ConfiguracionReportes.tsx:231. Editor de SQL del admin: recibe SQL
-- arbitrario por definición. Gate estricto a Super Administrador (rol 1), que ya
-- tiene acceso a toda la BD por rol, así que no amplía superficie.
--
-- El gate de permiso NO va en AND duro: el submenú 42
-- (/admin/configuracion-reportes) no tiene ninguna fila en submenus_permisos, así
-- que user_has_permission daría false para todos y la función nacería muerta. Se
-- aplica solo cuando la matriz esté configurada.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.validar_query_reporte(p_query text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sql              text;
  v_result           jsonb;
  v_matriz_cargada   boolean;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM usuarios u
    WHERE u.auth_user_id = auth.uid() AND u.activo = true AND u.rol_id = 1
  ) THEN
    RAISE EXCEPTION 'Solo Super Administrador puede validar queries de reportes'
      USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM submenus s
    JOIN submenus_permisos sp ON sp.submenu_id = s.id AND sp.activo = true
    WHERE s.vista_front_end = '/admin/configuracion-reportes'
      AND s.activo = true
  ) INTO v_matriz_cargada;

  IF v_matriz_cargada
     AND NOT public.user_has_permission('/admin/configuracion-reportes', 'actualizar') THEN
    RAISE EXCEPTION 'Sin permiso actualizar en /admin/configuracion-reportes'
      USING ERRCODE = '42501';
  END IF;

  v_sql := btrim(p_query);

  IF upper(v_sql) !~ '\mSELECT\s' AND upper(v_sql) !~ '\mWITH\s' THEN
    RAISE EXCEPTION 'Solo se permiten consultas SELECT o WITH (CTEs)' USING ERRCODE = '42601';
  END IF;
  IF upper(v_sql) ~ '\m(DROP|DELETE|UPDATE|INSERT|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|EXEC|EXECUTE|COPY)\M' THEN
    RAISE EXCEPTION 'Consulta contiene palabras clave no permitidas' USING ERRCODE = '42601';
  END IF;

  v_sql := regexp_replace(v_sql, ';\s*$', '');
  IF position(';' IN v_sql) > 0 THEN
    RAISE EXCEPTION 'No se permiten múltiples consultas' USING ERRCODE = '42601';
  END IF;

  -- Validación: 1 fila basta para confirmar que compila.
  IF upper(v_sql) NOT LIKE '%LIMIT%' THEN
    v_sql := v_sql || ' LIMIT 1';
  END IF;

  EXECUTE format('SELECT COALESCE(jsonb_agg(row_to_json(t)), ''[]''::jsonb) FROM (%s) t', v_sql)
  INTO v_result;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$function$;

COMMENT ON FUNCTION public.validar_query_reporte(text) IS
  'EXCEPCIÓN: recibe SQL arbitrario (editor de reportes). Gate: rol_id=1, más permiso '
  'actualizar en /admin/configuracion-reportes cuando ese submenú tenga permisos '
  'configurados (hoy no tiene ninguno). Solo valida con LIMIT 1. No otorgar a otros roles.';

REVOKE ALL ON FUNCTION public.validar_query_reporte(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.validar_query_reporte(text) TO authenticated;

-- =============================================================================
-- Self-verifying: aborta el CI si alguna función quedó sin gate o mal otorgada.
-- =============================================================================
DO $$
DECLARE
  v_firmas text[] := ARRAY[
    'public.get_valor_por_proyecto(integer[], bigint[])',
    'public.get_project_owner_breakdown(bigint[], integer)',
    'public.get_project_collection_totals(bigint[])',
    'public.get_contratos_pendientes()',
    'public.run_reporte(integer, jsonb, integer)',
    'public.get_reporte_filtro_opciones(integer, text, jsonb)',
    'public.validar_query_reporte(text)'
  ];
  v_sig text;
  v_oid oid;
  v_n   integer;
BEGIN
  FOREACH v_sig IN ARRAY v_firmas
  LOOP
    v_oid := to_regprocedure(v_sig);

    IF v_oid IS NULL THEN
      RAISE EXCEPTION 'Falta la función %', v_sig;
    END IF;

    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
      RAISE EXCEPTION '% quedó sin SECURITY DEFINER', v_sig;
    END IF;

    IF position('42501' IN pg_get_functiondef(v_oid)) = 0 THEN
      RAISE EXCEPTION '% no tiene gate de autorización', v_sig;
    END IF;

    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'authenticated no puede ejecutar %', v_sig;
    END IF;

    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'anon quedó con EXECUTE sobre %', v_sig;
    END IF;
  END LOOP;

  -- Una sola firma por nombre: PostgREST no resuelve sobrecargas.
  SELECT count(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('get_valor_por_proyecto','get_project_owner_breakdown',
                      'get_project_collection_totals','get_contratos_pendientes',
                      'run_reporte','get_reporte_filtro_opciones','validar_query_reporte');
  IF v_n <> 7 THEN
    RAISE EXCEPTION 'Se esperaban 7 funciones (una firma cada una), hay %', v_n;
  END IF;

  -- El motivo de todo el refactor: execute_safe_query NO se abre. El
  -- to_regprocedure evita que la aserción truene con undefined_function si el
  -- entorno no tiene esa función.
  IF to_regprocedure('public.execute_safe_query(text, integer)') IS NOT NULL
     AND (has_function_privilege('authenticated', 'public.execute_safe_query(text, integer)', 'EXECUTE')
          OR has_function_privilege('anon', 'public.execute_safe_query(text, integer)', 'EXECUTE')) THEN
    RAISE EXCEPTION 'execute_safe_query quedó abierta a anon/authenticated';
  END IF;

  -- Las RPC 1-3 dependen de que alguien tenga 'leer' en /admin/cuentas-cobranza.
  SELECT count(DISTINCT sp.rol_id) INTO v_n
  FROM submenus s
  JOIN submenus_permisos sp ON sp.submenu_id = s.id AND sp.activo = true
  JOIN permisos perm ON perm.id = sp.permiso_id
  WHERE s.vista_front_end = '/admin/cuentas-cobranza'
    AND s.activo = true
    AND perm.nombre = 'leer';
  -- WARNING por lo mismo que la pre-condición: los catálogos de dev y prod
  -- difieren (en prod son 10 roles) y quedarse solo con puede_impersonar no
  -- justifica tumbar el deploy.
  IF v_n = 0 THEN
    RAISE WARNING 'Ningún rol tiene leer en /admin/cuentas-cobranza en este entorno: las RPC 1-3 solo responderán a puede_impersonar';
  ELSIF v_n < 10 THEN
    RAISE NOTICE 'Roles con leer en /admin/cuentas-cobranza: % (en prod son 10)', v_n;
  END IF;

  -- RPC 7 exige rol_id = 1: si el rol no existe, la función nace muerta.
  IF NOT EXISTS (SELECT 1 FROM roles WHERE id = 1) THEN
    RAISE EXCEPTION 'No existe el rol 1 (Super Administrador): validar_query_reporte nacería muerta';
  END IF;
END
$$;
