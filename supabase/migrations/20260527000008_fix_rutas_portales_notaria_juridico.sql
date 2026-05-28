-- Fix: actualizar rutas de submenús Portal Notaría, Portal Jurídico,
--      Administrar Notarios y Administrar Jurídico a rutas independientes
--      (fuera del prefijo /admin/portal-escrituracion/ para evitar que
--       AdminLayout los enrute al PortalEscrituracionLayout).
--
-- Requiere: migración 20260527000007 aplicada (submenús 165-168 existen).

UPDATE public.submenus
SET vista_front_end = '/admin/portal-notaria/inicio'
WHERE id = 165;

UPDATE public.submenus
SET vista_front_end = '/admin/portal-juridico/inicio'
WHERE id = 166;

UPDATE public.submenus
SET vista_front_end = '/admin/notarios/administrar'
WHERE id = 167;

UPDATE public.submenus
SET vista_front_end = '/admin/juridico/administrar'
WHERE id = 168;
