-- Limpieza · DROP de los objetos legacy con prefijo `borrar_`
-- Fecha: 2026-07-28
--
-- ⚠️ MIGRACIÓN DESTRUCTIVA E IRREVERSIBLE. No hay copia de estos datos fuera del backup
--    de la instancia. Confirmar respaldo (PITR / dump) antes del deploy.
--
-- ALCANCE (verificado read-only contra prod tzmhgfjmddkfyffkkmto, 2026-07-28):
--   · 46 tablas `public.borrar_*` — staging de la migración legacy, ~250 MB en total.
--   · 11 funciones `public.borrar_sp_*` — cargadores que solo leen esas tablas de staging;
--     quedarían huérfanos y roto su cuerpo tras el DROP.
--   · 1 vista `public.v_pagos_efectivo` — su única fuente es `borrar_pagos_bottura`, por lo
--     que no puede sobrevivir al DROP. Sin uso en sozu-admin ni en sozu-edge-functions
--     (solo aparece en types.ts generado y en un .md de auditoría).
--
-- BENEFICIO DE SEGURIDAD ADICIONAL: estas tablas viven en `public`, o sea que PostgREST las
--   expone y anon tiene SELECT sobre ellas. Contienen pagos, personas, RFC/CURP y cuentas
--   bancarias del histórico. El DROP elimina esa superficie por completo.
--
-- REVISADO ANTES DE INCLUIRLAS:
--   · Sin FKs entrantes desde tablas fuera del conjunto `borrar_*`.
--   · Sin referencias en código (sozu-admin, sozu-edge-functions) fuera de types.ts.
--   · `borrar_pagos_stp_raw_duplicate` (1 388 filas): las 1 388 claves de rastreo existen
--     todas en `public.pagos_stp_raw` (12 423 filas), que NO se toca. Sin pérdida de datos
--     únicos. Igual conviene que Jorge confirme este caso y los otros dos de STP
--     (`borrar_pagos_stp_cuentas_437_y_445`, `borrar_stp_propiedades`) antes del deploy.
--
-- Idempotente (IF EXISTS). Un DROP TABLE único resuelve las FKs internas del conjunto.
-- Sin CASCADE a propósito: si algún objeto no previsto dependiera de estas tablas, la
-- migración debe fallar en el CI en lugar de arrastrarlo en silencio.
-- Sin BEGIN/COMMIT (el CI envuelve en transacción).

-- DROP dinámico: cubre TODAS las public.borrar_* (incluye leftovers que no estaban en la
-- lista fija verificada contra prod, p.ej. en dev: borrar_auditoria_pagos,
-- borrar_pagos_bottura_copia, borrar_pagos_bottura_corregido). Sin CASCADE (si algo externo
-- no previsto dependiera de estas tablas, el DROP falla en CI en vez de arrastrarlo).

-- 1) Vistas primero (dependen de tablas borrar_*).
--    v_pagos_efectivo (no lleva prefijo borrar_) depende de borrar_pagos_bottura.
DROP VIEW IF EXISTS public.v_pagos_efectivo;
DO $$
DECLARE v_list text;
BEGIN
  SELECT string_agg(format('public.%I', c.relname), ', ') INTO v_list
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relname LIKE 'borrar\_%' AND c.relkind = 'v';
  IF v_list IS NOT NULL THEN EXECUTE 'DROP VIEW IF EXISTS ' || v_list; END IF;

  SELECT string_agg(format('public.%I', c.relname), ', ') INTO v_list
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relname LIKE 'borrar\_%' AND c.relkind = 'm';
  IF v_list IS NOT NULL THEN EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS ' || v_list; END IF;
END $$;

-- 2) Funciones/cargadores borrar_*
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname LIKE 'borrar\_%'
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig;
  END LOOP;
END $$;

-- 3) Tablas de staging legacy — todas en UNA sentencia (resuelve FKs internas del conjunto).
DO $$
DECLARE v_list text;
BEGIN
  SELECT string_agg(format('public.%I', c.relname), ', ') INTO v_list
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relname LIKE 'borrar\_%' AND c.relkind IN ('r', 'p');
  IF v_list IS NOT NULL THEN EXECUTE 'DROP TABLE IF EXISTS ' || v_list; END IF;
END $$;

-- Verificación: no debe quedar ningún objeto `borrar_*` en public.
DO $$
DECLARE
  v_rel  text;
  v_fun  text;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO v_rel
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relname LIKE 'borrar\_%'
    AND c.relkind IN ('r', 'p', 'v', 'm', 'f');

  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_fun
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname LIKE 'borrar\_%';

  IF v_rel IS NOT NULL THEN
    RAISE EXCEPTION 'Quedan relaciones borrar_* en public: %', v_rel;
  END IF;
  IF v_fun IS NOT NULL THEN
    RAISE EXCEPTION 'Quedan funciones borrar_* en public: %', v_fun;
  END IF;

  RAISE NOTICE 'Verificación OK: sin objetos borrar_* en public';
END $$;

-- POST-DEPLOY (fuera de este repo): regenerar
--   sozu-admin/src/integrations/supabase/types.ts
-- para que dejen de aparecer las 46 tablas y v_pagos_efectivo.
