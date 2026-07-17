-- CRM tareas: campos extra para paridad con el form de HubSpot.
-- Fecha: 2026-07-16
--
-- Agrega a public.crm_tareas:
--   * descripcion          — Notas de la tarea (texto libre).
--   * hora de vencimiento  — se migra `fecha_vencimiento` de DATE a TIMESTAMPTZ
--                            para soportar fecha + hora (HubSpot muestra hora, ej. 8:00).
--   * fecha_recordatorio   — momento exacto en que debe dispararse el recordatorio
--                            (NULL = sin recordatorio). Lo calcula el front a partir
--                            del vencimiento (ej. "1 hora antes").
--   * recordatorio_enviado — gate de idempotencia para el cron de recordatorios.
--   * recurrencia          — NULL = no se repite; si no, la cadencia
--                            (diaria/semanal/quincenal/mensual/anual). La regeneración
--                            de la siguiente ocurrencia la hace el front al completar.
--
-- Además programa el cron `crm-recordatorios-tareas` (cada 15 min) que invoca la edge
-- function homónima (repo sozu-edge-functions). Lee functions_base_url / supabase_anon_key
-- de private.sozu_config igual que los demás crons; si faltan, no dispara.
--
-- Idempotente (ADD COLUMN IF NOT EXISTS, CREATE OR REPLACE, unschedule+schedule por
-- nombre). Sin BEGIN/COMMIT (el CI/CD envuelve en tx).

-- ─── Columnas nuevas ──────────────────────────────────────────────────────────
ALTER TABLE public.crm_tareas
    ADD COLUMN IF NOT EXISTS descripcion          TEXT,
    ADD COLUMN IF NOT EXISTS fecha_recordatorio   TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS recordatorio_enviado BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS recurrencia          TEXT;

-- Vencimiento con hora: DATE → TIMESTAMPTZ (idempotente: solo si sigue siendo date).
-- Los valores existentes se castean a medianoche en la zona del servidor.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = 'crm_tareas'
          AND column_name  = 'fecha_vencimiento'
          AND data_type    = 'date'
    ) THEN
        ALTER TABLE public.crm_tareas
            ALTER COLUMN fecha_vencimiento TYPE TIMESTAMPTZ
            USING fecha_vencimiento::timestamptz;
    END IF;
END $$;

-- Valida la cadencia de recurrencia permitida (idempotente).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'crm_tareas_recurrencia_check'
    ) THEN
        ALTER TABLE public.crm_tareas
            ADD CONSTRAINT crm_tareas_recurrencia_check
            CHECK (recurrencia IS NULL OR recurrencia IN
                ('diaria','semanal','quincenal','mensual','anual'));
    END IF;
END $$;

-- Índice para el escaneo del cron de recordatorios (solo tareas con recordatorio pendiente).
CREATE INDEX IF NOT EXISTS idx_crm_tareas_recordatorio
    ON public.crm_tareas (fecha_recordatorio)
    WHERE activo = TRUE AND recordatorio_enviado = FALSE AND fecha_recordatorio IS NOT NULL;

-- ─── Cron: crm-recordatorios-tareas ───────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION public.disparar_crm_recordatorios_tareas()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_base text;
    v_anon text;
BEGIN
    SELECT value INTO v_base FROM private.sozu_config WHERE key = 'functions_base_url';
    SELECT value INTO v_anon FROM private.sozu_config WHERE key = 'supabase_anon_key';

    -- Sin config → no disparar (evita URL nula / header sin token).
    IF v_base IS NULL OR v_anon IS NULL THEN
        RETURN;
    END IF;

    PERFORM net.http_post(
        url     := rtrim(v_base, '/') || '/crm-recordatorios-tareas',
        headers := jsonb_build_object(
            'Content-Type',  'application/json',
            'Authorization', 'Bearer ' || v_anon,
            'apikey',        v_anon
        ),
        body    := '{}'::jsonb
    );
END;
$$;

-- Reprogramar de forma idempotente.
DO $$
BEGIN
    PERFORM cron.unschedule('crm-recordatorios-tareas');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

SELECT cron.schedule(
    'crm-recordatorios-tareas',
    '*/15 * * * *',
    $$SELECT public.disparar_crm_recordatorios_tareas()$$
);
