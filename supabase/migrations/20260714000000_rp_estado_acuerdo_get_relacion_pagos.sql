-- RP (Relación de Pagos) — columna "Estado" vacía: emitir estado_acuerdo en get_relacion_pagos
-- ---------------------------------------------------------------------------------
-- La vista RP (/admin/portal-cobranza) muestra "Sin registro" en Estado porque la RPC nunca
-- emite estado_acuerdo (el front ya lo espera: useRelacionPagos.ts:25). Se agrega ese único
-- campo al jsonb 'pagos'. NO se agregan monto_aplicado ni fecha_limite (fuera de alcance):
-- fecha_limite (=acuerdos_pago.fecha_pago) solo se usa DENTRO del CASE de estado_acuerdo.
--
-- Acuerdo representativo (un pago puede aplicar a varios acuerdos): el de MAYOR monto aplicado
-- por ese pago (opción a), filtrando es_multa=false para consistencia; tiebreak acuerdos_pago.orden ASC.
-- Reglas de estado copiadas del Detalle de Cuenta (CobranzaCuentaDetalle.tsx:267-275, umbral 30 días).
--
-- Anchor-replace sobre la definición VIVA (fuente de verdad, drift-safe; independiente de E.3
-- total_por_estado). Self-verifying: aborta si algún anchor no matchea (1 hit). Idempotente:
-- si estado_acuerdo ya está, no-op.

DO $mig$
DECLARE v_def text; v_old text; v_new text; v_hits int;
BEGIN
  v_def := pg_get_functiondef('public.get_relacion_pagos(integer,integer,integer,text,text,text,text,text[],text[])'::regprocedure);

  IF position('estado_acuerdo' in v_def) > 0 THEN
    RAISE NOTICE 'RP estado_acuerdo ya aplicado — no-op';
    RETURN;
  END IF;

  -- A) Columna estado_acuerdo en el SELECT del CTE base (fluye por SELECT * a filtered/paginated).
  v_old := $q$) AS tiene_cep
    FROM pagos p$q$;
  v_new := $q$) AS tiene_cep,
      CASE
        WHEN ac_rep.id IS NULL               THEN NULL
        WHEN ac_rep.pago_completado          THEN 'pagado'
        WHEN ac_rep.fecha_pago IS NULL       THEN 'pendiente'
        WHEN ac_rep.fecha_pago < v_hoy       THEN 'vencido'
        WHEN ac_rep.fecha_pago <= v_hoy + 30 THEN 'proximo'
        ELSE 'pendiente'
      END AS estado_acuerdo
    FROM pagos p$q$;
  v_hits := (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'RP A abort: esperaba 1, halló %', v_hits; END IF;
  v_def := replace(v_def, v_old, v_new);

  -- B) LEFT JOIN LATERAL del acuerdo representativo (mayor monto aplicado, es_multa=false).
  v_old := $q$) val ON true
    WHERE p.activo = true$q$;
  v_new := $q$) val ON true
    LEFT JOIN LATERAL (
      SELECT ac.id, ac.pago_completado, ac.fecha_pago
      FROM aplicaciones_pago ap2
      JOIN acuerdos_pago ac ON ac.id = ap2.id_acuerdo_pago
      WHERE ap2.id_pago = p.id AND ap2.activo AND ac.activo AND ap2.es_multa = false
      ORDER BY ap2.monto DESC NULLS LAST, ac.orden ASC
      LIMIT 1
    ) ac_rep ON true
    WHERE p.activo = true$q$;
  v_hits := (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'RP B abort: esperaba 1, halló %', v_hits; END IF;
  v_def := replace(v_def, v_old, v_new);

  -- C) Clave estado_acuerdo en el jsonb_build_object del bloque 'pagos'.
  v_old := $q$'proyecto', proyecto, 'proyecto_id', proyecto_id, 'tiene_cep', tiene_cep
      )) FROM paginated$q$;
  v_new := $q$'proyecto', proyecto, 'proyecto_id', proyecto_id, 'tiene_cep', tiene_cep,
        'estado_acuerdo', estado_acuerdo
      )) FROM paginated$q$;
  v_hits := (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'RP C abort: esperaba 1, halló %', v_hits; END IF;
  v_def := replace(v_def, v_old, v_new);

  EXECUTE v_def;
  RAISE NOTICE 'RP estado_acuerdo OK';
END $mig$;
