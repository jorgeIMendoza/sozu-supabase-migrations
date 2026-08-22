-- =============================================================================
-- fix: cuadrar_centavos_cuenta truena con 23505 en su caso normal
-- =============================================================================
-- Solo cambia el INSERT sobre `aplicaciones_pago` por un upsert que SUMA.
-- El resto de la funcion (8 guardas, dry_run, retorno) queda IDENTICO a la
-- definicion viva de prod al 2026-08-22 (md5 443815a4be5df6e502a439cc03994573).
--
-- ─── Sintoma ─────────────────────────────────────────────────────────────────
--   duplicate key value violates unique constraint "uq_apppago_pago_acuerdo"
-- El dry-run se ve perfecto y ofrece aplicar; al aplicar revienta la transaccion
-- completa (no queda estado a medias, pero la operacion no se puede hacer).
--
-- ─── Causa ───────────────────────────────────────────────────────────────────
-- El cierre del hueco era un INSERT ciego, y la tabla tiene
--   uq_apppago_pago_acuerdo  UNIQUE (id_pago, id_acuerdo_pago, activo, es_multa)
-- o sea: un pago solo puede tener UNA aplicacion activa no-multa por acuerdo.
-- El pago que deja el residuo es, tipicamente, el MISMO que ya cubrio el ultimo
-- acuerdo — que es justo el acuerdo que la funcion ajusta.
--
-- Verificado en prod, CC-000069: pago 23051 de $36,551.20 (2026-08-10) ya tenia
-- la aplicacion 72515 al acuerdo 3771 por $36,551.08; saldo del pago $0.12 =
-- exactamente la diferencia. El segundo INSERT del par (23051, 3771) chocaba.
--
-- ─── Alcance medido en prod (142 cuentas activas descuadradas, 2026-08-22) ────
-- De las 13 aplicables (`se_aplicaria = true`), en las 13 basta un solo pago
-- (saldo == diferencia), y en 8 ese pago YA tiene aplicacion activa no-multa al
-- acuerdo a ajustar, asi que truenan con 23505:
--     cc 69, 228, 513, 926, 988, 1138, 1140, 1248
-- Las otras 5 (cc 125, 661, 871, 1143, 1168) hoy SI funcionan: su primer pago
-- con saldo no tiene aplicacion previa a ese acuerdo, y el INSERT ciego pasa.
-- (No es "0 de 13": es 8 rotas / 5 sanas. El fix las cubre todas.)
--
-- ─── El fix, y los dos detalles que no se pueden perder ──────────────────────
--   1. El ON CONFLICT lleva las CUATRO columnas del indice. Con dos da 42P10.
--      Verificado: uq_apppago_pago_acuerdo es UNIQUE btree no-parcial sobre las
--      cuatro, asi que la inferencia por columnas funciona.
--   2. El monto SUMA, no reemplaza: `SET monto = EXCLUDED.monto` borraria lo ya
--      aplicado y dejaria el acuerdo descubierto.
--
-- ─── Triggers de aplicaciones_pago con el camino UPDATE del upsert ───────────
--   · trg_aplicaciones_recalc_pago_completado  AFTER INSERT/DELETE/UPDATE OF
--     monto,... → SI corre. El recalculo se mantiene.
--   · trigger_actualizar_estatus_propiedad_pagada  AFTER INSERT OR UPDATE
--     WHEN new.activo → SI corre.
--   · update_aplicaciones_pago_updated_at  BEFORE UPDATE → SI corre (por eso el
--     upsert no toca fecha_actualizacion a mano).
--   · trg_crm_negocio_por_apartado y trigger_verificar_multa_completada son
--     AFTER INSERT solamente → NO corren en el camino UPDATE. Correcto: sumar
--     centavos a una aplicacion que ya existia no es un apartado nuevo ni una
--     multa nueva.
--
-- `CREATE OR REPLACE FUNCTION` conserva los privilegios, asi que el GRANT de
-- 20260822120000 no se pierde; se reafirma al final para que esta migracion sea
-- aplicable en cualquier orden.
-- =============================================================================
BEGIN;

-- -----------------------------------------------------------------------------
-- §1. Guardas de anclaje: la funcion y el indice deben ser los esperados
-- -----------------------------------------------------------------------------
DO $anchor$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'cuadrar_centavos_cuenta'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_id_cuenta_cobranza bigint, p_dry_run boolean'
  ) THEN
    RAISE EXCEPTION
      'No existe public.cuadrar_centavos_cuenta(bigint, boolean); revisar 20260813190000.';
  END IF;

  -- Si el indice cambiara de columnas o se volviera parcial, el ON CONFLICT de
  -- abajo dejaria de inferirlo (42P10). Mejor abortar aqui que en tiempo de uso.
  IF NOT EXISTS (
    SELECT 1
    FROM pg_index ix
    JOIN pg_class i ON i.oid = ix.indexrelid
    WHERE i.relname = 'uq_apppago_pago_acuerdo'
      AND ix.indisunique
      AND ix.indpred IS NULL
      AND pg_get_indexdef(ix.indexrelid)
          LIKE '%(id_pago, id_acuerdo_pago, activo, es_multa)'
  ) THEN
    RAISE EXCEPTION
      'uq_apppago_pago_acuerdo no es UNIQUE no-parcial sobre (id_pago, id_acuerdo_pago, activo, es_multa); el ON CONFLICT no aplica.';
  END IF;
END
$anchor$;

-- -----------------------------------------------------------------------------
-- §2. La funcion, con el upsert
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cuadrar_centavos_cuenta(
  p_id_cuenta_cobranza bigint,
  p_dry_run boolean DEFAULT true
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
  v_monto       numeric;
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

    v_monto := LEAST(v_pago.saldo, v_por_aplicar);

    -- FIX 2026-08-22: el pago que dejó el residuo es, casi siempre, el MISMO que ya
    -- cubrió el último acuerdo, y `uq_apppago_pago_acuerdo` es UNIQUE sobre
    -- (id_pago, id_acuerdo_pago, activo, es_multa). El INSERT ciego chocaba con 23505
    -- justo en el caso normal (CC-000069: el pago 23051 ya aplicaba al acuerdo 3771).
    -- El ON CONFLICT lleva las CUATRO columnas del índice —con dos da 42P10— y el
    -- monto SUMA: reemplazarlo borraría lo ya aplicado y dejaría el acuerdo descubierto.
    INSERT INTO aplicaciones_pago (id_pago, id_acuerdo_pago, monto, activo, es_multa)
    VALUES (v_pago.id, v_acuerdo.id, v_monto, TRUE, FALSE)
    ON CONFLICT (id_pago, id_acuerdo_pago, activo, es_multa)
    DO UPDATE SET monto = aplicaciones_pago.monto + EXCLUDED.monto;

    v_detalle := v_detalle || jsonb_build_object('id_pago', v_pago.id, 'monto', v_monto);
    v_aplicado    := v_aplicado    + v_monto;
    v_por_aplicar := v_por_aplicar - v_monto;
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

-- -----------------------------------------------------------------------------
-- §3. Permisos (CREATE OR REPLACE los conserva; se reafirman por orden de aplicacion)
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.cuadrar_centavos_cuenta(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cuadrar_centavos_cuenta(bigint, boolean)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- §4. Self-verifying
-- -----------------------------------------------------------------------------
DO $verify$
DECLARE
  v_oid  oid;
  v_src  text;
BEGIN
  SELECT p.oid, p.prosrc INTO v_oid, v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'cuadrar_centavos_cuenta'
    AND pg_get_function_identity_arguments(p.oid)
        = 'p_id_cuenta_cobranza bigint, p_dry_run boolean';

  IF position('ON CONFLICT (id_pago, id_acuerdo_pago, activo, es_multa)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'cuadrar_centavos_cuenta: falta el ON CONFLICT con las 4 columnas.';
  END IF;

  IF position('aplicaciones_pago.monto + EXCLUDED.monto' IN v_src) = 0 THEN
    RAISE EXCEPTION 'cuadrar_centavos_cuenta: el upsert no suma el monto.';
  END IF;

  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
    RAISE EXCEPTION 'cuadrar_centavos_cuenta: perdio SECURITY DEFINER.';
  END IF;

  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'cuadrar_centavos_cuenta: authenticated sin EXECUTE.';
  END IF;

  IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'cuadrar_centavos_cuenta: anon quedo con EXECUTE.';
  END IF;
END
$verify$;

COMMIT;
