-- P26 E.0 — Resolución de propiedad (id_propiedad NULL) vía la oferta
-- ---------------------------------------------------------------------------------
-- cuentas_cobranza.id_propiedad viene NULL (la propiedad vive en ofertas.id_propiedad).
-- Las RPC resuelven prop por cc/ccp.id_propiedad -> join a propiedades falla -> proyecto,
-- edificio, modelo, unidad y estatus salen NULL. Fix: COALESCE también con la oferta
-- (ya joined: alias eff_o en CC, o en las demás; unión por id_oferta, no circular).
--
-- Prerrequisito de P27 §E.1 (tipo_categoria). Self-verifying: CREATE OR REPLACE aborta
-- si un alias no queda en scope; cada bloque aborta si el anchor no aparece.
--
-- ⚠️ NO es regresión-cero. En Inmuebles/Complementos el universo filtra
-- `ed.id_proyecto IN (_sozu)`; con prop NULL, ed era NULL y esos acuerdos se EXCLUÍAN.
-- Al resolver prop vía oferta, ~575 acuerdos (~$79.1M programado, ~$519k vencido — medido
-- en dev 2026-07-12) ENTRAN al universo -> cambia cartera/vencido mostrados. Es la
-- corrección esperada (esa plata estaba oculta por el bug), pero DEBE validarse en dev
-- con el test de reconciliación antes de prod. CC/RP no cambian totales (su universo no
-- depende de este join).

-- E.0.1 — get_pcobranza_cuentas_cobranza (CC, inbox)
DO $mig$
DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_pcobranza_cuentas_cobranza(integer,text,boolean)'::regprocedure);
  v_old := 'propiedades        prop  ON prop.id    = eff_cc.id_propiedad';
  v_new := 'propiedades        prop  ON prop.id    = COALESCE(eff_cc.id_propiedad, eff_o.id_propiedad)';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits < 1 THEN RAISE EXCEPTION 'E.0.1 abort: ancla no encontrada'; END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'E.0.1 OK (CC id_propiedad vía oferta, % reemplazos)', v_hits;
END $mig$;

-- E.0.2 — get_pcobranza_complementos (2 CTEs: _pm y _pgc)
DO $mig$
DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_pcobranza_complementos(integer,integer[],text,date,date)'::regprocedure);
  v_old := 'prop ON prop.id = COALESCE(cc.id_propiedad, ccp.id_propiedad)';
  v_new := 'prop ON prop.id = COALESCE(cc.id_propiedad, ccp.id_propiedad, o.id_propiedad)';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits < 1 THEN RAISE EXCEPTION 'E.0.2 abort: ancla no encontrada'; END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'E.0.2 OK (Complementos id_propiedad vía oferta, % reemplazos)', v_hits;
END $mig$;

-- E.0.3 — get_pcobranza_inmuebles (3 CTEs: _ap, _pg, ceps_sin_validar)
DO $mig$
DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_pcobranza_inmuebles(integer,date,date,integer[])'::regprocedure);
  v_old := 'prop ON prop.id = COALESCE(cc.id_propiedad, ccp.id_propiedad)';
  v_new := 'prop ON prop.id = COALESCE(cc.id_propiedad, ccp.id_propiedad, o.id_propiedad)';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits < 1 THEN RAISE EXCEPTION 'E.0.3 abort: ancla no encontrada'; END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'E.0.3 OK (Inmuebles id_propiedad vía oferta, % reemplazos)', v_hits;
END $mig$;

-- E.0.4 — get_relacion_pagos (propiedades aliased 'pr')
DO $mig$
DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_relacion_pagos(integer,integer,integer,text,text,text,text,text[],text[])'::regprocedure);
  v_old := 'pr ON pr.id = cc.id_propiedad';
  v_new := 'pr ON pr.id = COALESCE(cc.id_propiedad, o.id_propiedad)';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits < 1 THEN RAISE EXCEPTION 'E.0.4 abort: ancla no encontrada'; END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'E.0.4 OK (RelaciónPagos id_propiedad vía oferta, % reemplazos)', v_hits;
END $mig$;
