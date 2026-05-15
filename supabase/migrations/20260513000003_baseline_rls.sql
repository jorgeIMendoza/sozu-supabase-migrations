-- ============================================================
-- BASELINE RLS (Row Level Security) — generado 2026-05-14
-- Extraído de producción (proyecto: tzmhgfjmddkfyffkkmto)
-- 49 tablas con RLS habilitado, ~130 políticas
-- ============================================================

-- Habilitar RLS en todas las tablas relevantes
ALTER TABLE public.ab_test_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ab_tests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.analytics_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.aviso_triggers_fuentes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.avisos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.avisos_ejecuciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.avisos_envios_evento ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.avisos_legales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.avisos_proyectos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.avisos_roles_destinatarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.avisos_triggers_evento ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bancos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.carta_acuerdos_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cartas_acuerdo ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.citas_calendar_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.citas_horarios_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comisionistas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.configuracion_citas_horarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.configuracion_citas_proyectos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.configuracion_citas_usuarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cta_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.documentos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.edificios_niveles_planos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.entidades_relacionadas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.estatus_aprobacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.estatus_cita ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.estatus_persona ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.estatus_proyecto ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.firmas_digitales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inmob_kpi_mensual ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.logs_actividad ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.modelos_planos_arquitectonicos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.multimedias_propiedad ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notificaciones_configuracion ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notificaciones_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.personas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.propiedades_caracteristicas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.puntos_interes_proyecto ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reportes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reservas_citas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roles_estatus_disponibilidad ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roles_reportes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.showrooms_proyecto ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.submenus_permisos_disponibles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tipos_cita ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tipos_cita_proyectos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tipos_entidad ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usuarios ENABLE ROW LEVEL SECURITY;

-- ── ab_test_assignments ────────────────────────────────────

DROP POLICY IF EXISTS "Super admin can manage AB assignments" ON public.ab_test_assignments;
CREATE POLICY "Super admin can manage AB assignments" ON public.ab_test_assignments
  AS PERMISSIVE FOR ALL TO authenticated
  USING (EXISTS ( SELECT 1 FROM usuarios u WHERE ((u.auth_user_id = auth.uid()) AND (u.rol_id = 1))));

DROP POLICY IF EXISTS "Super admin can read all AB assignments" ON public.ab_test_assignments;
CREATE POLICY "Super admin can read all AB assignments" ON public.ab_test_assignments
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (EXISTS ( SELECT 1 FROM usuarios u WHERE ((u.auth_user_id = auth.uid()) AND (u.rol_id = 1))));

DROP POLICY IF EXISTS "Users can insert own AB assignment" ON public.ab_test_assignments;
CREATE POLICY "Users can insert own AB assignment" ON public.ab_test_assignments
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (auth_user_id = auth.uid());

DROP POLICY IF EXISTS "Users can read own AB assignment" ON public.ab_test_assignments;
CREATE POLICY "Users can read own AB assignment" ON public.ab_test_assignments
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (auth_user_id = auth.uid());

-- ── ab_tests ───────────────────────────────────────────────

DROP POLICY IF EXISTS "Authenticated can read active AB tests" ON public.ab_tests;
CREATE POLICY "Authenticated can read active AB tests" ON public.ab_tests
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (activo = true);

DROP POLICY IF EXISTS "Super admin can manage AB tests" ON public.ab_tests;
CREATE POLICY "Super admin can manage AB tests" ON public.ab_tests
  AS PERMISSIVE FOR ALL TO authenticated
  USING (EXISTS ( SELECT 1 FROM usuarios u WHERE ((u.auth_user_id = auth.uid()) AND (u.rol_id = 1))));

-- ── analytics_events ───────────────────────────────────────

DROP POLICY IF EXISTS "Admin can read analytics" ON public.analytics_events;
CREATE POLICY "Admin can read analytics" ON public.analytics_events
  AS PERMISSIVE FOR SELECT TO authenticated
  USING ((auth.jwt() ->> 'email'::text) = 'jorge.mendoza@sozu.com'::text);

DROP POLICY IF EXISTS "Allow anon insert analytics_events" ON public.analytics_events;
CREATE POLICY "Allow anon insert analytics_events" ON public.analytics_events
  AS PERMISSIVE FOR INSERT TO anon
  WITH CHECK (true);

DROP POLICY IF EXISTS "Anon can insert reset events" ON public.analytics_events;
CREATE POLICY "Anon can insert reset events" ON public.analytics_events
  AS PERMISSIVE FOR INSERT TO anon
  WITH CHECK (event_type = 'password_reset'::text);

DROP POLICY IF EXISTS "Users can insert own events" ON public.analytics_events;
CREATE POLICY "Users can insert own events" ON public.analytics_events
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (user_email = (auth.jwt() ->> 'email'::text));

-- ── aviso_triggers_fuentes ─────────────────────────────────

DROP POLICY IF EXISTS "Authenticated users read aviso_triggers_fuentes" ON public.aviso_triggers_fuentes;
CREATE POLICY "Authenticated users read aviso_triggers_fuentes" ON public.aviso_triggers_fuentes
  AS PERMISSIVE FOR SELECT TO public
  USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Super admins manage aviso_triggers_fuentes" ON public.aviso_triggers_fuentes;
CREATE POLICY "Super admins manage aviso_triggers_fuentes" ON public.aviso_triggers_fuentes
  AS PERMISSIVE FOR ALL TO public
  USING (is_super_admin())
  WITH CHECK (is_super_admin());

-- ── avisos ─────────────────────────────────────────────────

DROP POLICY IF EXISTS "Authenticated users can delete avisos" ON public.avisos;
CREATE POLICY "Authenticated users can delete avisos" ON public.avisos
  AS PERMISSIVE FOR DELETE TO authenticated
  USING (true);

DROP POLICY IF EXISTS "Authenticated users can insert avisos" ON public.avisos;
CREATE POLICY "Authenticated users can insert avisos" ON public.avisos
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can read avisos" ON public.avisos;
CREATE POLICY "Authenticated users can read avisos" ON public.avisos
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS "Authenticated users can update avisos" ON public.avisos;
CREATE POLICY "Authenticated users can update avisos" ON public.avisos
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (true) WITH CHECK (true);

-- ── avisos_ejecuciones ─────────────────────────────────────

DROP POLICY IF EXISTS "Authenticated users can insert avisos_ejecuciones" ON public.avisos_ejecuciones;
CREATE POLICY "Authenticated users can insert avisos_ejecuciones" ON public.avisos_ejecuciones
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can read avisos_ejecuciones" ON public.avisos_ejecuciones;
CREATE POLICY "Authenticated users can read avisos_ejecuciones" ON public.avisos_ejecuciones
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS "Authenticated users can update avisos_ejecuciones" ON public.avisos_ejecuciones;
CREATE POLICY "Authenticated users can update avisos_ejecuciones" ON public.avisos_ejecuciones
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (true);

DROP POLICY IF EXISTS "Service role can manage avisos_ejecuciones" ON public.avisos_ejecuciones;
CREATE POLICY "Service role can manage avisos_ejecuciones" ON public.avisos_ejecuciones
  AS PERMISSIVE FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- ── avisos_envios_evento ───────────────────────────────────

DROP POLICY IF EXISTS "Authenticated users read avisos_envios_evento" ON public.avisos_envios_evento;
CREATE POLICY "Authenticated users read avisos_envios_evento" ON public.avisos_envios_evento
  AS PERMISSIVE FOR SELECT TO public
  USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Service role inserts envios" ON public.avisos_envios_evento;
CREATE POLICY "Service role inserts envios" ON public.avisos_envios_evento
  AS PERMISSIVE FOR INSERT TO service_role
  WITH CHECK (true);

DROP POLICY IF EXISTS "Super admins manage avisos_envios_evento" ON public.avisos_envios_evento;
CREATE POLICY "Super admins manage avisos_envios_evento" ON public.avisos_envios_evento
  AS PERMISSIVE FOR ALL TO public
  USING (is_super_admin()) WITH CHECK (is_super_admin());

-- ── avisos_legales ─────────────────────────────────────────

DROP POLICY IF EXISTS "Allow all access to avisos_legales" ON public.avisos_legales;
CREATE POLICY "Allow all access to avisos_legales" ON public.avisos_legales
  AS PERMISSIVE FOR ALL TO public
  USING (true) WITH CHECK (true);

-- ── avisos_proyectos ───────────────────────────────────────

DROP POLICY IF EXISTS "Admins cobranza pueden crear avisos proyectos" ON public.avisos_proyectos;
CREATE POLICY "Admins cobranza pueden crear avisos proyectos" ON public.avisos_proyectos
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (is_super_admin() OR (EXISTS ( SELECT 1 FROM usuarios u WHERE ((lower(TRIM(BOTH FROM u.email)) = lower(TRIM(BOTH FROM auth.email()))) AND (u.activo = true) AND (u.rol_id = 2)))));

DROP POLICY IF EXISTS "Admins cobranza pueden editar avisos proyectos" ON public.avisos_proyectos;
CREATE POLICY "Admins cobranza pueden editar avisos proyectos" ON public.avisos_proyectos
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (is_super_admin() OR (EXISTS ( SELECT 1 FROM usuarios u WHERE ((lower(TRIM(BOTH FROM u.email)) = lower(TRIM(BOTH FROM auth.email()))) AND (u.activo = true) AND (u.rol_id = 2)))))
  WITH CHECK (is_super_admin() OR (EXISTS ( SELECT 1 FROM usuarios u WHERE ((lower(TRIM(BOTH FROM u.email)) = lower(TRIM(BOTH FROM auth.email()))) AND (u.activo = true) AND (u.rol_id = 2)))));

DROP POLICY IF EXISTS "Admins cobranza pueden eliminar avisos proyectos" ON public.avisos_proyectos;
CREATE POLICY "Admins cobranza pueden eliminar avisos proyectos" ON public.avisos_proyectos
  AS PERMISSIVE FOR DELETE TO authenticated
  USING (is_super_admin() OR (EXISTS ( SELECT 1 FROM usuarios u WHERE ((lower(TRIM(BOTH FROM u.email)) = lower(TRIM(BOTH FROM auth.email()))) AND (u.activo = true) AND (u.rol_id = 2)))));

DROP POLICY IF EXISTS "Admins cobranza pueden ver avisos proyectos" ON public.avisos_proyectos;
CREATE POLICY "Admins cobranza pueden ver avisos proyectos" ON public.avisos_proyectos
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (is_super_admin() OR (EXISTS ( SELECT 1 FROM usuarios u WHERE ((lower(TRIM(BOTH FROM u.email)) = lower(TRIM(BOTH FROM auth.email()))) AND (u.activo = true) AND (u.rol_id = 2)))));

-- ── avisos_roles_destinatarios ─────────────────────────────

DROP POLICY IF EXISTS "Authenticated users can delete avisos_roles_destinatarios" ON public.avisos_roles_destinatarios;
CREATE POLICY "Authenticated users can delete avisos_roles_destinatarios" ON public.avisos_roles_destinatarios
  AS PERMISSIVE FOR DELETE TO authenticated USING (true);

DROP POLICY IF EXISTS "Authenticated users can insert avisos_roles_destinatarios" ON public.avisos_roles_destinatarios;
CREATE POLICY "Authenticated users can insert avisos_roles_destinatarios" ON public.avisos_roles_destinatarios
  AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can read avisos_roles_destinatarios" ON public.avisos_roles_destinatarios;
CREATE POLICY "Authenticated users can read avisos_roles_destinatarios" ON public.avisos_roles_destinatarios
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Authenticated users can update avisos_roles_destinatarios" ON public.avisos_roles_destinatarios;
CREATE POLICY "Authenticated users can update avisos_roles_destinatarios" ON public.avisos_roles_destinatarios
  AS PERMISSIVE FOR UPDATE TO authenticated USING (true);

-- ── avisos_triggers_evento ─────────────────────────────────

DROP POLICY IF EXISTS "Authenticated users read avisos_triggers_evento" ON public.avisos_triggers_evento;
CREATE POLICY "Authenticated users read avisos_triggers_evento" ON public.avisos_triggers_evento
  AS PERMISSIVE FOR SELECT TO public
  USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Super admins manage avisos_triggers_evento" ON public.avisos_triggers_evento;
CREATE POLICY "Super admins manage avisos_triggers_evento" ON public.avisos_triggers_evento
  AS PERMISSIVE FOR ALL TO public
  USING (is_super_admin()) WITH CHECK (is_super_admin());

-- ── bancos ─────────────────────────────────────────────────

DROP POLICY IF EXISTS "Allow all access to bancos" ON public.bancos;
CREATE POLICY "Allow all access to bancos" ON public.bancos
  AS PERMISSIVE FOR ALL TO public
  USING (true) WITH CHECK (true);

-- ── carta_acuerdos_template ────────────────────────────────

DROP POLICY IF EXISTS "Authenticated users can insert carta template" ON public.carta_acuerdos_template;
CREATE POLICY "Authenticated users can insert carta template" ON public.carta_acuerdos_template
  AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (auth.role() = 'authenticated'::text);

DROP POLICY IF EXISTS "Authenticated users can read carta template" ON public.carta_acuerdos_template;
CREATE POLICY "Authenticated users can read carta template" ON public.carta_acuerdos_template
  AS PERMISSIVE FOR SELECT TO public
  USING (auth.role() = 'authenticated'::text);

DROP POLICY IF EXISTS "Authenticated users can update carta template" ON public.carta_acuerdos_template;
CREATE POLICY "Authenticated users can update carta template" ON public.carta_acuerdos_template
  AS PERMISSIVE FOR UPDATE TO public
  USING (auth.role() = 'authenticated'::text);

-- ── cartas_acuerdo ─────────────────────────────────────────

DROP POLICY IF EXISTS "Authenticated users can insert cartas_acuerdo" ON public.cartas_acuerdo;
CREATE POLICY "Authenticated users can insert cartas_acuerdo" ON public.cartas_acuerdo
  AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can read cartas_acuerdo" ON public.cartas_acuerdo;
CREATE POLICY "Authenticated users can read cartas_acuerdo" ON public.cartas_acuerdo
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Authenticated users can update cartas_acuerdo" ON public.cartas_acuerdo;
CREATE POLICY "Authenticated users can update cartas_acuerdo" ON public.cartas_acuerdo
  AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

-- ── citas_calendar_events ──────────────────────────────────

DROP POLICY IF EXISTS "Authenticated users can delete citas_calendar_events" ON public.citas_calendar_events;
CREATE POLICY "Authenticated users can delete citas_calendar_events" ON public.citas_calendar_events
  AS PERMISSIVE FOR DELETE TO public USING (true);

DROP POLICY IF EXISTS "Authenticated users can insert citas_calendar_events" ON public.citas_calendar_events;
CREATE POLICY "Authenticated users can insert citas_calendar_events" ON public.citas_calendar_events
  AS PERMISSIVE FOR INSERT TO public WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can read citas_calendar_events" ON public.citas_calendar_events;
CREATE POLICY "Authenticated users can read citas_calendar_events" ON public.citas_calendar_events
  AS PERMISSIVE FOR SELECT TO public USING (true);

DROP POLICY IF EXISTS "Authenticated users can update citas_calendar_events" ON public.citas_calendar_events;
CREATE POLICY "Authenticated users can update citas_calendar_events" ON public.citas_calendar_events
  AS PERMISSIVE FOR UPDATE TO public USING (true);

-- ── citas_horarios_overrides ───────────────────────────────

DROP POLICY IF EXISTS "Authenticated users can insert overrides" ON public.citas_horarios_overrides;
CREATE POLICY "Authenticated users can insert overrides" ON public.citas_horarios_overrides
  AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can read overrides" ON public.citas_horarios_overrides;
CREATE POLICY "Authenticated users can read overrides" ON public.citas_horarios_overrides
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Authenticated users can update overrides" ON public.citas_horarios_overrides;
CREATE POLICY "Authenticated users can update overrides" ON public.citas_horarios_overrides
  AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

-- ── comisionistas ──────────────────────────────────────────

DROP POLICY IF EXISTS "Permitir actualización de comisionistas a usuarios autenticado" ON public.comisionistas;
CREATE POLICY "Permitir actualización de comisionistas a usuarios autenticado" ON public.comisionistas
  AS PERMISSIVE FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Permitir inserción de comisionistas a usuarios autenticados" ON public.comisionistas;
CREATE POLICY "Permitir inserción de comisionistas a usuarios autenticados" ON public.comisionistas
  AS PERMISSIVE FOR INSERT TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Permitir lectura de comisionistas a usuarios autenticados" ON public.comisionistas;
CREATE POLICY "Permitir lectura de comisionistas a usuarios autenticados" ON public.comisionistas
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Permitir lectura de comisionistas con anon" ON public.comisionistas;
CREATE POLICY "Permitir lectura de comisionistas con anon" ON public.comisionistas
  AS PERMISSIVE FOR SELECT TO anon USING (true);

-- ── configuracion_citas_horarios ───────────────────────────

DROP POLICY IF EXISTS "Authenticated users can read configuracion_citas_horarios" ON public.configuracion_citas_horarios;
CREATE POLICY "Authenticated users can read configuracion_citas_horarios" ON public.configuracion_citas_horarios
  AS PERMISSIVE FOR SELECT TO public USING (true);

DROP POLICY IF EXISTS "Super admins can manage all configs" ON public.configuracion_citas_horarios;
CREATE POLICY "Super admins can manage all configs" ON public.configuracion_citas_horarios
  AS PERMISSIVE FOR ALL TO public
  USING (EXISTS ( SELECT 1 FROM (usuarios u JOIN roles r ON ((r.id = u.rol_id))) WHERE ((u.auth_user_id = auth.uid()) AND (r.nombre = 'Super Administrador'::text))));

DROP POLICY IF EXISTS "Users can manage own configs" ON public.configuracion_citas_horarios;
CREATE POLICY "Users can manage own configs" ON public.configuracion_citas_horarios
  AS PERMISSIVE FOR ALL TO public
  USING (EXISTS ( SELECT 1 FROM usuarios u WHERE ((u.auth_user_id = auth.uid()) AND (u.email = configuracion_citas_horarios.id_usuario_email))));

-- ── configuracion_citas_proyectos ──────────────────────────

DROP POLICY IF EXISTS "Authenticated users can delete configuracion_citas_proyectos" ON public.configuracion_citas_proyectos;
CREATE POLICY "Authenticated users can delete configuracion_citas_proyectos" ON public.configuracion_citas_proyectos
  AS PERMISSIVE FOR DELETE TO public USING (true);

DROP POLICY IF EXISTS "Authenticated users can insert configuracion_citas_proyectos" ON public.configuracion_citas_proyectos;
CREATE POLICY "Authenticated users can insert configuracion_citas_proyectos" ON public.configuracion_citas_proyectos
  AS PERMISSIVE FOR INSERT TO public WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can update configuracion_citas_proyectos" ON public.configuracion_citas_proyectos;
CREATE POLICY "Authenticated users can update configuracion_citas_proyectos" ON public.configuracion_citas_proyectos
  AS PERMISSIVE FOR UPDATE TO public USING (true);

DROP POLICY IF EXISTS "Authenticated users can view configuracion_citas_proyectos" ON public.configuracion_citas_proyectos;
CREATE POLICY "Authenticated users can view configuracion_citas_proyectos" ON public.configuracion_citas_proyectos
  AS PERMISSIVE FOR SELECT TO public USING (true);

-- ── configuracion_citas_usuarios ───────────────────────────

DROP POLICY IF EXISTS "Authenticated users can delete configuracion_citas_usuarios" ON public.configuracion_citas_usuarios;
CREATE POLICY "Authenticated users can delete configuracion_citas_usuarios" ON public.configuracion_citas_usuarios
  AS PERMISSIVE FOR DELETE TO authenticated USING (true);

DROP POLICY IF EXISTS "Authenticated users can insert configuracion_citas_usuarios" ON public.configuracion_citas_usuarios;
CREATE POLICY "Authenticated users can insert configuracion_citas_usuarios" ON public.configuracion_citas_usuarios
  AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can read configuracion_citas_usuarios" ON public.configuracion_citas_usuarios;
CREATE POLICY "Authenticated users can read configuracion_citas_usuarios" ON public.configuracion_citas_usuarios
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Authenticated users can update configuracion_citas_usuarios" ON public.configuracion_citas_usuarios;
CREATE POLICY "Authenticated users can update configuracion_citas_usuarios" ON public.configuracion_citas_usuarios
  AS PERMISSIVE FOR UPDATE TO authenticated USING (true);

-- ── cta_events ─────────────────────────────────────────────

DROP POLICY IF EXISTS "Super admin can read CTA events" ON public.cta_events;
CREATE POLICY "Super admin can read CTA events" ON public.cta_events
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (EXISTS ( SELECT 1 FROM usuarios u WHERE ((u.auth_user_id = auth.uid()) AND (u.rol_id = 1))));

DROP POLICY IF EXISTS "Users can insert own CTA events" ON public.cta_events;
CREATE POLICY "Users can insert own CTA events" ON public.cta_events
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK ((auth.jwt() ->> 'email'::text) = user_email);

-- ── documentos ─────────────────────────────────────────────

DROP POLICY IF EXISTS "Usuarios autenticados pueden eliminar documentos" ON public.documentos;
CREATE POLICY "Usuarios autenticados pueden eliminar documentos" ON public.documentos
  AS PERMISSIVE FOR DELETE TO authenticated USING (true);

DROP POLICY IF EXISTS "Usuarios pueden actualizar documentos" ON public.documentos;
CREATE POLICY "Usuarios pueden actualizar documentos" ON public.documentos
  AS PERMISSIVE FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Usuarios pueden insertar documentos" ON public.documentos;
CREATE POLICY "Usuarios pueden insertar documentos" ON public.documentos
  AS PERMISSIVE FOR INSERT TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Usuarios pueden ver documentos" ON public.documentos;
CREATE POLICY "Usuarios pueden ver documentos" ON public.documentos
  AS PERMISSIVE FOR SELECT TO anon, authenticated USING (true);

-- ── edificios_niveles_planos ───────────────────────────────

DROP POLICY IF EXISTS "Authenticated users can insert edificios_niveles_planos" ON public.edificios_niveles_planos;
CREATE POLICY "Authenticated users can insert edificios_niveles_planos" ON public.edificios_niveles_planos
  AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can read edificios_niveles_planos" ON public.edificios_niveles_planos;
CREATE POLICY "Authenticated users can read edificios_niveles_planos" ON public.edificios_niveles_planos
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Authenticated users can update edificios_niveles_planos" ON public.edificios_niveles_planos;
CREATE POLICY "Authenticated users can update edificios_niveles_planos" ON public.edificios_niveles_planos
  AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

-- ── entidades_relacionadas ─────────────────────────────────

DROP POLICY IF EXISTS "delete_entidades_relacionadas" ON public.entidades_relacionadas;
CREATE POLICY "delete_entidades_relacionadas" ON public.entidades_relacionadas
  AS PERMISSIVE FOR DELETE TO public USING (is_admin_user());

DROP POLICY IF EXISTS "insert_entidades_relacionadas" ON public.entidades_relacionadas;
CREATE POLICY "insert_entidades_relacionadas" ON public.entidades_relacionadas
  AS PERMISSIVE FOR INSERT TO public WITH CHECK (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "select_entidades_relacionadas" ON public.entidades_relacionadas;
CREATE POLICY "select_entidades_relacionadas" ON public.entidades_relacionadas
  AS PERMISSIVE FOR SELECT TO public
  USING (is_admin_user() OR can_view_all_prospects() OR (id_tipo_entidad <> ALL (ARRAY[2, 7])) OR ((id_tipo_entidad = ANY (ARRAY[2, 7])) AND can_access_agent_owned_lead((id_persona_duena_lead)::bigint)));

DROP POLICY IF EXISTS "update_entidades_relacionadas" ON public.entidades_relacionadas;
CREATE POLICY "update_entidades_relacionadas" ON public.entidades_relacionadas
  AS PERMISSIVE FOR UPDATE TO public
  USING (is_admin_user() OR ((id_tipo_entidad = ANY (ARRAY[2, 7])) AND (get_current_user_persona_id() IS NOT NULL) AND (id_persona_duena_lead = get_current_user_persona_id())) OR (id_tipo_entidad <> ALL (ARRAY[2, 7])))
  WITH CHECK (is_admin_user() OR ((id_tipo_entidad = ANY (ARRAY[2, 7])) AND (get_current_user_persona_id() IS NOT NULL) AND (id_persona_duena_lead = get_current_user_persona_id())) OR (id_tipo_entidad <> ALL (ARRAY[2, 7])));

-- ── estatus_aprobacion ─────────────────────────────────────

DROP POLICY IF EXISTS "Allow authenticated users to read estatus_aprobacion" ON public.estatus_aprobacion;
CREATE POLICY "Allow authenticated users to read estatus_aprobacion" ON public.estatus_aprobacion
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- ── estatus_cita ───────────────────────────────────────────

DROP POLICY IF EXISTS "Estatus cita visible para todos" ON public.estatus_cita;
CREATE POLICY "Estatus cita visible para todos" ON public.estatus_cita
  AS PERMISSIVE FOR SELECT TO public USING (true);

-- ── estatus_persona ────────────────────────────────────────

DROP POLICY IF EXISTS "Allow all access to estatus_persona" ON public.estatus_persona;
CREATE POLICY "Allow all access to estatus_persona" ON public.estatus_persona
  AS PERMISSIVE FOR ALL TO public USING (true) WITH CHECK (true);

-- ── estatus_proyecto ───────────────────────────────────────

DROP POLICY IF EXISTS "Allow all access to estatus_proyecto" ON public.estatus_proyecto;
CREATE POLICY "Allow all access to estatus_proyecto" ON public.estatus_proyecto
  AS PERMISSIVE FOR ALL TO public USING (true) WITH CHECK (true);

-- ── firmas_digitales ───────────────────────────────────────

DROP POLICY IF EXISTS "Authenticated users can delete firmas" ON public.firmas_digitales;
CREATE POLICY "Authenticated users can delete firmas" ON public.firmas_digitales
  AS PERMISSIVE FOR DELETE TO authenticated USING (auth.role() = 'authenticated'::text);

DROP POLICY IF EXISTS "Authenticated users can insert firmas" ON public.firmas_digitales;
CREATE POLICY "Authenticated users can insert firmas" ON public.firmas_digitales
  AS PERMISSIVE FOR INSERT TO public WITH CHECK (auth.role() = 'authenticated'::text);

DROP POLICY IF EXISTS "Authenticated users can read firmas" ON public.firmas_digitales;
CREATE POLICY "Authenticated users can read firmas" ON public.firmas_digitales
  AS PERMISSIVE FOR SELECT TO public USING (auth.role() = 'authenticated'::text);

DROP POLICY IF EXISTS "Authenticated users can update firmas" ON public.firmas_digitales;
CREATE POLICY "Authenticated users can update firmas" ON public.firmas_digitales
  AS PERMISSIVE FOR UPDATE TO public USING (auth.role() = 'authenticated'::text);

-- ── inmob_kpi_mensual ──────────────────────────────────────

DROP POLICY IF EXISTS "Users can read their own KPIs" ON public.inmob_kpi_mensual;
CREATE POLICY "Users can read their own KPIs" ON public.inmob_kpi_mensual
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Users can upsert their own KPIs" ON public.inmob_kpi_mensual;
CREATE POLICY "Users can upsert their own KPIs" ON public.inmob_kpi_mensual
  AS PERMISSIVE FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ── logs_actividad ─────────────────────────────────────────

DROP POLICY IF EXISTS "Permitir inserción de logs a usuarios autenticados" ON public.logs_actividad;
CREATE POLICY "Permitir inserción de logs a usuarios autenticados" ON public.logs_actividad
  AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Permitir lectura de logs a usuarios autenticados" ON public.logs_actividad;
CREATE POLICY "Permitir lectura de logs a usuarios autenticados" ON public.logs_actividad
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- ── modelos_planos_arquitectonicos ─────────────────────────

DROP POLICY IF EXISTS "Authenticated users can delete model floor plans" ON public.modelos_planos_arquitectonicos;
CREATE POLICY "Authenticated users can delete model floor plans" ON public.modelos_planos_arquitectonicos
  AS PERMISSIVE FOR DELETE TO authenticated USING (true);

DROP POLICY IF EXISTS "Authenticated users can insert model floor plans" ON public.modelos_planos_arquitectonicos;
CREATE POLICY "Authenticated users can insert model floor plans" ON public.modelos_planos_arquitectonicos
  AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can update model floor plans" ON public.modelos_planos_arquitectonicos;
CREATE POLICY "Authenticated users can update model floor plans" ON public.modelos_planos_arquitectonicos
  AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can view model floor plans" ON public.modelos_planos_arquitectonicos;
CREATE POLICY "Authenticated users can view model floor plans" ON public.modelos_planos_arquitectonicos
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- ── multimedias_propiedad ──────────────────────────────────

DROP POLICY IF EXISTS "Allow all access to multimedias_propiedad" ON public.multimedias_propiedad;
CREATE POLICY "Allow all access to multimedias_propiedad" ON public.multimedias_propiedad
  AS PERMISSIVE FOR ALL TO public USING (true) WITH CHECK (true);

-- ── notificaciones_configuracion ───────────────────────────

DROP POLICY IF EXISTS "Admins can delete notification config" ON public.notificaciones_configuracion;
CREATE POLICY "Admins can delete notification config" ON public.notificaciones_configuracion
  AS PERMISSIVE FOR DELETE TO authenticated
  USING (EXISTS ( SELECT 1 FROM usuarios WHERE ((usuarios.auth_user_id = auth.uid()) AND (usuarios.rol_id = 1) AND (usuarios.activo = true))));

DROP POLICY IF EXISTS "Admins can insert notification config" ON public.notificaciones_configuracion;
CREATE POLICY "Admins can insert notification config" ON public.notificaciones_configuracion
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (EXISTS ( SELECT 1 FROM usuarios WHERE ((usuarios.auth_user_id = auth.uid()) AND (usuarios.rol_id = 1) AND (usuarios.activo = true))));

DROP POLICY IF EXISTS "Admins can update notification config" ON public.notificaciones_configuracion;
CREATE POLICY "Admins can update notification config" ON public.notificaciones_configuracion
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (EXISTS ( SELECT 1 FROM usuarios WHERE ((usuarios.auth_user_id = auth.uid()) AND (usuarios.rol_id = 1) AND (usuarios.activo = true))))
  WITH CHECK (EXISTS ( SELECT 1 FROM usuarios WHERE ((usuarios.auth_user_id = auth.uid()) AND (usuarios.rol_id = 1) AND (usuarios.activo = true))));

DROP POLICY IF EXISTS "Authenticated users can read notification config" ON public.notificaciones_configuracion;
CREATE POLICY "Authenticated users can read notification config" ON public.notificaciones_configuracion
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Service role can manage notification config" ON public.notificaciones_configuracion;
CREATE POLICY "Service role can manage notification config" ON public.notificaciones_configuracion
  AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

-- ── notificaciones_log ─────────────────────────────────────

DROP POLICY IF EXISTS "Service role can insert logs" ON public.notificaciones_log;
CREATE POLICY "Service role can insert logs" ON public.notificaciones_log
  AS PERMISSIVE FOR INSERT TO service_role WITH CHECK (true);

DROP POLICY IF EXISTS "Super Admin can read notification logs" ON public.notificaciones_log;
CREATE POLICY "Super Admin can read notification logs" ON public.notificaciones_log
  AS PERMISSIVE FOR SELECT TO authenticated USING (is_super_admin());

-- ── personas ───────────────────────────────────────────────

DROP POLICY IF EXISTS "Allow all access to personas" ON public.personas;
CREATE POLICY "Allow all access to personas" ON public.personas
  AS PERMISSIVE FOR ALL TO public USING (true) WITH CHECK (true);

-- ── propiedades_caracteristicas ────────────────────────────

DROP POLICY IF EXISTS "Allow all access to propiedades_caracteristicas" ON public.propiedades_caracteristicas;
CREATE POLICY "Allow all access to propiedades_caracteristicas" ON public.propiedades_caracteristicas
  AS PERMISSIVE FOR ALL TO public USING (true) WITH CHECK (true);

-- ── puntos_interes_proyecto ────────────────────────────────

DROP POLICY IF EXISTS "Authenticated users can delete puntos_interes" ON public.puntos_interes_proyecto;
CREATE POLICY "Authenticated users can delete puntos_interes" ON public.puntos_interes_proyecto
  AS PERMISSIVE FOR DELETE TO public USING (auth.role() = 'authenticated'::text);

DROP POLICY IF EXISTS "Authenticated users can insert puntos_interes" ON public.puntos_interes_proyecto;
CREATE POLICY "Authenticated users can insert puntos_interes" ON public.puntos_interes_proyecto
  AS PERMISSIVE FOR INSERT TO public WITH CHECK (auth.role() = 'authenticated'::text);

DROP POLICY IF EXISTS "Authenticated users can update puntos_interes" ON public.puntos_interes_proyecto;
CREATE POLICY "Authenticated users can update puntos_interes" ON public.puntos_interes_proyecto
  AS PERMISSIVE FOR UPDATE TO public USING (auth.role() = 'authenticated'::text);

DROP POLICY IF EXISTS "Authenticated users can view puntos_interes" ON public.puntos_interes_proyecto;
CREATE POLICY "Authenticated users can view puntos_interes" ON public.puntos_interes_proyecto
  AS PERMISSIVE FOR SELECT TO public USING (auth.role() = 'authenticated'::text);

-- ── reportes ───────────────────────────────────────────────

DROP POLICY IF EXISTS "Solo admins pueden modificar reportes" ON public.reportes;
CREATE POLICY "Solo admins pueden modificar reportes" ON public.reportes
  AS PERMISSIVE FOR ALL TO authenticated USING (is_admin_user()) WITH CHECK (is_admin_user());

DROP POLICY IF EXISTS "Usuarios autenticados pueden ver reportes activos" ON public.reportes;
CREATE POLICY "Usuarios autenticados pueden ver reportes activos" ON public.reportes
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- ── reservas_citas ─────────────────────────────────────────

DROP POLICY IF EXISTS "Authenticated users can insert reservas_citas" ON public.reservas_citas;
CREATE POLICY "Authenticated users can insert reservas_citas" ON public.reservas_citas
  AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can update reservas_citas" ON public.reservas_citas;
CREATE POLICY "Authenticated users can update reservas_citas" ON public.reservas_citas
  AS PERMISSIVE FOR UPDATE TO authenticated USING (true);

DROP POLICY IF EXISTS "Authenticated users can view reservas_citas" ON public.reservas_citas;
CREATE POLICY "Authenticated users can view reservas_citas" ON public.reservas_citas
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- ── roles_estatus_disponibilidad ───────────────────────────

DROP POLICY IF EXISTS "Admins can manage roles_estatus_disponibilidad" ON public.roles_estatus_disponibilidad;
CREATE POLICY "Admins can manage roles_estatus_disponibilidad" ON public.roles_estatus_disponibilidad
  AS PERMISSIVE FOR ALL TO authenticated USING (is_admin_user()) WITH CHECK (is_admin_user());

DROP POLICY IF EXISTS "Authenticated users can read roles_estatus_disponibilidad" ON public.roles_estatus_disponibilidad;
CREATE POLICY "Authenticated users can read roles_estatus_disponibilidad" ON public.roles_estatus_disponibilidad
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- ── roles_reportes ─────────────────────────────────────────

DROP POLICY IF EXISTS "Allow authenticated users to read roles_reportes" ON public.roles_reportes;
CREATE POLICY "Allow authenticated users to read roles_reportes" ON public.roles_reportes
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Super admins can delete roles_reportes" ON public.roles_reportes;
CREATE POLICY "Super admins can delete roles_reportes" ON public.roles_reportes
  AS PERMISSIVE FOR DELETE TO authenticated USING (is_super_admin());

DROP POLICY IF EXISTS "Super admins can insert roles_reportes" ON public.roles_reportes;
CREATE POLICY "Super admins can insert roles_reportes" ON public.roles_reportes
  AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (is_super_admin());

DROP POLICY IF EXISTS "Super admins can update roles_reportes" ON public.roles_reportes;
CREATE POLICY "Super admins can update roles_reportes" ON public.roles_reportes
  AS PERMISSIVE FOR UPDATE TO authenticated USING (is_super_admin()) WITH CHECK (is_super_admin());

-- ── showrooms_proyecto ─────────────────────────────────────

DROP POLICY IF EXISTS "Authenticated users can delete showrooms" ON public.showrooms_proyecto;
CREATE POLICY "Authenticated users can delete showrooms" ON public.showrooms_proyecto
  AS PERMISSIVE FOR DELETE TO authenticated USING (true);

DROP POLICY IF EXISTS "Authenticated users can insert showrooms" ON public.showrooms_proyecto;
CREATE POLICY "Authenticated users can insert showrooms" ON public.showrooms_proyecto
  AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can read showrooms" ON public.showrooms_proyecto;
CREATE POLICY "Authenticated users can read showrooms" ON public.showrooms_proyecto
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Authenticated users can update showrooms" ON public.showrooms_proyecto;
CREATE POLICY "Authenticated users can update showrooms" ON public.showrooms_proyecto
  AS PERMISSIVE FOR UPDATE TO authenticated USING (true);

DROP POLICY IF EXISTS "Public can view active showrooms" ON public.showrooms_proyecto;
CREATE POLICY "Public can view active showrooms" ON public.showrooms_proyecto
  AS PERMISSIVE FOR SELECT TO anon, authenticated USING (activo = true);

-- ── submenus_permisos_disponibles ──────────────────────────

DROP POLICY IF EXISTS "Authenticated users can read submenus_permisos_disponibles" ON public.submenus_permisos_disponibles;
CREATE POLICY "Authenticated users can read submenus_permisos_disponibles" ON public.submenus_permisos_disponibles
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Super admin can manage submenus_permisos_disponibles" ON public.submenus_permisos_disponibles;
CREATE POLICY "Super admin can manage submenus_permisos_disponibles" ON public.submenus_permisos_disponibles
  AS PERMISSIVE FOR ALL TO authenticated
  USING (EXISTS ( SELECT 1 FROM usuarios u WHERE ((u.auth_user_id = auth.uid()) AND (u.rol_id = 1) AND (u.activo = true))));

-- ── tipos_cita ─────────────────────────────────────────────

DROP POLICY IF EXISTS "Authenticated users can insert tipos_cita" ON public.tipos_cita;
CREATE POLICY "Authenticated users can insert tipos_cita" ON public.tipos_cita
  AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can read tipos_cita" ON public.tipos_cita;
CREATE POLICY "Authenticated users can read tipos_cita" ON public.tipos_cita
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Authenticated users can update tipos_cita" ON public.tipos_cita;
CREATE POLICY "Authenticated users can update tipos_cita" ON public.tipos_cita
  AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

-- ── tipos_cita_proyectos ───────────────────────────────────

DROP POLICY IF EXISTS "Authenticated users can delete tipos_cita_proyectos" ON public.tipos_cita_proyectos;
CREATE POLICY "Authenticated users can delete tipos_cita_proyectos" ON public.tipos_cita_proyectos
  AS PERMISSIVE FOR DELETE TO authenticated USING (true);

DROP POLICY IF EXISTS "Authenticated users can insert tipos_cita_proyectos" ON public.tipos_cita_proyectos;
CREATE POLICY "Authenticated users can insert tipos_cita_proyectos" ON public.tipos_cita_proyectos
  AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can read tipos_cita_proyectos" ON public.tipos_cita_proyectos;
CREATE POLICY "Authenticated users can read tipos_cita_proyectos" ON public.tipos_cita_proyectos
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- ── tipos_entidad ──────────────────────────────────────────

DROP POLICY IF EXISTS "Allow all access to tipos_entidad" ON public.tipos_entidad;
CREATE POLICY "Allow all access to tipos_entidad" ON public.tipos_entidad
  AS PERMISSIVE FOR ALL TO public USING (true) WITH CHECK (true);

-- ── user_roles ─────────────────────────────────────────────

DROP POLICY IF EXISTS "user_roles_modify" ON public.user_roles;
CREATE POLICY "user_roles_modify" ON public.user_roles
  AS PERMISSIVE FOR ALL TO authenticated USING (is_super_admin()) WITH CHECK (is_super_admin());

DROP POLICY IF EXISTS "user_roles_select" ON public.user_roles;
CREATE POLICY "user_roles_select" ON public.user_roles
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (is_super_admin() OR (lower(email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))));

-- ── usuarios ───────────────────────────────────────────────

DROP POLICY IF EXISTS "Anon puede verificar email de clientes" ON public.usuarios;
CREATE POLICY "Anon puede verificar email de clientes" ON public.usuarios
  AS PERMISSIVE FOR SELECT TO anon
  USING ((rol_id = 23) AND (activo = true));

DROP POLICY IF EXISTS "Inmob owners can view their agents" ON public.usuarios;
CREATE POLICY "Inmob owners can view their agents" ON public.usuarios
  AS PERMISSIVE FOR SELECT TO authenticated USING (is_inmob_agent_owner(email));

DROP POLICY IF EXISTS "Inmobiliaria can update own agents" ON public.usuarios;
CREATE POLICY "Inmobiliaria can update own agents" ON public.usuarios
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (is_inmob_agent_owner(email)) WITH CHECK (is_inmob_agent_owner(email));

DROP POLICY IF EXISTS "Internal roles can view all users" ON public.usuarios;
CREATE POLICY "Internal roles can view all users" ON public.usuarios
  AS PERMISSIVE FOR SELECT TO public USING (user_has_internal_role(auth.uid()));

DROP POLICY IF EXISTS "Super admins can delete users" ON public.usuarios;
CREATE POLICY "Super admins can delete users" ON public.usuarios
  AS PERMISSIVE FOR DELETE TO public USING (is_super_admin(auth.uid()));

DROP POLICY IF EXISTS "Super admins can insert users" ON public.usuarios;
CREATE POLICY "Super admins can insert users" ON public.usuarios
  AS PERMISSIVE FOR INSERT TO public WITH CHECK (is_super_admin(auth.uid()));

DROP POLICY IF EXISTS "Super admins can update users" ON public.usuarios;
CREATE POLICY "Super admins can update users" ON public.usuarios
  AS PERMISSIVE FOR UPDATE TO public USING (is_super_admin(auth.uid()));

DROP POLICY IF EXISTS "Super admins can view all users" ON public.usuarios;
CREATE POLICY "Super admins can view all users" ON public.usuarios
  AS PERMISSIVE FOR SELECT TO public USING (is_super_admin(auth.uid()));

DROP POLICY IF EXISTS "Users can update own record" ON public.usuarios;
CREATE POLICY "Users can update own record" ON public.usuarios
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING ((email = (auth.jwt() ->> 'email'::text)) OR (auth_user_id = auth.uid()))
  WITH CHECK ((email = (auth.jwt() ->> 'email'::text)) OR (auth_user_id = auth.uid()));

DROP POLICY IF EXISTS "Users can view own record" ON public.usuarios;
CREATE POLICY "Users can view own record" ON public.usuarios
  AS PERMISSIVE FOR SELECT TO public USING (auth_user_id = auth.uid());
