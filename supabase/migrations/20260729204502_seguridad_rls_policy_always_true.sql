-- Seguridad · Lints rls_policy_always_true (99 hallazgos, 49 tablas)
-- Fecha: 2026-07-28
--
-- PROBLEMA
--   Políticas RLS de INSERT/UPDATE/DELETE/ALL con USING (true) / WITH CHECK (true).
--   Dos gravedades distintas:
--
--   (A) CRÍTICO — 27 políticas cuyo rol es PUBLIC ({public}), no authenticated, pese a
--       llamarse "Authenticated users can ...". PUBLIC incluye anon, y anon tiene
--       INSERT/UPDATE/DELETE otorgado sobre estas tablas (verificado read-only en prod).
--       Con la clave anon publicada en el front, cualquiera puede escribir/borrar en
--       entregas*, postventa*, creditos_hipotecarios, embajadores*, citas_calendar_events
--       y configuracion_citas_proyectos.
--
--   (B) comisionistas: dos políticas con roles {anon,authenticated} explícito. Misma
--       exposición, además de UPDATE con USING (true) y WITH CHECK (true).
--
--   (C) El resto ({authenticated}): no hay exposición a anon, pero el predicado literal
--       `true` deja la política sin ninguna condición y dispara el lint.
--
-- CORRECCIÓN
--   Se reemplaza `true` por `(SELECT auth.uid()) IS NOT NULL` y, en (A) y (B), se
--   restringe el rol a authenticated. Efecto:
--     · anon deja de poder escribir (auth.uid() es NULL con la clave anon).
--     · cero cambio de comportamiento para usuarios con sesión — el acceso efectivo de
--       hoy se conserva íntegro.
--     · service_role no se afecta (rolbypassrls = true).
--     · el `(SELECT ...)` deja la expresión como InitPlan (se evalúa una vez, no por fila).
--
--   ALCANCE DECLARADO: esto cierra el agujero anon y limpia el lint, pero NO añade
--   autorización por fila/rol. Tablas como inmob_kpi_mensual ("Users can upsert their own
--   KPIs" con USING (true)) o crm_* siguen permitiendo a cualquier usuario autenticado
--   escribir cualquier fila. Endurecer eso requiere decisión de producto por tabla y va
--   en una fase posterior.
--
--   EXCEPCIÓN analytics_events: es telemetría pública insertada con clave anon desde los
--   landings (fuera de este workspace), así que conserva el rol anon. Se le pone un
--   WITH CHECK real con topes de tamaño en lugar de `true`.
--
-- Idempotente (solo altera políticas cuyo predicado sigue siendo `true`), tolerante a
-- drift (si una política no existe en dev, avisa y sigue) y self-verifying al final.
-- Sin BEGIN/COMMIT (el CI envuelve en transacción).

-- Tabla temporal con el inventario a corregir. Sin ON COMMIT DROP a propósito: así el
-- archivo funciona igual si el CI lo ejecuta en una transacción o en autocommit. Se elimina
-- de forma explícita al final.
DROP TABLE IF EXISTS _fix_rls_pol;
CREATE TEMP TABLE _fix_rls_pol (
  tabla         text NOT NULL,
  politica      text NOT NULL,
  roles_destino text,          -- NULL = no cambiar los roles de la política
  set_using     boolean NOT NULL,
  set_check     boolean NOT NULL
);

INSERT INTO _fix_rls_pol (tabla, politica, roles_destino, set_using, set_check) VALUES
-- ── (A) roles {public} → authenticated ──────────────────────────────────────────────
('citas_calendar_events',            'Authenticated users can delete citas_calendar_events',            'authenticated', true,  false),
('citas_calendar_events',            'Authenticated users can insert citas_calendar_events',            'authenticated', false, true ),
('citas_calendar_events',            'Authenticated users can update citas_calendar_events',            'authenticated', true,  false),
('configuracion_citas_proyectos',    'Authenticated users can delete configuracion_citas_proyectos',    'authenticated', true,  false),
('configuracion_citas_proyectos',    'Authenticated users can insert configuracion_citas_proyectos',    'authenticated', false, true ),
('configuracion_citas_proyectos',    'Authenticated users can update configuracion_citas_proyectos',    'authenticated', true,  false),
('creditos_hipotecarios',            'creditos_hipotecarios_insert',                                    'authenticated', false, true ),
('creditos_hipotecarios',            'creditos_hipotecarios_update',                                    'authenticated', true,  false),
('embajadores_config',               'embajadores_config_insert',                                       'authenticated', false, true ),
('embajadores_config',               'embajadores_config_update',                                       'authenticated', true,  false),
('embajadores_referidos',            'embajadores_referidos_insert',                                    'authenticated', false, true ),
('embajadores_referidos',            'embajadores_referidos_update',                                    'authenticated', true,  false),
('entregas',                         'entregas_insert',                                                 'authenticated', false, true ),
('entregas',                         'entregas_update',                                                 'authenticated', true,  false),
('entregas_checklist_categorias',    'ent_cat_insert',                                                  'authenticated', false, true ),
('entregas_checklist_categorias',    'ent_cat_update',                                                  'authenticated', true,  false),
('entregas_checklist_items',         'ent_items_insert',                                                'authenticated', false, true ),
('entregas_checklist_items',         'ent_items_update',                                                'authenticated', true,  false),
('entregas_evidencia',               'ent_evid_insert',                                                 'authenticated', false, true ),
('entregas_evidencia',               'ent_evid_update',                                                 'authenticated', true,  false),
('entregas_firmas',                  'ent_firmas_insert',                                               'authenticated', false, true ),
('entregas_firmas',                  'ent_firmas_update',                                               'authenticated', true,  false),
('entregas_observaciones',           'ent_obs_insert',                                                  'authenticated', false, true ),
('entregas_observaciones',           'ent_obs_update',                                                  'authenticated', true,  false),
('postventa_categorias_garantia',    'postventa_categorias_garantia_insert',                            'authenticated', false, true ),
('postventa_categorias_garantia',    'postventa_categorias_garantia_update',                            'authenticated', true,  false),
('postventa_categorias_personal',    'postventa_categorias_personal_insert',                            'authenticated', false, true ),
('postventa_categorias_personal',    'postventa_categorias_personal_update',                            'authenticated', true,  false),
('postventa_comentarios',            'postventa_comentarios_insert',                                    'authenticated', false, true ),
('postventa_comentarios',            'postventa_comentarios_update',                                    'authenticated', true,  false),
('postventa_evidencias',             'postventa_evidencias_insert',                                     'authenticated', false, true ),
('postventa_evidencias',             'postventa_evidencias_update',                                     'authenticated', true,  false),
('postventa_garantias_unidad',       'postventa_garantias_unidad_insert',                               'authenticated', false, true ),
('postventa_garantias_unidad',       'postventa_garantias_unidad_update',                               'authenticated', true,  false),
('postventa_log_actividades',        'postventa_log_actividades_insert',                                'authenticated', false, true ),
('postventa_tickets',                'postventa_tickets_insert',                                        'authenticated', false, true ),
('postventa_tickets',                'postventa_tickets_update',                                        'authenticated', true,  false),
-- ── (B) comisionistas: quitar anon del rol ──────────────────────────────────────────
('comisionistas',                    'Permitir inserción de comisionistas a usuarios autenticados',     'authenticated', false, true ),
('comisionistas',                    'Permitir actualización de comisionistas a usuarios autenticado',  'authenticated', true,  true ),
-- ── (C) roles {authenticated}: solo se sustituye el predicado ───────────────────────
('avisos',                           'Authenticated users can delete avisos',                           NULL, true,  false),
('avisos',                           'Authenticated users can insert avisos',                           NULL, false, true ),
('avisos',                           'Authenticated users can update avisos',                           NULL, true,  false),
('avisos_ejecuciones',               'Authenticated users can insert avisos_ejecuciones',               NULL, false, true ),
('avisos_ejecuciones',               'Authenticated users can update avisos_ejecuciones',               NULL, true,  false),
('avisos_roles_destinatarios',       'Authenticated users can delete avisos_roles_destinatarios',       NULL, true,  false),
('avisos_roles_destinatarios',       'Authenticated users can insert avisos_roles_destinatarios',       NULL, false, true ),
('avisos_roles_destinatarios',       'Authenticated users can update avisos_roles_destinatarios',       NULL, true,  false),
('cartas_acuerdo',                   'Authenticated users can insert cartas_acuerdo',                   NULL, false, true ),
('cartas_acuerdo',                   'Authenticated users can update cartas_acuerdo',                   NULL, true,  true ),
('citas_horarios_overrides',         'Authenticated users can insert overrides',                        NULL, false, true ),
('citas_horarios_overrides',         'Authenticated users can update overrides',                        NULL, true,  true ),
('configuracion_citas_usuarios',     'Authenticated users can delete configuracion_citas_usuarios',     NULL, true,  false),
('configuracion_citas_usuarios',     'Authenticated users can insert configuracion_citas_usuarios',     NULL, false, true ),
('configuracion_citas_usuarios',     'Authenticated users can update configuracion_citas_usuarios',     NULL, true,  false),
('crm_citas',                        'crm_citas_insert',                                                NULL, false, true ),
('crm_citas',                        'crm_citas_update',                                                NULL, true,  true ),
('crm_estados_lead',                 'crm_estados_lead_insert',                                         NULL, false, true ),
('crm_estados_lead',                 'crm_estados_lead_update',                                         NULL, true,  true ),
('crm_leads_atribucion',             'crm_leads_atribucion_insert',                                     NULL, false, true ),
-- crm_leads_atribucion_update ya tiene un USING real (is_admin_user() OR propietario) → solo WITH CHECK
('crm_leads_atribucion',             'crm_leads_atribucion_update',                                     NULL, false, true ),
('crm_meta_conversion_stages',       'crm_meta_conv_all',                                               NULL, true,  true ),
('crm_negocios',                     'crm_negocios_insert',                                             NULL, false, true ),
('crm_negocios',                     'crm_negocios_update',                                             NULL, true,  true ),
('crm_notas',                        'crm_notas_insert',                                                NULL, false, true ),
('crm_notas',                        'crm_notas_update',                                                NULL, true,  true ),
('crm_notas_adjuntos',               'crm_notas_adjuntos_insert',                                       NULL, false, true ),
('crm_notas_adjuntos',               'crm_notas_adjuntos_update',                                       NULL, true,  true ),
('crm_notas_comentarios',            'crm_notas_comentarios_insert',                                    NULL, false, true ),
('crm_notas_comentarios',            'crm_notas_comentarios_update',                                    NULL, true,  true ),
('crm_pipeline_etapas',              'crm_pipeline_etapas_insert',                                      NULL, false, true ),
('crm_pipeline_etapas',              'crm_pipeline_etapas_update',                                      NULL, true,  true ),
('crm_pipelines',                    'crm_pipelines_insert',                                            NULL, false, true ),
('crm_pipelines',                    'crm_pipelines_update',                                            NULL, true,  true ),
('crm_tareas',                       'crm_tareas_insert',                                               NULL, false, true ),
('crm_tareas',                       'crm_tareas_update',                                               NULL, true,  true ),
('demandas',                         'juridico_auth_insert_demandas',                                   NULL, false, true ),
('demandas',                         'juridico_auth_update_demandas',                                   NULL, true,  true ),
('edificios_niveles_planos',         'Authenticated users can insert edificios_niveles_planos',         NULL, false, true ),
('edificios_niveles_planos',         'Authenticated users can update edificios_niveles_planos',         NULL, true,  true ),
('entidades_relacionadas_categorias','er_categorias_insert',                                            NULL, false, true ),
('entidades_relacionadas_categorias','er_categorias_update',                                            NULL, true,  true ),
('inmob_kpi_mensual',                'Users can upsert their own KPIs',                                 NULL, true,  true ),
('logs_actividad',                   'Permitir inserción de logs a usuarios autenticados',              NULL, false, true ),
('modelos_planos_arquitectonicos',   'Authenticated users can delete model floor plans',                NULL, true,  false),
('modelos_planos_arquitectonicos',   'Authenticated users can insert model floor plans',                NULL, false, true ),
('modelos_planos_arquitectonicos',   'Authenticated users can update model floor plans',                NULL, true,  true ),
('perfiles_juridicos',               'pj_insert',                                                       NULL, false, true ),
('perfiles_juridicos',               'pj_update',                                                       NULL, true,  true ),
('personas',                         'personas_insert',                                                 NULL, false, true ),
('reservas_citas',                   'Authenticated users can insert reservas_citas',                   NULL, false, true ),
('reservas_citas',                   'Authenticated users can update reservas_citas',                   NULL, true,  false),
('showrooms_proyecto',               'Authenticated users can delete showrooms',                        NULL, true,  false),
('showrooms_proyecto',               'Authenticated users can insert showrooms',                        NULL, false, true ),
('showrooms_proyecto',               'Authenticated users can update showrooms',                        NULL, true,  false),
('tipos_cita',                       'Authenticated users can insert tipos_cita',                       NULL, false, true ),
('tipos_cita',                       'Authenticated users can update tipos_cita',                       NULL, true,  true ),
('tipos_cita_proyectos',             'Authenticated users can delete tipos_cita_proyectos',             NULL, true,  false),
('tipos_cita_proyectos',             'Authenticated users can insert tipos_cita_proyectos',             NULL, false, true );

DO $$
DECLARE
  r          record;
  v_sql      text;
  n_alter    int := 0;
  n_ok       int := 0;
  n_missing  int := 0;
BEGIN
  FOR r IN SELECT * FROM _fix_rls_pol ORDER BY tabla, politica LOOP

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'public' AND tablename = r.tabla AND policyname = r.politica
    ) THEN
      n_missing := n_missing + 1;
      RAISE NOTICE 'drift: no existe la política %.% — se omite', r.tabla, r.politica;
      CONTINUE;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'public' AND tablename = r.tabla AND policyname = r.politica
        AND (qual = 'true' OR with_check = 'true')
    ) THEN
      n_ok := n_ok + 1;   -- ya corregida (re-ejecución)
      CONTINUE;
    END IF;

    v_sql := format('ALTER POLICY %I ON public.%I', r.politica, r.tabla);
    IF r.roles_destino IS NOT NULL THEN
      v_sql := v_sql || format(' TO %I', r.roles_destino);
    END IF;
    IF r.set_using THEN
      v_sql := v_sql || ' USING ((SELECT auth.uid()) IS NOT NULL)';
    END IF;
    IF r.set_check THEN
      v_sql := v_sql || ' WITH CHECK ((SELECT auth.uid()) IS NOT NULL)';
    END IF;

    EXECUTE v_sql;
    n_alter := n_alter + 1;
  END LOOP;

  RAISE NOTICE 'políticas corregidas=%, ya correctas=%, ausentes por drift=%',
    n_alter, n_ok, n_missing;
END $$;

-- analytics_events: telemetría pública. Conserva el rol anon; se sustituye WITH CHECK (true)
-- por validación real con topes de tamaño (anti-abuso).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'analytics_events'
      AND policyname = 'Allow anon insert analytics_events'
      AND with_check = 'true'
  ) THEN
    ALTER POLICY "Allow anon insert analytics_events" ON public.analytics_events
      WITH CHECK (
        event_type IS NOT NULL
        AND btrim(event_type) <> ''
        AND length(event_type) <= 120
        AND user_email IS NOT NULL
        AND length(user_email) <= 320
        AND (event_data IS NULL OR pg_column_size(event_data) <= 8192)
      );
    RAISE NOTICE 'analytics_events: WITH CHECK acotado (rol anon conservado)';
  END IF;
END $$;

-- Verificación: ninguna política de la lista puede seguir con predicado `true`.
DO $$
DECLARE
  v_restantes text;
BEGIN
  SELECT string_agg(format('%s.%s', p.tablename, p.policyname), ', ' ORDER BY p.tablename)
    INTO v_restantes
  FROM pg_policies p
  JOIN _fix_rls_pol f ON f.tabla = p.tablename AND f.politica = p.policyname
  WHERE p.schemaname = 'public'
    AND (p.qual = 'true' OR p.with_check = 'true');

  IF v_restantes IS NOT NULL THEN
    RAISE EXCEPTION 'Políticas que siguen con predicado true: %', v_restantes;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'analytics_events'
      AND policyname = 'Allow anon insert analytics_events' AND with_check = 'true'
  ) THEN
    RAISE EXCEPTION 'analytics_events sigue con WITH CHECK (true)';
  END IF;

  -- Ninguna política de escritura de la lista debe seguir alcanzando a anon.
  SELECT string_agg(format('%s.%s', p.tablename, p.policyname), ', ' ORDER BY p.tablename)
    INTO v_restantes
  FROM pg_policies p
  JOIN _fix_rls_pol f ON f.tabla = p.tablename AND f.politica = p.policyname
  WHERE p.schemaname = 'public'
    AND (p.roles::text LIKE '%public%' OR p.roles::text LIKE '%anon%');

  IF v_restantes IS NOT NULL THEN
    RAISE EXCEPTION 'Políticas de escritura que siguen alcanzando a anon: %', v_restantes;
  END IF;

  RAISE NOTICE 'Verificación OK: sin predicados true ni escritura anon en las políticas tratadas';
END $$;

DROP TABLE IF EXISTS _fix_rls_pol;
