-- P29 — Eliminar pago (SOFT DELETE) — RPC eliminar_pago
-- ---------------------------------------------------------------------------------
-- Un pago es un registro contable (auditoría fiscal SAT / CFDI / trazabilidad de
-- saldos): no se borra físicamente. La eliminación es soft delete:
--   pagos.activo=false + auditoría, aplicaciones_pago.activo=false. El historial
--   (pago_validaciones, cep_audit_log) NO se toca.
--
-- Recálculo: UPDATE de aplicaciones_pago.activo dispara trg_aplicaciones_recalc_pago_completado
-- (recalcula acuerdos_pago.pago_completado sobre abonos activo=true) y la reversión de
-- estatus de propiedad (trg_revertir_estatus_si_hay_pendiente). Se desactiva el pago PRIMERO
-- para que el recálculo lo vea inactivo.
--
-- Autorización server-side (no solo UI): SECURITY DEFINER + verificación de que auth.uid()
-- sea un usuario activo cuyo rol tenga permiso 'eliminar' (permiso_id=4) en algún submenú de
-- pagos, resuelto por vista_front_end (estable entre dev y prod; los submenu_id difieren).
--
-- Bloqueos: factura de mantenimiento TIMBRADA (facturado=true) y método "STP" (id=6, exacto).
--
-- Idempotente: ADD COLUMN IF NOT EXISTS + CREATE OR REPLACE + GRANT → seguro re-aplicar por CI.

-- 1. Columnas de auditoría en pagos (soft delete)
ALTER TABLE public.pagos
  ADD COLUMN IF NOT EXISTS eliminado_por      uuid,
  ADD COLUMN IF NOT EXISTS fecha_eliminacion  timestamptz,
  ADD COLUMN IF NOT EXISTS motivo_eliminacion text;

-- 2. RPC soft-delete
CREATE OR REPLACE FUNCTION public.eliminar_pago(
  p_id_pago integer,
  p_motivo  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_cuenta          integer;
  v_monto           numeric;
  v_metodo          text;
  v_facturas        integer := 0;
  v_n_aplicaciones  integer := 0;
BEGIN
  -- Autorización server-side: el usuario (auth.uid) debe estar activo y su rol debe tener
  -- el permiso 'eliminar' (permiso_id=4) en algún submenú de pagos. Se resuelve por
  -- vista_front_end (estable entre dev y prod; los submenu_id difieren por ambiente).
  IF NOT EXISTS (
    SELECT 1
    FROM public.usuarios u
    JOIN public.submenus_permisos sp
      ON sp.rol_id = u.rol_id AND sp.permiso_id = 4 AND sp.activo = true
    JOIN public.submenus s
      ON s.id = sp.submenu_id AND s.activo = true
    WHERE u.auth_user_id = auth.uid()
      AND u.activo = true
      AND s.vista_front_end IN (
        '/admin/validacion-pagos',
        '/admin/portal-cobranza/relacion-pagos',
        '/admin/portal-cobranza/cuentas-cobranza'
      )
  ) THEN
    RAISE EXCEPTION 'No tienes permiso para eliminar pagos.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- El pago debe existir y estar activo. Traemos el método en el mismo SELECT (sin re-query).
  SELECT pg.id_cuenta_cobranza, pg.monto, mp.nombre
  INTO v_cuenta, v_monto, v_metodo
  FROM public.pagos pg
  LEFT JOIN public.metodos_pago mp ON mp.id = pg.id_metodos_pago
  WHERE pg.id = p_id_pago AND pg.activo = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El pago % no existe o ya fue eliminado.', p_id_pago
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Bloqueo STP: método exacto "STP" (automático) NUNCA se elimina. "STP-manual" y el
  -- resto sí. Comparación por nombre exacto (no LIKE, para no atrapar "STP-manual").
  IF v_metodo = 'STP' THEN
    RAISE EXCEPTION 'El pago % es STP (automático) y no se puede eliminar.', p_id_pago
      USING ERRCODE = 'raise_exception';
  END IF;

  -- Bloqueo fiscal: solo bloquea si hay factura de mantenimiento TIMBRADA (facturado=true).
  -- Un borrador (facturado=false) o un CFDI cancelado (facturado=false o fila borrada) NO bloquean.
  SELECT COUNT(*) INTO v_facturas
  FROM public.facturas_mantenimientos
  WHERE id_pago = p_id_pago AND facturado = true;

  IF v_facturas > 0 THEN
    RAISE EXCEPTION
      'El pago % tiene % factura(s) de mantenimiento timbrada(s). Cancela el CFDI antes de eliminar el pago.',
      p_id_pago, v_facturas
      USING ERRCODE = 'raise_exception';
  END IF;

  -- 1) Desactivar el pago PRIMERO (auditoría). Así el recálculo de saldo lo ve inactivo.
  UPDATE public.pagos
  SET activo             = false,
      eliminado_por      = auth.uid(),
      fecha_eliminacion  = now(),
      motivo_eliminacion = p_motivo
  WHERE id = p_id_pago;

  -- 2) Desactivar sus abonos. El UPDATE OF activo dispara el recálculo de
  --    pago_completado y la reversión de estatus de la propiedad.
  UPDATE public.aplicaciones_pago
  SET activo = false
  WHERE id_pago = p_id_pago AND activo = true;
  GET DIAGNOSTICS v_n_aplicaciones = ROW_COUNT;

  -- Seguro idempotente: recalcular todos los acuerdos de la cuenta.
  PERFORM public.recalcular_pago_completado_acuerdos(v_cuenta);

  RETURN jsonb_build_object(
    'id_pago',                   p_id_pago,
    'id_cuenta_cobranza',        v_cuenta,
    'monto',                     v_monto,
    'aplicaciones_desactivadas', v_n_aplicaciones,
    'soft_delete',               true
  );
END;
$function$;

-- Permitir invocación desde el cliente autenticado.
GRANT EXECUTE ON FUNCTION public.eliminar_pago(integer, text) TO authenticated;
