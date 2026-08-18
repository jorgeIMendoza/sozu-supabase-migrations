-- Generador del plan de pagos: erradicar las cuentas escalonadas sin mensualidades.
-- Fecha: 2026-08-17
--
-- Causa raíz: n8n arma el plan con esquemas_pago.porcentaje_mensualidades ×
-- numero_mensualidades y NO mira tramos_mensualidad. El esquema 1050 (Daiku,
-- Escalonado) tiene 0 % y 0 mensualidades y guarda su plan en el tramo
-- (monto_mensualidad = 2500000 centavos = $25,000), así que toda cuenta vendida con
-- él sale con cero parcialidades y el 94 % restante en el concepto 3.
--
-- Corrección sin tocar n8n: el concepto 3 (Pago a contra entrega) es SIEMPRE la última
-- fila que inserta el alta, así que un AFTER INSERT sobre esa fila completa el plan
-- dentro de la misma transacción.
--
-- Esta migración NO toca ninguna cuenta existente: el trigger solo actúa en altas
-- nuevas. El backfill de las 5 cuentas afectadas y la reasignación del pago de la 1832
-- son DML y se entregan/ejecutan aparte.
--
-- Depende de 20260818000000_mensualidades_fijas_oferta_digital.sql (columnas
-- mensualidades_fijas en propiedades/proyectos, que este generador consulta).
--
-- Verificado read-only contra prod el 2026-08-17:
--   * conceptos: 1 Apartado · 2 Enganche · 3 Pago a contra entrega · 5 Parcialidad
--                · 7 Pago por cancelación · 9 Devolución de pago.
--   * fn_reconciliar_acuerdos_cuenta ajusta el ÚLTIMO acuerdo ABIERTO por
--     (orden DESC, id DESC) y se protege de reentrada con sozu.reconciliando; por eso
--     aquí el concepto 3 se mueve al final ANTES de insertar las parcialidades.
--     El UPDATE de `orden` no dispara esa reconciliación (la columna no está en la
--     lista del trigger), así que el movimiento es seguro.
--   * tramos_mensualidad usa DOS formatos vivos: {monto} en pesos (esquemas 851-853)
--     y {monto_mensualidad} en centavos (esquema 1050). Se leen los dos, igual que
--     get_oferta_financials.
-- Idempotente y self-guarded. Sin BEGIN/COMMIT (el CI/CD envuelve en tx).

-- ─── 1. Generador único del plan de pagos de una cuenta ──────────────────────
-- Entiende las DOS formas de un esquema:
--   a) por porcentaje → numero_mensualidades × (precio_final × pct/100 / n)
--   b) por tramos     → monto fijo en pesos del tramo × meses  ← lo que n8n ignora
-- Idempotente: si la cuenta ya tiene parcialidades (activas o dadas de baja), no hace
-- nada.

CREATE OR REPLACE FUNCTION public.generar_plan_acuerdos_cuenta(
  p_cuenta_id   bigint,
  p_meses       integer DEFAULT NULL,   -- NULL = lo resuelve del esquema/proyecto/unidad
  p_dry_run     boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_cuenta      record;
  v_esq         record;
  v_propiedad   bigint;
  v_n_tramos    integer;
  v_monto_mens  numeric;
  v_meses       integer;
  v_orden_base  bigint;
  v_id_final    integer;
  v_primera     date;
  v_insertadas  integer := 0;
BEGIN
  SELECT cc.id, cc.precio_final, cc.fecha_compra, cc.activo, cc.id_oferta,
         cc.id_cuenta_cobranza_padre, cc.id_propiedad AS id_propiedad_cuenta,
         o.id_esquema_pago_seleccionado, o.id_propiedad AS id_propiedad_oferta
  INTO v_cuenta
  FROM cuentas_cobranza cc
  LEFT JOIN ofertas o ON o.id = cc.id_oferta
  WHERE cc.id = p_cuenta_id;

  IF NOT FOUND OR v_cuenta.activo IS NOT TRUE THEN
    RETURN jsonb_build_object('cuenta', p_cuenta_id, 'accion', 'omitido',
                              'motivo', 'cuenta_inexistente_o_inactiva');
  END IF;

  -- Las cuentas hijas de mantenimiento llevan un plan recurrente propio.
  IF v_cuenta.id_cuenta_cobranza_padre IS NOT NULL THEN
    RETURN jsonb_build_object('cuenta', p_cuenta_id, 'accion', 'omitido',
                              'motivo', 'cuenta_hija');
  END IF;

  -- Idempotencia fuerte: ni activas ni dadas de baja. Si alguien borró el plan a mano,
  -- no se le regenera por la espalda.
  IF EXISTS (SELECT 1 FROM acuerdos_pago
             WHERE id_cuenta_cobranza = p_cuenta_id AND id_concepto = 5) THEN
    RETURN jsonb_build_object('cuenta', p_cuenta_id, 'accion', 'omitido',
                              'motivo', 'ya_tiene_parcialidades');
  END IF;

  SELECT e.id, e.es_manual,
         COALESCE(e.porcentaje_mensualidades, 0) AS pct_mens,
         COALESCE(e.numero_mensualidades, 0)     AS num_mens,
         CASE WHEN jsonb_typeof(e.tramos_mensualidad) = 'array'
              THEN e.tramos_mensualidad ELSE '[]'::jsonb END AS tramos
  INTO v_esq
  FROM esquemas_pago e
  WHERE e.id = v_cuenta.id_esquema_pago_seleccionado;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('cuenta', p_cuenta_id, 'accion', 'omitido',
                              'motivo', 'sin_esquema_seleccionado');
  END IF;

  v_propiedad := COALESCE(v_cuenta.id_propiedad_cuenta, v_cuenta.id_propiedad_oferta);

  -- Tramos con monto > 0. Los dos formatos vivos: 'monto' en pesos y
  -- 'monto_mensualidad' en centavos (misma lectura que get_oferta_financials).
  SELECT count(*)
  INTO v_n_tramos
  FROM jsonb_array_elements(v_esq.tramos) elem
  WHERE COALESCE((elem->>'monto')::numeric,
                 (elem->>'monto_mensualidad')::numeric / 100, 0) > 0;

  -- Un esquema de varios tramos cobra montos distintos por periodo; una mensualidad
  -- plana lo cobraría mal. Se marca para revisión en vez de inventar un número.
  IF v_n_tramos > 1 THEN
    RETURN jsonb_build_object('cuenta', p_cuenta_id, 'accion', 'requiere_revision',
                              'motivo', 'esquema_con_multiples_tramos',
                              'esquema', v_esq.id, 'tramos', v_n_tramos);
  END IF;

  -- Monto de la mensualidad: el tramo manda cuando existe. Es un monto en PESOS fijo,
  -- no derivable de un porcentaje (por eso no basta con "rellenar" el esquema).
  v_monto_mens := COALESCE(
    (SELECT COALESCE((elem->>'monto')::numeric,
                     (elem->>'monto_mensualidad')::numeric / 100)
     FROM jsonb_array_elements(v_esq.tramos) elem
     WHERE COALESCE((elem->>'monto')::numeric,
                    (elem->>'monto_mensualidad')::numeric / 100, 0) > 0
     ORDER BY COALESCE((elem->>'orden')::int, 0)
     LIMIT 1),
    CASE WHEN v_esq.num_mens > 0
         THEN v_cuenta.precio_final * v_esq.pct_mens / 100 / v_esq.num_mens
         ELSE 0 END
  );

  -- Número de mensualidades: parámetro explícito > mensualidades fijas de la unidad >
  -- del proyecto > tramos del esquema > numero_mensualidades.
  -- Misma cascada que get_oferta_financials, para que la cuenta cobre exactamente lo
  -- que mostró la oferta.
  v_meses := COALESCE(
    p_meses,
    (SELECT p.mensualidades_fijas FROM propiedades p WHERE p.id = v_propiedad),
    (SELECT pr.mensualidades_fijas
     FROM proyectos pr
     WHERE pr.id = (SELECT ed.id_proyecto FROM edificios ed
                    WHERE ed.id = (SELECT em.id_edificio FROM edificios_modelos em
                                   WHERE em.id = (SELECT p.id_edificio_modelo
                                                  FROM propiedades p WHERE p.id = v_propiedad)))),
    NULLIF((SELECT SUM(COALESCE((elem->>'numero_mensualidades')::int, 0))
            FROM jsonb_array_elements(v_esq.tramos) elem), 0),
    NULLIF(v_esq.num_mens, 0),
    0
  );

  IF v_meses <= 0 OR v_monto_mens <= 0 THEN
    RETURN jsonb_build_object('cuenta', p_cuenta_id, 'accion', 'omitido',
                              'motivo', 'plan_sin_mensualidades',
                              'meses', v_meses, 'monto_mensual', v_monto_mens);
  END IF;

  -- El plan no puede comerse el precio: si las mensualidades superan lo que queda por
  -- cubrir, algo está mal configurado y es mejor no escribir nada.
  IF (v_meses * v_monto_mens) > v_cuenta.precio_final THEN
    RETURN jsonb_build_object('cuenta', p_cuenta_id, 'accion', 'requiere_revision',
                              'motivo', 'plan_excede_precio_final',
                              'meses', v_meses, 'monto_mensual', v_monto_mens,
                              'total_plan', v_meses * v_monto_mens,
                              'precio_final', v_cuenta.precio_final);
  END IF;

  -- Último día del mes SIGUIENTE. fecha_compra puede venir NULL cuando el alta la
  -- dispara el pago del apartado; ahí cuenta desde hoy.
  v_primera := (date_trunc('month', COALESCE(v_cuenta.fecha_compra, CURRENT_DATE))
                + interval '2 month - 1 day')::date;

  SELECT id INTO v_id_final
  FROM acuerdos_pago
  WHERE id_cuenta_cobranza = p_cuenta_id AND id_concepto = 3 AND activo = TRUE
  ORDER BY orden DESC, id DESC LIMIT 1;

  SELECT COALESCE(MAX(orden), 0) INTO v_orden_base
  FROM acuerdos_pago
  WHERE id_cuenta_cobranza = p_cuenta_id AND activo = TRUE AND id_concepto IN (1, 2);

  IF p_dry_run THEN
    RETURN jsonb_build_object('cuenta', p_cuenta_id, 'accion', 'dry_run',
                              'meses', v_meses, 'monto_mensual', round(v_monto_mens, 2),
                              'total', round(v_meses * v_monto_mens, 2),
                              'primera', v_primera,
                              'id_acuerdo_final', v_id_final);
  END IF;

  -- El pago a contra entrega se va al final: fn_reconciliar_acuerdos_cuenta ajusta
  -- SIEMPRE el último acuerdo abierto, y ese tiene que ser él, no una parcialidad.
  IF v_id_final IS NOT NULL THEN
    UPDATE acuerdos_pago SET orden = v_orden_base + v_meses + 1 WHERE id = v_id_final;
  END IF;

  INSERT INTO acuerdos_pago (id_cuenta_cobranza, id_concepto, monto, fecha_pago, orden,
                             pago_completado, activo)
  SELECT p_cuenta_id, 5, round(v_monto_mens, 2),
         (date_trunc('month', v_primera + (g || ' month')::interval)
          + interval '1 month - 1 day')::date,
         v_orden_base + 1 + g,
         false, true
  FROM generate_series(0, v_meses - 1) g;

  GET DIAGNOSTICS v_insertadas = ROW_COUNT;

  RETURN jsonb_build_object('cuenta', p_cuenta_id, 'accion', 'generado',
                            'parcialidades', v_insertadas,
                            'monto_mensual', round(v_monto_mens, 2),
                            'total', round(v_meses * v_monto_mens, 2),
                            'primera', v_primera,
                            'id_acuerdo_final', v_id_final);
END;
$function$;

-- Escribe acuerdos con privilegios de definer (salta RLS). Solo el backend de
-- confianza y el trigger la ejecutan; `authenticated` NO, para que un usuario logueado
-- no pueda generarle plan a cualquier cuenta.
REVOKE ALL ON FUNCTION public.generar_plan_acuerdos_cuenta(bigint, integer, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.generar_plan_acuerdos_cuenta(bigint, integer, boolean) TO service_role;

COMMENT ON FUNCTION public.generar_plan_acuerdos_cuenta(bigint, integer, boolean) IS
  'Genera las parcialidades (concepto 5) de una cuenta a partir de su esquema, entendiendo '
  'tanto los esquemas por porcentaje como los de tramos (monto fijo en pesos). Idempotente. '
  'La dispara el trigger trg_autogenerar_plan_acuerdos al crearse la cuenta.';

-- ─── 2. Trigger: completar el plan en el alta, sin tocar n8n ─────────────────
-- n8n inserta el pago a contra entrega (concepto 3) como ÚLTIMA fila del alta. Ese es
-- el momento en que ya existen apartado y enganche y ya se sabe si hubo parcialidades.

CREATE OR REPLACE FUNCTION public.trg_autogenerar_plan_acuerdos()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_res jsonb;
BEGIN
  -- Reentrada: el propio generador inserta acuerdos.
  IF COALESCE(current_setting('sozu.generando_plan', true), '') = '1' THEN
    RETURN NULL;
  END IF;

  -- Si la cuenta tiene CUALQUIER parcialidad —activa o dada de baja— el plan ya existió
  -- y no es un alta virgen. No se toca.
  IF EXISTS (SELECT 1 FROM acuerdos_pago
             WHERE id_cuenta_cobranza = NEW.id_cuenta_cobranza AND id_concepto = 5) THEN
    RETURN NULL;
  END IF;

  PERFORM set_config('sozu.generando_plan', '1', true);
  BEGIN
    v_res := public.generar_plan_acuerdos_cuenta(NEW.id_cuenta_cobranza, NULL, false);
    RAISE LOG '[autogenerar_plan] %', v_res;
  EXCEPTION WHEN OTHERS THEN
    -- Nunca tumbar el alta de la cuenta por esto: una cuenta sin plan se detecta con
    -- get_cuentas_plan_incompleto(); un apartado que se cae, no se recupera solo.
    RAISE WARNING '[autogenerar_plan] cuenta % falló: % (%)',
      NEW.id_cuenta_cobranza, SQLERRM, SQLSTATE;
  END;
  PERFORM set_config('sozu.generando_plan', '', true);

  RETURN NULL;   -- AFTER trigger
END;
$function$;

DROP TRIGGER IF EXISTS trg_autogenerar_plan_acuerdos ON public.acuerdos_pago;
CREATE TRIGGER trg_autogenerar_plan_acuerdos
AFTER INSERT ON public.acuerdos_pago
FOR EACH ROW
WHEN (NEW.id_concepto = 3 AND NEW.activo = TRUE)
EXECUTE FUNCTION public.trg_autogenerar_plan_acuerdos();

-- ─── 3. Detector de cuentas con el plan incompleto ──────────────────────────
-- Tipos alineados a los reales: cuentas_cobranza.id es bigint; ofertas.id y
-- esquemas_pago.id son integer. Un RETURNS TABLE con el tipo equivocado revienta en
-- ejecución con 42804.
--
-- p_solo_tramos = true (default): solo esquemas por TRAMOS, que es el bug que ataca
-- esta migración. Hoy son exactamente las 5 cuentas escalonadas de Daiku y debe quedar
-- en 0 tras el backfill.
-- p_solo_tramos = false: incluye además 565 cuentas históricas de 2025 con esquema por
-- porcentaje y sin parcialidades (mayoría de contado, solo enganche y ya liquidadas).
-- Ésas NO son este bug y nunca van a llegar a 0; por eso no entran por default.

DROP FUNCTION IF EXISTS public.get_cuentas_plan_incompleto();

CREATE FUNCTION public.get_cuentas_plan_incompleto(p_solo_tramos boolean DEFAULT true)
RETURNS TABLE (
  id_cuenta        bigint,
  id_oferta        integer,
  id_esquema       integer,
  tipo_esquema     text,
  proyecto         text,
  unidad           text,
  meses_esperados  integer,
  parcialidades    integer,
  monto_concepto_3 numeric,
  precio_final     numeric
)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT cc.id, cc.id_oferta, e.id,
         CASE WHEN jsonb_typeof(e.tramos_mensualidad) = 'array'
                   AND jsonb_array_length(e.tramos_mensualidad) > 0
              THEN 'tramos' ELSE 'porcentaje' END,
         pr.nombre, p.numero_propiedad,
         GREATEST(
           COALESCE(NULLIF((SELECT SUM(COALESCE((elem->>'numero_mensualidades')::int, 0))
                            FROM jsonb_array_elements(
                                   CASE WHEN jsonb_typeof(e.tramos_mensualidad) = 'array'
                                        THEN e.tramos_mensualidad ELSE '[]'::jsonb END) elem), 0), 0),
           COALESCE(e.numero_mensualidades, 0)
         )::int,
         (SELECT count(*)::int FROM acuerdos_pago a
          WHERE a.id_cuenta_cobranza = cc.id AND a.id_concepto = 5 AND a.activo = TRUE),
         (SELECT COALESCE(SUM(a.monto), 0) FROM acuerdos_pago a
          WHERE a.id_cuenta_cobranza = cc.id AND a.id_concepto = 3 AND a.activo = TRUE),
         cc.precio_final
  FROM cuentas_cobranza cc
  JOIN ofertas o        ON o.id = cc.id_oferta
  JOIN esquemas_pago e  ON e.id = o.id_esquema_pago_seleccionado
  LEFT JOIN propiedades p        ON p.id = COALESCE(cc.id_propiedad, o.id_propiedad)
  LEFT JOIN edificios_modelos em ON em.id = p.id_edificio_modelo
  LEFT JOIN edificios ed         ON ed.id = em.id_edificio
  LEFT JOIN proyectos pr         ON pr.id = ed.id_proyecto
  WHERE COALESCE(cc.activo, true)
    AND cc.id_cuenta_cobranza_padre IS NULL
    AND GREATEST(
          COALESCE(NULLIF((SELECT SUM(COALESCE((elem->>'numero_mensualidades')::int, 0))
                           FROM jsonb_array_elements(
                                  CASE WHEN jsonb_typeof(e.tramos_mensualidad) = 'array'
                                       THEN e.tramos_mensualidad ELSE '[]'::jsonb END) elem), 0), 0),
          COALESCE(e.numero_mensualidades, 0)
        ) > 0
    AND NOT EXISTS (SELECT 1 FROM acuerdos_pago a
                    WHERE a.id_cuenta_cobranza = cc.id AND a.id_concepto = 5 AND a.activo = TRUE)
    AND (NOT p_solo_tramos
         OR (jsonb_typeof(e.tramos_mensualidad) = 'array'
             AND jsonb_array_length(e.tramos_mensualidad) > 0))
  ORDER BY cc.id;
$function$;

-- Solo lectura y sin PII del titular: el panel la puede consultar. anon no.
REVOKE ALL ON FUNCTION public.get_cuentas_plan_incompleto(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_cuentas_plan_incompleto(boolean) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_cuentas_plan_incompleto(boolean) IS
  'Cuentas activas cuyo esquema define mensualidades pero que no tienen ni una '
  'parcialidad (concepto 5) activa. Por default solo esquemas por tramos (el bug del '
  'escalonado): 5 filas hoy, 0 tras el backfill. Con p_solo_tramos = false suma 565 '
  'cuentas históricas de 2025 por porcentaje, que son otro asunto.';
