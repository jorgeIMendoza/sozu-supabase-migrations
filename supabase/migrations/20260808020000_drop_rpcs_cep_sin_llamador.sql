-- 20260808020000_drop_rpcs_cep_sin_llamador.sql
--
-- Elimina tres RPC que se quedaron sin llamador el 2026-08-08, cuando el
-- microservicio borro sus endpoints:
--
--   * /audit/cep (+ status y pending-chains): la verificacion de "este PDF es un
--     CEP real de Banxico" se fusiono dentro de consolidate, que ya la hacia para
--     decidir el bucket. Si el metodo exige CEP (STP, STP-manual, transferencia) y
--     el archivo no lo es, el pago queda en `error` con el motivo nombrado.
--     pending-chains alimentaba a server-stp para generar los CEP faltantes; ese
--     flujo ya no se usa.
--   * /kpi/sin-evidencia: el mismo dato sale del Excel de consolidate — los pagos
--     sin url_cep ni url_recibo salen como `skipped`.
--
-- NO se toca: cep_audit_log (consolidate sigue escribiendo ahi) ni
-- save_cep_audit_results(jsonb) (la RPC con la que consolidate escribe esa tabla).
--
-- Deuda que deja (no bloquea): cep_audit_log conserva banco_ordenante,
-- banco_beneficiario y num_cuenta, que solo llenaba /audit/cep y ahora quedan en
-- null. Se dropean en otra migracion cuando se confirme que server-stp no vuelve.
--
-- Rollback: recrear las funciones desde el historial de migraciones
-- (20260609123752, 20260609123930, 20260617060000). El micro no las volveria a
-- llamar sin revertir tambien su codigo.

BEGIN;

-- Firmas confirmadas contra dev y prod el 2026-08-08 (identity arguments exactos).
DROP FUNCTION IF EXISTS public.get_payments_for_cep_audit(
  p_proyecto text, p_limit integer, p_excluir_proyectos text[], p_metodos text[]);

DROP FUNCTION IF EXISTS public.get_pending_cep_chains(
  p_limit integer, p_offset integer);

DROP FUNCTION IF EXISTS public.get_payments_sin_evidencia(
  p_proyecto text, p_metodo text, p_limit integer, p_excluir_proyectos text[]);

-- Self-verifying: si sobrevive alguna sobrecarga con otra firma, aborta en vez de
-- dejar la funcion viva y el CI en verde.
DO $$
DECLARE
  v_restantes text;
BEGIN
  SELECT string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    INTO v_restantes
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'get_payments_for_cep_audit',
      'get_pending_cep_chains',
      'get_payments_sin_evidencia'
    );

  IF v_restantes IS NOT NULL THEN
    RAISE EXCEPTION
      'Quedaron sobrecargas sin dropear: %. Agrega el DROP con su firma exacta.',
      v_restantes;
  END IF;
END;
$$;

COMMIT;
