-- notificaciones_cliente: Realtime (contador en vivo de la campana) + RLS
-- Fecha: 2026-07-09
--
-- Paso 5b del feature de push: el app se suscribe por WebSocket a los INSERT de sus
-- propias notificaciones para refrescar la campana al instante.
--
-- Supabase Realtime respeta RLS: si RLS está DESHABILITADO, los cambios se difunden a
-- TODOS los suscriptores (fuga). La tabla tenía RLS OFF, así que se HABILITA y se crean
-- policies:
--   - notif_realtime_select: cada cliente SELECCIONA solo sus filas (email = jwt email).
--     Es lo que acota el Realtime al dueño.
--   - notif_staff_all: el staff (usuarios activos con rol_id <> 23 = no-cliente) mantiene
--     acceso total, porque el front admin inserta/lee esta tabla directo con la sesión del
--     navegador (DocumentsTab, ClienteINECaptureDialog, ClientePerfil, notification-data).
-- service_role (edge functions: cliente-notificaciones, trigger de push) bypassa RLS.
--
-- Idempotente: guard en la publicación, ENABLE RLS re-ejecutable, DROP POLICY IF EXISTS +
-- CREATE. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

-- 1) Exponer la tabla al canal realtime (guard: ADD TABLE falla si ya es miembro).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'notificaciones_cliente'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notificaciones_cliente;
  END IF;
END $$;

-- 2) Habilitar RLS (estaba deshabilitado).
ALTER TABLE public.notificaciones_cliente ENABLE ROW LEVEL SECURITY;

-- 3) Cliente: SELECT solo de sus propias notificaciones (acota el Realtime al dueño).
DROP POLICY IF EXISTS notif_realtime_select ON public.notificaciones_cliente;
CREATE POLICY notif_realtime_select ON public.notificaciones_cliente
  FOR SELECT
  USING (email_cliente = (auth.jwt() ->> 'email'));

-- 4) Staff (no-cliente) mantiene acceso total (el front admin escribe/lee directo).
DROP POLICY IF EXISTS notif_staff_all ON public.notificaciones_cliente;
CREATE POLICY notif_staff_all ON public.notificaciones_cliente
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid() AND u.rol_id <> 23 AND u.activo
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid() AND u.rol_id <> 23 AND u.activo
    )
  );
