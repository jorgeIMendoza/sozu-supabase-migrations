-- ─── 1. Tabla principal ───────────────────────────────────────────────────────
CREATE TABLE public.creditos_hipotecarios (
    id                   BIGINT         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_cuenta_cobranza   INT            NOT NULL REFERENCES public.cuentas_cobranza(id),
    id_banco             INT            REFERENCES public.bancos(id),
    monto_credito        NUMERIC(15, 2) NOT NULL DEFAULT 0,

    vobo_banco           VARCHAR(20)    NOT NULL DEFAULT 'PENDIENTE'
        CHECK (vobo_banco IN ('PENDIENTE', 'EN_REVISION', 'APROBADO', 'RECHAZADO', 'NO_APLICA')),

    pago_banco_estatus   VARCHAR(20)    NOT NULL DEFAULT 'PENDIENTE'
        CHECK (pago_banco_estatus IN ('PENDIENTE', 'PROGRAMADO', 'PAGADO', 'RECHAZADO', 'PARCIAL')),

    fecha_cita_firma     DATE,
    fecha_vobo           DATE,
    fecha_pago_banco     DATE,
    observaciones        TEXT,
    activo               BOOLEAN        NOT NULL DEFAULT TRUE,
    fecha_creacion       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    fecha_actualizacion  TIMESTAMPTZ    NOT NULL DEFAULT NOW(),

    CONSTRAINT creditos_hipotecarios_cuenta_unica UNIQUE (id_cuenta_cobranza)
);

-- ─── 2. Índices ───────────────────────────────────────────────────────────────
CREATE INDEX idx_creditos_hipotecarios_banco
    ON public.creditos_hipotecarios (id_banco);

CREATE INDEX idx_creditos_hipotecarios_cuenta
    ON public.creditos_hipotecarios (id_cuenta_cobranza);

-- ─── 3. Trigger — fecha_actualizacion automática ─────────────────────────────
CREATE OR REPLACE FUNCTION public.set_creditos_hipotecarios_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.fecha_actualizacion = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_creditos_hipotecarios_updated_at
BEFORE UPDATE ON public.creditos_hipotecarios
FOR EACH ROW EXECUTE FUNCTION public.set_creditos_hipotecarios_updated_at();

-- ─── 4. Row Level Security ────────────────────────────────────────────────────
ALTER TABLE public.creditos_hipotecarios ENABLE ROW LEVEL SECURITY;

CREATE POLICY "creditos_hipotecarios_select"
    ON public.creditos_hipotecarios FOR SELECT USING (true);

CREATE POLICY "creditos_hipotecarios_insert"
    ON public.creditos_hipotecarios FOR INSERT WITH CHECK (true);

CREATE POLICY "creditos_hipotecarios_update"
    ON public.creditos_hipotecarios FOR UPDATE USING (true);
