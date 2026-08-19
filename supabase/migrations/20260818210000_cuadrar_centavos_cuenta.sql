-- Cuadrar al centavo las cuentas con el plan corto.
-- Fecha: 2026-08-18
--
-- ORDEN: va DESPUÉS de 20260818200000_estatus_pagada_no_pisa_entregado.sql. Esta función
-- inserta en aplicaciones_pago, y eso despierta trigger_actualizar_estatus_propiedad_pagada.
-- Sin el fix del estatus aplicado, cuadrar un centavo puede regresar una propiedad
-- Entregada a Pagada completamente.
--
-- Problema: una cuenta cuyo plan de pagos vale unos centavos MENOS que su precio_final no
-- se puede cuadrar con nada de lo que existe hoy:
--   · recalcular-aplicaciones reparte hasta el `monto` de cada acuerdo; si el plan entero
--     ya está pagado no hay dónde poner el centavo. Correcto por diseño.
--   · fn_reconciliar_acuerdos_cuenta busca el último acuerdo ABIERTO para absorber la
--     diferencia y devuelve requiere_revision / sin_acuerdo_abierto cuando no hay. Esa
--     guarda existe para no reabrir deuda en una cuenta liquidada y es correcta para
--     diferencias de negocio, pero vuelve irreparable un descuadre de redondeo.
--
-- Regla: el precio de la cuenta manda y el plan lo sigue — la misma que ya implementa
-- fn_reconciliar_acuerdos_cuenta. Lo único que se agrega es permitir el ajuste cuando el
-- último acuerdo ya está pagado Y la diferencia es indiscutiblemente de redondeo.
-- El límite es aritmético, no arbitrario: redondear N parcialidades a dos decimales no
-- puede perder más de N centavos, así que `diferencia <= n_acuerdos * 0.01` es la frontera
-- exacta entre residuo de redondeo y diferencia de negocio.
--
-- Los montos se comparan en numeric, que en PostgreSQL es decimal exacto. El bug de
-- flotantes que originó esto vive en JavaScript, no aquí.
--
-- ─── Por qué la guarda del dinero es DURA y no informativa ──────────────────
-- Las condiciones aritméticas de arriba NO distinguen "al plan le faltan centavos" de
-- "el cliente pagó centavos de menos", que son cosas opuestas. Medido read-only en prod
-- el 2026-08-18, 57 cuentas activas pasan esas condiciones:
--     13  tienen dinero sin aplicar >= diferencia  → se cuadran y quedan liquidadas
--      1  lo tiene parcial (cuenta 1131: 0.03 de 0.05)
--     43  no tienen nada: `recibido - precio_final` es negativo por exactamente los
--         centavos que le faltan al plan. Eso es COBRO PENDIENTE, no descuadre.
--
-- Aplicar sobre esas 44 no dejaría deuda visible sino deuda INVISIBLE con detonador
-- diferido:
--   1. Subir acuerdos_pago.monto no recalcula pago_completado: ese recálculo vive en
--      trg_aplicaciones_recalc_pago_completado, que solo dispara desde aplicaciones_pago.
--      El acuerdo queda con monto > aplicado y pago_completado todavía TRUE.
--   2. Meses después alguien toca una aplicación de ese acuerdo, el recálculo llega y lo
--      pone en FALSE, lo que dispara trg_revertir_estatus_si_hay_pendiente y baja la
--      propiedad de 9 o 7 a Vendido (5) si el saldo supera 0.01.
-- Por eso la función se niega en seco cuando el dinero no alcanza
-- (omitido / sin_dinero_para_cubrir_la_diferencia) en vez de limitarse a avisarlo. Las 44
-- quedan como listado de cobranza: son centavos que el cliente debe, y ahora la función lo
-- dice en vez de taparlo.
--
-- ─── Permisos ───────────────────────────────────────────────────────────────
-- EXECUTE solo para service_role. Es una función SECURITY DEFINER que muta acuerdos_pago y
-- aplicaciones_pago sin chequeo de rol, y `authenticated` incluye los usuarios con rol
-- Cliente: cualquier sesión del portal podría llamarla contra cualquier id_cuenta_cobranza.
-- Para abrirla al front hay que meterle antes un gate de permisos dentro de la función
-- (current_puede('/admin/portal-cobranza/...', 'actualizar')); no antes.
-- Además, toda función nueva en public nace con EXECUTE para anon por los DEFAULT
-- PRIVILEGES del proyecto y REVOKE FROM PUBLIC no lo quita: por eso el REVOKE de anon es
-- explícito.
--
-- ─── Verificado read-only en prod el 2026-08-18 ─────────────────────────────
--   · public.cuadrar_centavos_cuenta no existe (0 filas en pg_proc).
--   · aplicaciones_pago.id, acuerdos_pago.id, pagos.id y cuentas_cobranza.id son IDENTITY
--     BY DEFAULT, así que el INSERT sin id de esta función es válido.
--   · Conceptos 7 = "Pago por cancelación" y 9 = "Devolución de pago": excluirlos del plan
--     es correcto y es lo que ya hacen fn_reconciliar_acuerdos_cuenta y
--     trg_recalc_pago_completado.
--   · El UPDATE de monto despierta trg_acuerdos_reconciliar_precio_final →
--     ajustar_ultimo_acuerdo_pago() → fn_reconciliar_acuerdos_cuenta(): para entonces la
--     diferencia ya es 0, así que devuelve 'sin_cambio'. Sin recursión ni doble ajuste.
--   · Cuentas que pasan la guarda dura hoy, exactamente 13:
--     69, 125, 228, 513, 661, 871, 926, 988, 1138, 1140, 1143, 1168, 1248.
--
-- Idempotente (CREATE OR REPLACE). Sin BEGIN/COMMIT (el CI/CD envuelve en tx).

CREATE OR REPLACE FUNCTION public.cuadrar_centavos_cuenta(
  p_id_cuenta_cobranza bigint,
  p_dry_run            boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_cuenta      record;
  v_n_acuerdos  integer;
  v_suma_plan   numeric;
  v_diferencia  numeric;
  v_tolerancia  numeric;
  v_abiertos    integer;
  v_acuerdo     record;
  v_disponible  numeric;
  v_alcanza     boolean;
  v_pago        record;
  v_por_aplicar numeric;
  v_aplicado    numeric := 0;
  v_detalle     jsonb   := '[]'::jsonb;
BEGIN
  SELECT id, precio_final, activo, id_cuenta_cobranza_padre
    INTO v_cuenta
  FROM cuentas_cobranza WHERE id = p_id_cuenta_cobranza;

  IF NOT FOUND OR v_cuenta.activo IS NOT TRUE THEN
    RETURN jsonb_build_object('cc', p_id_cuenta_cobranza, 'accion', 'omitido',
                              'motivo', 'cuenta_inexistente_o_cancelada');
  END IF;

  -- Las hijas de mantenimiento llevan precio_final = 0 por diseño: su plan es recurrente
  -- y no se compara contra un precio.
  IF v_cuenta.id_cuenta_cobranza_padre IS NOT NULL THEN
    RETURN jsonb_build_object('cc', p_id_cuenta_cobranza, 'accion', 'omitido',
                              'motivo', 'cuenta_hija');
  END IF;

  IF v_cuenta.precio_final IS NULL OR v_cuenta.precio_final <= 0 THEN
    RETURN jsonb_build_object('cc', p_id_cuenta_cobranza, 'accion', 'omitido',
                              'motivo', 'precio_final_invalido');
  END IF;

  SELECT COUNT(*), COALESCE(SUM(monto), 0),
         COUNT(*) FILTER (WHERE pago_completado = false)
    INTO v_n_acuerdos, v_suma_plan, v_abiertos
  FROM acuerdos_pago
  WHERE id_cuenta_cobranza = p_id_cuenta_cobranza
    AND activo = TRUE AND id_concepto NOT IN (7, 9);

  IF v_n_acuerdos = 0 THEN
    RETURN jsonb_build_object('cc', p_id_cuenta_cobranza, 'accion', 'omitido',
                              'motivo', 'sin_plan');
  END IF;

  -- Si hay un acuerdo abierto, esto le toca a la reconciliación de siempre.
  IF v_abiertos > 0 THEN
    RETURN jsonb_build_object('cc', p_id_cuenta_cobranza, 'accion', 'omitido',
                              'motivo', 'usar_reconciliacion_normal',
                              'acuerdos_abiertos', v_abiertos);
  END IF;

  v_diferencia := v_cuenta.precio_final - v_suma_plan;
  -- Máximo residuo posible al redondear N parcialidades a dos decimales: N centavos.
  v_tolerancia := v_n_acuerdos * 0.01;

  IF v_diferencia <= 0 THEN
    RETURN jsonb_build_object('cc', p_id_cuenta_cobranza, 'accion', 'omitido',
                              'motivo', CASE WHEN v_diferencia = 0 THEN 'ya_cuadra'
                                             ELSE 'plan_excede_precio' END,
                              'diferencia', v_diferencia);
  END IF;

  IF v_diferencia > v_tolerancia THEN
    RETURN jsonb_build_object('cc', p_id_cuenta_cobranza, 'accion', 'requiere_revision',
                              'motivo', 'diferencia_mayor_a_redondeo',
                              'diferencia', v_diferencia, 'tolerancia', v_tolerancia);
  END IF;

  -- Dinero de la cuenta que sigue sin aplicarse.
  SELECT COALESCE(SUM(p.monto - COALESCE(ya.aplicado, 0)), 0)
    INTO v_disponible
  FROM pagos p
  LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(x.monto), 0) AS aplicado
    FROM aplicaciones_pago x WHERE x.id_pago = p.id AND x.activo = TRUE
  ) ya ON TRUE
  WHERE p.id_cuenta_cobranza = p_id_cuenta_cobranza AND p.activo = TRUE;

  -- Guarda dura: el ajuste del plan solo se hace si viene acompañado del dinero. Si no
  -- alcanza, la diferencia no es residuo de redondeo sino cobro pendiente del cliente, y
  -- subir el acuerdo dejaría monto > aplicado con pago_completado todavía TRUE.
  v_alcanza := (v_disponible >= v_diferencia);

  SELECT id, orden, monto INTO v_acuerdo
  FROM acuerdos_pago
  WHERE id_cuenta_cobranza = p_id_cuenta_cobranza
    AND activo = TRUE AND id_concepto NOT IN (7, 9)
  ORDER BY orden DESC, id DESC
  LIMIT 1;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'cc', p_id_cuenta_cobranza, 'accion', 'dry_run',
      'precio_final', v_cuenta.precio_final, 'suma_plan', v_suma_plan,
      'diferencia', v_diferencia, 'tolerancia', v_tolerancia,
      'acuerdos', v_n_acuerdos,
      'id_acuerdo_a_ajustar', v_acuerdo.id, 'monto_actual', v_acuerdo.monto,
      'monto_nuevo', v_acuerdo.monto + v_diferencia,
      'dinero_sin_aplicar', v_disponible,
      'se_aplicaria', v_alcanza,
      'motivo_rechazo', CASE WHEN v_alcanza THEN NULL
                             ELSE 'sin_dinero_para_cubrir_la_diferencia' END);
  END IF;

  IF NOT v_alcanza THEN
    RETURN jsonb_build_object('cc', p_id_cuenta_cobranza, 'accion', 'omitido',
                              'motivo', 'sin_dinero_para_cubrir_la_diferencia',
                              'diferencia', v_diferencia,
                              'dinero_sin_aplicar', v_disponible);
  END IF;

  -- 1. El plan pasa a valer lo que vale la cuenta.
  UPDATE acuerdos_pago
  SET monto = v_acuerdo.monto + v_diferencia,
      fecha_actualizacion = CURRENT_TIMESTAMP
  WHERE id = v_acuerdo.id;

  -- 2. Se aplica el dinero que ya estaba en la cuenta, pago por pago, en orden.
  v_por_aplicar := v_diferencia;

  FOR v_pago IN
    SELECT p.id, (p.monto - COALESCE(ya.aplicado, 0)) AS saldo
    FROM pagos p
    LEFT JOIN LATERAL (
      SELECT COALESCE(SUM(x.monto), 0) AS aplicado
      FROM aplicaciones_pago x WHERE x.id_pago = p.id AND x.activo = TRUE
    ) ya ON TRUE
    WHERE p.id_cuenta_cobranza = p_id_cuenta_cobranza AND p.activo = TRUE
      AND (p.monto - COALESCE(ya.aplicado, 0)) > 0
    ORDER BY p.fecha_pago ASC, p.id ASC
  LOOP
    EXIT WHEN v_por_aplicar <= 0;

    INSERT INTO aplicaciones_pago (id_pago, id_acuerdo_pago, monto, activo, es_multa)
    VALUES (v_pago.id, v_acuerdo.id, LEAST(v_pago.saldo, v_por_aplicar), TRUE, FALSE);

    v_detalle := v_detalle || jsonb_build_object(
      'id_pago', v_pago.id, 'monto', LEAST(v_pago.saldo, v_por_aplicar));
    v_aplicado    := v_aplicado    + LEAST(v_pago.saldo, v_por_aplicar);
    v_por_aplicar := v_por_aplicar - LEAST(v_pago.saldo, v_por_aplicar);
  END LOOP;

  RETURN jsonb_build_object(
    'cc', p_id_cuenta_cobranza, 'accion', 'cuadrada',
    'id_acuerdo_ajustado', v_acuerdo.id, 'orden', v_acuerdo.orden,
    'monto_anterior', v_acuerdo.monto, 'monto_nuevo', v_acuerdo.monto + v_diferencia,
    'diferencia', v_diferencia, 'aplicado', v_aplicado,
    'aplicaciones', v_detalle,
    'quedo_liquidada', (v_aplicado >= v_diferencia));
END;
$function$;

REVOKE ALL ON FUNCTION public.cuadrar_centavos_cuenta(bigint, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cuadrar_centavos_cuenta(bigint, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.cuadrar_centavos_cuenta(bigint, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.cuadrar_centavos_cuenta(bigint, boolean) TO service_role;

COMMENT ON FUNCTION public.cuadrar_centavos_cuenta(bigint, boolean) IS
  'Cuadra una cuenta cuyo plan quedó unos centavos por debajo de precio_final por redondeo: '
  'sube el último acuerdo por la diferencia y aplica el dinero que ya está en la cuenta. '
  'Solo actúa si no hay acuerdos abiertos, si la diferencia no excede 1 centavo por acuerdo '
  'y si hay dinero sin aplicar suficiente para cubrirla (si no, es cobro pendiente del '
  'cliente, no descuadre). EXECUTE solo para service_role. p_dry_run = true por defecto.';
