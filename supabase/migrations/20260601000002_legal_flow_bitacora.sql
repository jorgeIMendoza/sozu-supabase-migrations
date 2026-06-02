-- SOZU Legal Flow — bitácora de validaciones/rechazos por cuenta de cobranza.
--
-- Reemplaza el enfoque previo (columna jsonb cuentas_cobranza.bitacora) por una
-- tabla dedicada 1:N contra cuentas_cobranza. Ventajas: append atómico (un INSERT
-- por entrada, sin read-modify-write que pisa escrituras concurrentes), consultable
-- por SQL/índices, e integridad referencial. No engorda cuentas_cobranza.
--
-- Consumida por src/hooks/useBitacoraCuentaCobranza.ts (panel de validaciones del
-- detalle de expediente — src/pages/admin/legal-flow/CaseDetail.tsx).
--
-- Cada fila = una entrada con shape (ver src/types/bitacora.ts):
--   { id, timestamp, autorEmail, autorNombre, tipo, mensaje, referencia? }
--   tipo:             'nota' | 'validacion' | 'rechazo' | 'sistema'
--   referencia.scope: 'expediente' | 'comprador_basica' | 'comprador_direccion'
--                     | 'comprador_fiscal' | 'documento'
--
-- Notas de diseño:
--   * PK uuid: BitacoraEntry.id es string/uuid en el tipo del frontend; se genera
--     server-side (gen_random_uuid) para evitar generación en cliente y colisiones.
--   * FKs con tipos reales del baseline: cuentas_cobranza.id e documentos.id son
--     bigint; personas.id es integer.
--   * Sin RLS, igual que la tabla hermana legal_flow_expedientes (acceso vía grants
--     default de Supabase a authenticated).

CREATE TABLE IF NOT EXISTS public.legal_flow_bitacora (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_cuenta_cobranza  bigint NOT NULL REFERENCES public.cuentas_cobranza(id) ON DELETE CASCADE,
  tipo                text NOT NULL CHECK (tipo IN ('nota','validacion','rechazo','sistema')),
  mensaje             text NOT NULL,
  -- Referencia opcional (scope NULL = entrada general del expediente sin pieza concreta).
  scope               text CHECK (scope IN (
                        'expediente',
                        'comprador_basica',
                        'comprador_direccion',
                        'comprador_fiscal',
                        'documento'
                      )),
  id_persona          integer REFERENCES public.personas(id),
  id_documento        bigint  REFERENCES public.documentos(id),
  -- Autoría
  autor_email         text NOT NULL,
  autor_nombre        text,
  -- Campos de control
  activo              boolean NOT NULL DEFAULT true,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now()
);

-- Lectura típica: todas las entradas de una CC en orden de inserción.
CREATE INDEX IF NOT EXISTS legal_flow_bitacora_cuenta_idx
  ON public.legal_flow_bitacora (id_cuenta_cobranza, fecha_creacion) WHERE activo;

-- getValidationState filtra por documento dentro de la CC.
CREATE INDEX IF NOT EXISTS legal_flow_bitacora_documento_idx
  ON public.legal_flow_bitacora (id_documento) WHERE activo;

-- Refresca fecha_actualizacion en cada UPDATE (función genérica del legal flow,
-- creada en 20260601000000_legal_flow_expedientes.sql).
DROP TRIGGER IF EXISTS legal_flow_bitacora_set_fecha_actualizacion ON public.legal_flow_bitacora;
CREATE TRIGGER legal_flow_bitacora_set_fecha_actualizacion
  BEFORE UPDATE ON public.legal_flow_bitacora
  FOR EACH ROW EXECUTE FUNCTION public.legal_flow_actualizar_fecha_modificacion();

COMMENT ON TABLE public.legal_flow_bitacora IS
  'Bitácora viva del Legal Flow por cuenta de cobranza: notas, validaciones y rechazos de documentos y secciones del comprador. Reemplaza el jsonb cuentas_cobranza.bitacora.';

-- Forzar recarga del schema cache de PostgREST para que vea la tabla nueva.
NOTIFY pgrst, 'reload schema';
