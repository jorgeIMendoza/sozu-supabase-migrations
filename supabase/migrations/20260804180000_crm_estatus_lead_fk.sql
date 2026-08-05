-- crm_leads_atribucion.estatus_lead (TEXT, guarda la `clave` de crm_estados_lead) -> se
-- agrega la FK id_estatus_lead. Pedido por el portal del agente (Eduardo) / app movil, que
-- necesitan el id, no el texto plano, ya que el catalogo crece.
--
-- ADITIVA y sin ruptura: la columna de texto SE CONSERVA; un trigger mantiene texto<->id
-- sincronizados durante la transicion (el CRM escribe texto, el portal externo escribe id).
-- El cutover (quitar la columna de texto y el trigger) es una migracion futura aparte,
-- cuando TODOS los consumidores usen el id.
--
-- Verificado contra datos reales: los 16 claves de crm_estados_lead cubren los 16 valores
-- limpios de estatus_lead, y el unico sucio ("asesor inmobiliario" con espacio) se normaliza
-- a asesor_inmobiliario -> backfill sin perdida (2307/2307 filas en dev).
--
-- Idempotente y self-guarded. Sin BEGIN/COMMIT (supabase db push envuelve cada migracion en
-- su propia transaccion). NO toca etapa_ciclo_vida ni el modulo Meta (crm_meta_conversion_stages).

-- ─── 1) Columna FK (nullable durante la transicion) ───────────────────────────
ALTER TABLE public.crm_leads_atribucion
    ADD COLUMN IF NOT EXISTS id_estatus_lead INTEGER
    REFERENCES public.crm_estados_lead(id);

CREATE INDEX IF NOT EXISTS idx_crm_leads_atribucion_id_estatus_lead
    ON public.crm_leads_atribucion (id_estatus_lead);

-- ─── 2) Backfill (normaliza espacios/mayusculas: "asesor inmobiliario" -> asesor_inmobiliario) ───
UPDATE public.crm_leads_atribucion a
SET    id_estatus_lead = c.id
FROM   public.crm_estados_lead c
WHERE  c.clave = lower(regexp_replace(btrim(a.estatus_lead), '\s+', '_', 'g'))
  AND  a.id_estatus_lead IS NULL;

-- ─── 3) Trigger de transicion bidireccional texto<->id ────────────────────────
-- En INSERT: si viene el id, manda el id (deriva el texto); si no, deriva el id del texto.
-- En UPDATE: gana la columna que cambio (id -> deriva texto; texto -> deriva id).
CREATE OR REPLACE FUNCTION public.crm_sync_estatus_lead_id()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_norm TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.id_estatus_lead IS NOT NULL THEN
            NEW.estatus_lead := COALESCE(
                (SELECT clave FROM public.crm_estados_lead WHERE id = NEW.id_estatus_lead),
                NEW.estatus_lead);
        ELSIF NEW.estatus_lead IS NOT NULL THEN
            v_norm := lower(regexp_replace(btrim(NEW.estatus_lead), '\s+', '_', 'g'));
            NEW.id_estatus_lead := (SELECT id FROM public.crm_estados_lead WHERE clave = v_norm);
        END IF;
    ELSE  -- UPDATE
        IF NEW.id_estatus_lead IS DISTINCT FROM OLD.id_estatus_lead THEN
            NEW.estatus_lead := COALESCE(
                (SELECT clave FROM public.crm_estados_lead WHERE id = NEW.id_estatus_lead),
                NEW.estatus_lead);
        ELSIF NEW.estatus_lead IS DISTINCT FROM OLD.estatus_lead THEN
            v_norm := lower(regexp_replace(btrim(NEW.estatus_lead), '\s+', '_', 'g'));
            NEW.id_estatus_lead := (SELECT id FROM public.crm_estados_lead WHERE clave = v_norm);
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_crm_sync_estatus_lead_id ON public.crm_leads_atribucion;
CREATE TRIGGER trg_crm_sync_estatus_lead_id
BEFORE INSERT OR UPDATE OF estatus_lead, id_estatus_lead ON public.crm_leads_atribucion
FOR EACH ROW EXECUTE FUNCTION public.crm_sync_estatus_lead_id();

COMMENT ON COLUMN public.crm_leads_atribucion.id_estatus_lead IS
    'FK a crm_estados_lead(id). En transicion convive con estatus_lead (TEXT); el trigger trg_crm_sync_estatus_lead_id los mantiene sincronizados. Cutover futuro: dejar solo el id.';
