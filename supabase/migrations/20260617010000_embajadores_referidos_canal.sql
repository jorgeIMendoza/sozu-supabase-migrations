-- Agrega columna `canal` a embajadores_referidos.
-- Fecha: 2026-06-17
--
-- El frontend (AmbassadorsContext.loadReferrals) SELECTa `canal` de forma
-- incondicional, mientras que el INSERT (ReferralFormDialog) ya degrada con
-- DDL probe. Al faltar la columna en dev y prod, la lectura fallaba con
-- PostgREST 400: «column embajadores_referidos.canal does not exist».
--
-- `canal` registra el origen del referido. Valores válidos (type ReferralCanal):
--   admin · portal_embajador · link_referido · importacion
-- Nullable: el front mapea `row.canal ?? undefined`, así que NULL es aceptable
-- para filas históricas previas a esta migración.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS + CHECK guardado por nombre.

ALTER TABLE public.embajadores_referidos
    ADD COLUMN IF NOT EXISTS canal text;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'embajadores_referidos_canal_check'
          AND conrelid = 'public.embajadores_referidos'::regclass
    ) THEN
        ALTER TABLE public.embajadores_referidos
            ADD CONSTRAINT embajadores_referidos_canal_check
            CHECK (canal IS NULL OR canal IN ('admin','portal_embajador','link_referido','importacion'));
    END IF;
END $$;
