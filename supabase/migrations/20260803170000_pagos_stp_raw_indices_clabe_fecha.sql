-- Rendimiento · Índices de búsqueda en public.pagos_stp_raw
-- Fecha: 2026-08-03
--
-- QUÉ RESUELVE
--   La columna "Pagos STP" del listado de Propiedades (/admin/propiedades) cruza
--   `pagos_stp_raw.cuenta_beneficiario` contra las dos CLABEs posibles de cada propiedad
--   —`propiedades.clabe_stp_tmp_apartado` mientras no hay cuenta de cobranza, y
--   `cuentas_cobranza.clabe_stp` una vez generada— para confirmar en la propia unidad que un
--   depósito cayó (típicamente el de prueba de $1), sin salir a Rastreo Pagos STP.
--
--   Hoy no existe índice por `cuenta_beneficiario` ni por `fecha_creacion`, así que esa
--   consulta hace Seq Scan. Medido en prod: 5.5 ms y 536 buffers por página, descartando
--   12,272 filas para quedarse con 169. Funciona, pero el costo crece lineal con la tabla.
--
--   NO es un bloqueante: el front ya opera sin estos índices. Esto es para que siga siendo
--   rápido cuando la tabla crezca.
--
-- POR QUÉ NO SE USA `CONCURRENTLY` (corrección sobre la especificación)
--   La especificación pedía `CREATE INDEX CONCURRENTLY` para no bloquear las inserciones de
--   n8n. No se puede: `supabase db push` envuelve cada migración en una transacción y
--   CONCURRENTLY no es transaccionable. Comprobado:
--     BEGIN; CREATE INDEX CONCURRENTLY ...
--     ERROR:  CREATE INDEX CONCURRENTLY cannot run inside a transaction block
--   Eso reventaría el deploy y bloquearía la cola de migraciones. Con 12,516 filas el
--   CREATE INDEX normal tarda milisegundos, así que el ACCESS EXCLUSIVE dura lo mismo: la
--   ventana en la que la conciliación STP podría esperar es despreciable frente a romper el
--   CI. Como efecto colateral desaparece el riesgo de quedarse con un índice INVALID por una
--   creación concurrente interrumpida.
--
-- QUÉ ESPERAR DEL PLAN (medido sobre una réplica con la misma forma: 12,516 filas,
-- 1,093 CLABEs distintas)
--   · Consulta del front (`cuenta_beneficiario = ANY(...)` + ORDER BY fecha_creacion DESC
--     + LIMIT 5000): Bitmap Index Scan sobre idx_pagos_stp_raw_clabe_fecha. Buffers de 536
--     a 17 y tiempo de 5.5 ms a ~0.2 ms.
--     OJO: el nodo `Sort` NO desaparece, y eso es correcto. Con `= ANY(array)` el bitmap no
--     preserva el orden, y con LIMIT 5000 muy por encima de las filas que matchean el
--     planner prefiere bitmap + sort a un index scan ordenado. La especificación afirmaba lo
--     contrario; quien valide el plan no debe leer ese `Sort` como que el índice no sirvió.
--   · Listado por defecto de Rastreo Pagos STP (ORDER BY fecha_creacion DESC LIMIT 50):
--     Index Scan sobre idx_pagos_stp_raw_fecha_creacion, sin `Sort`, ~0.08 ms.
--
--   La segunda columna del compuesto no aporta a la consulta de Propiedades: un índice
--   simple sobre (cuenta_beneficiario) daría el mismo plan. Se deja compuesto porque sirve
--   al día que se filtre por rango de fechas dentro de una CLABE, y porque el costo de la
--   columna extra es marginal a este volumen.
--
-- OTROS CONSUMIDORES DE LA TABLA (contexto, no requieren cambios)
--   · PagoProveedores.tsx filtra `in(cuenta_beneficiario, …)` pero ordena por
--     `fecha_operacion`: aprovecha el filtro, no el orden.
--   · RastreoPagosSTP.tsx busca CLABE con `ilike '%…%'`: ningún btree puede servir eso; si
--     esa búsqueda se vuelve lenta hará falta pg_trgm, no este índice.
--
-- Riesgo de datos: ninguno. No cambia filas, columnas, permisos ni funciones.
-- Idempotente (IF NOT EXISTS) y self-verifying.
-- Sin BEGIN/COMMIT (el CI envuelve en transacción).

-- 1) Cruce propiedad → depósitos STP (columna "Pagos STP" en /admin/propiedades).
CREATE INDEX IF NOT EXISTS idx_pagos_stp_raw_clabe_fecha
  ON public.pagos_stp_raw (cuenta_beneficiario, fecha_creacion DESC);

COMMENT ON INDEX public.idx_pagos_stp_raw_clabe_fecha IS
  'Depósitos STP por CLABE beneficiaria, más recientes primero. Lo usa la columna Pagos STP '
  'de /admin/propiedades (cruce contra propiedades.clabe_stp_tmp_apartado y '
  'cuentas_cobranza.clabe_stp) y el filtro por cuenta de /admin/pago-proveedores.';

-- 2) Listado por defecto de Rastreo Pagos STP (ORDER BY fecha_creacion DESC LIMIT 50).
CREATE INDEX IF NOT EXISTS idx_pagos_stp_raw_fecha_creacion
  ON public.pagos_stp_raw (fecha_creacion DESC);

COMMENT ON INDEX public.idx_pagos_stp_raw_fecha_creacion IS
  'Orden cronológico inverso para el listado de /admin/rastreo-pagos-stp.';

-- -----------------------------------------------------------------------------
-- Self-verifying: los dos índices existen, son válidos y tienen la definición
-- esperada. Un índice INVALID no lo usa el planner: mejor abortar aquí.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  r        record;
  v_nombre text;
BEGIN
  FOREACH v_nombre IN ARRAY ARRAY['idx_pagos_stp_raw_clabe_fecha',
                                  'idx_pagos_stp_raw_fecha_creacion']
  LOOP
    IF to_regclass('public.' || v_nombre) IS NULL THEN
      RAISE EXCEPTION 'No se creó el índice %', v_nombre;
    END IF;

    SELECT i.indisvalid, i.indisready INTO r
    FROM pg_index i
    WHERE i.indexrelid = to_regclass('public.' || v_nombre);

    IF NOT r.indisvalid OR NOT r.indisready THEN
      RAISE EXCEPTION 'El índice % quedó INVALID/NOT READY', v_nombre;
    END IF;
  END LOOP;

  IF pg_get_indexdef(to_regclass('public.idx_pagos_stp_raw_clabe_fecha'))
     NOT LIKE '%cuenta_beneficiario, fecha_creacion DESC%' THEN
    RAISE EXCEPTION 'idx_pagos_stp_raw_clabe_fecha no quedó con las columnas esperadas: %',
      pg_get_indexdef(to_regclass('public.idx_pagos_stp_raw_clabe_fecha'));
  END IF;

  RAISE NOTICE 'Índices de pagos_stp_raw OK (clabe_fecha y fecha_creacion, ambos válidos)';
END $$;
