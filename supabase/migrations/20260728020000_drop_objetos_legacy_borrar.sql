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

-- 1) Vista dependiente de borrar_pagos_bottura
DROP VIEW IF EXISTS public.v_pagos_efectivo;

-- 2) Cargadores de staging
DROP FUNCTION IF EXISTS public.borrar_sp_cargar_amenidades_proyectos_desde_stagin();
DROP FUNCTION IF EXISTS public.borrar_sp_cargar_edificio_modelo();
DROP FUNCTION IF EXISTS public.borrar_sp_cargar_edificios_desde_stagin();
DROP FUNCTION IF EXISTS public.borrar_sp_cargar_modelos_caracteristicas_desde_stagin();
DROP FUNCTION IF EXISTS public.borrar_sp_cargar_modelos_desde_stagin();
DROP FUNCTION IF EXISTS public.borrar_sp_cargar_multimedias_modelo_desde_stagin();
DROP FUNCTION IF EXISTS public.borrar_sp_cargar_multimedias_proyecto();
DROP FUNCTION IF EXISTS public.borrar_sp_cargar_proyectos_desde_stagin();
DROP FUNCTION IF EXISTS public.borrar_sp_cargar_videos_youtube_proyecto();
DROP FUNCTION IF EXISTS public.borrar_sp_esquemas_pago_proyecto();
DROP FUNCTION IF EXISTS public.borrar_sp_vistas();

-- 3) Tablas de staging legacy
DROP TABLE IF EXISTS
  public.borrar_acuerdos_pago_manto_stagin,
  public.borrar_acuerdos_pago_productos_stagin,
  public.borrar_acuerdos_pago_stagin,
  public.borrar_amenidades_proyectos_stagin,
  public.borrar_aplicacion_pagos_migracion,
  public.borrar_audit_errores,
  public.borrar_audit_pagos,
  public.borrar_audit_splits,
  public.borrar_bancos_banxico,
  public.borrar_bodegas_estacionamientos_daiku_stagin,
  public.borrar_bodegas_stagin,
  public.borrar_brochures_proyecto_stagin,
  public.borrar_cuentas_bancarias_stagin,
  public.borrar_cuentas_cobranza_mantenimientos_stagin,
  public.borrar_cuentas_cobranza_productos_stagin,
  public.borrar_cuentas_cobranza_stagin,
  public.borrar_documentos_stagin,
  public.borrar_duenos_desarrolladoras_proyecto_stagin,
  public.borrar_edificios_stagin,
  public.borrar_esquemas_pago_stagin,
  public.borrar_estacionamientos_stagin,
  public.borrar_historico_completo,
  public.borrar_leads_hs_manuel_stagin,
  public.borrar_modelos_caracteristicas_stagin,
  public.borrar_modelos_stagin,
  public.borrar_multimedias_modelo_stagin,
  public.borrar_multimedias_todo_stagin,
  public.borrar_ofertas_esquemas_pago_productos_stagin,
  public.borrar_ofertas_stagin,
  public.borrar_pagos_bottura,
  public.borrar_pagos_duplicate2,
  public.borrar_pagos_error,
  public.borrar_pagos_error_cc,
  public.borrar_pagos_revision_evidencias,
  public.borrar_pagos_stagin,
  public.borrar_pagos_stp_cuentas_437_y_445,
  public.borrar_pagos_stp_raw_duplicate,
  public.borrar_personas_stagin,
  public.borrar_propiedades_cuenta_stp_stagin,
  public.borrar_propiedades_imagenes_360_stagin,
  public.borrar_propiedades_imagenes_stagin,
  public.borrar_propiedades_stagin,
  public.borrar_proyectos_stagin,
  public.borrar_stp_propiedades,
  public.borrar_videos_youtube_stagin,
  public.borrar_vistas_stagin;

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
