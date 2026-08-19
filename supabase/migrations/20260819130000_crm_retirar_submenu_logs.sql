-- Reutilizar el submenú "Auditoría" (ya existente, id ~218, ruta /admin/portal-crm/configuracion/auditoria)
-- para la página de auditoría del CRM (CrmLogs), y RETIRAR el submenú "Logs" que se había creado en
-- 20260818213000_crm_submenu_logs.sql. El front ahora sirve CrmLogs en la ruta de "Auditoría".
--
-- Aquí SOLO desactivamos el submenú "Logs". NO se tocan los permisos de "Auditoría": ya incluye al
-- Super Administrador y ajustar roles de un submenú EXISTENTE va por la pantalla Roles y Permisos
-- (los rol_id difieren dev↔prod). Idempotente (en prod, donde "Logs" nunca existió, afecta 0 filas).
-- Sin BEGIN/COMMIT.

UPDATE public.submenus
SET activo = false
WHERE vista_front_end = '/admin/portal-crm/configuracion/logs';
