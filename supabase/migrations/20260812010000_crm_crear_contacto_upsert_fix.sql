-- HOTFIX: crm_crear_contacto tronaba en CADA alta nueva del CRM con "duplicate key"
-- (UNIQUE crm_leads_atr_er_unica) → el front lo mostraba como "Ese contacto ya existe".
--
-- CAUSA: la entidad_relacionada tipo 7 tiene un trigger AFTER INSERT
-- (fn_crm_lead_autoasignar + fn_crm_sync_dueno_desde_er) que YA crea la fila de
-- crm_leads_atribucion para esa entidad (con ON CONFLICT). La versión previa de esta RPC
-- (20260811010000) hacía DESPUÉS su propio INSERT plano de la misma fila → colisión con el
-- UNIQUE(id_entidad_relacionada). El código viejo del front toleraba el choque porque su
-- insert de atribución era best-effort (console.warn); la RPC lo lanzaba duro.
--
-- FIX: la RPC ahora hace UPSERT de la atribución (ON CONFLICT (id_entidad_relacionada) DO
-- UPDATE) en vez de INSERT plano. Si el trigger ya creó la fila, la ACTUALIZA con los valores
-- del alta del CRM (origen='crm' + estado/etapa/propietario elegidos en el form); si no existe,
-- la crea. Firma idéntica (CREATE OR REPLACE) → no requiere tocar el front. Sin BEGIN/COMMIT.

CREATE OR REPLACE FUNCTION public.crm_crear_contacto(
    p_nombre            text,
    p_email             text    DEFAULT NULL,
    p_telefono          text    DEFAULT NULL,
    p_id_proyecto       integer DEFAULT NULL,
    p_estatus_lead      text    DEFAULT 'nuevo',
    p_etapa_ciclo_vida  text    DEFAULT 'lead',
    p_id_propietario    uuid    DEFAULT NULL,
    p_id_categoria      integer DEFAULT NULL)
RETURNS TABLE (persona_id integer, entidad_id bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_owner_uuid    uuid    := COALESCE(p_id_propietario, auth.uid());
    v_owner_persona integer;
    v_persona_id    integer;
    v_entidad_id    bigint;
BEGIN
    IF p_nombre IS NULL OR btrim(p_nombre) = '' THEN
        RAISE EXCEPTION 'El nombre del contacto es obligatorio';
    END IF;

    -- Dueño del lead (persona id) a partir del propietario/creador -> satisface can_access_agent_owned_lead.
    SELECT u.id_persona INTO v_owner_persona
    FROM public.usuarios u WHERE u.auth_user_id = v_owner_uuid LIMIT 1;

    -- 1. Persona
    INSERT INTO public.personas (tipo_persona, nombre_legal, email, telefono)
    VALUES ('pf', btrim(p_nombre),
            NULLIF(btrim(COALESCE(p_email, '')), ''),
            NULLIF(btrim(COALESCE(p_telefono, '')), ''))
    RETURNING id INTO v_persona_id;

    -- 2. Entidad (prospecto tipo 7) CON dueño. OJO: su trigger AFTER INSERT ya crea la fila de
    --    crm_leads_atribucion, por eso el paso 3 es UPSERT, no INSERT.
    INSERT INTO public.entidades_relacionadas (id_persona, id_tipo_entidad, id_proyecto, activo, id_persona_duena_lead)
    VALUES (v_persona_id, 7, p_id_proyecto, true, v_owner_persona)
    RETURNING id INTO v_entidad_id;

    -- 3. Atribución (estado del CRM) — UPSERT sobre la fila que ya dejó el trigger de la entidad.
    INSERT INTO public.crm_leads_atribucion (id_entidad_relacionada, estatus_lead, etapa_ciclo_vida, id_propietario, origen)
    VALUES (v_entidad_id,
            COALESCE(NULLIF(btrim(COALESCE(p_estatus_lead, '')), ''), 'nuevo'),
            COALESCE(NULLIF(btrim(COALESCE(p_etapa_ciclo_vida, '')), ''), 'lead'),
            v_owner_uuid, 'crm')
    ON CONFLICT (id_entidad_relacionada) DO UPDATE
      SET estatus_lead     = EXCLUDED.estatus_lead,
          etapa_ciclo_vida = EXCLUDED.etapa_ciclo_vida,
          id_propietario   = COALESCE(EXCLUDED.id_propietario, public.crm_leads_atribucion.id_propietario),
          origen           = 'crm';

    -- 4. Categoría (opcional, idempotente).
    IF p_id_categoria IS NOT NULL THEN
        INSERT INTO public.entidades_relacionadas_categorias (id_entidad_relacionada, id_categoria, activo)
        VALUES (v_entidad_id, p_id_categoria, true)
        ON CONFLICT DO NOTHING;
    END IF;

    persona_id := v_persona_id;
    entidad_id := v_entidad_id;
    RETURN NEXT;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.crm_crear_contacto(text, text, text, integer, text, text, uuid, integer)
    TO authenticated;
