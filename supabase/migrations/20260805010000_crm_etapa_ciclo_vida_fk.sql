-- crm_leads_atribucion.etapa_ciclo_vida (TEXT, guarda la clave de la etapa) -> se agrega la
-- FK id_etapa_ciclo_vida -> crm_meta_conversion_stages(id). Pedido por el portal del agente
-- (Eduardo) / app movil, que necesitan el id, no el texto plano.
--
-- ADITIVA y sin ruptura: la columna de texto SE CONSERVA. IMPORTANTE: la integracion de Meta
-- (Conversions API) lee etapa_ciclo_vida en TEXTO desde el front y la cruza con
-- crm_meta_conversion_stages para disparar los eventos; al conservar el texto, esa integracion
-- NO se toca. Verificado: ningun trigger/funcion de BD depende de etapa_ciclo_vida.
--
-- El catalogo destino es crm_meta_conversion_stages (YA existe; tiene las etapas
-- lead/mql/sql/opportunity/customer, keyed por etapa_ciclo_vida). FK con ON DELETE SET NULL:
-- esa tabla la gestiona el modulo Meta; si alguna etapa se borrara (hoy la UI no lo permite),
-- el lead solo pierde el id y conserva el texto, sin truene.
--
-- Backfill verificado en dev: 2307/2307 filas mapean, 0 sin mapear. Idempotente, sin BEGIN/COMMIT
-- (supabase db push envuelve cada migracion en su propia transaccion).

-- ─── 1) Columna FK (nullable) ─────────────────────────────────────────────────
ALTER TABLE public.crm_leads_atribucion
    ADD COLUMN IF NOT EXISTS id_etapa_ciclo_vida INTEGER
    REFERENCES public.crm_meta_conversion_stages(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_crm_leads_atribucion_id_etapa_ciclo_vida
    ON public.crm_leads_atribucion (id_etapa_ciclo_vida);

-- ─── 2) Backfill (match por el texto de la etapa; etapa_ciclo_vida es unica en el catalogo) ───
UPDATE public.crm_leads_atribucion a
SET    id_etapa_ciclo_vida = s.id
FROM   public.crm_meta_conversion_stages s
WHERE  lower(s.etapa_ciclo_vida) = lower(btrim(a.etapa_ciclo_vida))
  AND  a.id_etapa_ciclo_vida IS NULL;

-- ─── 3) Trigger de transicion bidireccional texto<->id ────────────────────────
-- En INSERT: si viene el id, manda el id (deriva el texto); si no, deriva el id del texto.
-- En UPDATE: gana la columna que cambio (id -> deriva texto; texto -> deriva id).
CREATE OR REPLACE FUNCTION public.crm_sync_etapa_ciclo_vida_id()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_norm TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.id_etapa_ciclo_vida IS NOT NULL THEN
            NEW.etapa_ciclo_vida := COALESCE(
                (SELECT etapa_ciclo_vida FROM public.crm_meta_conversion_stages WHERE id = NEW.id_etapa_ciclo_vida),
                NEW.etapa_ciclo_vida);
        ELSIF NEW.etapa_ciclo_vida IS NOT NULL THEN
            v_norm := lower(btrim(NEW.etapa_ciclo_vida));
            NEW.id_etapa_ciclo_vida := (SELECT id FROM public.crm_meta_conversion_stages
                                        WHERE lower(etapa_ciclo_vida) = v_norm ORDER BY id LIMIT 1);
        END IF;
    ELSE  -- UPDATE
        IF NEW.id_etapa_ciclo_vida IS DISTINCT FROM OLD.id_etapa_ciclo_vida THEN
            NEW.etapa_ciclo_vida := COALESCE(
                (SELECT etapa_ciclo_vida FROM public.crm_meta_conversion_stages WHERE id = NEW.id_etapa_ciclo_vida),
                NEW.etapa_ciclo_vida);
        ELSIF NEW.etapa_ciclo_vida IS DISTINCT FROM OLD.etapa_ciclo_vida THEN
            v_norm := lower(btrim(NEW.etapa_ciclo_vida));
            NEW.id_etapa_ciclo_vida := (SELECT id FROM public.crm_meta_conversion_stages
                                        WHERE lower(etapa_ciclo_vida) = v_norm ORDER BY id LIMIT 1);
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_crm_sync_etapa_ciclo_vida_id ON public.crm_leads_atribucion;
CREATE TRIGGER trg_crm_sync_etapa_ciclo_vida_id
BEFORE INSERT OR UPDATE OF etapa_ciclo_vida, id_etapa_ciclo_vida ON public.crm_leads_atribucion
FOR EACH ROW EXECUTE FUNCTION public.crm_sync_etapa_ciclo_vida_id();

COMMENT ON COLUMN public.crm_leads_atribucion.id_etapa_ciclo_vida IS
    'FK a crm_meta_conversion_stages(id). En transicion convive con etapa_ciclo_vida (TEXT), que la integracion de Meta lee. El trigger trg_crm_sync_etapa_ciclo_vida_id los mantiene sincronizados.';
