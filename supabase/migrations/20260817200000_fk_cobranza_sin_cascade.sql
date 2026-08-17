-- 20260817200000_fk_cobranza_sin_cascade.sql
-- Propósito: cerrar una ruta de borrado en cascada del histórico financiero y declarar la
-- FK que faltaba entre cuentas_cobranza y propiedades.
--
-- Nota de versión: este archivo nació como 20260817190000 y se renombró. Ese timestamp lo
-- tomó en paralelo 20260817190000_portal_personal_menu_submenus_permisos.sql (PR #610), que
-- se mergeó primero y ganó la fila en supabase_migrations.schema_migrations, cuya PK es solo
-- la versión. Con las dos versiones iguales, `supabase db push` reventó en deploy-dev con
-- "duplicate key value violates unique constraint schema_migrations_pkey" y esta migración
-- nunca llegó a aplicarse.
--
-- PUNTO 1 — CASCADE escondido detrás de una FK duplicada
--
-- Dos columnas tienen HOY dos foreign keys hacia la misma tabla, con acciones distintas:
--
--   pagos.id_cuenta_cobranza      fk_pagos_cuenta               ON DELETE/UPDATE CASCADE
--   pagos.id_cuenta_cobranza      pagos_id_cuenta_cobranza_fkey NO ACTION
--   cuentas_cobranza.id_oferta    fk_ccob_oferta                ON DELETE/UPDATE CASCADE
--   cuentas_cobranza.id_oferta    fk_cuentas_cobranza_oferta    NO ACTION
--
-- Las dos se disparan en el mismo DELETE. La CASCADE borra los hijos primero, así que
-- cuando la NO ACTION verifica al final de la sentencia ya no encuentra referencias y deja
-- pasar la operación: el comportamiento efectivo es CASCADE. La FK NO ACTION no protege
-- nada. En la práctica:
--
--   DELETE FROM ofertas WHERE id = X
--     └─► borra sus cuentas_cobranza            (fk_ccob_oferta, CASCADE)
--           └─► borra los pagos de esas cuentas (fk_pagos_cuenta, CASCADE)
--
-- Esto NO es solo un riesgo de borrado manual: la policy ofertas_passthrough_write es
-- FOR ALL TO authenticated USING (current_socio_bancario_id() IS NULL), de modo que
-- cualquier usuario logueado que no sea socio bancario puede ejecutar
-- DELETE /rest/v1/ofertas?id=eq.X y llevarse pagos por delante. (anon tiene el GRANT de
-- DELETE pero no tiene policy de DELETE, así que RLS lo frena.)
--
-- El sistema no borra en duro por diseño: pagos tiene activo, eliminado_por y
-- fecha_eliminacion. Medido en prod el 2026-08-17: 22 886 pagos, 44 inactivos, 38 cuentas
-- de cobranza inactivas con 243 pagos colgando de ellas. La baja lógica es la vía real; la
-- cascada es un camino paralelo que nadie pidió.
--
-- Decisión (Eduardo, 2026-08-17): se conservan las NO ACTION y se eliminan las CASCADE.
-- Se verificó que ningún flujo depende de la cascada:
--   * sozu-admin no borra en duro ofertas, cuentas_cobranza, propiedades ni pagos.
--   * sozu-edge-functions/asignar-propiedad hace rollback compensatorio borrando primero
--     cuentas_cobranza y después ofertas (orden explícito hijo→padre), sobre filas recién
--     creadas y sin pagos. Sigue funcionando sin la cascada.
--
-- PUNTO 2 — la FK que falta
--
-- cuentas_cobranza.id_propiedad guarda un propiedades.id en 1 439 filas, pero la relación
-- nunca se declaró: Postgres no la valida y PostgREST no puede unir las tablas en una sola
-- llamada. Verificado el 2026-08-17: 0 huérfanas en dev y en prod, así que el ALTER pasa
-- sin limpieza previa. Nota de tipos: id_propiedad es integer y propiedades.id es bigint;
-- la FK int4→int8 es válida (misma familia de operadores btree) y replica la asimetría que
-- ya existe en pagos.id_cuenta_cobranza (integer) → cuentas_cobranza.id (bigint).
--
-- LO QUE ESTA MIGRACIÓN NO ARREGLA (decisión aparte, no bloquea)
--
-- Borrar una cuenta_cobranza sigue cascadeando hacia acuerdos_pago, comisionistas,
-- compradores, legal_flow_bitacora y notificaciones_agente/cliente, que conservan su
-- ON DELETE CASCADE. Con esta migración, si la cuenta tiene pagos el DELETE aborta y toda
-- la sentencia hace rollback; si no los tiene, esos hijos sí se van. Es justo lo que
-- necesita el rollback de asignar-propiedad, por eso se deja como está.
--
-- Efectos secundarios buscados:
--   * Borrar en duro una oferta con cuentas de cobro → error de FK en vez de cascada.
--   * Borrar en duro una cuenta con pagos → error de FK en vez de cascada.
--   * Borrar en duro una propiedad con cuentas de cobro → error de FK en vez de dejar la
--     cuenta apuntando al vacío.
--   * Se pierde también el ON UPDATE CASCADE de las dos FK eliminadas. Son PK de identidad
--     que nadie reasigna, así que no hay impacto real.
--
-- Rollback al final del archivo.

BEGIN;

-- 1. Antes de tocar nada: garantizar que la FK NO ACTION que se queda existe de verdad.
--    Si alguien la hubiera borrado antes, dropear la CASCADE dejaría la columna sin
--    ninguna FK. Idempotente: no-op cuando ya está (el caso de dev y prod hoy).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.pagos'::regclass
      AND conname  = 'pagos_id_cuenta_cobranza_fkey'
  ) THEN
    ALTER TABLE public.pagos
      ADD CONSTRAINT pagos_id_cuenta_cobranza_fkey
      FOREIGN KEY (id_cuenta_cobranza) REFERENCES public.cuentas_cobranza(id)
      ON DELETE NO ACTION ON UPDATE NO ACTION;
    RAISE NOTICE 'Se repuso pagos_id_cuenta_cobranza_fkey (no existía).';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.cuentas_cobranza'::regclass
      AND conname  = 'fk_cuentas_cobranza_oferta'
  ) THEN
    ALTER TABLE public.cuentas_cobranza
      ADD CONSTRAINT fk_cuentas_cobranza_oferta
      FOREIGN KEY (id_oferta) REFERENCES public.ofertas(id)
      ON DELETE NO ACTION ON UPDATE NO ACTION;
    RAISE NOTICE 'Se repuso fk_cuentas_cobranza_oferta (no existía).';
  END IF;
END $$;

-- 2. Fuera las CASCADE duplicadas.
ALTER TABLE public.pagos
  DROP CONSTRAINT IF EXISTS fk_pagos_cuenta;

ALTER TABLE public.cuentas_cobranza
  DROP CONSTRAINT IF EXISTS fk_ccob_oferta;

-- 3. La FK faltante a propiedades. Se comprueban las huérfanas primero para fallar con un
--    mensaje legible en lugar del error genérico del ALTER.
DO $$
DECLARE
  v_huerfanas bigint;
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.cuentas_cobranza'::regclass
      AND conname  = 'fk_cuentas_cobranza_propiedad'
  ) THEN
    RETURN;
  END IF;

  SELECT count(*) INTO v_huerfanas
  FROM public.cuentas_cobranza c
  WHERE c.id_propiedad IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.propiedades p WHERE p.id = c.id_propiedad);

  IF v_huerfanas > 0 THEN
    RAISE EXCEPTION
      'cuentas_cobranza tiene % fila(s) con id_propiedad inexistente en propiedades. Limpiarlas antes de declarar la FK.',
      v_huerfanas;
  END IF;

  ALTER TABLE public.cuentas_cobranza
    ADD CONSTRAINT fk_cuentas_cobranza_propiedad
    FOREIGN KEY (id_propiedad) REFERENCES public.propiedades(id)
    ON DELETE NO ACTION ON UPDATE NO ACTION;
END $$;

COMMENT ON CONSTRAINT fk_cuentas_cobranza_propiedad ON public.cuentas_cobranza IS
  'Integridad de id_propiedad y relación explícita para embeds de PostgREST. NO ACTION a propósito: una propiedad con cuentas de cobro no se borra en duro.';

-- 4. Self-verifying: la migración solo puede terminar con exactamente una FK por columna y
--    ninguna en CASCADE. Si queda otra sobrecarga o una acción distinta, aborta el deploy
--    en vez de dejar el CI en verde con la cascada viva.
DO $$
DECLARE
  v_detalle text;
  v_total   int;
  v_malas   int;
BEGIN
  SELECT count(*),
         count(*) FILTER (WHERE con.confdeltype <> 'a' OR con.confupdtype <> 'a'),
         string_agg(rel.relname || '.' || att.attname || ' → ' || con.conname ||
                    ' [del=' || con.confdeltype::text || ',upd=' || con.confupdtype::text || ']', ', '
                    ORDER BY rel.relname, att.attname, con.conname)
    INTO v_total, v_malas, v_detalle
  FROM pg_constraint con
  JOIN pg_class rel ON rel.oid = con.conrelid
  JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
  WHERE con.contype = 'f'
    AND array_length(con.conkey, 1) = 1
    AND (rel.relname, att.attname) IN (('pagos', 'id_cuenta_cobranza'),
                                       ('cuentas_cobranza', 'id_oferta'),
                                       ('cuentas_cobranza', 'id_propiedad'));

  IF v_total <> 3 OR v_malas > 0 THEN
    RAISE EXCEPTION
      'Estado inesperado de las FK de cobranza (esperado: 3 FK, todas NO ACTION). Encontrado: %',
      coalesce(v_detalle, 'ninguna');
  END IF;
END $$;

COMMIT;

-- ROLLBACK (ejecutar solo si se decide volver al borrado en cascada):
--
--   ALTER TABLE public.cuentas_cobranza DROP CONSTRAINT fk_cuentas_cobranza_propiedad;
--
--   ALTER TABLE public.pagos ADD CONSTRAINT fk_pagos_cuenta
--     FOREIGN KEY (id_cuenta_cobranza) REFERENCES public.cuentas_cobranza(id)
--     ON DELETE CASCADE ON UPDATE CASCADE;
--
--   ALTER TABLE public.cuentas_cobranza ADD CONSTRAINT fk_ccob_oferta
--     FOREIGN KEY (id_oferta) REFERENCES public.ofertas(id)
--     ON DELETE CASCADE ON UPDATE CASCADE;
--
-- VERIFICACIÓN POSTERIOR:
--
--   SELECT rel.relname, att.attname, con.conname,
--          CASE con.confdeltype WHEN 'a' THEN 'NO ACTION' WHEN 'c' THEN 'CASCADE'
--                               WHEN 'r' THEN 'RESTRICT'  WHEN 'n' THEN 'SET NULL' END AS on_delete
--   FROM pg_constraint con
--   JOIN pg_class rel ON rel.oid = con.conrelid
--   JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
--   WHERE con.contype = 'f'
--     AND (rel.relname, att.attname) IN (('pagos','id_cuenta_cobranza'),
--                                        ('cuentas_cobranza','id_oferta'),
--                                        ('cuentas_cobranza','id_propiedad'))
--   ORDER BY 1, 2;                       -- esperado: 3 filas, todas NO ACTION
--
--   SELECT count(*) FROM public.pagos;   -- esperado: 22 886 (medido en prod 2026-08-17)
