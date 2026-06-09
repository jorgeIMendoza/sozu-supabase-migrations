-- Backfill de la tabla cep_audit_log.
-- Existe en producción (creada ad-hoc, ~7.5k filas) pero nunca tuvo migración ni
-- está en el baseline. Las RPCs de auditoría de CEP la referencian, por lo que sin
-- esta tabla las migraciones 20260609123710 en adelante fallan en un DB fresco (dev).
-- Estructura tomada por introspección de prod (2026-06-09).
-- Idempotente: IF NOT EXISTS para que en prod (donde ya existe) sea no-op.

CREATE TABLE IF NOT EXISTS public.cep_audit_log (
    id                 bigserial PRIMARY KEY,
    id_pago            bigint      NOT NULL,
    url_cep            text        NOT NULL,
    estado             text        NOT NULL,
    motivo             text,
    clave_rastreo      text,
    fecha_pago         text,
    monto              numeric,
    banco_ordenante    text,
    banco_beneficiario text,
    num_cuenta         text,
    auditado_en        timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cep_audit_log_id_pago ON public.cep_audit_log USING btree (id_pago);
CREATE INDEX IF NOT EXISTS idx_cep_audit_log_estado  ON public.cep_audit_log USING btree (estado);

GRANT ALL ON TABLE public.cep_audit_log TO service_role;
