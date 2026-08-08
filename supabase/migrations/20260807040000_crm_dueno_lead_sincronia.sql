-- Homologación CRM ↔ Portal Agente — 04: dueño del lead, fuente única y sincronía
-- Fecha: 2026-08-07
--
-- «De quién es este lead» tiene hoy dos respuestas que no se hablan:
-- `entidades_relacionadas.id_persona_duena_lead` (lo que ve el Portal Agente) y
-- `crm_leads_atribucion.id_propietario` (lo que administra el CRM). Este archivo declara
-- canónico el del CRM, sincroniza los dos sentidos por trigger y rellena el histórico.
--
-- ─── Por qué esto no es cosmético: la RLS cuelga del campo viejo ─────────────
-- Verificada la policy viva de SELECT sobre `entidades_relacionadas`:
--   is_admin_user() OR can_view_all_prospects() OR (id_tipo_entidad <> ALL (ARRAY[2,7]))
--   OR (id_tipo_entidad = ANY (ARRAY[2,7]) AND can_access_agent_owned_lead(id_persona_duena_lead::bigint))
-- La visibilidad de un lead depende EXCLUSIVAMENTE de `id_persona_duena_lead`. Los leads que
-- solo tienen `id_propietario` en el CRM tienen ese campo en NULL, así que su agente no puede
-- verlos con un SELECT directo por más que le pertenezcan. El backfill 2 es lo que los hace
-- visibles. La policy de UPDATE es igual de estricta
-- (`id_persona_duena_lead = get_current_user_persona_id()`), por eso las escrituras del 06 van
-- por RPC SECURITY DEFINER y no por UPDATE directo.
--
-- ─── Verificado read-only contra prod (tzmhgfjmddkfyffkkmto, 2026-08-07) ──────
--   * 3,426 entidades tipo 7 activas: 999 con `id_persona_duena_lead`, 2,239 con
--     `id_propietario`, **19 con ambos y 12 de esos contradictorios**, 1,143 sin ninguna fila
--     de atribución (invisibles para el CRM), 207 sin dueño por ningún lado, 10 con dueño que
--     no tiene usuario con `auth_user_id`. (El documento traía 3,416 / 993 / 2,231 / 17 / 12 /
--     1,142 / 209 / 10 del 5-ago: mismo cuadro, dos días después.)
--   * De los 207 sin dueño, **94** se resuelven por el creador de su oferta; **113** quedan
--     para repartir a mano en CRM > Asignación.
--   * `crm_leads_atr_er_unica` es UNIQUE (no parcial) sobre `id_entidad_relacionada`: el
--     `ON CONFLICT (id_entidad_relacionada)` es válido.
--   * `crm_leads_atribucion` no tiene CHECK sobre `origen` (default 'manual'), así que
--     'portal_agente' y 'oferta' entran sin problema; `estatus_lead` y `etapa_ciclo_vida` son
--     NOT NULL pero con DEFAULT, y el trigger del CRM deriva `id_estatus_lead` al insertar.
--   * `id_propietario` NO tiene FK a `auth.users`: insertar un auth_user_id de `usuarios` no
--     puede fallar por integridad referencial.
--   * Tipos: `id_persona_duena_lead`, `er.id_persona` y `usuarios.id_persona` son integer, así
--     que las firmas de los helpers resuelven sin cast.
--   * `agent_claim_or_reactivate_prospect_project` existe (2 sobrecargas) y escribe solo
--     `id_persona_duena_lead`: con estos triggers queda reflejada en el CRM sin tocarla.
--
-- ─── Cuatro correcciones respecto al documento ───────────────────────────────
-- 1. HELPERS DETERMINISTAS. `ORDER BY u.activo DESC LIMIT 1` no desempata: en prod **3
--    personas tienen más de un usuario con `auth_user_id`**, así que dos llamadas podían
--    devolver auth distintos y hacer oscilar la sincronía. Se agrega desempate estable.
-- 2. LOS CONFLICTOS SIEMPRE DEJAN RASTRO. El documento inserta la bitácora en
--    `crm_leads_reasignaciones` (tabla del 07) «si existe», pero **pisa el dueño anterior
--    igual cuando no existe** — y hoy no existe, porque el 07 corre después. Los 12 agentes
--    que pierden el lead se quedarían sin nada con qué reclamar. Aquí el respaldo se escribe
--    SIEMPRE en `_bak_conflicto_dueno_lead_20260807`, y además en `crm_leads_reasignaciones`
--    si ya está creada. El 07 puede importar de ahí.
-- 3. SIN GUARDA POR PROFUNDIDAD. `pg_trigger_depth() > 1` corta la recursión, pero también
--    apaga la sincronía cuando la escritura ocurre DENTRO de otro trigger — justo lo que va a
--    pasar cuando el 05 mueva dueños desde sus propios triggers. No hace falta: los dos
--    sentidos ya escriben solo si el valor cambia (`IS DISTINCT FROM` y `ON CONFLICT ... WHERE`),
--    y un UPDATE que no modifica ninguna fila no dispara el trigger del otro lado, así que la
--    ida y vuelta converge sola en dos saltos.
-- 4. LOS HELPERS NACEN SIN `anon`. Toda función nueva en `public` recibe EXECUTE para `anon` y
--    `authenticated` por defecto; siendo SECURITY DEFINER, `fn_persona_de_auth_user` sería un
--    oráculo público para mapear auth_user_id → persona. Se revoca al final. Los triggers y las
--    RPC del 06 corren como el dueño, así que no necesitan ese GRANT.
--
-- `id_persona_duena_lead` significa cosas distintas según el tipo de entidad: en tipo 7 es el
-- agente dueño del lead, pero en los tipos 1 y 19 es la INMOBILIARIA del agente. Por eso todos
-- los triggers y backfills filtran `id_tipo_entidad = 7`.
--
-- Idempotente: CREATE OR REPLACE, DROP TRIGGER IF EXISTS + CREATE, backfills convergentes.
-- Sin BEGIN/COMMIT (el CI envuelve cada migración en transacción).

-- ─────────────────────────────────────────────────────────────────────
-- 1. Helpers de conversión persona <-> auth_user_id
--    Sin filtrar por `usuarios.activo`: si el agente está dado de baja, su lead histórico
--    debe seguir apuntando a él. Filtrar aquí borraría atribución.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_auth_user_de_persona(p_id_persona integer)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT u.auth_user_id
  FROM public.usuarios u
  WHERE u.id_persona = p_id_persona AND u.auth_user_id IS NOT NULL
  ORDER BY u.activo DESC, u.auth_user_id      -- desempate estable: hay personas con 2 usuarios
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.fn_persona_de_auth_user(p_auth_user_id uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT u.id_persona
  FROM public.usuarios u
  WHERE u.auth_user_id = p_auth_user_id AND u.id_persona IS NOT NULL
  ORDER BY u.activo DESC, u.id_persona       -- desempate estable
  LIMIT 1;
$$;

COMMENT ON FUNCTION public.fn_auth_user_de_persona(integer) IS
  'Persona -> auth_user_id. No filtra por usuarios.activo: los leads de un agente dado de baja siguen siendo suyos.';
COMMENT ON FUNCTION public.fn_persona_de_auth_user(uuid) IS
  'auth_user_id -> persona. No filtra por usuarios.activo (ver fn_auth_user_de_persona).';

-- ─────────────────────────────────────────────────────────────────────
-- 2. ER.id_persona_duena_lead  ->  atribucion.id_propietario
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_crm_sync_dueno_desde_er()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_auth uuid;
BEGIN
  IF NEW.id_tipo_entidad <> 7 THEN RETURN NEW; END IF;

  v_auth := public.fn_auth_user_de_persona(NEW.id_persona_duena_lead);
  IF v_auth IS NULL THEN RETURN NEW; END IF;   -- sin usuario mapeable: mejor a medias que perdido

  INSERT INTO public.crm_leads_atribucion (id_entidad_relacionada, id_propietario, origen, activo)
  VALUES (NEW.id, v_auth, 'portal_agente', true)
  ON CONFLICT (id_entidad_relacionada) DO UPDATE
    SET id_propietario = EXCLUDED.id_propietario
    WHERE public.crm_leads_atribucion.id_propietario IS DISTINCT FROM EXCLUDED.id_propietario;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  -- El alta o edición del contacto nunca debe fallar por un problema del CRM.
  RAISE WARNING 'fn_crm_sync_dueno_desde_er (er=%): %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_crm_sync_dueno_desde_er ON public.entidades_relacionadas;
CREATE TRIGGER trg_crm_sync_dueno_desde_er
AFTER INSERT OR UPDATE OF id_persona_duena_lead ON public.entidades_relacionadas
FOR EACH ROW EXECUTE FUNCTION public.fn_crm_sync_dueno_desde_er();

-- ─────────────────────────────────────────────────────────────────────
-- 3. atribucion.id_propietario  ->  ER.id_persona_duena_lead
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_crm_sync_dueno_desde_atribucion()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_persona integer;
BEGIN
  v_persona := public.fn_persona_de_auth_user(NEW.id_propietario);
  IF v_persona IS NULL THEN RETURN NEW; END IF;

  UPDATE public.entidades_relacionadas
  SET id_persona_duena_lead = v_persona
  WHERE id = NEW.id_entidad_relacionada
    AND id_tipo_entidad = 7
    AND id_persona_duena_lead IS DISTINCT FROM v_persona;   -- corta la ida y vuelta

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'fn_crm_sync_dueno_desde_atribucion (er=%): %', NEW.id_entidad_relacionada, SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_crm_sync_dueno_desde_atribucion ON public.crm_leads_atribucion;
CREATE TRIGGER trg_crm_sync_dueno_desde_atribucion
AFTER INSERT OR UPDATE OF id_propietario ON public.crm_leads_atribucion
FOR EACH ROW EXECUTE FUNCTION public.fn_crm_sync_dueno_desde_atribucion();

-- ─────────────────────────────────────────────────────────────────────
-- 4. Backfill 1: los del Portal Agente -> atribución (999 en prod).
--    Efecto colateral buscado: las 1,143 entidades sin ninguna fila de atribución pasan a
--    tenerla, así que dejan de ser invisibles para el CRM.
--    COALESCE: si el CRM ya tenía propietario, gana el del CRM.
-- ─────────────────────────────────────────────────────────────────────
INSERT INTO public.crm_leads_atribucion (id_entidad_relacionada, id_propietario, origen, activo)
SELECT er.id, public.fn_auth_user_de_persona(er.id_persona_duena_lead), 'portal_agente', true
FROM public.entidades_relacionadas er
WHERE er.activo
  AND er.id_tipo_entidad = 7
  AND er.id_persona_duena_lead IS NOT NULL
  AND public.fn_auth_user_de_persona(er.id_persona_duena_lead) IS NOT NULL
ON CONFLICT (id_entidad_relacionada) DO UPDATE
  SET id_propietario = COALESCE(public.crm_leads_atribucion.id_propietario, EXCLUDED.id_propietario);

-- ─────────────────────────────────────────────────────────────────────
-- 5. Backfill 2: los del CRM -> id_persona_duena_lead (los hace visibles en el portal)
-- ─────────────────────────────────────────────────────────────────────
UPDATE public.entidades_relacionadas er
SET id_persona_duena_lead = public.fn_persona_de_auth_user(a.id_propietario)
FROM public.crm_leads_atribucion a
WHERE a.id_entidad_relacionada = er.id
  AND a.activo
  AND er.activo
  AND er.id_tipo_entidad = 7
  AND er.id_persona_duena_lead IS NULL
  AND a.id_propietario IS NOT NULL
  AND public.fn_persona_de_auth_user(a.id_propietario) IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────
-- 6. Backfill 3: los 12 conflictos. Gana el CRM y el dueño anterior queda registrado.
--    El respaldo se crea aquí para no depender del 07: quien pierda un lead tiene con qué
--    reclamar aunque la bitácora definitiva todavía no exista.
-- ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public._bak_conflicto_dueno_lead_20260807 (
  id_entidad_relacionada bigint      NOT NULL,
  persona_portal         integer,
  auth_portal            uuid,
  auth_crm               uuid,
  persona_crm            integer,
  fecha                  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public._bak_conflicto_dueno_lead_20260807 IS
  'Dueño que tenía el Portal Agente en los leads donde contradecía al CRM, antes de que ganara el CRM (migración 20260807040000). El 07 puede importar esto a crm_leads_reasignaciones.';

DO $$
DECLARE
  r record;
  v_hay_bitacora boolean := to_regclass('public.crm_leads_reasignaciones') IS NOT NULL;
  v_n int := 0;
BEGIN
  FOR r IN
    SELECT er.id AS id_er,
           er.id_persona_duena_lead AS persona_portal,
           a.id_propietario         AS auth_crm,
           public.fn_auth_user_de_persona(er.id_persona_duena_lead) AS auth_portal,
           public.fn_persona_de_auth_user(a.id_propietario)         AS persona_crm
    FROM public.entidades_relacionadas er
    JOIN public.crm_leads_atribucion a ON a.id_entidad_relacionada = er.id AND a.activo
    WHERE er.activo AND er.id_tipo_entidad = 7
      AND er.id_persona_duena_lead IS NOT NULL
      AND a.id_propietario IS NOT NULL
      AND public.fn_persona_de_auth_user(a.id_propietario) IS DISTINCT FROM er.id_persona_duena_lead
  LOOP
    CONTINUE WHEN r.persona_crm IS NULL;   -- sin persona destino no se pisa nada

    INSERT INTO public._bak_conflicto_dueno_lead_20260807
      (id_entidad_relacionada, persona_portal, auth_portal, auth_crm, persona_crm)
    VALUES (r.id_er, r.persona_portal, r.auth_portal, r.auth_crm, r.persona_crm);

    IF v_hay_bitacora AND r.auth_portal IS NOT NULL THEN
      INSERT INTO public.crm_leads_reasignaciones
        (id_entidad_relacionada, de_propietario, a_propietario, id_usuario_ejecuta, motivo)
      VALUES (r.id_er, r.auth_portal, r.auth_crm, NULL, 'conflicto_homologacion: gana el propietario del CRM');
    END IF;

    UPDATE public.entidades_relacionadas
    SET id_persona_duena_lead = r.persona_crm
    WHERE id = r.id_er;

    v_n := v_n + 1;
  END LOOP;

  IF v_n > 0 THEN
    RAISE NOTICE 'Conflictos de dueño resueltos a favor del CRM: % (respaldados en _bak_conflicto_dueno_lead_20260807)', v_n;
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────
-- 7. Backfill 4: sin dueño pero con oferta -> dueño = creador de la oferta (94 en prod).
--    Único criterio determinista; los 113 restantes se reparten a mano.
-- ─────────────────────────────────────────────────────────────────────
WITH creador AS (
  SELECT DISTINCT ON (er.id)
         er.id AS id_er,
         u.auth_user_id
  FROM public.entidades_relacionadas er
  LEFT JOIN public.crm_leads_atribucion a ON a.id_entidad_relacionada = er.id AND a.activo
  JOIN public.ofertas o            ON o.id_persona_lead = er.id_persona AND o.activo
  JOIN public.propiedades p        ON p.id  = o.id_propiedad AND p.activo
  JOIN public.edificios_modelos em ON em.id = p.id_edificio_modelo
  JOIN public.edificios e          ON e.id  = em.id_edificio AND e.id_proyecto = er.id_proyecto
  JOIN public.usuarios u           ON lower(u.email) = lower(o.email_creador)
                                  AND u.auth_user_id IS NOT NULL
  WHERE er.activo
    AND er.id_tipo_entidad = 7
    AND er.id_persona_duena_lead IS NULL
    AND a.id_propietario IS NULL
  ORDER BY er.id, o.fecha_generacion DESC NULLS LAST, o.id DESC
)
INSERT INTO public.crm_leads_atribucion (id_entidad_relacionada, id_propietario, origen, activo)
SELECT c.id_er, c.auth_user_id, 'oferta', true
FROM creador c
ON CONFLICT (id_entidad_relacionada) DO UPDATE
  SET id_propietario = COALESCE(public.crm_leads_atribucion.id_propietario, EXCLUDED.id_propietario);

-- ─────────────────────────────────────────────────────────────────────
-- 8. Los helpers no nacen públicos (ver corrección 4)
-- ─────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.fn_auth_user_de_persona(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_persona_de_auth_user(uuid)    FROM PUBLIC, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- 9. Self-verifying
-- ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_desalineados bigint;
BEGIN
  IF to_regprocedure('public.fn_auth_user_de_persona(integer)') IS NULL
     OR to_regprocedure('public.fn_persona_de_auth_user(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Faltan los helpers de conversión persona <-> auth_user_id';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_crm_sync_dueno_desde_er')
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_crm_sync_dueno_desde_atribucion') THEN
    RAISE EXCEPTION 'Faltan los triggers de sincronía de dueño';
  END IF;

  SELECT count(*) INTO v_desalineados
  FROM public.entidades_relacionadas er
  JOIN public.crm_leads_atribucion a ON a.id_entidad_relacionada = er.id AND a.activo
  WHERE er.activo AND er.id_tipo_entidad = 7
    AND a.id_propietario IS NOT NULL
    AND public.fn_persona_de_auth_user(a.id_propietario) IS NOT NULL
    AND er.id_persona_duena_lead IS DISTINCT FROM public.fn_persona_de_auth_user(a.id_propietario);
  IF v_desalineados > 0 THEN
    RAISE EXCEPTION 'Quedaron % leads con dueño desalineado entre atribución y entidad', v_desalineados;
  END IF;
END $$;

-- Rollback:
--   DROP TRIGGER IF EXISTS trg_crm_sync_dueno_desde_er ON public.entidades_relacionadas;
--   DROP TRIGGER IF EXISTS trg_crm_sync_dueno_desde_atribucion ON public.crm_leads_atribucion;
--   DROP FUNCTION IF EXISTS public.fn_crm_sync_dueno_desde_er();
--   DROP FUNCTION IF EXISTS public.fn_crm_sync_dueno_desde_atribucion();
--   -- Los helpers los usa el 06: borrarlos solo si también se revierte el 06.
--   -- DROP FUNCTION IF EXISTS public.fn_auth_user_de_persona(integer);
--   -- DROP FUNCTION IF EXISTS public.fn_persona_de_auth_user(uuid);
--   El backfill no se revierte: asignar dueño a un lead que no lo tenía es corrección, no
--   daño. Los 12 conflictos sí se pueden deshacer con _bak_conflicto_dueno_lead_20260807.
--
-- Validación posterior:
--   SELECT count(*) t7, count(*) FILTER (WHERE er.id_persona_duena_lead IS NOT NULL) con_dueno,
--          count(*) FILTER (WHERE er.id_persona_duena_lead IS NULL AND a.id_propietario IS NULL) sin_dueno
--   FROM public.entidades_relacionadas er
--   LEFT JOIN public.crm_leads_atribucion a ON a.id_entidad_relacionada = er.id AND a.activo
--   WHERE er.activo AND er.id_tipo_entidad = 7;      -- esperado: 3426 · ~3313 · 113
