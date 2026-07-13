-- Configuración general de la app de clientes (key/value).
-- Fecha: 2026-07-13
--
-- Tabla que respalda la pestaña "Configuración" de Enviar avisos en el app de
-- clientes. Primera clave: animacion_campana (sobre | gol | cohete) — la
-- animación de llegada de notificaciones, global para todos los clientes.
-- La escribe la edge function admin-avisos-app (config_get/config_set) y la
-- lee cliente-notificaciones para incluirla en su respuesta.
--
-- Solo service_role (edge functions) accede: RLS habilitado sin policies.
-- Idempotente: IF NOT EXISTS + seed con ON CONFLICT DO NOTHING.

CREATE TABLE IF NOT EXISTS public.app_cliente_config (
  key                 text PRIMARY KEY,
  value               text NOT NULL,
  fecha_actualizacion timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.app_cliente_config IS
  'Configuración general de la app de clientes (key/value); acceso sólo vía edge functions.';

ALTER TABLE public.app_cliente_config ENABLE ROW LEVEL SECURITY;

INSERT INTO public.app_cliente_config (key, value)
VALUES ('animacion_campana', 'gol')
ON CONFLICT (key) DO NOTHING;
