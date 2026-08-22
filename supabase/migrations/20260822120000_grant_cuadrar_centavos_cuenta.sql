-- =============================================================================
-- GRANT EXECUTE a cuadrar_centavos_cuenta
-- =============================================================================
-- Solo permisos. NO modifica la funcion ni los datos.
--
-- `cuadrar_centavos_cuenta(bigint, boolean)` existe y esta bien hecha desde
-- 20260813190000, pero nacio con ACL {postgres, service_role}: desde el navegador
-- responde 42501 permission denied. El detalle de cuenta del portal de cobranza ya
-- tiene el dialogo de cuadre (sozu-admin, CuadrarCentavosDialog.tsx) y le nombraba al
-- usuario una funcion que su sesion no podia ejecutar.
--
-- Su hermana del mismo flujo, `reconciliar_acuerdos_precio_final(bigint, boolean)`,
-- ya tiene EXECUTE para `authenticated` (misma migracion 20260813190000, §5).
--
-- ─── Por que es seguro ───────────────────────────────────────────────────────
-- Todas las guardas viven DENTRO de la funcion y ninguna depende de quien la llame:
--   · cuenta inexistente / cancelada .......... omitido
--   · cuenta hija (mantenimiento) ............. omitido / cuenta_hija
--   · precio_final nulo o <= 0 ................ omitido / precio_final_invalido
--   · sin plan de pagos ....................... omitido / sin_plan
--   · hay acuerdos abiertos ................... omitido / usar_reconciliacion_normal
--   · diferencia <= 0 ......................... omitido / ya_cuadra | plan_excede_precio
--                                               (nunca BAJA un acuerdo)
--   · diferencia > N * $0.01 (N = acuerdos) ... requiere_revision
--   · sin dinero cobrado sin aplicar .......... omitido / sin_dinero_para_cubrir_...
-- Las dos ultimas son las duras: solo cuadra cuando la diferencia cabe en el redondeo
-- del plan Y el dinero ya esta cobrado. Nunca inventa dinero. `p_dry_run` (default
-- true) no escribe.
--
-- ─── Alcance medido en prod al 2026-08-22 (142 cuentas activas descuadradas) ──
--   aplicable (se_aplicaria = true) ............ 13 cuentas ....... $0.48
--   sin_dinero_para_cubrir_la_diferencia ....... 44 cuentas ....... $1.23
--   plan_excede_precio (diferencia negativa) ... 51 cuentas .. -$34,494.90
--   requiere_revision / diferencia_mayor ....... 31 cuentas .. $77,749.97
--   sin_plan .................................... 3 cuentas ........... —
-- Cierra 13 por si sola. Las otras 129 siguen necesitando decision humana.
--
-- NOTA de alcance: el GRANT es a `authenticated`, es decir a cualquier sesion logueada
-- (incluido el rol 23 del portal de cliente), igual que su hermana. Es aceptable porque
-- la funcion es SECURITY DEFINER con guardas propias y el submenu de cobranza no existe
-- en el portal del cliente, pero si algun dia se quiere acotar por rol el lugar es un
-- `current_puede_tabla('acuerdos_pago','actualizar')` DENTRO de la funcion, no el GRANT.
-- No se hace aqui.
--
-- Fuera de alcance: las 51 de `plan_excede_precio` (-$34,494.90). Ahi el plan pide MAS
-- que el precio y la funcion no las toca por diseño; probablemente toca corregir el
-- `precio_final` contra el contrato, no el plan. Va aparte.
-- =============================================================================
BEGIN;

-- -----------------------------------------------------------------------------
-- §1. Guarda: sin la funcion, este GRANT no tiene sentido
-- -----------------------------------------------------------------------------
DO $guard$
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
END
$guard$;

-- -----------------------------------------------------------------------------
-- §2. Permisos
-- -----------------------------------------------------------------------------
-- `anon` nunca: la funcion escribe sobre el plan de pagos.
REVOKE ALL ON FUNCTION public.cuadrar_centavos_cuenta(bigint, boolean) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.cuadrar_centavos_cuenta(bigint, boolean)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.cuadrar_centavos_cuenta(bigint, boolean) IS
  'Cuadra el residuo de redondeo entre precio_final y la suma del plan: sube el ULTIMO '
  'acuerdo por la diferencia y aplica el dinero ya cobrado. Solo actua si la diferencia '
  'cabe en N centavos (N = numero de acuerdos) y si hay dinero cobrado sin aplicar que la '
  'cubra; si no, devuelve requiere_revision u omitido sin escribir. p_dry_run = true '
  '(default) solo simula. La llama el dialogo de cuadre del detalle de cuenta en sozu-admin.';

-- -----------------------------------------------------------------------------
-- §3. Self-verifying
-- -----------------------------------------------------------------------------
DO $verify$
DECLARE
  v_oid oid;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'cuadrar_centavos_cuenta'
    AND pg_get_function_identity_arguments(p.oid)
        = 'p_id_cuenta_cobranza bigint, p_dry_run boolean';

  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'cuadrar_centavos_cuenta: authenticated sigue sin EXECUTE.';
  END IF;

  IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'cuadrar_centavos_cuenta: anon quedo con EXECUTE.';
  END IF;

  -- La funcion no se recreo: sigue siendo SECURITY DEFINER.
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
    RAISE EXCEPTION 'cuadrar_centavos_cuenta: perdio SECURITY DEFINER.';
  END IF;
END
$verify$;

COMMIT;
