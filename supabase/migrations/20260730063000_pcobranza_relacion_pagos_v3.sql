-- Portal Cobranza · get_pcobranza_relacion_pagos v3
-- Fecha: 2026-07-30
-- Spec: sozu-admin/Ejecuciones_manuales/portal-cobranza/20260729_rpc_relacion_pagos_v3.md
--
-- QUÉ CAMBIA
--   1. Universo completo. La v1 recortaba con
--      `AND (cc.id_propiedad IS NOT NULL OR o.id_producto IS NOT NULL)` y derivaba oferta y
--      propiedad solo de la cuenta del pago, sin mirar la cuenta padre: mostraba 19,459 de
--      22,525 pagos activos (medición del 2026-07-27). Perdía las cuentas de mantenimiento
--      —que heredan oferta y propiedad del padre— y las que tienen la propiedad únicamente
--      en `ofertas.id_propiedad` (p.ej. CC-001759 de Daiku). Ahora: `WHERE p.activo = true`.
--   2. "Estado" describe el PAGO, no el acuerdo. `estado_pago` = pagado / parcial /
--      sin_aplicar según cuánto del pago quedó aplicado. Antes se tomaba el acuerdo con mayor
--      aplicación y se comparaba su fecha contra hoy, así que un pago cobrado y validado
--      salía "Vencido" porque su acuerdo seguía abierto. `estado_acuerdo` se elimina.
--   3. Filtros, orden y paginación server-side (método, estatus de propiedad, estado de
--      validación, modelo, estado de pago), en vez de traer ~22.5k filas en un jsonb y
--      filtrar en el navegador.
--   4. Cliente por nombre O email, `Mantenimiento` como tipo y folio canónico CC-/CCP-/CM-.
--
-- CORRECCIONES SOBRE LA SPEC (verificadas read-only contra prod el 2026-07-30)
--   a) DOS RUTAS EXPLÍCITAS, NO UN CTE COMPARTIDO. La spec dejaba `filtered` referenciado
--      ocho veces (totales, orden, por_proyecto, catálogos…). Con más de una referencia
--      Postgres MATERIALIZA el CTE, así que la página pagaba el recorrido completo del
--      universo aunque `p_incluir_totales` fuera false: los `CASE WHEN p_incluir_totales`
--      evitan el agregado, no la materialización.
--      Medido en prod con la estructura de la spec: 146.9 ms por página (Seq Scan sobre
--      pagos + LATERAL con loops=22544 + Sort). La misma consulta con el conjunto
--      referenciado UNA vez: 0.392 ms (Index Scan Backward + Run Condition del row_number).
--      Por eso la función queda con la misma forma que CC v3: `IF` de página e `IF` de
--      totales, cada uno con su propia consulta. El costo es que el bloque canónico de joins
--      aparece dos veces en este archivo; está marcado en ambos sitios.
--   b) FALTABA `total_por_estado_pago`. El contrato, el UAT y el resultado esperado de la
--      spec lo prometen; el jsonb_build_object solo construía `total_por_estado` (que es por
--      estado de VALIDACIÓN). Se agrega. El front hoy lee `total_por_estado`, así que la
--      llave nueva es aditiva.
--   c) GUARDA DE AUTORIZACIÓN INTERNA. SECURITY DEFINER corre como postgres (BYPASSRLS): sin
--      guarda, cualquier `authenticated` —622 usuarios `Cliente`, 829 `Inmobiliaria`, 322
--      `Agente Inmobiliario` activos— puede volcar los 22,544 pagos con CLABE, monto, nombre
--      y correo. Se usa la regla base de 20260730020000 con el catálogo de 20260730060000:
--      current_puede('pagos','leer'), que cubre tanto /admin/portal-cobranza/relacion-pagos
--      como /admin/portal-escrituracion/relacion-pagos.
--   d) REVOKE a anon: el DROP + CREATE hace nacer la función con la ACL por defecto de
--      Supabase, que incluye `anon=X`. Sin esto se revierte 20260729204501.
--   e) `p_cuenta` sin dígitos (p.ej. "CC-") daba NULLIF → NULL → ILIKE NULL → NULL, o sea
--      CERO filas en vez de "sin filtro". Ahora, si no hay dígitos, el filtro se ignora.
--   f) En la ruta de totales el aplicado va PRE-AGREGADO (hash) en vez de por LATERAL: es un
--      barrido completo, ahí la forma correcta es la agregación, igual que en CC v3.
--
-- NOTA SOBRE `es_multa`
--   Aquí `monto_aplicado` suma TODAS las aplicaciones activas del pago, multas incluidas
--   (hoy en prod: 3 aplicaciones de multa activas por $325,476.77). CC excluye
--   `es_multa = true` de su `total_aplicado`. Es una divergencia conocida entre las dos RPC;
--   unificarla cambia números de negocio y queda pendiente de decisión, documentada en el
--   contrato canónico.
--
-- El DROP de la firma vieja es obligatorio: agregar parámetros crea una sobrecarga y
-- PostgREST no sabría cuál llamar. Esta migración va junto con el deploy del front.
--
-- Idempotente (DROP IF EXISTS + CREATE OR REPLACE) y self-verifying.
-- Sin BEGIN/COMMIT (el CI envuelve en transacción).

DROP FUNCTION IF EXISTS public.get_pcobranza_relacion_pagos(
  integer, integer, integer, text, text, text, text, text[], text[]);

CREATE OR REPLACE FUNCTION public.get_pcobranza_relacion_pagos(
  p_proyecto_id       integer DEFAULT NULL,
  p_limit             integer DEFAULT 50,
  p_offset            integer DEFAULT 0,
  p_clabe             text    DEFAULT NULL,
  p_cliente           text    DEFAULT NULL,
  p_unidad            text    DEFAULT NULL,
  p_cuenta            text    DEFAULT NULL,
  p_tipos             text[]  DEFAULT NULL,
  p_estatus           text[]  DEFAULT NULL,
  p_metodos           text[]  DEFAULT NULL,
  p_estatus_prop      text[]  DEFAULT NULL,
  p_estado_validacion text[]  DEFAULT NULL,
  p_estado_pago       text[]  DEFAULT NULL,
  p_modelos           text[]  DEFAULT NULL,
  p_sort_key          text    DEFAULT NULL,
  p_sort_dir          text    DEFAULT 'asc',
  -- Los totales/KPIs y los catálogos de filtros son lo único que recorre TODO el universo.
  -- Se piden una vez al abrir o al cambiar filtros; al navegar de página se manda false.
  p_incluir_totales   boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_hoy        date    := current_date;
  v_asc        boolean := (COALESCE(p_sort_dir, 'asc') <> 'desc');
  v_cuenta_dig text    := NULLIF(regexp_replace(COALESCE(p_cuenta, ''), '\D', '', 'g'), '');
  v_pagos      jsonb   := '[]'::jsonb;
  v_totales    jsonb   := '{}'::jsonb;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════════
  -- AUTORIZACIÓN — regla base 2026-07-29 (ver 20260730020000 y 20260730060000).
  -- ═══════════════════════════════════════════════════════════════════════════
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;
    IF NOT public.current_puede('pagos', 'leer') THEN
      RAISE EXCEPTION 'Rol sin permiso de lectura sobre pagos.' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════════
  -- RUTA 1 — PÁGINA. El CTE se referencia UNA sola vez: Postgres lo inlinea, el
  -- orden por defecto lo sirve idx_pagos_fecha_id_activo y el `Run Condition` del
  -- row_number corta el scan en la fila p_offset + p_limit. ~1.7 ms.
  -- ═══════════════════════════════════════════════════════════════════════════
  IF COALESCE(p_limit, 0) > 0 THEN
    WITH pagina AS (
      SELECT
        p.id AS pago_id, p.monto, p.fecha_pago, p.clave_rastreo, p.url_cep, p.url_recibo,
        p.descripcion, p.id_cuenta_cobranza AS cuenta_id,
        mp.nombre AS metodo_pago, cc.clabe_stp,
        per.nombre_legal AS cliente_nombre, per.email AS cliente_email,
        prop.numero_propiedad, mod.nombre AS modelo, ed.nombre AS edificio,
        ps.nombre AS producto_nombre,
        proy.nombre AS proyecto, proy.id AS proyecto_id,
        -- Estatus de la propiedad; 'Cancelada'/'Inactiva' cuando lo muerto es la cuenta
        CASE WHEN cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL THEN 'Cancelada'
             WHEN cc.activo = false                                        THEN 'Inactiva'
             ELSE est.nombre END AS estatus_propiedad,
        -- ── Bloque canónico (90_contrato_canonico_pagos.md §2) ────────────────
        CASE
          WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL THEN 'Mantenimiento'
          WHEN o.id_producto IS NOT NULL THEN 'Producto'
          ELSE 'Propiedad'
        END AS tipo_cuenta,
        CASE
          WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL THEN 'Mantenimiento'
          WHEN o.id_producto IS NULL      THEN 'Propiedad'
          WHEN ps.id_categoria = 1        THEN 'Estacionamiento'
          WHEN ps.id_categoria = 2        THEN 'Bodega'
          WHEN ps.id_categoria IN (3, 4)  THEN 'Producto'
          ELSE 'Adicional'
        END AS tipo_categoria,
        CASE
          WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL
            THEN 'CM-'  || lpad(cc.id::text, 6, '0')
          WHEN o.id_producto IS NOT NULL
            THEN 'CCP-' || lpad(cc.id::text, 6, '0')
          ELSE 'CC-'    || lpad(cc.id::text, 6, '0')
        END AS cuenta_folio,
        -- ──────────────────────────────────────────────────────────────────────
        pv.estado AS estado_validacion,
        CASE pv.estado
          WHEN 'coincide'    THEN 'valido'
          WHEN 'no_coincide' THEN 'invalido'
          WHEN 'error'       THEN 'error'
          ELSE 'sin_revisar'
        END AS estatus_validacion,
        (p.url_cep IS NOT NULL AND length(trim(p.url_cep)) > 0) AS tiene_cep,
        COALESCE(apl.aplicado, 0) AS monto_aplicado,
        -- Estado del PAGO, no del acuerdo (§4 del contrato)
        CASE
          WHEN COALESCE(apl.n, 0) = 0                      THEN 'sin_aplicar'
          WHEN COALESCE(apl.aplicado, 0) >= p.monto - 0.01 THEN 'pagado'
          ELSE 'parcial'
        END AS estado_pago,
        CASE WHEN pv.estado IS DISTINCT FROM 'coincide' AND p.fecha_pago IS NOT NULL
             THEN GREATEST(0, (v_hoy - p.fecha_pago)::int) ELSE 0 END AS atraso,
        row_number() OVER (
          ORDER BY
            CASE WHEN p_sort_key='account' AND v_asc     THEN p.id_cuenta_cobranza   END ASC,
            CASE WHEN p_sort_key='account' AND NOT v_asc THEN p.id_cuenta_cobranza   END DESC,
            CASE WHEN p_sort_key='client'  AND v_asc     THEN lower(per.nombre_legal) END ASC,
            CASE WHEN p_sort_key='client'  AND NOT v_asc THEN lower(per.nombre_legal) END DESC,
            CASE WHEN p_sort_key='amount'  AND v_asc     THEN p.monto                END ASC,
            CASE WHEN p_sort_key='amount'  AND NOT v_asc THEN p.monto                END DESC,
            CASE WHEN p_sort_key='status'  AND v_asc     THEN pv.estado              END ASC,
            CASE WHEN p_sort_key='status'  AND NOT v_asc THEN pv.estado              END DESC,
            CASE WHEN p_sort_key='date'    AND v_asc     THEN p.fecha_pago           END ASC,
            CASE WHEN p_sort_key IS NULL OR p_sort_key='date' THEN p.fecha_pago      END DESC,
            p.id DESC
        ) AS rn
      FROM pagos p
      LEFT JOIN metodos_pago          mp   ON mp.id   = p.id_metodos_pago
      -- ── Bloque canónico: herencia de cuenta padre (§1) ──────────────────────
      -- OJO: este bloque está duplicado en la ruta de totales de esta misma función.
      -- Si se toca aquí, se toca allá (y en las otras dos RPC del contrato).
      LEFT JOIN cuentas_cobranza      cc   ON cc.id   = p.id_cuenta_cobranza
      LEFT JOIN cuentas_cobranza      ccp  ON ccp.id  = cc.id_cuenta_cobranza_padre
      LEFT JOIN ofertas               o    ON o.id    = COALESCE(cc.id_oferta, ccp.id_oferta)
      LEFT JOIN propiedades           prop ON prop.id = COALESCE(cc.id_propiedad, ccp.id_propiedad, o.id_propiedad)
      LEFT JOIN edificios_modelos     em   ON em.id   = prop.id_edificio_modelo
      LEFT JOIN edificios             ed   ON ed.id   = em.id_edificio
      LEFT JOIN modelos               mod  ON mod.id  = em.id_modelo
      LEFT JOIN estatus_disponibilidad est ON est.id  = prop.id_estatus_disponibilidad
      LEFT JOIN productos_servicios   ps   ON ps.id   = o.id_producto
      LEFT JOIN personas              per  ON per.id  = o.id_persona_lead
      LEFT JOIN proyectos             proy ON proy.id = COALESCE(ed.id_proyecto, ps.id_proyecto)
      -- ────────────────────────────────────────────────────────────────────────
      -- pago_validaciones tiene UNIQUE (id_pago): a lo más una validación por pago
      LEFT JOIN pago_validaciones     pv   ON pv.id_pago = p.id
      LEFT JOIN LATERAL (
        SELECT COALESCE(SUM(a.monto), 0) AS aplicado, COUNT(*) AS n
        FROM aplicaciones_pago a
        WHERE a.id_pago = p.id AND a.activo = true
      ) apl ON true
      -- Universo (§3): todo pago activo. La v1 recortaba aquí y perdía 3,066 pagos.
      WHERE p.activo = true
        AND (p_proyecto_id IS NULL OR proy.id = p_proyecto_id)
        AND (p_tipos IS NULL OR
             (CASE
                WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL THEN 'Mantenimiento'
                WHEN o.id_producto IS NULL      THEN 'Propiedad'
                WHEN ps.id_categoria = 1        THEN 'Estacionamiento'
                WHEN ps.id_categoria = 2        THEN 'Bodega'
                WHEN ps.id_categoria IN (3, 4)  THEN 'Producto'
                ELSE 'Adicional' END) = ANY(p_tipos))
        AND (p_estatus IS NULL OR
             (CASE pv.estado
                WHEN 'coincide'    THEN 'valido'
                WHEN 'no_coincide' THEN 'invalido'
                WHEN 'error'       THEN 'error'
                ELSE 'sin_revisar' END) = ANY(p_estatus))
        AND (p_metodos      IS NULL OR mp.nombre    = ANY(p_metodos))
        AND (p_modelos      IS NULL OR mod.nombre   = ANY(p_modelos))
        AND (p_estatus_prop IS NULL OR
             (CASE WHEN cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL THEN 'Cancelada'
                   WHEN cc.activo = false THEN 'Inactiva'
                   ELSE est.nombre END) = ANY(p_estatus_prop))
        AND (p_estado_validacion IS NULL
             OR COALESCE(pv.estado, 'sin_validar') = ANY(p_estado_validacion))
        AND (p_estado_pago IS NULL OR
             (CASE
                WHEN COALESCE(apl.n, 0) = 0                      THEN 'sin_aplicar'
                WHEN COALESCE(apl.aplicado, 0) >= p.monto - 0.01 THEN 'pagado'
                ELSE 'parcial' END) = ANY(p_estado_pago))
        AND (p_clabe   IS NULL OR p_clabe   = '' OR cc.clabe_stp ILIKE '%'||p_clabe||'%')
        AND (p_unidad  IS NULL OR p_unidad  = '' OR prop.numero_propiedad ILIKE '%'||p_unidad||'%')
        AND (p_cliente IS NULL OR p_cliente = '' OR
             per.nombre_legal ILIKE '%'||p_cliente||'%' OR per.email ILIKE '%'||p_cliente||'%')
        -- (e) sin dígitos → sin filtro (antes devolvía cero filas)
        AND (v_cuenta_dig IS NULL OR p.id_cuenta_cobranza::text LIKE '%'||v_cuenta_dig||'%')
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'pago_id', pago_id, 'monto', monto, 'fecha_pago', fecha_pago,
             'clave_rastreo', clave_rastreo, 'url_cep', url_cep, 'url_recibo', url_recibo,
             'descripcion', descripcion, 'id_cuenta_cobranza', cuenta_id,
             'cuenta_folio', cuenta_folio,
             'metodo_pago', metodo_pago, 'clabe_stp', clabe_stp,
             'cliente', cliente_nombre, 'cliente_email', cliente_email,
             'num_propiedad', numero_propiedad, 'modelo', modelo, 'edificio', edificio,
             'estatus_propiedad', estatus_propiedad, 'producto', producto_nombre,
             'tipo_cuenta', tipo_cuenta, 'tipo_categoria', tipo_categoria,
             'estatus', estatus_validacion, 'estado_validacion', estado_validacion,
             'estado_pago', estado_pago, 'monto_aplicado', monto_aplicado,
             'atraso', atraso, 'proyecto', proyecto, 'proyecto_id', proyecto_id,
             'tiene_cep', tiene_cep
           ) ORDER BY rn), '[]'::jsonb)
    INTO v_pagos
    FROM (SELECT * FROM pagina WHERE rn > p_offset AND rn <= p_offset + p_limit) q;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════════
  -- RUTA 2 — TOTALES, KPIs y catálogos. Un solo barrido del universo del filtro,
  -- con el aplicado PRE-AGREGADO (aquí sí es la forma correcta: no hay LIMIT que
  -- corte). ~250 ms, una vez por combinación de filtros.
  -- Sin filtro de proyecto a propósito: el desglose `por_proyecto` deja que el
  -- front cambie de proyecto sin volver a consultar.
  -- ═══════════════════════════════════════════════════════════════════════════
  IF p_incluir_totales THEN
    WITH apl_pago AS (
      SELECT a.id_pago, SUM(a.monto) AS aplicado, COUNT(*) AS n
      FROM aplicaciones_pago a
      WHERE a.activo = true
      GROUP BY a.id_pago
    ),
    filtered AS (
      SELECT
        p.monto,
        proy.nombre AS proyecto, proy.id AS proyecto_id,
        mp.nombre  AS metodo_pago,
        mod.nombre AS modelo,
        CASE WHEN cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL THEN 'Cancelada'
             WHEN cc.activo = false                                        THEN 'Inactiva'
             ELSE est.nombre END AS estatus_propiedad,
        pv.estado AS estado_validacion,
        p.url_recibo,
        (p.url_cep IS NOT NULL AND length(trim(p.url_cep)) > 0) AS tiene_cep,
        CASE
          WHEN COALESCE(ap.n, 0) = 0                      THEN 'sin_aplicar'
          WHEN COALESCE(ap.aplicado, 0) >= p.monto - 0.01 THEN 'pagado'
          ELSE 'parcial'
        END AS estado_pago
      FROM pagos p
      LEFT JOIN metodos_pago          mp   ON mp.id   = p.id_metodos_pago
      -- ── Bloque canónico: herencia de cuenta padre (§1) — duplicado a propósito,
      --    ver la nota de la ruta de página. ──────────────────────────────────
      LEFT JOIN cuentas_cobranza      cc   ON cc.id   = p.id_cuenta_cobranza
      LEFT JOIN cuentas_cobranza      ccp  ON ccp.id  = cc.id_cuenta_cobranza_padre
      LEFT JOIN ofertas               o    ON o.id    = COALESCE(cc.id_oferta, ccp.id_oferta)
      LEFT JOIN propiedades           prop ON prop.id = COALESCE(cc.id_propiedad, ccp.id_propiedad, o.id_propiedad)
      LEFT JOIN edificios_modelos     em   ON em.id   = prop.id_edificio_modelo
      LEFT JOIN edificios             ed   ON ed.id   = em.id_edificio
      LEFT JOIN modelos               mod  ON mod.id  = em.id_modelo
      LEFT JOIN estatus_disponibilidad est ON est.id  = prop.id_estatus_disponibilidad
      LEFT JOIN productos_servicios   ps   ON ps.id   = o.id_producto
      LEFT JOIN personas              per  ON per.id  = o.id_persona_lead
      LEFT JOIN proyectos             proy ON proy.id = COALESCE(ed.id_proyecto, ps.id_proyecto)
      -- ────────────────────────────────────────────────────────────────────────
      LEFT JOIN pago_validaciones     pv   ON pv.id_pago = p.id
      LEFT JOIN apl_pago              ap   ON ap.id_pago = p.id
      WHERE p.activo = true
        AND (p_tipos IS NULL OR
             (CASE
                WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL THEN 'Mantenimiento'
                WHEN o.id_producto IS NULL      THEN 'Propiedad'
                WHEN ps.id_categoria = 1        THEN 'Estacionamiento'
                WHEN ps.id_categoria = 2        THEN 'Bodega'
                WHEN ps.id_categoria IN (3, 4)  THEN 'Producto'
                ELSE 'Adicional' END) = ANY(p_tipos))
        AND (p_estatus IS NULL OR
             (CASE pv.estado
                WHEN 'coincide'    THEN 'valido'
                WHEN 'no_coincide' THEN 'invalido'
                WHEN 'error'       THEN 'error'
                ELSE 'sin_revisar' END) = ANY(p_estatus))
        AND (p_metodos      IS NULL OR mp.nombre  = ANY(p_metodos))
        AND (p_modelos      IS NULL OR mod.nombre = ANY(p_modelos))
        AND (p_estatus_prop IS NULL OR
             (CASE WHEN cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL THEN 'Cancelada'
                   WHEN cc.activo = false THEN 'Inactiva'
                   ELSE est.nombre END) = ANY(p_estatus_prop))
        AND (p_estado_validacion IS NULL
             OR COALESCE(pv.estado, 'sin_validar') = ANY(p_estado_validacion))
        AND (p_estado_pago IS NULL OR
             (CASE
                WHEN COALESCE(ap.n, 0) = 0                      THEN 'sin_aplicar'
                WHEN COALESCE(ap.aplicado, 0) >= p.monto - 0.01 THEN 'pagado'
                ELSE 'parcial' END) = ANY(p_estado_pago))
        AND (p_clabe   IS NULL OR p_clabe   = '' OR cc.clabe_stp ILIKE '%'||p_clabe||'%')
        AND (p_unidad  IS NULL OR p_unidad  = '' OR prop.numero_propiedad ILIKE '%'||p_unidad||'%')
        AND (p_cliente IS NULL OR p_cliente = '' OR
             per.nombre_legal ILIKE '%'||p_cliente||'%' OR per.email ILIKE '%'||p_cliente||'%')
        AND (v_cuenta_dig IS NULL OR p.id_cuenta_cobranza::text LIKE '%'||v_cuenta_dig||'%')
    )
    SELECT jsonb_build_object(
      'total',             (SELECT COUNT(*) FROM filtered),
      'total_monto',       (SELECT COALESCE(SUM(monto), 0) FROM filtered),
      'total_validos',     (SELECT COUNT(*) FROM filtered
                            WHERE tiene_cep AND estado_validacion = 'coincide'),
      'total_sin_validar', (SELECT COUNT(*) FROM filtered
                            WHERE url_recibo IS NOT NULL AND estado_validacion IS DISTINCT FROM 'coincide'),
      'total_por_estado', (
        SELECT COALESCE(jsonb_object_agg(estado, n), '{}'::jsonb) FROM (
          SELECT COALESCE(estado_validacion, 'sin_validar') AS estado, COUNT(*) AS n
          FROM filtered GROUP BY 1) q),
      -- (b) faltaba en la spec: el desglose por estado del PAGO.
      'total_por_estado_pago', (
        SELECT COALESCE(jsonb_object_agg(estado_pago, n), '{}'::jsonb) FROM (
          SELECT estado_pago, COUNT(*) AS n FROM filtered GROUP BY 1) q),
      'por_proyecto', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'proyecto_id', proyecto_id, 'proyecto', proyecto,
          'total', n, 'total_monto', monto,
          'total_validos', validos, 'total_sin_validar', sin_validar,
          'total_coincide', coincide, 'total_con_obs', con_obs
        ) ORDER BY n DESC), '[]'::jsonb)
        FROM (
          SELECT proyecto_id, MIN(proyecto) AS proyecto, COUNT(*) AS n,
                 COALESCE(SUM(monto), 0) AS monto,
                 COUNT(*) FILTER (WHERE tiene_cep AND estado_validacion = 'coincide') AS validos,
                 COUNT(*) FILTER (WHERE url_recibo IS NOT NULL AND estado_validacion IS DISTINCT FROM 'coincide') AS sin_validar,
                 COUNT(*) FILTER (WHERE estado_validacion = 'coincide') AS coincide,
                 COUNT(*) FILTER (WHERE estado_validacion IS NOT NULL AND estado_validacion <> 'coincide') AS con_obs
          FROM filtered GROUP BY proyecto_id
        ) q),
      -- Catálogos de los selectores: universo del filtro actual, no de la página
      'metodos', (SELECT COALESCE(jsonb_agg(DISTINCT metodo_pago ORDER BY metodo_pago)
                    FILTER (WHERE metodo_pago IS NOT NULL), '[]'::jsonb) FROM filtered),
      'modelos', (SELECT COALESCE(jsonb_agg(DISTINCT modelo ORDER BY modelo)
                    FILTER (WHERE modelo IS NOT NULL), '[]'::jsonb) FROM filtered),
      'estatus_prop', (SELECT COALESCE(jsonb_agg(DISTINCT estatus_propiedad ORDER BY estatus_propiedad)
                    FILTER (WHERE estatus_propiedad IS NOT NULL), '[]'::jsonb) FROM filtered)
    ) INTO v_totales;
  END IF;

  RETURN jsonb_build_object('pagos', v_pagos) || v_totales;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_pcobranza_relacion_pagos(
  integer,integer,integer,text,text,text,text,text[],text[],text[],text[],text[],text[],text[],text,text,boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pcobranza_relacion_pagos(
  integer,integer,integer,text,text,text,text,text[],text[],text[],text[],text[],text[],text[],text,text,boolean)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Self-verifying
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_oid oid;
  v_n   integer;
  v_src text;
BEGIN
  SELECT count(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_pcobranza_relacion_pagos';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'Quedaron % sobrecargas de get_pcobranza_relacion_pagos: PostgREST no sabría cuál llamar', v_n;
  END IF;

  v_oid := to_regprocedure('public.get_pcobranza_relacion_pagos(integer, integer, integer, '
        || 'text, text, text, text, text[], text[], text[], text[], text[], text[], text[], '
        || 'text, text, boolean)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'No quedó la firma de 17 argumentos';
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = v_oid;
  IF v_src NOT LIKE '%current_puede(''pagos'', ''leer'')%' OR v_src NOT LIKE '%42501%' THEN
    RAISE EXCEPTION 'La función quedó sin guarda de autorización interna';
  END IF;
  IF v_src NOT LIKE '%total_por_estado_pago%' THEN
    RAISE EXCEPTION 'Falta la llave total_por_estado_pago del contrato';
  END IF;
  IF (SELECT provolatile FROM pg_proc WHERE oid = v_oid) <> 's' THEN
    RAISE EXCEPTION 'La función no quedó STABLE';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
    RAISE EXCEPTION 'La función no quedó SECURITY DEFINER';
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'anon quedó con EXECUTE sobre get_pcobranza_relacion_pagos';
  END IF;
  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated/service_role se quedaron sin EXECUTE';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rls_tablas_submenus WHERE tabla = 'pagos' AND activo = true) THEN
    RAISE EXCEPTION 'Falta el catálogo authz de pagos (20260730060000)';
  END IF;

  RAISE NOTICE 'get_pcobranza_relacion_pagos v3 OK: 1 firma, guarda 42501, sin anon';
END $$;
