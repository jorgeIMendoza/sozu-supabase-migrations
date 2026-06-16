-- Fix: fuga visual del menú "Escrituración" en el Admin Panel.
-- Fecha: 2026-06-15
--
-- El menú "Escrituración" (creado en 20260612110000) aparece como grupo colapsable
-- en el sidebar principal del Admin Panel (useDynamicMenus lo renderiza por estar
-- activo). Su único submenú "Expedientes" apunta a /admin/legal-flow/escrituracion/
-- expedientes, que pertenece al Portal Legal Flow. Se mueve ese submenú a "Portal
-- Legal Flow" y se elimina el menú huérfano.
--
-- Resuelto por NOMBRE/VISTA, no por id: los ids difieren entre ambientes (en dev el
-- submenú es 245, en prod 248). Idempotente: el UPDATE por vista es no-op si ya se
-- movió; el DELETE sólo borra "Escrituración" si quedó sin submenús.
-- Los permisos del submenú (Super Admin: leer/exportar) se conservan intactos.

BEGIN;

-- 1. Reasignar el submenú "Expedientes" al Portal Legal Flow (orden 8, tras los 7 actuales)
UPDATE public.submenus
SET menu_id = (SELECT id FROM public.menus WHERE nombre = 'Portal Legal Flow' AND activo = true LIMIT 1),
    orden   = 8
WHERE vista_front_end = '/admin/legal-flow/escrituracion/expedientes';

-- 2. Eliminar el menú huérfano "Escrituración" sólo si ya no tiene submenús colgando
DELETE FROM public.menus m
WHERE m.nombre = 'Escrituración'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus s WHERE s.menu_id = m.id
  );

COMMIT;
