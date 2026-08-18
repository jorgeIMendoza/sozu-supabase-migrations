-- fecha_compra deja de reescribirse con la fecha de hoy.
-- Fecha: 2026-08-17
--
-- verificar_propiedad_vendida() hace `UPDATE cuentas_cobranza SET fecha_compra =
-- CURRENT_DATE` sin condición, para TODAS las cuentas de la propiedad. Cuelga de dos
-- triggers de acuerdos_pago, así que cada "Recalcular pagos" (la EF
-- recalcular-aplicaciones reinserta aplicaciones_pago → se re-marca el enganche como
-- pagado) mueve la fecha de compra al día del recálculo, y pisa lo capturado en
-- Validación de contratos PDF y en la edición manual.
--
-- Daño medido read-only en prod el 2026-08-17, sobre 1604 cuentas activas con pagos:
--   587 con fecha_compra POSTERIOR a su último pago (imposible)
--   612 con fecha_compra más de 180 días después del primer pago
--   104 estampadas este mes · 10 estampadas hoy · 0 nulas
--
-- Cambio: la fecha se siembra con el PRIMER pago activo de esa cuenta y SOLO cuando
-- fecha_compra está vacía. El trigger deja de competir con el contrato: no vuelve a
-- pisar una fecha capturada y nunca escribe CURRENT_DATE sobre una existente.
-- MIN(fecha_pago) se calcula por cuenta, no por propiedad: la principal, la de bodega y
-- la de estacionamiento tienen calendarios propios.
--
-- El histórico ya corrompido NO se corrige aquí: va en el DML de respaldo + backfill de
-- las 587 cuentas, que se entrega y ejecuta aparte.
--
-- Anclada a la definición viva verificada en dev y prod el 2026-08-17
-- (md5(prosrc) = 8e97d15fcc4632def9a9b4ae1bf55a48, 2767 chars, idéntica en ambos).
-- Idempotente y self-guarded. Sin BEGIN/COMMIT (el CI/CD envuelve en tx).
--
-- NOTA (no lo cambia esta migración): la URL de la edge function está hardcodeada al
-- proyecto de prod y dev tiene exactamente la misma cadena, así que hoy dev dispara
-- generar-factura-comision-sozu contra prod. Se conserva tal cual para no mezclar dos
-- cambios; queda anotado para atacarlo aparte.

-- ─── 0. Anchor: abortar si la función viva no es la esperada ─────────────────
DO $anchor$
DECLARE
  v_src text;
BEGIN
  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'verificar_propiedad_vendida';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'anchor: public.verificar_propiedad_vendida() no existe';
  END IF;

  -- Acepta el estado previo (escribe CURRENT_DATE) y el ya migrado (siembra si es NULL).
  IF position('fecha_compra = CURRENT_DATE' IN v_src) = 0
     AND position('cc.fecha_compra IS NULL' IN v_src) = 0
  THEN
    RAISE EXCEPTION
      'anchor: verificar_propiedad_vendida cambió (md5=%); revisar drift antes de reemplazar',
      md5(v_src);
  END IF;
END
$anchor$;

-- ─── 1. La función: sembrar la fecha, no reescribirla ───────────────────────

CREATE OR REPLACE FUNCTION public.verificar_propiedad_vendida()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_propiedad_id INTEGER;
    tiene_contrato_verificado BOOLEAN := FALSE;
    tiene_enganche_pagado BOOLEAN := FALSE;
    v_id_edificio_modelo INTEGER;
    v_cuenta_id INTEGER;
    v_key TEXT;
BEGIN
    IF TG_TABLE_NAME = 'documentos' THEN
        v_propiedad_id := NEW.id_propiedad;
    ELSIF TG_TABLE_NAME = 'acuerdos_pago' THEN
        SELECT o.id_propiedad INTO v_propiedad_id
        FROM acuerdos_pago ap
        JOIN cuentas_cobranza cc ON ap.id_cuenta_cobranza = cc.id
        JOIN ofertas o ON cc.id_oferta = o.id
        WHERE ap.id = NEW.id;
    END IF;

    SELECT id_edificio_modelo INTO v_id_edificio_modelo FROM propiedades WHERE id = v_propiedad_id;
    IF v_id_edificio_modelo IS NULL THEN RETURN NEW; END IF;

    SELECT EXISTS(
        SELECT 1 FROM documentos
        WHERE id_propiedad = v_propiedad_id AND id_tipo_documento = 18
        AND id_estatus_verificacion = 2 AND activo = TRUE
    ) INTO tiene_contrato_verificado;

    SELECT EXISTS(
        SELECT 1 FROM acuerdos_pago ap
        JOIN cuentas_cobranza cc ON ap.id_cuenta_cobranza = cc.id
        JOIN ofertas o ON cc.id_oferta = o.id
        WHERE o.id_propiedad = v_propiedad_id AND ap.id_concepto = 2
        AND ap.pago_completado = TRUE AND ap.activo = TRUE
    ) INTO tiene_enganche_pagado;

    IF tiene_contrato_verificado AND tiene_enganche_pagado THEN
        UPDATE propiedades SET id_estatus_disponibilidad = 5 WHERE id = v_propiedad_id;

        -- fecha_compra = fecha del PRIMER pago de esa cuenta, nunca CURRENT_DATE sobre
        -- una fecha existente. Solo se siembra cuando está vacía: la fecha del contrato
        -- (Validación de contratos PDF) y la edición manual mandan sobre cualquier
        -- cálculo. Antes esto era `SET fecha_compra = CURRENT_DATE` sin WHERE, así que
        -- cada recálculo de dispersión movía la fecha de compra al día del recálculo.
        UPDATE cuentas_cobranza cc
        SET fecha_compra = COALESCE(
                (SELECT MIN(p.fecha_pago)
                   FROM pagos p
                  WHERE p.id_cuenta_cobranza = cc.id AND p.activo = TRUE),
                CURRENT_DATE)
        WHERE cc.fecha_compra IS NULL
          AND cc.id IN (
            SELECT cc2.id FROM cuentas_cobranza cc2
            JOIN ofertas o ON cc2.id_oferta = o.id
            WHERE o.id_propiedad = v_propiedad_id AND cc2.activo = TRUE
        );

        -- Obtener la cuenta de cobranza principal
        SELECT cc.id INTO v_cuenta_id
        FROM cuentas_cobranza cc
        JOIN ofertas o ON cc.id_oferta = o.id
        WHERE o.id_propiedad = v_propiedad_id
          AND cc.activo = TRUE
          AND cc.id_cuenta_cobranza_padre IS NULL
        ORDER BY cc.id DESC
        LIMIT 1;

        -- Llamar a la edge function (fire and forget)
        IF v_cuenta_id IS NOT NULL THEN
            v_key := private.get_edge_function_key();
            IF v_key IS NOT NULL THEN
                PERFORM net.http_post(
                    url     := 'https://tzmhgfjmddkfyffkkmto.supabase.co/functions/v1/generar-factura-comision-sozu',
                    headers := jsonb_build_object(
                        'Content-Type',  'application/json',
                        'Authorization', 'Bearer ' || v_key
                    ),
                    body    := jsonb_build_object('id_cuenta_cobranza', v_cuenta_id)
                );
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

-- ─── 2. Quitar el trigger duplicado ─────────────────────────────────────────
-- trigger_verificar_venta_pago (AFTER INSERT OR UPDATE, cualquier columna, mismo WHEN)
-- es un superconjunto de trg_verificar_propiedad_vendida_pago (AFTER UPDATE OF
-- pago_completado). Tenerlos juntos corre la función —y su net.http_post a
-- generar-factura-comision-sozu— dos veces por cada evento.
-- Se conserva el de documentos (trg_verificar_propiedad_vendida_documento), que cubre
-- otra vía.

DROP TRIGGER IF EXISTS trg_verificar_propiedad_vendida_pago ON public.acuerdos_pago;

COMMENT ON FUNCTION public.verificar_propiedad_vendida() IS
  'Marca la propiedad como Vendida (estatus 5) cuando hay contrato verificado + enganche pagado. '
  'Siembra fecha_compra con el primer pago de cada cuenta SOLO si está vacía: nunca pisa la fecha '
  'capturada desde el contrato ni la editada a mano, y nunca escribe CURRENT_DATE encima.';
