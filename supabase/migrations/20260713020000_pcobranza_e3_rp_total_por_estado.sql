-- P27 E.3 — RP: conteos por estado de validación para las cards
-- ---------------------------------------------------------------------------------
-- Las cards de Relación de Pagos (Válidos / Sin validar) usaban un conteo derivado
-- de un solo campo → escondían no_coincide/error y los estados nuevos. Se agrega
-- 'total_por_estado' al payload: conteo por los 6 estados + 'sin_validar', SOBRE EL
-- UNIVERSO COMPLETO (CTE filtered, no la página paginada).
-- Prerrequisito: E.1/E.2 (20260712030000) — validacion_estado ya vive en RP.
-- Front ya lee data.total_por_estado con fallback (commit 6fb7b325).
--
-- Self-verifying: lee la función viva y ABORTA si el anchor no matchea (1 hit).
-- Idempotente: si total_por_estado ya está presente, no-op (RETURN) → seguro
-- re-aplicar. Esto reconcilia dev, donde el cambio ya está vivo, cuando el CI
-- corra `supabase db push` (registra la versión aunque el bloque sea no-op).

DO $mig$ DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_relacion_pagos(integer,integer,integer,text,text,text,text,text[],text[])'::regprocedure);

  -- Guard idempotente: si ya se aplicó, no re-anexar (evita clave duplicada).
  IF position('total_por_estado' in v_def) > 0 THEN
    RAISE NOTICE 'E.3 ya aplicado (total_por_estado presente) — no-op';
    RETURN;
  END IF;

  v_old := '''total_sin_validar'', (SELECT total_sin_validar FROM totals)';
  v_new := '''total_sin_validar'', (SELECT total_sin_validar FROM totals),
    ''total_por_estado'', (SELECT COALESCE(jsonb_object_agg(estado, n), ''{}''::jsonb)
       FROM (SELECT COALESCE(validacion_estado, ''sin_validar'') AS estado, COUNT(*) AS n FROM filtered GROUP BY 1) q)';
  v_hits := (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'E.3 abort: esperaba 1, halló %', v_hits; END IF;
  EXECUTE replace(v_def,v_old,v_new); RAISE NOTICE 'E.3 OK (total_por_estado)';
END $mig$;
