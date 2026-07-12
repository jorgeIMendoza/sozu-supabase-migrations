-- P27 — Portal Cobranza: Año/Mes en "Cobranza por Proyecto" + fixes Complementos
-- ---------------------------------------------------------------------------------
-- Cada bloque LEE la función viva con pg_get_functiondef, valida el texto y ABORTA
-- si no lo halla (la definición cambió) — no re-teclea la función. Idempotencia:
-- re-correr aborta con hits<>esperado si ya se aplicó (texto viejo ya no existe).
--
-- Regla Año/Mes: flujo (cobrado) = ventana [p_fecha_inicio, p_fecha_fin];
-- saldo/stock (vencido, pendiente) = corte a COALESCE(p_fecha_fin, v_hoy).
-- Periodo NULL => estado a hoy (regresión cero).
--
-- Nota exactitud: el corte reclasifica por fecha de vencimiento usando el SALDO
-- ACTUAL del cargo (no deshace pagos posteriores al corte). As-of 100% histórico
-- requeriría recalcular pend uniendo pagos con fecha_pago <= corte — cambio mayor,
-- fuera de alcance salvo que negocio lo exija.

-- ═══════════════════════════════════════════════════════════════════════════════
-- A. get_pcobranza_complementos
-- ═══════════════════════════════════════════════════════════════════════════════

-- A.1 — Fix #1: categoría de producto huérfana (2 ocurrencias, filtro de universo)
DO $mig$
DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_pcobranza_complementos(integer,integer[],text,date,date)'::regprocedure);
  v_old := '(o.id_producto IS NOT NULL AND (ps.id_categoria IN (3, 4) OR ps.id_categoria IS NULL))';
  v_new := '(o.id_producto IS NOT NULL AND (ps.id_categoria IS NULL OR ps.id_categoria NOT IN (1, 2)))';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits <> 2 THEN RAISE EXCEPTION 'A.1 abort: esperaba 2 ocurrencias, halló %', v_hits; END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'A.1 OK (Fix #1 categoría huérfana)';
END $mig$;

-- A.2 — Año/Mes en "Cobranza por Proyecto" (por_proyecto)
DO $mig$
DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_pcobranza_complementos(integer,integer[],text,date,date)'::regprocedure);
  v_old := 'SELECT id_proyecto,
          COALESCE(SUM(pend) FILTER (WHERE pago_completado = false AND (fecha_pago >= v_hoy OR fecha_pago IS NULL)), 0) AS pendiente,
          COALESCE(SUM(pend) FILTER (WHERE pago_completado = false AND fecha_pago < v_hoy), 0) AS vencido
        FROM _pm GROUP BY id_proyecto
      ) m
      JOIN proyectos pr ON pr.id = m.id_proyecto
      LEFT JOIN (SELECT id_proyecto, SUM(monto) AS cobrado FROM _pgc GROUP BY id_proyecto) g';
  v_new := 'SELECT id_proyecto,
          COALESCE(SUM(pend) FILTER (WHERE pago_completado = false AND (fecha_pago >= COALESCE(p_fecha_fin, v_hoy) OR fecha_pago IS NULL)), 0) AS pendiente,
          COALESCE(SUM(pend) FILTER (WHERE pago_completado = false AND fecha_pago < COALESCE(p_fecha_fin, v_hoy)), 0) AS vencido
        FROM _pm GROUP BY id_proyecto
      ) m
      JOIN proyectos pr ON pr.id = m.id_proyecto
      LEFT JOIN (SELECT id_proyecto, SUM(monto) AS cobrado FROM _pgc
        WHERE (p_fecha_inicio IS NULL OR fecha_pago >= p_fecha_inicio)
          AND (p_fecha_fin IS NULL OR fecha_pago <= p_fecha_fin)
        GROUP BY id_proyecto) g';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'A.2 abort: esperaba 1 ocurrencia, halló %', v_hits; END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'A.2 OK (por_proyecto Año/Mes)';
END $mig$;

-- A.3 — Fix #2: morosidad server-side (campo nuevo, aditivo; antes del bloque duenos)
DO $mig$
DECLARE v_def text; v_anchor text; v_block text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_pcobranza_complementos(integer,integer[],text,date,date)'::regprocedure);
  v_anchor := '  -- ════ Dueños de proyectos SOZU (fuente del filtro) ════';
  v_block :=
'  -- ════ Morosidad server-side (espejo de Inmuebles: 1_vencida / 2_vencidas / 3_plus) ════
  result := result || jsonb_build_object(''morosidad'', (
    WITH venc AS (
      SELECT id_cuenta_cobranza,
             COUNT(*) FILTER (WHERE pago_completado = false AND fecha_pago < v_hoy) AS parc
      FROM _pm GROUP BY id_cuenta_cobranza
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(''grupo'', grupo, ''cuentas'', cnt)), ''[]''::jsonb)
    FROM (
      SELECT CASE WHEN parc = 1 THEN ''1_vencida'' WHEN parc = 2 THEN ''2_vencidas'' ELSE ''3_plus'' END AS grupo,
             COUNT(*) AS cnt
      FROM venc WHERE parc >= 1 GROUP BY 1
    ) g
  ));

';
  v_hits := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'A.3 abort: ancla no única (%).', v_hits; END IF;
  EXECUTE replace(v_def, v_anchor, v_block || v_anchor);
  RAISE NOTICE 'A.3 OK (morosidad server-side)';
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- B. get_pcobranza_inmuebles — Año/Mes en "Cobranza por Proyecto"
-- ═══════════════════════════════════════════════════════════════════════════════
DO $mig$
DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_pcobranza_inmuebles(integer,date,date,integer[])'::regprocedure);
  v_old := 'LEFT JOIN (SELECT id_proyecto, SUM(monto) AS cobrado FROM _pg GROUP BY 1) c ON c.id_proyecto = pr.id
      LEFT JOIN (SELECT id_proyecto, SUM(pend) AS vencido FROM _ap WHERE pago_completado = false AND fecha_pago < v_hoy GROUP BY 1) v ON v.id_proyecto = pr.id
      LEFT JOIN (SELECT id_proyecto, SUM(pend) AS pendiente FROM _ap WHERE pago_completado = false AND (fecha_pago >= v_hoy OR fecha_pago IS NULL) GROUP BY 1) pe ON pe.id_proyecto = pr.id';
  v_new := 'LEFT JOIN (SELECT id_proyecto, SUM(monto) AS cobrado FROM _pg WHERE (p_fecha_inicio IS NULL OR fecha_pago >= p_fecha_inicio) AND (p_fecha_fin IS NULL OR fecha_pago <= p_fecha_fin) GROUP BY 1) c ON c.id_proyecto = pr.id
      LEFT JOIN (SELECT id_proyecto, SUM(pend) AS vencido FROM _ap WHERE pago_completado = false AND fecha_pago < COALESCE(p_fecha_fin, v_hoy) GROUP BY 1) v ON v.id_proyecto = pr.id
      LEFT JOIN (SELECT id_proyecto, SUM(pend) AS pendiente FROM _ap WHERE pago_completado = false AND (fecha_pago >= COALESCE(p_fecha_fin, v_hoy) OR fecha_pago IS NULL) GROUP BY 1) pe ON pe.id_proyecto = pr.id';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'B abort: esperaba 1 ocurrencia, halló %', v_hits; END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'B OK (inmuebles por_proyecto Año/Mes)';
END $mig$;
