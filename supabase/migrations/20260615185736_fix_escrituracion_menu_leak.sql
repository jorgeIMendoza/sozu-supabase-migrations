-- Fix: fuga visual del menú "Escrituración" en el Admin Panel.
-- Fecha: 2026-06-15
--
-- NOTA: esta versión (20260615185736) se aplicó directamente en producción sin
-- commitearse, rompiendo el deploy con "Remote migration versions not found in
-- local migrations directory". Se recupera aquí para reconciliar el historial.
--
-- Hace lo mismo que 20260615000003_fix_menu_escrituracion_huerfano.sql (mover el
-- submenú "Expedientes" al Portal Legal Flow y eliminar el menú huérfano
-- "Escrituración"). El original aplicado en prod usaba ids hardcoded (248/33); aquí
-- se reescribe por nombre/vista para ser inocuo y idempotente en cualquier ambiente
-- (en prod ya está aplicado → push lo salta; en dev 000003 ya hizo el cambio → no-op).

BEGIN;

-- 1. Reasignar el submenú "Expedientes" al Portal Legal Flow (orden 8)
UPDATE public.submenus
SET menu_id = (SELECT id FROM public.menus WHERE nombre = 'Portal Legal Flow' AND activo = true LIMIT 1),
    orden   = 8
WHERE vista_front_end = '/admin/legal-flow/escrituracion/expedientes';

-- 2. Eliminar el menú huérfano "Escrituración" si quedó sin submenús
DELETE FROM public.menus m
WHERE m.nombre = 'Escrituración'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus s WHERE s.menu_id = m.id
  );

COMMIT;
