-- P27 · C — get_pcobranza_cuentas_cobranza: traer cuentas CANCELADAS + estatus
-- ---------------------------------------------------------------------------------
-- Hoy el inbox filtra WHERE cc.activo = true → excluye canceladas
-- (activo=false + id_tipo_cancelacion IS NOT NULL). Se traen y se expone el
-- estatus 'Cancelada' para el filtro/badge del front. Las inactivas SIN
-- id_tipo_cancelacion (baja no-cancelación) siguen excluidas.
--
-- Self-verifying: lee la función viva con pg_get_functiondef y ABORTA si el
-- anchor no matchea.

-- C.1 — incluir canceladas en el universo
DO $mig$
DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_pcobranza_cuentas_cobranza(integer,text,boolean)'::regprocedure);
  v_old := 'cc.activo = true';
  v_new := '(cc.activo = true OR (cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL))';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'C.1 abort: esperaba 1, halló %', v_hits; END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'C.1 OK (incluye canceladas)';
END $mig$;

-- C.2 — exponer estatus 'Cancelada' para el filtro/badge del front
DO $mig$
DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_pcobranza_cuentas_cobranza(integer,text,boolean)'::regprocedure);
  v_old := 'est.nombre      AS estatus_propiedad,';
  v_new := 'CASE WHEN cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL THEN ''Cancelada'' ELSE est.nombre END AS estatus_propiedad,';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'C.2 abort: esperaba 1, halló %', v_hits; END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'C.2 OK (estatus Cancelada)';
END $mig$;

-- C.3 — canceladas fuera del ranking de morosidad (prioridad = gray, va al final)
DO $mig$
DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_pcobranza_cuentas_cobranza(integer,text,boolean)'::regprocedure);
  v_old := 'WHEN COALESCE(vc.parcialidades_vencidas, 0) = 0 THEN ''green''';
  v_new := 'WHEN cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL THEN ''gray''
        WHEN COALESCE(vc.parcialidades_vencidas, 0) = 0 THEN ''green''';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'C.3 abort: esperaba 1, halló %', v_hits; END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'C.3 OK (canceladas prioridad gray)';
END $mig$;

-- C.4 — corrige el ORDER BY: 'gray' mapeaba a 0 (PRIMERO). Sin esto las canceladas
-- (C.3) saltarían al tope del inbox. Se remapea gray a 7 (después de green=6) para
-- que queden al FINAL, como pide la regla de negocio de C.3.
DO $mig$
DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_pcobranza_cuentas_cobranza(integer,text,boolean)'::regprocedure);
  v_old := 'WHEN ''gray''     THEN 0';
  v_new := 'WHEN ''gray''     THEN 7';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'C.4 abort: esperaba 1, halló %', v_hits; END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'C.4 OK (gray al final del orden)';
END $mig$;
