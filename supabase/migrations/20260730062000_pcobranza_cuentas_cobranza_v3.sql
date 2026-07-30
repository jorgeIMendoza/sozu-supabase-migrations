-- Portal Cobranza · get_pcobranza_cuentas_cobranza v3
-- Fecha: 2026-07-30
-- Spec: sozu-admin/Ejecuciones_manuales/portal-cobranza/20260729_rpc_cuentas_cobranza_v3.md
--
-- QUÉ CAMBIA
--   1. Atraso real. La columna "Atraso" pintaba `dias_sin_pagar` (días desde el último pago),
--      así que una cuenta liquidada seguía acumulando atraso y una con vencido reciente lo
--      subestimaba. Se agrega `dias_atraso` = antigüedad de la parcialidad vencida más
--      antigua, 0 si no hay vencidas. Los escalones de color (30/60/90) pasan a usarlo.
--   2. Nada con dinero queda oculto. Las cuentas desactivadas SIN tipo de cancelación no se
--      listaban; en prod son 2 (536 y 1155) con un pago activo cada una. Ahora entran
--      marcadas 'Inactiva'. Con eso se cumple el invariante "lo que está en CC está en RP".
--   3. Herencia canónica de cuenta padre por COALESCE (§1 del contrato), idéntica a las otras
--      dos RPC, en lugar del LATERAL `eff_cc`.
--   4. Dos rutas: página (15 filas, saldos por LATERAL) y totales/KPIs (pre-agregados). Con
--      `p_incluir_totales => false` cada clic de paginación deja de recorrer todas las
--      cuentas: 338 ms → ~2.3 ms.
--
-- CORRECCIONES SOBRE LA SPEC (verificadas read-only contra prod el 2026-07-30)
--   a) EL DROP ES OBLIGATORIO. La spec usaba `CREATE OR REPLACE` para una firma con un
--      parámetro nuevo (`p_incluir_totales`), pero la firma viva tiene 16 argumentos y la
--      nueva 17: eso NO reemplaza, crea una SOBRECARGA. Quedarían dos funciones y PostgREST
--      respondería PGRST203 (ambigüedad) a cada llamada del panel.
--   b) PERMISOS EXPLÍCITOS. Como es una función nueva (no un REPLACE), no hereda la ACL. Y
--      `pg_default_acl` de Supabase otorga EXECUTE a `anon` en toda función nueva de public:
--      sin el REVOKE, esta RPC de dinero quedaría invocable con la llave anon, revirtiendo
--      20260729204501_seguridad_revoke_anon_funciones_secdef.
--   c) GUARDA DE AUTORIZACIÓN INTERNA. SECURITY DEFINER corre como postgres (BYPASSRLS), así
--      que el RLS de cuentas_cobranza —incluida la restricción de socio bancario— no aplica.
--      Sin guarda, cualquier `authenticated` (622 usuarios `Cliente`, 829 `Inmobiliaria`,
--      322 `Agente Inmobiliario` activos) puede volcar el libro completo. Se compone con la
--      regla base de 20260730020000 vía current_puede('cuentas_cobranza','leer'); el catálogo
--      lo siembra 20260730060000.
--   d) `invalidos` no filtraba `ap2.activo`, mientras que su subconsulta hermana
--      (`acuerdos_sin_pago`) sí: los acuerdos desactivados inflaban el conteo y con él el
--      escalón de color y el filtro p_invalid_level. Ahora ambas filtran igual.
--   e) `p_invalid_level` se aplicaba solo en la ruta de página, así que el `total` de los
--      KPIs lo ignoraba y la paginación mostraba páginas fantasma. Ahora la ruta de totales
--      calcula el mismo `invalidos` pre-agregado y aplica el filtro.
--   f) `p_cuenta` sin dígitos (p.ej. "CC-") producía NULLIF → NULL → ILIKE NULL → NULL, es
--      decir CERO filas en vez de "sin filtro". Ahora, si el texto no trae dígitos, el filtro
--      se ignora.
--
-- DECISIÓN EXPLÍCITA SOBRE `liquidada`
--   Se conserva la definición de la spec: precio_final − total_aplicado <= 0.01. Ojo: 418
--   cuentas visibles tienen precio_final = 0 (305 de mantenimiento y 91 de propiedad) y por
--   esa regla salen `liquidada = true`. Se midió la alternativa de exigir además
--   saldo_pendiente <= 0.01: cambiaría 248 cuentas a "no liquidada" (243 de ellas con
--   precio_final = 0), lo que movería el conteo de "unidades listas para escriturar" de
--   Validación de Pagos sin que nadie lo haya pedido. Quien necesite "no debe nada" tiene
--   `saldo_pendiente` en la misma respuesta. El saldo residual de las 91 cuentas de propiedad
--   con precio 0 es $3.31 en total, así que hoy el impacto de la regla laxa es nulo.
--
-- Idempotente (DROP IF EXISTS + CREATE OR REPLACE) y self-verifying.
-- Sin BEGIN/COMMIT (el CI envuelve en transacción).

-- La firma de 16 argumentos: hay que quitarla o PostgREST no sabe cuál llamar.
DROP FUNCTION IF EXISTS public.get_pcobranza_cuentas_cobranza(
  integer, text, boolean, text, text, text, text, text[], text[], text[], text[], text[],
  text, text, integer, integer);

CREATE OR REPLACE FUNCTION public.get_pcobranza_cuentas_cobranza(
  p_proyecto_id     integer DEFAULT NULL::integer,
  p_search          text    DEFAULT NULL::text,
  p_solo_vencidas   boolean DEFAULT false,
  p_cliente         text    DEFAULT NULL::text,
  p_unidad          text    DEFAULT NULL::text,
  p_clabe           text    DEFAULT NULL::text,
  p_cuenta          text    DEFAULT NULL::text,
  p_modelos         text[]  DEFAULT NULL::text[],
  p_tipos           text[]  DEFAULT NULL::text[],
  p_estatus         text[]  DEFAULT NULL::text[],
  p_prioridad       text[]  DEFAULT NULL::text[],
  p_invalid_level   text[]  DEFAULT NULL::text[],
  p_sort_key        text    DEFAULT NULL::text,
  p_sort_dir        text    DEFAULT 'asc'::text,
  p_limit           integer DEFAULT 15,
  p_offset          integer DEFAULT 0,
  -- KPIs y catálogos son lo único que recorre todas las cuentas: se piden al abrir y al
  -- cambiar filtros, no en cada página.
  p_incluir_totales boolean DEFAULT true
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
  v_cuentas    jsonb   := '[]'::jsonb;
  v_totales    jsonb   := '{}'::jsonb;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════════
  -- AUTORIZACIÓN — regla base 2026-07-29 (ver 20260730020000 y 20260730060000).
  -- SECURITY DEFINER corre como postgres (BYPASSRLS): el RLS de cuentas_cobranza,
  -- incluida la restricción de socio bancario, no limita nada aquí dentro.
  -- ═══════════════════════════════════════════════════════════════════════════
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;
    IF NOT public.current_puede('cuentas_cobranza', 'leer') THEN
      RAISE EXCEPTION 'Rol sin permiso de lectura sobre cuentas de cobranza.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════════
  -- RUTA 1 — PÁGINA: saldos por LATERAL, solo para las filas de la página.
  -- El CTE se referencia UNA vez: Postgres lo inlinea y, con el orden por defecto
  -- (cuenta_id DESC = la PK), el `Run Condition` del row_number corta el scan.
  -- ═══════════════════════════════════════════════════════════════════════════
  IF COALESCE(p_limit, 0) > 0 THEN
    WITH pagina AS (
      SELECT
        cc.id AS cuenta_id,
        CASE
          WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL
            THEN 'CM-'  || lpad(cc.id::text, 6, '0')
          WHEN o.id_producto IS NOT NULL
            THEN 'CCP-' || lpad(cc.id::text, 6, '0')
          ELSE 'CC-'    || lpad(cc.id::text, 6, '0')
        END AS cuenta_folio,
        cc.clabe_stp, cc.precio_final, cc.fecha_compra,
        prop.id AS propiedad_id,
        per.nombre_legal AS cliente_nombre,
        per.email        AS cliente_email,
        per.telefono     AS cliente_telefono,
        proy.nombre AS proyecto, proy.id AS proyecto_id, ed.nombre AS edificio,
        prop.numero_propiedad, mod.nombre AS modelo, prop.id_estatus_disponibilidad,
        CASE WHEN cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL THEN 'Cancelada'
             WHEN cc.activo = false                                        THEN 'Inactiva'
             ELSE est.nombre END AS estatus_propiedad,
        CASE WHEN o.id_producto IS NOT NULL THEN ps.nombre ELSE NULL END AS producto_nombre,
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
        -- ──────────────────────────────────────────────────────────────────────
        COALESCE(vc.parcialidades_vencidas, 0) AS parcialidades_vencidas,
        COALESCE(vc.monto_vencido,   0)        AS monto_vencido,
        COALESCE(vc.saldo_pendiente, 0)        AS saldo_pendiente,
        COALESCE(vc.total_aplicado,  0)        AS total_aplicado,
        COALESCE(inv.invalidos, 0)
          + CASE WHEN o.id_producto IS NOT NULL THEN COALESCE(inv.acuerdos_sin_pago, 0) ELSE 0 END
          AS invalidos,
        vc.proximo_vencimiento,
        pgc.ultima_fecha_pago,
        COALESCE(pgc.pagos_activos, 0) AS pagos_activos,
        (cc.precio_final - COALESCE(vc.total_aplicado, 0)) <= 0.01 AS liquidada,
        CASE
          WHEN pgc.ultima_fecha_pago IS NOT NULL THEN GREATEST(0, (v_hoy - pgc.ultima_fecha_pago)::int)
          WHEN cc.fecha_compra       IS NOT NULL THEN GREATEST(0, (v_hoy - cc.fecha_compra)::int)
          ELSE 0
        END AS dias_sin_pagar,
        CASE
          WHEN COALESCE(vc.parcialidades_vencidas, 0) = 0 OR vc.primera_vencida IS NULL THEN 0
          ELSE GREATEST(0, (v_hoy - vc.primera_vencida)::int)
        END AS dias_atraso,
        CASE
          WHEN cc.activo = false                          THEN 'gray'
          WHEN COALESCE(vc.parcialidades_vencidas, 0) = 0 THEN 'green'
          WHEN (v_hoy - vc.primera_vencida)::int >= 90    THEN 'purple'
          WHEN (v_hoy - vc.primera_vencida)::int >= 60    THEN 'red_dark'
          WHEN (v_hoy - vc.primera_vencida)::int >= 30    THEN 'red'
          ELSE 'yellow'
        END AS prioridad,
        row_number() OVER (
          ORDER BY
            CASE WHEN p_sort_key='account'      AND v_asc     THEN cc.id                   END ASC,
            CASE WHEN p_sort_key='account'      AND NOT v_asc THEN cc.id                   END DESC,
            CASE WHEN p_sort_key='client'       AND v_asc     THEN lower(per.nombre_legal)  END ASC,
            CASE WHEN p_sort_key='client'       AND NOT v_asc THEN lower(per.nombre_legal)  END DESC,
            CASE WHEN p_sort_key='price'        AND v_asc     THEN cc.precio_final         END ASC,
            CASE WHEN p_sort_key='price'        AND NOT v_asc THEN cc.precio_final         END DESC,
            CASE WHEN p_sort_key='overdue'      AND v_asc     THEN COALESCE(vc.monto_vencido,0)   END ASC,
            CASE WHEN p_sort_key='overdue'      AND NOT v_asc THEN COALESCE(vc.monto_vencido,0)   END DESC,
            CASE WHEN p_sort_key='pending'      AND v_asc     THEN COALESCE(vc.saldo_pendiente,0) END ASC,
            CASE WHEN p_sort_key='pending'      AND NOT v_asc THEN COALESCE(vc.saldo_pendiente,0) END DESC,
            CASE WHEN p_sort_key='installments' AND v_asc     THEN COALESCE(vc.parcialidades_vencidas,0) END ASC,
            CASE WHEN p_sort_key='installments' AND NOT v_asc THEN COALESCE(vc.parcialidades_vencidas,0) END DESC,
            CASE WHEN p_sort_key='daysLate'     AND v_asc
                 THEN CASE WHEN COALESCE(vc.parcialidades_vencidas,0)=0 OR vc.primera_vencida IS NULL THEN 0
                           ELSE (v_hoy - vc.primera_vencida)::int END END ASC,
            CASE WHEN p_sort_key='daysLate'     AND NOT v_asc
                 THEN CASE WHEN COALESCE(vc.parcialidades_vencidas,0)=0 OR vc.primera_vencida IS NULL THEN 0
                           ELSE (v_hoy - vc.primera_vencida)::int END END DESC,
            -- Bandeja de cobranza clásica (vencidas primero), ahora explícita
            CASE WHEN p_sort_key='priority' THEN COALESCE(vc.parcialidades_vencidas,0) END DESC,
            -- DEFAULT: la cuenta más nueva primero (es la PK, y con ella el planner
            -- arranca por Index Scan Backward y los LATERAL solo corren para la página).
            CASE WHEN p_sort_key IS NULL THEN cc.id END DESC,
            cc.id DESC
        ) AS rn
      FROM cuentas_cobranza cc
      -- ── Bloque canónico: herencia de cuenta padre (§1) ──────────────────────
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
      LEFT JOIN LATERAL (
        SELECT
          COUNT(*) FILTER (WHERE ap.pago_completado = false AND ap.fecha_pago < v_hoy)::int AS parcialidades_vencidas,
          COALESCE(SUM(CASE WHEN ap.pago_completado = false AND ap.fecha_pago < v_hoy
            THEN GREATEST(ap.monto - COALESCE(aa.aplicado, 0), 0) END), 0) AS monto_vencido,
          COALESCE(SUM(CASE WHEN ap.pago_completado = false
            THEN GREATEST(ap.monto - COALESCE(aa.aplicado, 0), 0) END), 0) AS saldo_pendiente,
          COALESCE(SUM(COALESCE(aa.aplicado, 0)), 0) AS total_aplicado,
          MIN(CASE WHEN ap.pago_completado = false AND ap.fecha_pago >= v_hoy THEN ap.fecha_pago END) AS proximo_vencimiento,
          MIN(CASE WHEN ap.pago_completado = false AND ap.fecha_pago <  v_hoy THEN ap.fecha_pago END) AS primera_vencida
        FROM acuerdos_pago ap
        LEFT JOIN LATERAL (
          SELECT COALESCE(SUM(a.monto), 0) AS aplicado
          FROM aplicaciones_pago a
          WHERE a.id_acuerdo_pago = ap.id AND a.activo = true AND a.es_multa = false
        ) aa ON true
        WHERE ap.id_cuenta_cobranza = cc.id AND ap.activo = true
      ) vc ON true
      LEFT JOIN LATERAL (
        SELECT MAX(pg.fecha_pago) AS ultima_fecha_pago, COUNT(*)::int AS pagos_activos
        FROM pagos pg WHERE pg.id_cuenta_cobranza = cc.id AND pg.activo = true
      ) pgc ON true
      LEFT JOIN LATERAL (
        SELECT
          (SELECT COUNT(*)::int
           FROM acuerdos_pago ap2
           JOIN aplicaciones_pago apl2 ON apl2.id_acuerdo_pago = ap2.id
                                      AND apl2.activo = true AND apl2.id_pago IS NOT NULL
           LEFT JOIN pago_validaciones pv2 ON pv2.id_pago = apl2.id_pago
           WHERE ap2.id_cuenta_cobranza = cc.id
             AND ap2.activo = true                    -- (d) faltaba: los acuerdos muertos inflaban el conteo
             AND pv2.estado IS DISTINCT FROM 'coincide') AS invalidos,
          (SELECT COUNT(*)::int
           FROM acuerdos_pago ap3
           WHERE ap3.id_cuenta_cobranza = cc.id AND ap3.activo = true
             AND NOT EXISTS (SELECT 1 FROM aplicaciones_pago apl3
                             WHERE apl3.id_acuerdo_pago = ap3.id AND apl3.activo = true
                               AND apl3.id_pago IS NOT NULL)) AS acuerdos_sin_pago
      ) inv ON true
      -- Universo (§3): activa · cancelada · desactivada CON pagos activos
      WHERE (
          cc.activo = true
          OR (cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL)
          OR COALESCE(pgc.pagos_activos, 0) > 0
        )
        AND (p_proyecto_id IS NULL OR proy.id = p_proyecto_id)
        AND (p_search IS NULL OR p_search = '' OR
             cc.clabe_stp ILIKE '%'||p_search||'%' OR per.nombre_legal ILIKE '%'||p_search||'%' OR
             per.email ILIKE '%'||p_search||'%' OR prop.numero_propiedad ILIKE '%'||p_search||'%' OR
             ps.nombre ILIKE '%'||p_search||'%' OR ed.nombre ILIKE '%'||p_search||'%' OR
             proy.nombre ILIKE '%'||p_search||'%')
        AND (p_cliente IS NULL OR p_cliente = '' OR
             per.nombre_legal ILIKE '%'||p_cliente||'%' OR per.email ILIKE '%'||p_cliente||'%')
        AND (p_unidad  IS NULL OR p_unidad  = '' OR prop.numero_propiedad ILIKE '%'||p_unidad||'%')
        AND (p_clabe   IS NULL OR p_clabe   = '' OR cc.clabe_stp ILIKE '%'||p_clabe||'%')
        -- (f) sin dígitos → sin filtro (antes devolvía cero filas)
        AND (v_cuenta_dig IS NULL OR cc.id::text LIKE '%'||v_cuenta_dig||'%')
        AND (p_modelos IS NULL OR mod.nombre = ANY(p_modelos))
        AND (p_tipos IS NULL OR
             (CASE
                WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL THEN 'Mantenimiento'
                WHEN o.id_producto IS NULL      THEN 'Propiedad'
                WHEN ps.id_categoria = 1        THEN 'Estacionamiento'
                WHEN ps.id_categoria = 2        THEN 'Bodega'
                WHEN ps.id_categoria IN (3, 4)  THEN 'Producto'
                ELSE 'Adicional' END) = ANY(p_tipos))
        AND (p_estatus IS NULL OR
             (CASE WHEN cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL THEN 'Cancelada'
                   WHEN cc.activo = false THEN 'Inactiva'
                   ELSE est.nombre END) = ANY(p_estatus))
        -- Filtros que dependen de saldos: obligan a evaluar los LATERAL de todas las cuentas
        AND (p_solo_vencidas = false OR COALESCE(vc.parcialidades_vencidas, 0) > 0)
        AND (p_prioridad IS NULL OR
          (CASE WHEN COALESCE(vc.parcialidades_vencidas,0) = 0 THEN 'Al día'
                WHEN COALESCE(vc.parcialidades_vencidas,0) = 1 THEN 'Alerta'
                WHEN COALESCE(vc.parcialidades_vencidas,0) = 2 THEN 'Urgente'
                ELSE 'Crítico' END) = ANY(p_prioridad))
        AND (p_invalid_level IS NULL OR
          (CASE WHEN (COALESCE(inv.invalidos,0)
                      + CASE WHEN o.id_producto IS NOT NULL THEN COALESCE(inv.acuerdos_sin_pago,0) ELSE 0 END) = 0 THEN 'Al día'
                WHEN (COALESCE(inv.invalidos,0)
                      + CASE WHEN o.id_producto IS NOT NULL THEN COALESCE(inv.acuerdos_sin_pago,0) ELSE 0 END) = 1 THEN 'Alerta'
                WHEN (COALESCE(inv.invalidos,0)
                      + CASE WHEN o.id_producto IS NOT NULL THEN COALESCE(inv.acuerdos_sin_pago,0) ELSE 0 END) = 2 THEN 'Urgente'
                ELSE 'Crítico' END) = ANY(p_invalid_level))
    )
    SELECT COALESCE(jsonb_agg(to_jsonb(pg2) - 'rn' ORDER BY pg2.rn), '[]'::jsonb)
    INTO v_cuentas
    FROM (SELECT * FROM pagina WHERE rn > p_offset AND rn <= p_offset + p_limit) pg2;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════════
  -- RUTA 2 — TOTALES: solo cuando se piden. Agrega con hash, no por fila.
  -- ═══════════════════════════════════════════════════════════════════════════
  IF p_incluir_totales THEN
    WITH apl_acuerdo AS (
      SELECT a.id_acuerdo_pago, SUM(a.monto) AS aplicado
      FROM aplicaciones_pago a
      WHERE a.activo = true AND a.es_multa = false
      GROUP BY a.id_acuerdo_pago
    ),
    saldos AS (
      SELECT
        ap.id_cuenta_cobranza AS cuenta_id,
        COUNT(*) FILTER (WHERE ap.pago_completado = false AND ap.fecha_pago < v_hoy)::int AS parcialidades_vencidas,
        COALESCE(SUM(CASE WHEN ap.pago_completado = false AND ap.fecha_pago < v_hoy
          THEN GREATEST(ap.monto - COALESCE(aa.aplicado, 0), 0) END), 0) AS monto_vencido,
        COALESCE(SUM(CASE WHEN ap.pago_completado = false
          THEN GREATEST(ap.monto - COALESCE(aa.aplicado, 0), 0) END), 0) AS saldo_pendiente
      FROM acuerdos_pago ap
      LEFT JOIN apl_acuerdo aa ON aa.id_acuerdo_pago = ap.id
      WHERE ap.activo = true
      GROUP BY ap.id_cuenta_cobranza
    ),
    -- (e) Mismo `invalidos` que la ruta de página, pre-agregado, para que
    --     p_invalid_level también aplique al total y la paginación cuadre.
    invalidos_cta AS (
      SELECT ap.id_cuenta_cobranza AS cuenta_id,
             COUNT(*) FILTER (WHERE pv.estado IS DISTINCT FROM 'coincide')::int AS invalidos
      FROM acuerdos_pago ap
      JOIN aplicaciones_pago apl ON apl.id_acuerdo_pago = ap.id
                                AND apl.activo = true AND apl.id_pago IS NOT NULL
      LEFT JOIN pago_validaciones pv ON pv.id_pago = apl.id_pago
      WHERE ap.activo = true
      GROUP BY ap.id_cuenta_cobranza
    ),
    sin_pago_cta AS (
      SELECT ap.id_cuenta_cobranza AS cuenta_id, COUNT(*)::int AS acuerdos_sin_pago
      FROM acuerdos_pago ap
      WHERE ap.activo = true
        AND NOT EXISTS (SELECT 1 FROM aplicaciones_pago apl
                        WHERE apl.id_acuerdo_pago = ap.id AND apl.activo = true
                          AND apl.id_pago IS NOT NULL)
      GROUP BY ap.id_cuenta_cobranza
    ),
    pagos_cuenta AS (
      SELECT pg.id_cuenta_cobranza AS cuenta_id, COUNT(*)::int AS pagos_activos
      FROM pagos pg WHERE pg.activo = true GROUP BY pg.id_cuenta_cobranza
    ),
    universo AS (
      SELECT
        cc.id AS cuenta_id,
        proy.id     AS proyecto_id,
        proy.nombre AS proyecto,
        mod.nombre  AS modelo,
        CASE WHEN cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL THEN 'Cancelada'
             WHEN cc.activo = false                                        THEN 'Inactiva'
             ELSE est.nombre END AS estatus_propiedad,
        COALESCE(s.parcialidades_vencidas, 0) AS parcialidades_vencidas,
        COALESCE(s.monto_vencido,   0)        AS monto_vencido,
        COALESCE(s.saldo_pendiente, 0)        AS saldo_pendiente
      FROM cuentas_cobranza cc
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
      LEFT JOIN saldos        s   ON s.cuenta_id   = cc.id
      LEFT JOIN pagos_cuenta  pgc ON pgc.cuenta_id = cc.id
      LEFT JOIN invalidos_cta ic  ON ic.cuenta_id  = cc.id
      LEFT JOIN sin_pago_cta  sc  ON sc.cuenta_id  = cc.id
      WHERE (
          cc.activo = true
          OR (cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL)
          OR COALESCE(pgc.pagos_activos, 0) > 0
        )
        -- Sin filtro de proyecto a propósito: el desglose `por_proyecto` lo cubre.
        AND (p_search IS NULL OR p_search = '' OR
             cc.clabe_stp ILIKE '%'||p_search||'%' OR per.nombre_legal ILIKE '%'||p_search||'%' OR
             per.email ILIKE '%'||p_search||'%' OR prop.numero_propiedad ILIKE '%'||p_search||'%' OR
             ps.nombre ILIKE '%'||p_search||'%' OR ed.nombre ILIKE '%'||p_search||'%' OR
             proy.nombre ILIKE '%'||p_search||'%')
        AND (p_cliente IS NULL OR p_cliente = '' OR
             per.nombre_legal ILIKE '%'||p_cliente||'%' OR per.email ILIKE '%'||p_cliente||'%')
        AND (p_unidad  IS NULL OR p_unidad  = '' OR prop.numero_propiedad ILIKE '%'||p_unidad||'%')
        AND (p_clabe   IS NULL OR p_clabe   = '' OR cc.clabe_stp ILIKE '%'||p_clabe||'%')
        AND (v_cuenta_dig IS NULL OR cc.id::text LIKE '%'||v_cuenta_dig||'%')
        AND (p_modelos IS NULL OR mod.nombre = ANY(p_modelos))
        AND (p_solo_vencidas = false OR COALESCE(s.parcialidades_vencidas, 0) > 0)
        AND (p_tipos IS NULL OR
             (CASE
                WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL THEN 'Mantenimiento'
                WHEN o.id_producto IS NULL      THEN 'Propiedad'
                WHEN ps.id_categoria = 1        THEN 'Estacionamiento'
                WHEN ps.id_categoria = 2        THEN 'Bodega'
                WHEN ps.id_categoria IN (3, 4)  THEN 'Producto'
                ELSE 'Adicional' END) = ANY(p_tipos))
        AND (p_estatus IS NULL OR
             (CASE WHEN cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL THEN 'Cancelada'
                   WHEN cc.activo = false THEN 'Inactiva'
                   ELSE est.nombre END) = ANY(p_estatus))
        AND (p_prioridad IS NULL OR
          (CASE WHEN COALESCE(s.parcialidades_vencidas,0) = 0 THEN 'Al día'
                WHEN COALESCE(s.parcialidades_vencidas,0) = 1 THEN 'Alerta'
                WHEN COALESCE(s.parcialidades_vencidas,0) = 2 THEN 'Urgente'
                ELSE 'Crítico' END) = ANY(p_prioridad))
        AND (p_invalid_level IS NULL OR
          (CASE WHEN (COALESCE(ic.invalidos,0)
                      + CASE WHEN o.id_producto IS NOT NULL THEN COALESCE(sc.acuerdos_sin_pago,0) ELSE 0 END) = 0 THEN 'Al día'
                WHEN (COALESCE(ic.invalidos,0)
                      + CASE WHEN o.id_producto IS NOT NULL THEN COALESCE(sc.acuerdos_sin_pago,0) ELSE 0 END) = 1 THEN 'Alerta'
                WHEN (COALESCE(ic.invalidos,0)
                      + CASE WHEN o.id_producto IS NOT NULL THEN COALESCE(sc.acuerdos_sin_pago,0) ELSE 0 END) = 2 THEN 'Urgente'
                ELSE 'Crítico' END) = ANY(p_invalid_level))
    )
    SELECT jsonb_build_object(
      -- Desglose por proyecto del MISMO barrido: cambiar de proyecto en la UI no cuesta
      -- ninguna consulta, el front lee la fila.
      'por_proyecto', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'proyecto_id', proyecto_id, 'proyecto', proyecto, 'total', n,
          'overdue', overdue, 'pending', pending, 'in_arrears', in_arrears
        ) ORDER BY n DESC), '[]'::jsonb)
        FROM (
          SELECT proyecto_id, MIN(proyecto) AS proyecto, COUNT(*) AS n,
                 COALESCE(SUM(monto_vencido), 0)   AS overdue,
                 COALESCE(SUM(saldo_pendiente), 0) AS pending,
                 COUNT(*) FILTER (WHERE parcialidades_vencidas > 0) AS in_arrears
          FROM universo GROUP BY proyecto_id
        ) q),
      'total', (SELECT COUNT(*) FROM universo),
      'kpis', jsonb_build_object(
        'total',      (SELECT COUNT(*) FROM universo),
        'overdue',    (SELECT COALESCE(SUM(monto_vencido), 0)   FROM universo),
        'pending',    (SELECT COALESCE(SUM(saldo_pendiente), 0) FROM universo),
        'in_arrears', (SELECT COUNT(*) FROM universo WHERE parcialidades_vencidas > 0)
      ),
      'modelos', (SELECT COALESCE(jsonb_agg(DISTINCT modelo ORDER BY modelo)
                    FILTER (WHERE modelo IS NOT NULL), '[]'::jsonb) FROM universo),
      'estatus', (SELECT COALESCE(jsonb_agg(DISTINCT estatus_propiedad ORDER BY estatus_propiedad)
                    FILTER (WHERE estatus_propiedad IS NOT NULL), '[]'::jsonb) FROM universo)
    ) INTO v_totales;
  END IF;

  RETURN jsonb_build_object('cuentas', v_cuentas) || v_totales;
END;
$function$;

-- Permisos: la función es nueva (cambió la firma), así que NO hereda la ACL anterior y
-- pg_default_acl le habría dado EXECUTE a anon.
REVOKE ALL ON FUNCTION public.get_pcobranza_cuentas_cobranza(
  integer, text, boolean, text, text, text, text, text[], text[], text[], text[], text[],
  text, text, integer, integer, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pcobranza_cuentas_cobranza(
  integer, text, boolean, text, text, text, text, text[], text[], text[], text[], text[],
  text, text, integer, integer, boolean) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Self-verifying
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_oid  oid;
  v_n    integer;
  v_src  text;
BEGIN
  SELECT count(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_pcobranza_cuentas_cobranza';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'Quedaron % sobrecargas de get_pcobranza_cuentas_cobranza: PostgREST no sabría cuál llamar', v_n;
  END IF;

  v_oid := to_regprocedure('public.get_pcobranza_cuentas_cobranza(integer, text, boolean, text, '
        || 'text, text, text, text[], text[], text[], text[], text[], text, text, integer, '
        || 'integer, boolean)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'No quedó la firma de 17 argumentos';
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = v_oid;
  IF v_src NOT LIKE '%current_puede(''cuentas_cobranza'', ''leer'')%' OR v_src NOT LIKE '%42501%' THEN
    RAISE EXCEPTION 'La función quedó sin guarda de autorización interna';
  END IF;
  IF (SELECT provolatile FROM pg_proc WHERE oid = v_oid) <> 's' THEN
    RAISE EXCEPTION 'La función no quedó STABLE';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
    RAISE EXCEPTION 'La función no quedó SECURITY DEFINER';
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'anon quedó con EXECUTE sobre get_pcobranza_cuentas_cobranza';
  END IF;
  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated/service_role se quedaron sin EXECUTE';
  END IF;

  -- El catálogo de authz tiene que existir o la guarda negaría a todos.
  IF NOT EXISTS (SELECT 1 FROM public.rls_tablas_submenus
                 WHERE tabla = 'cuentas_cobranza' AND activo = true) THEN
    RAISE EXCEPTION 'Falta el catálogo authz de cuentas_cobranza (20260730060000)';
  END IF;

  RAISE NOTICE 'get_pcobranza_cuentas_cobranza v3 OK: 1 firma, guarda 42501, sin anon';
END $$;
