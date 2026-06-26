-- Tabla notificaciones_cliente: centro de notificaciones del portal cliente.
-- Fecha: 2026-05-28 (generada 2026-06-25)
--
-- Notificaciones por cliente (email), tipadas (urgente/accionable/informativa/exito)
-- y categorizadas (pagos/documentos/mantenimiento/construccion/reventa/entrega),
-- ligadas opcionalmente a una cuenta de cobranza. Trigger mantiene fecha_actualizacion.
-- Idempotente. Verificado en dev: tabla no existe; set_fecha_actualizacion() existe;
-- cuentas_cobranza.id es bigint (FK coincide).

CREATE TABLE IF NOT EXISTS public.notificaciones_cliente (
  id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_cuenta_cobranza  BIGINT REFERENCES public.cuentas_cobranza(id) ON DELETE CASCADE,
  email_cliente       TEXT NOT NULL,
  tipo                TEXT NOT NULL CHECK (tipo IN ('urgente', 'accionable', 'informativa', 'exito')),
  categoria           TEXT NOT NULL CHECK (categoria IN ('pagos', 'documentos', 'mantenimiento', 'construccion', 'reventa', 'entrega')),
  titulo              TEXT NOT NULL,
  descripcion         TEXT NOT NULL,
  url_accion          TEXT,
  etiqueta_accion     TEXT,
  leida               BOOLEAN NOT NULL DEFAULT FALSE,
  descartada          BOOLEAN NOT NULL DEFAULT FALSE,
  fecha_lectura       TIMESTAMPTZ,
  fecha_descarte      TIMESTAMPTZ,
  metadata            JSONB,
  activo              BOOLEAN NOT NULL DEFAULT TRUE,
  fecha_creacion      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notif_email
  ON public.notificaciones_cliente (email_cliente)
  WHERE activo = true;

CREATE INDEX IF NOT EXISTS idx_notif_cuenta
  ON public.notificaciones_cliente (id_cuenta_cobranza)
  WHERE activo = true AND id_cuenta_cobranza IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_notif_no_leida
  ON public.notificaciones_cliente (email_cliente, leida)
  WHERE activo = true AND descartada = false;

DROP TRIGGER IF EXISTS trg_notificaciones_cliente_upd ON public.notificaciones_cliente;
CREATE TRIGGER trg_notificaciones_cliente_upd
  BEFORE UPDATE ON public.notificaciones_cliente
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();
