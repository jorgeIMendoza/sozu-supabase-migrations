-- P27 E.1/E.2 — Paridad CC ↔ RP: tipo_categoria canónico + estado_validacion crudo
-- ---------------------------------------------------------------------------------
-- Cierra la paridad de filtros entre Cuentas de Cobranza (CC) y Relación de Pagos (RP).
-- Prerrequisito: E.0 (id_propiedad vía oferta, migración 20260712020000) — aplica antes
-- por orden de timestamp. Front ya consume estos campos con fallback (commit a31e2224).
--
-- Self-verifying: cada bloque lee la función viva y ABORTA si el anchor no matchea (1 hit).
--
-- Nota (limitación conocida): RP no joinea acuerdos_pago → no tiene id_concepto, por eso
-- su tipo_categoria NO emite 'Mantenimiento' (CC sí, vía id_cuenta_cobranza_padre). Las
-- cuentas de mantenimiento normalmente no entran al universo de RP (id_oferta NULL →
-- o.id_producto NULL y cc.id_propiedad NULL). Si alguna apareciera, caería en 'Propiedad'.

-- E.1a — CC: agregar columna tipo_categoria (canónica por id_categoria)
DO $mig$ DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_pcobranza_cuentas_cobranza(integer,text,boolean)'::regprocedure);
  v_old := 'END AS tipo_cuenta,';
  v_new := 'END AS tipo_cuenta,
      CASE
        WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL THEN ''Mantenimiento''
        WHEN eff_o.id_producto IS NULL THEN ''Propiedad''
        WHEN ps.id_categoria = 1 THEN ''Estacionamiento''
        WHEN ps.id_categoria = 2 THEN ''Bodega''
        WHEN ps.id_categoria IN (3, 4) THEN ''Producto''
        ELSE ''Adicional''
      END AS tipo_categoria,';
  v_hits := (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'E.1a abort: esperaba 1, halló %', v_hits; END IF;
  EXECUTE replace(v_def,v_old,v_new); RAISE NOTICE 'E.1a OK (CC tipo_categoria)';
END $mig$;

-- E.1b — RP: reemplazar tipo_categoria string-match por el canónico
DO $mig$ DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_relacion_pagos(integer,integer,integer,text,text,text,text,text[],text[])'::regprocedure);
  v_old := 'CASE
        WHEN cc.id_propiedad IS NOT NULL THEN ''Propiedad''
        WHEN lower(coalesce(ps.nombre,'''')) LIKE ''%bodega%'' THEN ''Bodega''
        WHEN lower(coalesce(ps.nombre,'''')) LIKE ''%estacionamiento%'' THEN ''Estacionamiento''
        WHEN o.id_producto IS NOT NULL THEN ''Producto''
        ELSE ''Producto''
      END AS tipo_categoria';
  v_new := 'CASE
        WHEN o.id_producto IS NULL THEN ''Propiedad''
        WHEN ps.id_categoria = 1 THEN ''Estacionamiento''
        WHEN ps.id_categoria = 2 THEN ''Bodega''
        WHEN ps.id_categoria IN (3, 4) THEN ''Producto''
        ELSE ''Adicional''
      END AS tipo_categoria';
  v_hits := (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'E.1b abort: esperaba 1, halló %', v_hits; END IF;
  EXECUTE replace(v_def,v_old,v_new); RAISE NOTICE 'E.1b OK (RP tipo_categoria canónico)';
END $mig$;

-- E.2 — RP: exponer estado_validacion crudo en el JSON (el alias ya se calcula)
DO $mig$ DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_relacion_pagos(integer,integer,integer,text,text,text,text,text[],text[])'::regprocedure);
  v_old := '''tipo_categoria'', tipo_categoria, ''estatus'', estatus, ''atraso'', atraso,';
  v_new := '''tipo_categoria'', tipo_categoria, ''estatus'', estatus, ''estado_validacion'', validacion_estado, ''atraso'', atraso,';
  v_hits := (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'E.2 abort: esperaba 1, halló %', v_hits; END IF;
  EXECUTE replace(v_def,v_old,v_new); RAISE NOTICE 'E.2 OK (RP expone estado_validacion)';
END $mig$;
