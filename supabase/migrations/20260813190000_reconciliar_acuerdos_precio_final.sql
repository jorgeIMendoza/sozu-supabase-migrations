-- =============================================================================
-- Reconciliación precio_final ↔ acuerdos de pago
-- =============================================================================
-- `cuentas_cobranza.precio_final` es el precio del contrato y debe ser la fuente única:
-- la suma de `acuerdos_pago` tiene que seguirlo al centavo. Hoy no lo hace en 711 de las
-- 1,742 cuentas activas con acuerdos.
--
-- ALCANCE DE ESTA MIGRACIÓN (decisión del 2026-08-13): solo la PREVENCIÓN. Que ninguna
-- cuenta nueva vuelva a nacer descuadrada y que cualquier cambio de precio o de plan
-- reconcilie solo, más la RPC que ya usa el botón "Reconciliar acuerdos" del front.
--
-- El BARRIDO del rezago (265 cuentas) queda DIFERIDO y no se ejecuta aquí. Mientras tanto
-- cobranza las cierra de una en una con el botón, que usa esta misma RPC.
--
-- ─── Por qué existe el rezago ────────────────────────────────────────────────
-- Los dos triggers ya implementaban la regla correcta, pero casi nunca corrían:
--   · `trigger_ajustar_acuerdos_precio_final` (cuentas_cobranza) solo dispara si cambia el
--     precio. Si el descuadre lo provocó el plan, nunca corre.
--   · `trigger_ajustar_acuerdo_update` (acuerdos_pago) es `AFTER UPDATE OF monto`: agregar,
--     borrar o desactivar un acuerdo dejaba el descuadre vivo.
-- Y las dos abrían con `pg_trigger_depth() > 1 → RETURN`, guard demasiado ancho: si el
-- UPDATE venía desde cualquier otra función, la reconciliación se saltaba entera y el
-- único rastro era un RAISE NOTICE.
--
-- ─── Verificado read-only el 2026-08-13 en prod (tzmhgfjmddkfyffkkmto) ───────
-- · `ajustar_acuerdos_por_precio_final()` y `ajustar_ultimo_acuerdo_pago()` existen, las
--   dos RETURNS trigger y SECURITY DEFINER → el CREATE OR REPLACE respeta la firma.
-- · `trigger_ajustar_acuerdos_precio_final` = AFTER UPDATE OF precio_final. Se conserva.
-- · `trigger_ajustar_acuerdo_update` = AFTER UPDATE OF monto WHEN (old.monto IS DISTINCT
--   FROM new.monto). Se reemplaza.
-- · `fn_reconciliar_acuerdos_cuenta` y `reconciliar_acuerdos_precio_final` no existen.
-- · Conceptos: 1 Apartado, 5 Parcialidad, 7 Pago por cancelación, 9 Devolución de pago.
-- · Ninguna función de la BD inserta en `acuerdos_pago`; el front solo inserta conceptos
--   7 y 9 (excluidos de la suma). Los planes los crea el flujo externo.
--
-- ─── Sobre el nuevo AFTER INSERT ─────────────────────────────────────────────
-- Los planes se insertan en UN SOLO statement: las 39 filas de la CC 1835 comparten
-- `fecha_creacion` al segundo, con 0.00s entre la primera y la última. Postgres encola los
-- triggers AFTER ROW y los corre al final del statement, así que cuando dispara el primero
-- ya existen las 39 filas y la suma está completa.
--
-- VIGILAR: si algún día el plan se insertara fila por fila en statements separados, la
-- primera fila se inflaría al precio de contrato completo y las siguientes saldrían como
-- `quedaria_negativo`. Si eso llega a pasar, el trigger se pasa a
-- CREATE CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED para que corra una sola vez
-- al COMMIT. No se hace ahora porque diferirlo cambiaría lo que se ve dentro de la misma
-- transacción y hoy no hace falta.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §0. Guards
-- -----------------------------------------------------------------------------
DO $guard$
BEGIN
  IF to_regclass('public.acuerdos_pago') IS NULL OR to_regclass('public.cuentas_cobranza') IS NULL THEN
    RAISE EXCEPTION 'Faltan acuerdos_pago o cuentas_cobranza';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='cuentas_cobranza' AND column_name='precio_final'
  ) THEN
    RAISE EXCEPTION 'No existe cuentas_cobranza.precio_final';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='cuentas_cobranza' AND column_name='id_cuenta_cobranza_padre'
  ) THEN
    RAISE EXCEPTION 'No existe cuentas_cobranza.id_cuenta_cobranza_padre; sin eso no se pueden excluir las cuentas hijas';
  END IF;

  -- Los conceptos excluidos tienen que seguir siendo los que se creen.
  IF NOT EXISTS (SELECT 1 FROM public.conceptos_pago WHERE id = 7 AND nombre ILIKE '%cancelaci%')
     OR NOT EXISTS (SELECT 1 FROM public.conceptos_pago WHERE id = 9 AND nombre ILIKE '%devoluci%') THEN
    RAISE EXCEPTION
      'Los conceptos 7/9 ya no son cancelación/devolución; el catálogo se renumeró y la exclusión de la suma quedaría mal';
  END IF;
END;
$guard$;

-- -----------------------------------------------------------------------------
-- §1. NÚCLEO: única implementación de la regla
--     El precio de contrato manda; el último acuerdo ABIERTO absorbe la diferencia.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_reconciliar_acuerdos_cuenta(p_cc bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_tolerancia constant numeric := 0.005;   -- el plan debe cuadrar al centavo
  v_cuenta        record;
  v_suma          numeric;
  v_diferencia    numeric;
  v_acuerdo       record;
BEGIN
  -- No re-entrar cuando este mismo núcleo dispara el UPDATE interno.
  IF coalesce(current_setting('sozu.reconciliando', true), '') = '1' THEN
    RETURN jsonb_build_object('cc', p_cc, 'accion', 'omitido', 'motivo', 'reentrada');
  END IF;

  SELECT id, precio_final, activo, id_cuenta_cobranza_padre
  INTO v_cuenta
  FROM public.cuentas_cobranza
  WHERE id = p_cc;

  IF NOT FOUND OR v_cuenta.activo IS NOT TRUE THEN
    RETURN jsonb_build_object('cc', p_cc, 'accion', 'omitido', 'motivo', 'cuenta_inactiva');
  END IF;

  -- Las cuentas hijas de mantenimiento llevan precio_final = 0 por diseño: su plan es
  -- recurrente y no se compara contra un precio de contrato. Son 305 y hoy inflan el
  -- banner de descuadre como falso positivo.
  IF v_cuenta.id_cuenta_cobranza_padre IS NOT NULL THEN
    RETURN jsonb_build_object('cc', p_cc, 'accion', 'omitido', 'motivo', 'cuenta_hija');
  END IF;

  IF v_cuenta.precio_final IS NULL OR v_cuenta.precio_final <= 0 THEN
    RETURN jsonb_build_object('cc', p_cc, 'accion', 'omitido', 'motivo', 'precio_final_invalido',
                              'precio_final', v_cuenta.precio_final);
  END IF;

  -- Suma del plan, excluyendo cancelación (7) y devolución (9).
  SELECT COALESCE(SUM(monto), 0) INTO v_suma
  FROM public.acuerdos_pago
  WHERE id_cuenta_cobranza = p_cc AND activo = TRUE AND id_concepto NOT IN (7, 9);

  v_diferencia := v_cuenta.precio_final - v_suma;

  IF ABS(v_diferencia) <= c_tolerancia THEN
    RETURN jsonb_build_object('cc', p_cc, 'accion', 'sin_cambio', 'suma', v_suma);
  END IF;

  -- Último acuerdo ABIERTO. Si todos están pagados no se toca nada: reabrir o borrar deuda
  -- de una cuenta liquidada es decisión de legal, no del sistema.
  SELECT id, monto, orden
  INTO v_acuerdo
  FROM public.acuerdos_pago
  WHERE id_cuenta_cobranza = p_cc
    AND activo = TRUE
    AND id_concepto NOT IN (7, 9)
    AND pago_completado = FALSE
  ORDER BY orden DESC, id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('cc', p_cc, 'accion', 'requiere_revision',
                              'motivo', 'sin_acuerdo_abierto',
                              'precio_final', v_cuenta.precio_final,
                              'suma', v_suma, 'diferencia', v_diferencia);
  END IF;

  IF (v_acuerdo.monto + v_diferencia) < 0 THEN
    RETURN jsonb_build_object('cc', p_cc, 'accion', 'requiere_revision',
                              'motivo', 'quedaria_negativo',
                              'id_acuerdo', v_acuerdo.id,
                              'monto_actual', v_acuerdo.monto,
                              'suma', v_suma, 'diferencia', v_diferencia);
  END IF;

  -- La bandera se limpia SIEMPRE, incluso si el UPDATE revienta. Si se quedara encendida,
  -- el resto de la transacción se saltaría la reconciliación en silencio.
  PERFORM set_config('sozu.reconciliando', '1', true);   -- local a la transacción
  BEGIN
    UPDATE public.acuerdos_pago
    SET monto = v_acuerdo.monto + v_diferencia,
        fecha_actualizacion = CURRENT_TIMESTAMP
    WHERE id = v_acuerdo.id;
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('sozu.reconciliando', '', true);
    RAISE;
  END;
  PERFORM set_config('sozu.reconciliando', '', true);

  RETURN jsonb_build_object('cc', p_cc, 'accion', 'ajustado',
                            'id_acuerdo', v_acuerdo.id, 'orden', v_acuerdo.orden,
                            'monto_anterior', v_acuerdo.monto,
                            'monto_nuevo', v_acuerdo.monto + v_diferencia,
                            'suma', v_suma,
                            'diferencia', v_diferencia,
                            'precio_final', v_cuenta.precio_final);
END;
$function$;

COMMENT ON FUNCTION public.fn_reconciliar_acuerdos_cuenta(bigint) IS
  'Fuente única de la regla precio_final ↔ suma de acuerdos. El precio de contrato manda y el '
  'último acuerdo ABIERTO absorbe la diferencia (tolerancia 0.005). Omite cuentas hijas de '
  'mantenimiento y devuelve requiere_revision en cuentas liquidadas.';

-- -----------------------------------------------------------------------------
-- §2. Trigger en cuentas_cobranza: cambió el precio de contrato
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ajustar_acuerdos_por_precio_final()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.precio_final IS DISTINCT FROM OLD.precio_final THEN
    PERFORM public.fn_reconciliar_acuerdos_cuenta(NEW.id);
  END IF;
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.ajustar_acuerdos_por_precio_final() IS
  'Trigger de cuentas_cobranza. Delega en fn_reconciliar_acuerdos_cuenta. 2026-08-13: se quita '
  'el guard por pg_trigger_depth(), que saltaba la reconciliación cuando el cambio venía '
  'anidado desde otra función.';

-- -----------------------------------------------------------------------------
-- §3. Trigger en acuerdos_pago: cambió el plan (alta, baja, monto, activo o concepto)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ajustar_ultimo_acuerdo_pago()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_nueva bigint;
  v_vieja bigint;
BEGIN
  v_nueva := CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE NEW.id_cuenta_cobranza END;
  v_vieja := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.id_cuenta_cobranza END;

  IF v_nueva IS NOT NULL THEN
    PERFORM public.fn_reconciliar_acuerdos_cuenta(v_nueva);
  END IF;

  -- Si el acuerdo cambió de cuenta, la de origen también quedó descuadrada. Sin esto se
  -- reconcilia solo el destino y la vieja se queda rota sin que nadie lo note.
  IF v_vieja IS NOT NULL AND v_vieja IS DISTINCT FROM v_nueva THEN
    PERFORM public.fn_reconciliar_acuerdos_cuenta(v_vieja);
  END IF;

  RETURN NULL;   -- AFTER trigger
END;
$function$;

COMMENT ON FUNCTION public.ajustar_ultimo_acuerdo_pago() IS
  'Trigger de acuerdos_pago. Delega en fn_reconciliar_acuerdos_cuenta. 2026-08-13: antes solo '
  'escuchaba UPDATE OF monto — agregar, borrar o desactivar un acuerdo dejaba el descuadre '
  'vivo, y de ahí salieron las 265 cuentas de rezago.';

DROP TRIGGER IF EXISTS trigger_ajustar_acuerdo_update ON public.acuerdos_pago;
DROP TRIGGER IF EXISTS trg_acuerdos_reconciliar_precio_final ON public.acuerdos_pago;

-- `id_cuenta_cobranza` va en la lista a propósito: mover un acuerdo de cuenta descuadra
-- las DOS, y sin esa columna el trigger ni siquiera dispararía.
CREATE TRIGGER trg_acuerdos_reconciliar_precio_final
AFTER INSERT OR DELETE OR UPDATE OF monto, activo, id_concepto, id_cuenta_cobranza
ON public.acuerdos_pago
FOR EACH ROW EXECUTE FUNCTION public.ajustar_ultimo_acuerdo_pago();

-- -----------------------------------------------------------------------------
-- §4. RPC para el botón del front y para el barrido diferido
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reconciliar_acuerdos_precio_final(
  p_id_cuenta_cobranza bigint DEFAULT NULL,
  p_dry_run            boolean DEFAULT false
)
 RETURNS TABLE (
   id_cuenta_cobranza bigint,
   accion             text,
   motivo             text,
   id_acuerdo         bigint,
   precio_final       numeric,
   suma_anterior      numeric,
   monto_anterior     numeric,
   monto_nuevo        numeric,
   diferencia         numeric
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cc  bigint;
  v_res jsonb;
BEGIN
  FOR v_cc IN
    SELECT c.id
    FROM public.cuentas_cobranza c
    WHERE c.activo = TRUE
      AND c.id_cuenta_cobranza_padre IS NULL
      AND c.precio_final > 0
      AND (p_id_cuenta_cobranza IS NULL OR c.id = p_id_cuenta_cobranza)
      AND EXISTS (SELECT 1 FROM public.acuerdos_pago a
                  WHERE a.id_cuenta_cobranza = c.id AND a.activo)
    ORDER BY c.id
  LOOP
    IF p_dry_run THEN
      SELECT jsonb_build_object(
               'cc', c.id,
               'accion', CASE
                 WHEN ABS(c.precio_final - s.suma) <= 0.005 THEN 'sin_cambio'
                 WHEN u.id IS NULL THEN 'requiere_revision'
                 WHEN (u.monto + (c.precio_final - s.suma)) < 0 THEN 'requiere_revision'
                 ELSE 'ajustaria' END,
               'motivo', CASE
                 WHEN ABS(c.precio_final - s.suma) <= 0.005 THEN NULL
                 WHEN u.id IS NULL THEN 'sin_acuerdo_abierto'
                 WHEN (u.monto + (c.precio_final - s.suma)) < 0 THEN 'quedaria_negativo'
                 ELSE NULL END,
               'id_acuerdo', u.id,
               'precio_final', c.precio_final,
               'suma', s.suma,
               'monto_anterior', u.monto,
               'monto_nuevo', u.monto + (c.precio_final - s.suma),
               'diferencia', c.precio_final - s.suma)
      INTO v_res
      FROM public.cuentas_cobranza c
      CROSS JOIN LATERAL (
        SELECT COALESCE(SUM(a.monto), 0) suma FROM public.acuerdos_pago a
        WHERE a.id_cuenta_cobranza = c.id AND a.activo AND a.id_concepto NOT IN (7,9)
      ) s
      LEFT JOIN LATERAL (
        SELECT a.id, a.monto FROM public.acuerdos_pago a
        WHERE a.id_cuenta_cobranza = c.id AND a.activo
          AND a.id_concepto NOT IN (7,9) AND a.pago_completado = FALSE
        ORDER BY a.orden DESC, a.id DESC LIMIT 1
      ) u ON TRUE
      WHERE c.id = v_cc;
    ELSE
      v_res := public.fn_reconciliar_acuerdos_cuenta(v_cc);
    END IF;

    IF (v_res->>'accion') <> 'sin_cambio' THEN
      RETURN QUERY SELECT
        (v_res->>'cc')::bigint,
        (v_res->>'accion')::text,
        (v_res->>'motivo')::text,
        (v_res->>'id_acuerdo')::bigint,
        (v_res->>'precio_final')::numeric,
        (v_res->>'suma')::numeric,
        (v_res->>'monto_anterior')::numeric,
        (v_res->>'monto_nuevo')::numeric,
        (v_res->>'diferencia')::numeric;
    END IF;
  END LOOP;
END;
$function$;

COMMENT ON FUNCTION public.reconciliar_acuerdos_precio_final(bigint, boolean) IS
  'Reconcilia una cuenta (p_id_cuenta_cobranza) o todas (NULL). p_dry_run = true solo simula. '
  'Excluye cuentas hijas y precio_final <= 0. Las liquidadas salen como requiere_revision. '
  'La usa el botón "Reconciliar acuerdos" del detalle de cuenta y del portal de cobranza.';

-- -----------------------------------------------------------------------------
-- §5. Permisos
-- -----------------------------------------------------------------------------
-- Toda función nueva en `public` nace con EXECUTE para PUBLIC, o sea anon. El núcleo no lo
-- necesita (lo invocan los triggers, que corren como el dueño) y la RPC solo la ocupa el
-- botón del panel.
REVOKE ALL ON FUNCTION public.fn_reconciliar_acuerdos_cuenta(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reconciliar_acuerdos_precio_final(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reconciliar_acuerdos_precio_final(bigint, boolean) TO authenticated;

-- -----------------------------------------------------------------------------
-- §6. Self-verifying
-- -----------------------------------------------------------------------------
DO $check$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger
             WHERE tgrelid = 'public.acuerdos_pago'::regclass
               AND tgname = 'trigger_ajustar_acuerdo_update') THEN
    RAISE EXCEPTION 'El trigger viejo trigger_ajustar_acuerdo_update sigue vivo';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.acuerdos_pago'::regclass
                   AND tgname = 'trg_acuerdos_reconciliar_precio_final') THEN
    RAISE EXCEPTION 'No quedó creado trg_acuerdos_reconciliar_precio_final';
  END IF;

  IF NOT has_function_privilege('authenticated',
       'public.reconciliar_acuerdos_precio_final(bigint, boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated no puede ejecutar la RPC; el botón del front quedaría muerto';
  END IF;

  IF has_function_privilege('anon',
       'public.reconciliar_acuerdos_precio_final(bigint, boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon quedó con EXECUTE sobre la RPC de reconciliación';
  END IF;
END;
$check$;

COMMIT;

-- =============================================================================
-- Validación (read-only, correr después del deploy)
-- =============================================================================
-- 1) Las cuatro funciones, SECURITY DEFINER
--    SELECT p.proname, p.prosecdef, pg_get_function_identity_arguments(p.oid) args
--    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
--      AND p.proname IN ('fn_reconciliar_acuerdos_cuenta','reconciliar_acuerdos_precio_final',
--                        'ajustar_acuerdos_por_precio_final','ajustar_ultimo_acuerdo_pago');
--
-- 2) El trigger nuevo escucha INSERT/DELETE/UPDATE y el viejo ya no existe
--    SELECT tgname, pg_get_triggerdef(oid) FROM pg_trigger
--    WHERE tgrelid = 'public.acuerdos_pago'::regclass AND NOT tgisinternal ORDER BY tgname;
--
-- 3) Rezago pendiente. El barrido está diferido, así que NO baja a 0 todavía: es la línea
--    base, debe ir bajando conforme cobranza usa el botón y nunca subir.
--    WITH ac AS (SELECT id_cuenta_cobranza cc, SUM(monto) suma FROM acuerdos_pago
--                WHERE activo AND id_concepto NOT IN (7,9) GROUP BY 1)
--    SELECT count(*) FROM cuentas_cobranza c JOIN ac ON ac.cc = c.id
--    WHERE c.activo AND c.id_cuenta_cobranza_padre IS NULL AND c.precio_final > 0
--      AND ABS(c.precio_final - ac.suma) > 0.005
--      AND EXISTS (SELECT 1 FROM acuerdos_pago a WHERE a.id_cuenta_cobranza = c.id
--                  AND a.activo AND a.id_concepto NOT IN (7,9) AND NOT a.pago_completado);
--
-- 4) Simulación del rezago (solo lectura, no escribe)
--    SELECT accion, motivo, count(*) cuentas, round(sum(diferencia),2) delta
--    FROM public.reconciliar_acuerdos_precio_final(NULL, true) GROUP BY 1,2 ORDER BY 1,2;
--
-- BARRIDO DIFERIDO — NO ejecutar en este deploy. Cuando se autorice:
--    CREATE TABLE public._bak_acuerdos_pago_<fecha> AS SELECT a.* FROM acuerdos_pago a
--      JOIN cuentas_cobranza c ON c.id = a.id_cuenta_cobranza
--     WHERE c.activo AND c.id_cuenta_cobranza_padre IS NULL AND c.precio_final > 0;
--    SELECT accion, motivo, count(*) FROM public.reconciliar_acuerdos_precio_final(NULL,false)
--     GROUP BY 1,2;
--    SELECT public.recalcular_pago_completado_acuerdos(NULL);
--  (y el respaldo nace con RLS, ver 20260813150000)
--
-- Nota operativa: cada uso del botón cambia el monto de un acuerdo, así que después
-- conviene correr la EF `recalcular-aplicaciones` de esa cuenta —el botón "Recalcular
-- dispersión" del detalle— para que las aplicaciones cuadren con el plan nuevo.
-- =============================================================================
