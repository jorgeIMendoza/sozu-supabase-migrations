-- El recálculo de pagos deja de retroceder el estatus de la propiedad.
-- Fecha: 2026-08-18
--
-- Ciclo de vida: APARTADO(4) → VENDIDO(5) → PAGADA COMPLETAMENTE(9) → ESCRITURACIÓN(7)
-- → ENTREGADO(8). El 9 va ANTES que el 7 y el 8, así que escribir 9 sobre una propiedad
-- entregada la regresa dos pasos.
--
-- actualizar_estatus_propiedad_pagada() (trigger AFTER INSERT OR UPDATE sobre
-- aplicaciones_pago, WHEN new.activo) tiene DOS defectos, los dos por confiar en la cuenta
-- equivocada y en la guarda equivocada:
--
--   1. Sube la propiedad a 9 con una sola guarda, `id_estatus_disponibilidad != 9`, que
--      únicamente evita reescribir el mismo valor. No mira si la propiedad ya avanzó a
--      escrituración (7), entrega (8), asignado (10), demanda (11) o dación (12).
--   2. Resuelve la propiedad desde CUALQUIER cuenta de cobranza, sin el filtro
--      `o.id_producto IS NULL` que sí tiene su gemela revertir_estatus_si_hay_pendiente(),
--      y cuenta los acuerdos de la cuenta que disparó, no los de la principal. Liquidar la
--      bodega o el estacionamiento —1 a 3 parcialidades— promueve la propiedad a 9 con la
--      principal todavía debiendo.
--
-- Cadena al pulsar "Recalcular pagos": la EF recalcular-aplicaciones borra e inserta
-- aplicaciones_pago → trg_recalc_pago_completado marca los acuerdos como pagados → este
-- trigger sube la propiedad a 9 → si además queda saldo contra precio_final,
-- revertir_estatus_si_hay_pendiente la baja de 9 a 5. Neto: 8 → 5.
--
-- Verificado read-only en prod el 2026-08-18:
--   · Propiedades con acta de entrega (id_tipo_documento = 24) y estatus distinto de 8:
--       5 en Vendido (4857, 4915, 4917, 4976, 5074)
--       2 en Disponible (5062, 5085) — se revisan aparte, probablemente re-listadas
--       1 en Dación en pago (4985) — desenlace legítimo
--     Las 10 que estaban en 9 ya fueron revertidas a 8 por fuera de esta migración.
--   · 607 propiedades con cuenta activa; 503 de ellas tienen además cuentas de producto.
--     Caso probado, propiedad 4917: cuenta principal 396 (oferta 463, id_producto NULL)
--     con 52 de 53 acuerdos pagados, y las cuentas de producto 1032 (id_producto 6) y
--     1033 (id_producto 12) liquidadas, promoviéndola.
--   · Ninguna propiedad tiene más de una cuenta activa con id_producto NULL, así que el
--     filtro no vuelve ambigua la resolución.
--   · Una sola propiedad (4849) tiene su única cuenta activa con id_producto (981,
--     estacionamiento): deja de promoverse, pero está en estatus 2 (Disponible), que la
--     guarda `IN (4, 5)` tampoco promovería. Sin pérdida real.
--
-- El histórico ya dañado NO se corrige aquí: las propiedades a revertir van en DML aparte.
--
-- Anclada a la definición viva verificada en prod el 2026-08-18
-- (md5(prosrc) = 50fbd579213b680e3d0035ab944e106d, 2102 chars).
-- Idempotente y self-guarded. Sin BEGIN/COMMIT (el CI/CD envuelve en tx).

-- ─── 0. Anchor: abortar si la función viva no es la esperada ─────────────────
DO $anchor$
DECLARE
  v_src text;
BEGIN
  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'actualizar_estatus_propiedad_pagada';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'anchor: public.actualizar_estatus_propiedad_pagada() no existe';
  END IF;

  -- Acepta el estado previo (guarda `!= 9`) y el ya migrado (guarda `IN (4, 5)`).
  IF position('id_estatus_disponibilidad != 9' IN v_src) = 0
     AND position('id_estatus_disponibilidad IN (4, 5)' IN v_src) = 0
  THEN
    RAISE EXCEPTION
      'anchor: actualizar_estatus_propiedad_pagada cambió (md5=%); revisar drift antes de reemplazar',
      md5(v_src);
  END IF;
END
$anchor$;

-- ─── 1. La función: solo la cuenta principal, y solo promover desde 4 o 5 ────

CREATE OR REPLACE FUNCTION public.actualizar_estatus_propiedad_pagada()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id_cuenta_cobranza INTEGER;
  v_id_oferta INTEGER;
  v_id_propiedad BIGINT;
  v_total_acuerdos INTEGER;
  v_acuerdos_completados INTEGER;
  v_todos_completados BOOLEAN := FALSE;
BEGIN
  -- Obtener id_cuenta_cobranza desde el acuerdo de pago
  SELECT id_cuenta_cobranza INTO v_id_cuenta_cobranza
  FROM acuerdos_pago
  WHERE id = NEW.id_acuerdo_pago
    AND activo = true;

  IF v_id_cuenta_cobranza IS NULL THEN
    RETURN NEW;
  END IF;

  -- Obtener id_oferta de la cuenta de cobranza
  SELECT id_oferta INTO v_id_oferta
  FROM cuentas_cobranza
  WHERE id = v_id_cuenta_cobranza
    AND activo = true;

  IF v_id_oferta IS NULL THEN
    RETURN NEW;
  END IF;

  -- Guarda 1 de 2. Solo la cuenta PRINCIPAL decide el estatus de la propiedad. Sin el
  -- filtro `id_producto IS NULL` bastaba con liquidar la cuenta de una bodega o un
  -- estacionamiento —que suelen tener 1 a 3 acuerdos— para que v_todos_completados diera
  -- true y la propiedad subiera a 9 con la principal todavía debiendo. En prod hay 503
  -- propiedades con cuentas de producto además de la principal. Caso probado: propiedad
  -- 4917, cuenta principal 396 con 52 de 53 acuerdos pagados, y las cuentas de producto
  -- 1032 y 1033 liquidadas promoviéndola.
  -- `revertir_estatus_si_hay_pendiente` ya trae este mismo filtro.
  SELECT o.id_propiedad INTO v_id_propiedad
  FROM ofertas o
  WHERE o.id = v_id_oferta
    AND o.id_producto IS NULL;

  -- Sale también cuando la oferta no es de propiedad (producto/servicio)
  IF v_id_propiedad IS NULL THEN
    RETURN NEW;
  END IF;

  -- Verificar si TODOS los acuerdos activos de la cuenta principal están completados
  SELECT
    COUNT(*) as total,
    COUNT(CASE WHEN pago_completado = true THEN 1 END) as completados
  INTO v_total_acuerdos, v_acuerdos_completados
  FROM acuerdos_pago
  WHERE id_cuenta_cobranza = v_id_cuenta_cobranza
    AND activo = true;

  v_todos_completados := (v_total_acuerdos > 0 AND v_total_acuerdos = v_acuerdos_completados);

  IF v_todos_completados THEN
    -- Guarda 2 de 2: el estatus 9 va ANTES que escrituración (7) y entrega (8) en el ciclo
    -- (4 → 5 → 9 → 7 → 8), así que solo se promueve desde apartado o vendido. Antes la
    -- única guarda era `!= 9` y por eso un recálculo de dispersión regresaba una
    -- propiedad Entregada a Pagada completamente — y, encadenado con
    -- revertir_estatus_si_hay_pendiente, hasta Vendido.
    -- Nunca se pisa 7 (escrituración), 8 (entregado), 10 (asignado), 11 (en demanda)
    -- ni 12 (dación en pago).
    UPDATE propiedades
    SET id_estatus_disponibilidad = 9  -- Pagada completamente
    WHERE id = v_id_propiedad
      AND id_estatus_disponibilidad IN (4, 5);

    RAISE LOG 'Propiedad %: acuerdos % de % completados',
      v_id_propiedad, v_acuerdos_completados, v_total_acuerdos;
  ELSE
    RAISE LOG 'Propiedad %: acuerdos % de % completados - NO actualizar estatus',
      v_id_propiedad, v_acuerdos_completados, v_total_acuerdos;
  END IF;

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.actualizar_estatus_propiedad_pagada() IS
  'Promueve la propiedad a Pagada completamente (9) cuando todos los acuerdos activos de '
  'la cuenta PRINCIPAL están pagados (id_producto IS NULL: bodegas y estacionamientos no '
  'deciden el estatus de la propiedad). Solo promueve desde Apartado (4) o Vendido (5): '
  'nunca pisa escrituración (7), entrega (8), asignado (10), demanda (11) ni dación (12).';
