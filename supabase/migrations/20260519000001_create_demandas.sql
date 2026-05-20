-- Módulo de Demandas
-- Los documentos se gestionan en public.documentos (FK a id_cuenta_cobranza).
-- Se agregan tipos_documento específicos para este módulo.

-- ── 1. Nuevos tipos de documento para demandas ───────────────────────────────
-- Sincronizar secuencia antes de insertar para evitar conflictos de PK
SELECT setval(
  pg_get_serial_sequence('public.tipos_documento', 'id'),
  (SELECT MAX(id) FROM public.tipos_documento)
);

INSERT INTO public.tipos_documento (nombre, activo, id_categoria_documento)
VALUES
  ('Escrito de demanda',      true, 9),
  ('Acuerdo extrajudicial',   true, 9),
  ('Resolución judicial',     true, 9)
ON CONFLICT (nombre) DO NOTHING;

-- ── 2. Función para fecha_actualizacion automática ───────────────────────────
-- (CREATE OR REPLACE — seguro si ya existe de otra migración)
CREATE OR REPLACE FUNCTION public.set_fecha_actualizacion()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.fecha_actualizacion = NOW();
  RETURN NEW;
END;
$$;

-- ── 3. Tabla principal de demandas ───────────────────────────────────────────
CREATE TABLE public.demandas (
  id                       BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_cuenta_cobranza       BIGINT       NOT NULL REFERENCES public.cuentas_cobranza(id),
  id_propiedad             INTEGER      NOT NULL REFERENCES public.propiedades(id),
  id_proyecto              INTEGER               REFERENCES public.proyectos(id),
  estatus_demanda          TEXT         NOT NULL DEFAULT 'SIN_DEMANDA'
                             CHECK (estatus_demanda IN (
                               'SIN_DEMANDA','NOTIFICADO','EN_PROCESO',
                               'ACUERDO','LITIGIO','RESUELTO','CERRADO'
                             )),
  fecha_compromiso_entrega DATE,
  responsable              TEXT,
  observaciones            TEXT,
  activo                   BOOLEAN      NOT NULL DEFAULT true,
  fecha_creacion           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  fecha_actualizacion      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Una sola demanda activa por cuenta
CREATE UNIQUE INDEX demandas_cuenta_uidx
  ON public.demandas(id_cuenta_cobranza) WHERE activo = true;

CREATE INDEX idx_demandas_propiedad   ON public.demandas(id_propiedad);
CREATE INDEX idx_demandas_proyecto    ON public.demandas(id_proyecto);
CREATE INDEX idx_demandas_estatus     ON public.demandas(estatus_demanda);

-- ── 4. Timeline / bitácora de eventos ────────────────────────────────────────
CREATE TABLE public.demandas_timeline (
  id             BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_demanda     BIGINT      NOT NULL REFERENCES public.demandas(id) ON DELETE CASCADE,
  tipo_evento    TEXT        NOT NULL
                   CHECK (tipo_evento IN (
                     'CREACION','CAMBIO_ESTATUS','NOTA','DOCUMENTO',
                     'ACUERDO','PAGO','RESOLUCION','OTRO'
                   )),
  descripcion    TEXT        NOT NULL,
  creado_por     TEXT,
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_demandas_timeline_demanda ON public.demandas_timeline(id_demanda);

-- ── 5. Trigger fecha_actualizacion ───────────────────────────────────────────
CREATE TRIGGER demandas_updated_at
  BEFORE UPDATE ON public.demandas
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- ── 6. RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE public.demandas          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.demandas_timeline ENABLE ROW LEVEL SECURITY;

CREATE POLICY "demandas_select"          ON public.demandas          FOR SELECT USING (true);
CREATE POLICY "demandas_insert"          ON public.demandas          FOR INSERT WITH CHECK (true);
CREATE POLICY "demandas_update"          ON public.demandas          FOR UPDATE USING (true);

CREATE POLICY "demandas_timeline_select" ON public.demandas_timeline FOR SELECT USING (true);
CREATE POLICY "demandas_timeline_insert" ON public.demandas_timeline FOR INSERT WITH CHECK (true);
