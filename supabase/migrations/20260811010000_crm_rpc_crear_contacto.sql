-- RPC atomica para crear un contacto/prospecto desde el CRM. Reemplaza los 3 INSERTs sueltos
-- del front (persona -> entidad -> atribucion), que NO eran transaccionales: si el .select("id")
-- de la entidad no la podia leer (RLS can_access_agent_owned_lead devuelve false cuando el lead
-- tiene dueno NULL y el usuario no es admin ni tiene ver_todos), PostgREST abortaba esa fila y
-- quedaba la PERSONA huerfana. Bug vivo desde el deploy del 8-ago para roles no-admin.
--
-- Fixes que aplica esta RPC:
--   1) ATOMICA: persona + entidad + atribucion + categoria en UNA transaccion. Si algo falla,
--      se revierte TODO -> ya no quedan personas huerfanas.
--   2) SECURITY DEFINER: evita el problema del RETURNING bloqueado por RLS.
--   3) Fija id_persona_duena_lead = persona del propietario (o del creador si no se asigna) para
--      que la RLS de agentes deje VER el contacto recien creado (can_access_agent_owned_lead).
--
-- Idempotente (CREATE OR REPLACE). Sin BEGIN/COMMIT.

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

    -- Dueno del lead (persona id) a partir del propietario/creador -> satisface can_access_agent_owned_lead.
    SELECT u.id_persona INTO v_owner_persona
    FROM public.usuarios u WHERE u.auth_user_id = v_owner_uuid LIMIT 1;

    -- 1. Persona
    INSERT INTO public.personas (tipo_persona, nombre_legal, email, telefono)
    VALUES ('pf', btrim(p_nombre),
            NULLIF(btrim(COALESCE(p_email, '')), ''),
            NULLIF(btrim(COALESCE(p_telefono, '')), ''))
    RETURNING id INTO v_persona_id;

    -- 2. Entidad (prospecto tipo 7) CON dueno -> la RLS ya la deja ver (no truena el RETURNING).
    INSERT INTO public.entidades_relacionadas (id_persona, id_tipo_entidad, id_proyecto, activo, id_persona_duena_lead)
    VALUES (v_persona_id, 7, p_id_proyecto, true, v_owner_persona)
    RETURNING id INTO v_entidad_id;

    -- 3. Atribucion (estado del CRM).
    INSERT INTO public.crm_leads_atribucion (id_entidad_relacionada, estatus_lead, etapa_ciclo_vida, id_propietario, origen)
    VALUES (v_entidad_id,
            COALESCE(NULLIF(btrim(COALESCE(p_estatus_lead, '')), ''), 'nuevo'),
            COALESCE(NULLIF(btrim(COALESCE(p_etapa_ciclo_vida, '')), ''), 'lead'),
            v_owner_uuid, 'crm');

    -- 4. Categoria (opcional, best-effort dentro de la misma tx).
    IF p_id_categoria IS NOT NULL THEN
        INSERT INTO public.entidades_relacionadas_categorias (id_entidad_relacionada, id_categoria, activo)
        VALUES (v_entidad_id, p_id_categoria, true);
    END IF;

    persona_id := v_persona_id;
    entidad_id := v_entidad_id;
    RETURN NEXT;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.crm_crear_contacto(text, text, text, integer, text, text, uuid, integer)
    TO authenticated;
