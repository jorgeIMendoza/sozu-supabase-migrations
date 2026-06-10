-- Portal CRM Sozu: menú + 43 submenús + permisos Super Administrador (rol_id=1).
-- Fecha: 2026-06-10
--
-- Consolida las 6 fases del andamiaje del portal CRM (Resumen/Tracking, CRM,
-- Marketing, Dirección/Revenue, Operación, Configuración). Permisos completos
-- leer(1)/crear(2)/actualizar(3)/eliminar(4)/exportar(6) al rol Super Admin.
--
-- Idempotente con guardas WHERE NOT EXISTS: ninguna de estas tablas tiene PK/UNIQUE,
-- así que NO se usa ON CONFLICT. menus.id/submenus.id son GENERATED ALWAYS → no se fijan.
-- "Contacto · detalle" (:contactId) es vista hija de Contactos y NO se da de alta.
-- Verificado: permisos 1,2,3,4,6 existen; rol 1 = Super Administrador.

-- 1) Menú principal (orden 260)
INSERT INTO public.menus (nombre, orden, activo)
SELECT 'Portal CRM Sozu', 260, true
WHERE NOT EXISTS (
  SELECT 1 FROM public.menus WHERE nombre = 'Portal CRM Sozu'
);

-- 2) Submenús (43) — idempotente por vista_front_end
WITH m AS (
  SELECT id FROM public.menus WHERE nombre = 'Portal CRM Sozu' LIMIT 1
)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT m.id, v.nombre, v.ruta, v.orden, true, false
FROM m
CROSS JOIN (VALUES
  -- Fase 1 — Andamiaje (Resumen + Tracking)
  ('Panel principal',          '/admin/portal-crm/dashboard',                              10),
  ('Alertas',                  '/admin/portal-crm/alertas',                                20),
  ('Salud de tracking',        '/admin/portal-crm/tracking-health',                       210),
  ('Eventos de conversión',    '/admin/portal-crm/conversion-events',                     220),
  -- Fase 2 — CRM
  ('Contactos',                '/admin/portal-crm/crm/contacts',                           50),
  ('Pipeline',                 '/admin/portal-crm/crm/deals',                              60),
  ('Citas',                    '/admin/portal-crm/crm/appointments',                       70),
  ('Tareas',                   '/admin/portal-crm/crm/tasks',                              80),
  ('Secuencias',               '/admin/portal-crm/crm/sequences',                          90),
  ('Routing de leads',         '/admin/portal-crm/crm/routing',                           100),
  ('Reglas de automatización', '/admin/portal-crm/crm/automation-rules',                  110),
  ('Escalaciones',             '/admin/portal-crm/crm/escalations',                       120),
  ('Lead Intelligence',        '/admin/portal-crm/crm/lead-intelligence',                 130),
  ('Performance de agentes',   '/admin/portal-crm/crm/agent-performance',                 140),
  ('Operaciones de ventas',    '/admin/portal-crm/crm/sales-operations',                  150),
  -- Fase 3 — Inteligencia de marketing
  ('Campañas',                 '/admin/portal-crm/marketing/campaigns',                   300),
  ('Audiencias',               '/admin/portal-crm/marketing/audiences',                   310),
  ('Atribución',               '/admin/portal-crm/marketing/attribution',                 320),
  ('Creatividades',            '/admin/portal-crm/marketing/creatives',                   330),
  ('UTMs',                     '/admin/portal-crm/marketing/utms',                        340),
  ('A/B Tests',                '/admin/portal-crm/marketing/ab-tests',                    350),
  ('Landing pages',            '/admin/portal-crm/marketing/landing-pages',               360),
  ('Formularios',              '/admin/portal-crm/marketing/forms',                       370),
  ('Integraciones de ads',     '/admin/portal-crm/marketing/integrations',                380),
  ('Costos y presupuesto',     '/admin/portal-crm/marketing/budget',                      390),
  -- Fase 4 — Dirección e Inteligencia de ingresos
  ('KPIs ejecutivos',          '/admin/portal-crm/executive/kpis',                        400),
  ('Forecast',                 '/admin/portal-crm/revenue/forecast',                      410),
  ('Pipeline review',          '/admin/portal-crm/revenue/pipeline-review',               420),
  ('Revenue ops',              '/admin/portal-crm/revenue/operations',                    430),
  ('Cohorts',                  '/admin/portal-crm/revenue/cohorts',                       440),
  ('Churn',                    '/admin/portal-crm/revenue/churn',                         450),
  ('Reportería',               '/admin/portal-crm/executive/reports',                     460),
  -- Fase 5 — Operación
  ('Bandeja unificada',        '/admin/portal-crm/operations/inbox',                      500),
  ('Colas de atención',        '/admin/portal-crm/operations/queues',                     510),
  ('Monitor de SLA',           '/admin/portal-crm/operations/sla-monitor',                520),
  -- Fase 6 — Configuración
  ('Usuarios CRM',             '/admin/portal-crm/settings/users',                        600),
  ('Roles y permisos CRM',     '/admin/portal-crm/settings/roles',                        610),
  ('Etapas del pipeline',      '/admin/portal-crm/settings/pipeline-stages',              620),
  ('Campos personalizados',    '/admin/portal-crm/settings/custom-fields',                630),
  ('Webhooks',                 '/admin/portal-crm/settings/webhooks',                     640),
  ('Callback OAuth Google',    '/admin/portal-crm/settings/connections/google/callback',  650),
  ('Callback OAuth Meta',      '/admin/portal-crm/settings/connections/meta/callback',    660),
  ('Log de auditoría',         '/admin/portal-crm/settings/audit-log',                    670)
) AS v(nombre, ruta, orden)
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus s WHERE s.vista_front_end = v.ruta
);

-- 3) Permisos DISPONIBLES (catálogo) de cada submenú del portal: 1,2,3,4,6
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
JOIN public.menus m ON m.id = s.menu_id
CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
WHERE m.nombre = 'Portal CRM Sozu'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- 4) Asignación a Super Administrador (rol_id=1): 1,2,3,4,6 por submenú
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, 1, true
FROM public.submenus s
JOIN public.menus m ON m.id = s.menu_id
CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
WHERE m.nombre = 'Portal CRM Sozu'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = 1
  );
