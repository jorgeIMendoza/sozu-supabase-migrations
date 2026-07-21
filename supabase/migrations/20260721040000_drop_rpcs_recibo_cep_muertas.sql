-- DROP de 4 RPCs muertas tras retirar /validates y /audit/recibo/rescue del micro
-- Fecha: 2026-07-20
--
-- consolidate pasó a ser el homogenizador universal (PostgREST directo). Con eso se
-- eliminaron del código los endpoints /api/v1/validates* y /api/v1/audit/recibo/rescue,
-- y estas 4 funciones quedaron sin ningún llamador.
--
-- Verificado read-only vs prod 2026-07-20:
--  - Ninguna otra función referencia sus nombres en su cuerpo.
--  - Ninguna vista/trigger/default depende de ellas (pg_depend).
--  => muertas, DROP seguro.
--
-- Firmas exactas confirmadas con pg_proc (OJO: get_payments_recibo_for_validation es
-- (text,integer,text[],text[]) — 4 params, no 3 como decía el runbook; con la firma
-- equivocada + IF EXISTS el DROP sería un no-op silencioso).
--
-- Idempotente: DROP FUNCTION IF EXISTS con firma exacta.

DROP FUNCTION IF EXISTS public.update_payment_cep_from_recibo(jsonb);
DROP FUNCTION IF EXISTS public.get_payments_recibo_for_validation(text, integer, text[], text[]);
DROP FUNCTION IF EXISTS public.rescue_recibo_to_cep(text[]);
DROP FUNCTION IF EXISTS public.migrate_invalid_cep_to_recibo(text[]);
