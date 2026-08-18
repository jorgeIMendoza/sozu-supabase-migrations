-- Backfill: cada AGENTE REGISTRADO (usuarios rol 3 "Agente Inmobiliario" UNIÓN entidades tipo 19
-- "Agente") que aún NO es contacto del CRM (sin entidad tipo 2/7 activa) recibe:
--   1) entidad tipo 7 (contacto), dueño = Keity (keity.galindo@sozu.com)
--   2) atribución con estatus_lead = 'asesor_inmobiliario' (crm_estados_lead id 13) — UPSERT sobre la
--      fila que YA deja el trigger fn_crm_lead_autoasignar al insertar la entidad tipo 7
--   3) categoría "Agente Externo" (crm_categorias id 3)
--   4) negocio en pipeline "Onboarding Externos" (id 4), etapa "Registro Exitoso" (id 27), dueño Keity
--
-- Solo los FALTANTES (los ~63 que ya son contacto NO se tocan). Idempotente: al re-correr, quien ya
-- tenga entidad tipo 7 se salta (ya no está en "faltantes"). Sin BEGIN/COMMIT (supabase db push
-- envuelve cada migración en su propia tx → si algo falla, se revierte todo).

DO $$
DECLARE
  v_keity_persona integer;
  v_keity_uid     uuid;
  r               RECORD;
  v_entidad       bigint;
BEGIN
  SELECT u.id_persona, u.auth_user_id INTO v_keity_persona, v_keity_uid
  FROM public.usuarios u
  WHERE u.email = 'keity.galindo@sozu.com' AND u.activo = true
  LIMIT 1;

  IF v_keity_uid IS NULL THEN
    RAISE EXCEPTION 'Backfill agentes: no se encontró al propietario keity.galindo@sozu.com';
  END IF;

  FOR r IN
    SELECT p.id AS persona_id, p.nombre_legal
    FROM public.personas p
    WHERE p.activo = true
      AND (
        EXISTS (SELECT 1 FROM public.usuarios u
                WHERE u.id_persona = p.id AND u.rol_id = 3 AND u.activo = true)
        OR EXISTS (SELECT 1 FROM public.entidades_relacionadas e
                   WHERE e.id_persona = p.id AND e.id_tipo_entidad = 19 AND e.activo = true)
      )
      AND NOT EXISTS (SELECT 1 FROM public.entidades_relacionadas e
                      WHERE e.id_persona = p.id AND e.id_tipo_entidad IN (2, 7) AND e.activo = true)
  LOOP
    -- 1. Contacto (entidad tipo 7). Su trigger AFTER INSERT ya crea la fila de crm_leads_atribucion.
    INSERT INTO public.entidades_relacionadas (id_persona, id_tipo_entidad, activo, id_persona_duena_lead)
    VALUES (r.persona_id, 7, true, v_keity_persona)
    RETURNING id INTO v_entidad;

    -- 2. Atribución: estatus 'asesor_inmobiliario' + dueño Keity (UPSERT sobre lo que dejó el trigger;
    --    el trigger crm_sync_estatus_lead_id deriva id_estatus_lead=13 desde el texto).
    INSERT INTO public.crm_leads_atribucion (id_entidad_relacionada, estatus_lead, id_propietario, origen, activo)
    VALUES (v_entidad, 'asesor_inmobiliario', v_keity_uid, 'crm', true)
    ON CONFLICT (id_entidad_relacionada) DO UPDATE
      SET estatus_lead   = EXCLUDED.estatus_lead,
          id_propietario = EXCLUDED.id_propietario,
          origen         = EXCLUDED.origen;

    -- 3. Categoría "Agente Externo" (id 3).
    INSERT INTO public.entidades_relacionadas_categorias (id_entidad_relacionada, id_categoria, activo)
    VALUES (v_entidad, 3, true)
    ON CONFLICT DO NOTHING;

    -- 4. Negocio en Onboarding Externos (4) / Registro Exitoso (27), dueño Keity.
    INSERT INTO public.crm_negocios (nombre, id_pipeline, id_etapa, id_entidad_relacionada, id_usuario_propietario, activo)
    VALUES (COALESCE(NULLIF(btrim(r.nombre_legal), ''), 'Agente') || ' · Onboarding',
            4, 27, v_entidad, v_keity_uid, true);
  END LOOP;
END $$;
