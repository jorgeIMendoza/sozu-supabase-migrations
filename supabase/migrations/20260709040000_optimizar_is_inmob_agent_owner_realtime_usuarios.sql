-- Optimizar is_inmob_agent_owner + reactivar realtime de usuarios
-- Fecha: 2026-07-09
--
-- El poller de Realtime (WALRUS) se caía con query_canceled evaluando las policies de
-- usuarios que llaman a is_inmob_agent_owner() (corre por cada cambio × cada suscriptor,
-- con joins sin índices). Se sacó usuarios de la publicación como mitigación (en prod);
-- esto la optimiza para regresarla. Misma semántica: índices + reescritura con salidas
-- tempranas (roles sin relación inmobiliaria salen tras 1 index lookup).
--
-- Idempotente: CREATE INDEX IF NOT EXISTS, CREATE OR REPLACE, guard en la publicación
-- (en dev usuarios sigue en la publicación → no-op; en prod se re-agrega). Sin CONCURRENTLY
-- (CI/CD envuelve en tx). Sin BEGIN/COMMIT.

-- ==============================================================
-- Paso 1 — Índices
-- ==============================================================

CREATE INDEX IF NOT EXISTS idx_usuarios_auth_user_id_activo
  ON public.usuarios (auth_user_id) WHERE (activo = true);

CREATE INDEX IF NOT EXISTS idx_usuarios_email_lower_activo
  ON public.usuarios (lower(email)) WHERE (activo = true);

-- Agentes por inmobiliaria dueña (tipo 19): rama agentes + verificación final.
CREATE INDEX IF NOT EXISTS idx_entrel_t19_dueno
  ON public.entidades_relacionadas (id_persona_duena_lead)
  WHERE (id_tipo_entidad = 19 AND activo = true);

CREATE INDEX IF NOT EXISTS idx_entrel_t19_persona
  ON public.entidades_relacionadas (id_persona)
  WHERE (id_tipo_entidad = 19 AND activo = true);

-- Fallback por proyectos_acceso.
CREATE INDEX IF NOT EXISTS idx_proyacc_usuario_lower_activo
  ON public.proyectos_acceso (lower(usuario_id)) WHERE (activo = true);

-- ==============================================================
-- Paso 2 — Función con salidas tempranas (misma lógica)
-- ==============================================================

CREATE OR REPLACE FUNCTION public.is_inmob_agent_owner(target_email text)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_id_persona bigint;
  v_rol integer;
  v_email text;
BEGIN
  -- Actor (1 lookup indexado).
  SELECT u.id_persona, u.rol_id, u.email
    INTO v_id_persona, v_rol, v_email
  FROM public.usuarios u
  WHERE u.activo = true
    AND (
      u.auth_user_id = auth.uid()
      OR lower(u.email) = lower(auth.jwt() ->> 'email')
    )
  ORDER BY CASE WHEN u.auth_user_id = auth.uid() THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_rol IS NULL THEN
    RETURN false;                 -- sin usuario interno: nada que evaluar
  END IF;

  IF v_rol IN (1, 2) THEN
    RETURN true;                  -- Super Admin / Admin Proyecto: acceso total
  END IF;

  IF v_rol NOT IN (3, 4, 9) THEN
    RETURN false;                 -- roles sin contexto inmobiliaria (corto)
  END IF;

  RETURN EXISTS (
    WITH owner_candidates AS (
      -- Agentes: inmobiliaria dueña por relación tipo 19.
      SELECT er.id_persona_duena_lead::bigint AS owner_persona
      FROM public.entidades_relacionadas er
      WHERE v_rol IN (3, 9)
        AND er.id_persona = v_id_persona
        AND er.id_tipo_entidad = 19
        AND er.activo = true
        AND er.id_persona_duena_lead IS NOT NULL

      UNION

      -- Usuario inmobiliaria: su id_persona solo si tiene agentes vinculados.
      SELECT v_id_persona::bigint
      WHERE v_rol = 4
        AND v_id_persona IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM public.entidades_relacionadas er_check
          WHERE er_check.id_tipo_entidad = 19
            AND er_check.activo = true
            AND er_check.id_persona_duena_lead = v_id_persona
        )

      UNION

      -- Fallback por proyectos_acceso (inmobiliaria secundaria).
      SELECT er_owner.id_persona::bigint
      FROM public.proyectos_acceso pa
      JOIN public.entidades_relacionadas er_owner
        ON er_owner.id = pa.id_entidad_relacionada_dueno
       AND er_owner.id_tipo_entidad = 5
       AND er_owner.activo = true
      WHERE lower(pa.usuario_id) = lower(v_email)
        AND pa.activo = true
        AND pa.id_entidad_relacionada_dueno IS NOT NULL
    )
    SELECT 1
    FROM owner_candidates oc
    JOIN public.entidades_relacionadas er_agent
      ON er_agent.id_tipo_entidad = 19
     AND er_agent.activo = true
     AND er_agent.id_persona_duena_lead = oc.owner_persona
    JOIN public.usuarios u_agent
      ON u_agent.id_persona = er_agent.id_persona
    WHERE oc.owner_persona IS NOT NULL
      AND lower(u_agent.email) = lower(trim(target_email))
  );
END;
$$;

-- ==============================================================
-- Paso 4 — Reactivar realtime de usuarios (guard: ADD TABLE falla si ya es miembro)
-- ==============================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'usuarios'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.usuarios;
  END IF;
END $$;
