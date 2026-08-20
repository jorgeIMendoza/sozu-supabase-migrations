-- Trigger: toda alta/reactivación en public.compradores garantiza la entidad
-- relacionada tipo 2 (Comprador, id_proyecto NULL) de la persona.
--
-- Sin esa fila la persona existe como comprador de la cuenta de cobranza pero no
-- aparece en Personas > Compradores (/admin/compradores). El front ya se corrigió
-- (EditCuentaCobranzaDialog.addCompradorMutation), pero hay altas que no pasan por
-- ahí: EF `asignar-propiedad`, el trigger de cónyuge (agregar_conyuge_como_comprador)
-- y cualquier alta por SQL.
--
-- Notas de diseño verificadas contra prod (2026-08-20):
--   * uq_entrel_persona_tipo_proy_cuenta no dedupe con id_proyecto NULL (los NULL son
--     distintos entre sí en un índice único), así que el guard va con NOT EXISTS.
--   * id_estatus_persona se deja en NULL: las 753 filas activas tipo 2 de prod lo
--     tienen en NULL; el valor 3 sólo lo usa el flujo de prospectos (tipo 7).
--   * Los triggers del CRM sobre entidades_relacionadas (fn_crm_lead_autoasignar,
--     fn_crm_sync_dueno_desde_er) salen temprano cuando id_tipo_entidad <> 7, así que
--     esta fila no dispara atribución de leads.
--   * SECURITY DEFINER: los inserts llegan como service_role (EF), authenticated
--     (front) y desde otro trigger; la RLS de entidades_relacionadas no debe poder
--     bloquear la fila que hace visible al comprador.
--   * No corrige datos existentes (eso va como DML aparte).

BEGIN;

CREATE OR REPLACE FUNCTION public.asegurar_entidad_comprador()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.activo IS NOT TRUE OR NEW.id_persona IS NULL THEN
    RETURN NULL;
  END IF;

  -- NULL::integer explícito: en INSERT ... SELECT sin contexto Postgres infiere text
  -- y revienta con 42804.
  INSERT INTO public.entidades_relacionadas
    (id_persona, id_tipo_entidad, id_proyecto, activo)
  SELECT NEW.id_persona, 2, NULL::integer, true
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.entidades_relacionadas er
    WHERE er.id_persona = NEW.id_persona
      AND er.id_tipo_entidad = 2
      AND er.id_proyecto IS NULL
      AND er.activo = true
  );

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.asegurar_entidad_comprador() IS
  'Garantiza la entidad relacionada tipo 2 (Comprador, id_proyecto NULL) de toda persona '
  'insertada/activada en compradores. Sin esa fila la persona no aparece en '
  'Personas > Compradores (/admin/compradores).';

-- Las funciones nuevas en public nacen con EXECUTE para PUBLIC/anon por DEFAULT
-- PRIVILEGES; una función de trigger no debe ser invocable como RPC.
REVOKE ALL ON FUNCTION public.asegurar_entidad_comprador() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.asegurar_entidad_comprador() FROM anon;
REVOKE ALL ON FUNCTION public.asegurar_entidad_comprador() FROM authenticated;

DROP TRIGGER IF EXISTS trg_asegurar_entidad_comprador ON public.compradores;

CREATE TRIGGER trg_asegurar_entidad_comprador
AFTER INSERT OR UPDATE OF id_persona, activo ON public.compradores
FOR EACH ROW
WHEN (NEW.activo = true)
EXECUTE FUNCTION public.asegurar_entidad_comprador();

-- Self-verifying: si el trigger no quedó, aborta y el CI truena aquí y no en runtime.
DO $verify$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'compradores'
      AND t.tgname = 'trg_asegurar_entidad_comprador'
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'trg_asegurar_entidad_comprador no quedó creado en public.compradores';
  END IF;
END
$verify$;

COMMIT;
