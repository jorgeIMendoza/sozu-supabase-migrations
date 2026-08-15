-- =============================================================================
-- Portal Agente: el prospecto es del agente por CUALQUIERA de los dos dueños
-- + RPC de duplicados que puede nombrar al dueño que RLS oculta
-- =============================================================================
-- Reportes que cierra:
--   1. «El Portal Agente jala toda la información del CRM.» La fuga real vivía en el
--      front (la impersonación no viajaba al `auth.uid()`); ya se corrigió en el repo
--      del admin. Aquí no hay nada que arreglar: `fn_agente_actual` ya valida
--      `current_puede_impersonar()` antes de aceptar un uid ajeno.
--   2. Leads que sí son del agente y no aparecían en su portal.
--   3. Personas duplicadas por mayúsculas en el correo y por teléfono repetido:
--      se entrega el inventario y la RPC de detección. El índice y la fusión NO
--      se aplican aquí (ver bloques B/C/D al final).
--
-- ─── Verificado read-only el 2026-08-15 en prod (tzmhgfjmddkfyffkkmto) ───────
-- · `get_agente_prospectos(text,integer,integer,uuid,integer,integer)` existe, plpgsql,
--   STABLE SECURITY DEFINER, search_path='public'. md5 de la definición viva:
--   1bd7e6856f417d57a03098a28cc0dd36. Este archivo la reemplaza a partir de ESA
--   definición, no del repo.
-- · Su `mis_leads` hace INNER JOIN a `crm_leads_atribucion` y scopea solo por
--   `a.id_propietario = v_auth`. Ignora `entidades_relacionadas.id_persona_duena_lead`,
--   que es la columna que usan las policies y la que llena el alta del Portal Agente.
-- · `fn_agente_actual(uuid)` acepta un uid distinto SOLO si
--   `current_puede_impersonar()`; si no, RAISE 42501. `fn_persona_de_auth_user(uuid)`
--   y `get_current_user_persona_id()` existen, ambas SECURITY DEFINER.
-- · Entidades tipo 7 (Prospecto) activas: 3,847. De ellas:
--     – 63 sin fila en `crm_leads_atribucion`  → hoy invisibles (INNER JOIN)
--     – 44 con atribución pero `id_propietario` NULL → hoy invisibles
--     – 10 con dueño en `er.id_persona_duena_lead` y sin `id_propietario`
--       → SON DEL AGENTE y hoy no las ve. Esto es lo que arregla el bloque A.
--   Ninguna entidad tiene más de una atribución activa (0 casos), así que pasar el
--   INNER JOIN a LEFT JOIN no multiplica filas.
-- · `tipos_entidad`: 7 = Prospecto, 2 = Comprador.
-- · Duplicados hoy: 6 grupos / 12 filas por `lower(btrim(email))`;
--   225 grupos por últimos 10 dígitos del teléfono (subió desde 212 el 2026-08-11).
--   Por eso los índices únicos van comentados: reventarían el CI.
-- · `buscar_prospecto_existente` NO existe (ni en dev ni en prod): se crea nueva, y nace
--   ya con los 3 argumentos. Agregar `p_auth_user_id` después no reemplazaría nada:
--   CREATE OR REPLACE no cambia la firma, crearía una segunda sobrecarga y la llamada
--   de 2 args quedaría ambigua para PostgREST. `src/lib/prospectos/duplicados.ts` todavía
--   resuelve por consultas directas, así que estrenarla a 3 args no rompe al front.
--
-- ─── Nota de seguridad (leer antes de aprobar) ───────────────────────────────
-- `personas` tiene RLS activa pero su policy `personas_select` es `USING (true)` para
-- `anon` y `authenticated`: nombre, correo y teléfono de TODA la tabla ya son legibles
-- con la anon key. `buscar_prospecto_existente` NO agrega esa exposición — lo nuevo que
-- expone es, para un usuario autenticado, el NOMBRE del dueño del lead, su desarrollo y
-- su estatus, que RLS sí oculta. Es el objetivo del cambio (evitar el doble registro),
-- y por eso devuelve el nombre del dueño y nada más: ni su correo, ni su auth uid, ni el
-- registro del lead. Queda cerrada a `anon` explícitamente.
-- La policy abierta de `personas` es un hallazgo aparte, no se toca aquí.
-- =============================================================================

-- =============================================================================
-- BLOQUE A — get_agente_prospectos: dueño por atribución O por entidad
-- =============================================================================
BEGIN;

-- Guard self-verifying: si el anchor no está, abortar antes de reemplazar nada.
DO $guard$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'get_agente_prospectos'
      AND pg_get_function_identity_arguments(p.oid) =
          'p_search text, p_estatus integer, p_proyecto integer, p_auth_user_id uuid, p_limit integer, p_offset integer'
  ) THEN
    RAISE EXCEPTION 'get_agente_prospectos no existe con la firma esperada: no se reemplaza a ciegas';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'fn_persona_de_auth_user'
  ) THEN
    RAISE EXCEPTION 'Falta fn_persona_de_auth_user: el nuevo scope la necesita';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'entidades_relacionadas'
      AND column_name = 'id_persona_duena_lead'
  ) THEN
    RAISE EXCEPTION 'Falta entidades_relacionadas.id_persona_duena_lead';
  END IF;
END;
$guard$;

CREATE OR REPLACE FUNCTION public.get_agente_prospectos(
  p_search text DEFAULT NULL::text,
  p_estatus integer DEFAULT NULL::integer,
  p_proyecto integer DEFAULT NULL::integer,
  p_auth_user_id uuid DEFAULT NULL::uuid,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE(id_persona integer, nombre text, email text, telefono text,
              total_personas bigint, proyectos jsonb)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  -- fn_agente_actual exige current_puede_impersonar() para aceptar un uid ajeno.
  v_auth    uuid    := public.fn_agente_actual(p_auth_user_id);
  v_persona integer := public.fn_persona_de_auth_user(v_auth);
BEGIN
  -- Sin identidad no hay cartera: nunca devolver "todo" por un uid nulo.
  IF v_auth IS NULL AND v_persona IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH mis_leads AS (
    SELECT er.id, er.id_persona, er.id_proyecto, a.id_estatus_lead
    FROM public.entidades_relacionadas er
    -- LEFT: el lead dado de alta en el Portal Agente puede no tener atribución.
    -- Verificado: ninguna entidad tiene 2 atribuciones activas, no duplica filas.
    LEFT JOIN public.crm_leads_atribucion a
      ON a.id_entidad_relacionada = er.id AND a.activo
    WHERE er.activo
      AND er.id_tipo_entidad = 7
      -- Suyo por atribución (alta desde el CRM) o por dueño de la entidad
      -- (alta desde el Portal Agente). La propiedad del lead vive en las dos.
      AND (
        (v_auth    IS NOT NULL AND a.id_propietario         = v_auth)
        OR (v_persona IS NOT NULL AND er.id_persona_duena_lead = v_persona)
      )
      AND (p_proyecto IS NULL OR er.id_proyecto = p_proyecto)
      -- Filtrar por estatus deja fuera los leads sin atribución: no tienen estatus.
      AND (p_estatus  IS NULL OR a.id_estatus_lead = p_estatus)
  ),
  filtrados AS (
    SELECT l.*, per.nombre_legal, per.nombre_comercial, per.email, per.telefono
    FROM mis_leads l
    JOIN public.personas per ON per.id = l.id_persona AND per.activo
    WHERE p_search IS NULL OR p_search = '' OR (
         per.nombre_legal     ILIKE '%' || p_search || '%'
      OR per.nombre_comercial ILIKE '%' || p_search || '%'
      OR per.email            ILIKE '%' || p_search || '%'
      OR per.telefono         ILIKE '%' || p_search || '%')
  ),
  personas_pagina AS (
    SELECT f.id_persona,
           min(coalesce(f.nombre_legal, f.nombre_comercial)) AS nombre,
           min(f.email)    AS email,
           min(f.telefono) AS telefono,
           count(*) OVER () AS total
    FROM filtrados f
    GROUP BY f.id_persona
    ORDER BY 2
    LIMIT p_limit OFFSET p_offset
  )
  SELECT pp.id_persona, pp.nombre, pp.email, pp.telefono, pp.total,
         (
           SELECT jsonb_agg(jsonb_build_object(
                    'id_entidad_relacionada', l.id,
                    'id_proyecto',            l.id_proyecto,
                    'proyecto',               pr.nombre,
                    'id_estatus_lead',        l.id_estatus_lead,
                    'estatus',                el.nombre,
                    'estatus_clave',          el.clave,
                    'estatus_color',          el.color,
                    'unidades', coalesce((
                      SELECT jsonb_agg(jsonb_build_object(
                               'id_negocio',    n.id,
                               'id_oferta',     n.id_oferta,
                               'unidad',        coalesce(p.numero_propiedad, ps.nombre),
                               'tipo',          CASE WHEN n.id_propiedad IS NOT NULL THEN 'Propiedad'
                                                     ELSE coalesce(cp.nombre, 'Producto') END,
                               'ofertas_count', n.ofertas_count,
                               'valor',         n.valor,
                               'etapa',         e.nombre,
                               'etapa_clave',   e.clave,
                               'etapa_orden',   e.orden,
                               'automatica',    e.hecho_disparador IS NOT NULL,
                               'es_cliente',    e.orden >= 70 AND e.orden <> 99)
                             ORDER BY e.orden DESC)
                      FROM public.crm_negocios n
                      LEFT JOIN public.crm_pipeline_etapas e  ON e.id  = n.id_etapa
                      LEFT JOIN public.propiedades p          ON p.id  = n.id_propiedad
                      LEFT JOIN public.productos_servicios ps ON ps.id = n.id_producto
                      LEFT JOIN public.categorias_producto cp ON cp.id = ps.id_categoria
                      WHERE n.activo AND n.id_entidad_relacionada = l.id
                    ), '[]'::jsonb))
                  ORDER BY pr.nombre)
           FROM mis_leads l
           LEFT JOIN public.proyectos pr        ON pr.id = l.id_proyecto
           LEFT JOIN public.crm_estados_lead el ON el.id = l.id_estatus_lead
           WHERE l.id_persona = pp.id_persona
         ) AS proyectos
  FROM personas_pagina pp
  ORDER BY pp.nombre;        -- el LIMIT vive en el CTE: sin esto el orden de la página no está garantizado
END;
$function$;

COMMENT ON FUNCTION public.get_agente_prospectos(text,integer,integer,uuid,integer,integer) IS
  'Prospectos del agente. Es suyo por crm_leads_atribucion.id_propietario (alta desde el CRM) '
  'o por entidades_relacionadas.id_persona_duena_lead (alta desde el Portal Agente). '
  'p_auth_user_id permite impersonar: fn_agente_actual exige current_puede_impersonar().';

COMMIT;

-- =============================================================================
-- BLOQUE B2 — Quién ya tiene a este prospecto
-- =============================================================================
-- `personas` se lee sin restricción, pero `entidades_relacionadas` está bajo RLS: hoy el
-- agente que teclea un correo repetido ve "ya existe" y nada más, así que lo da de alta
-- otra vez y se abre un conflicto de comisión (caso Janeth: personas 3058 y 3112, mismo
-- teléfono, mismo desarrollo, dos agentes dueños). Con esta RPC la pantalla puede decir
-- "ya está registrado en Monócolo · Diego Escobar" sin abrir el lead ajeno.
-- =============================================================================
BEGIN;

-- Guard: si en algún entorno ya vive una sobrecarga de 2 args, abortar. Con las dos
-- firmas activas, PostgREST no puede resolver la llamada de 2 argumentos.
DO $guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'buscar_prospecto_existente'
      AND pg_get_function_identity_arguments(p.oid) = 'p_email text, p_telefono text'
  ) THEN
    RAISE EXCEPTION 'Ya existe buscar_prospecto_existente(text,text): hay que borrarla antes, dos firmas vuelven ambigua la llamada';
  END IF;
END;
$guard$;

-- La firma nace con `p_auth_user_id`: agregarlo después NO reemplaza la función,
-- crea una segunda sobrecarga y la llamada de 2 args queda ambigua (42725) para
-- PostgREST. Se define una sola vez, con los 3 argumentos.
CREATE OR REPLACE FUNCTION public.buscar_prospecto_existente(
  p_email        text DEFAULT NULL,
  p_telefono     text DEFAULT NULL,
  p_auth_user_id uuid DEFAULT NULL
)
RETURNS TABLE (
  id_persona   integer,
  nombre       text,
  email        text,
  telefono     text,
  es_cliente   boolean,
  leads        jsonb
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  -- plpgsql y no sql: así el gate corre SIEMPRE. En LANGUAGE sql, fn_agente_actual
  -- vive en un CTE que el planner puede no evaluar si no hay candidatas, y la
  -- impersonación no autorizada se saltaría el RAISE 42501.
  v_auth    uuid    := public.fn_agente_actual(p_auth_user_id);
  v_persona integer := public.fn_persona_de_auth_user(v_auth);
  v_correo  text    := lower(btrim(coalesce(p_email, '')));
  v_tel10   text    := right(regexp_replace(coalesce(p_telefono, ''), '[^0-9]', '', 'g'), 10);
BEGIN
  -- SECURITY DEFINER: sin sesión no responde.
  IF v_auth IS NULL THEN
    RETURN;
  END IF;

  -- Sin criterio no hay búsqueda: nunca devolver la tabla entera.
  IF v_correo = '' AND length(v_tel10) <> 10 THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH candidatas AS (
    SELECT p.id, p.nombre_legal, p.nombre_comercial, p.email, p.telefono
    FROM public.personas p
    WHERE p.activo
      AND (
        (v_correo <> '' AND lower(btrim(p.email)) = v_correo)
        OR (length(v_tel10) = 10
            AND right(regexp_replace(coalesce(p.telefono, ''), '[^0-9]', '', 'g'), 10) = v_tel10)
      )
    LIMIT 10
  )
  SELECT ca.id,
         coalesce(ca.nombre_legal, ca.nombre_comercial, 'Sin nombre'),
         ca.email,
         ca.telefono,
         EXISTS (SELECT 1 FROM public.entidades_relacionadas e
                  WHERE e.id_persona = ca.id AND e.activo AND e.id_tipo_entidad = 2),
         coalesce((
           SELECT jsonb_agg(jsonb_build_object(
                    'id_entidad_relacionada', er.id,
                    'id_proyecto',            er.id_proyecto,
                    'proyecto',               pr.nombre,
                    -- Solo el nombre del dueño: ni su correo ni su id de usuario.
                    'dueno',                  coalesce(du.nombre_legal, us.nombre),
                    -- Identidad efectiva: al impersonar, "mío" es del agente impersonado.
                    'es_mio',                 ((v_persona IS NOT NULL
                                                AND er.id_persona_duena_lead = v_persona)
                                               OR a.id_propietario = v_auth),
                    'estatus',                el.nombre)
                  ORDER BY pr.nombre)
           FROM public.entidades_relacionadas er
           LEFT JOIN public.crm_leads_atribucion a ON a.id_entidad_relacionada = er.id AND a.activo
           LEFT JOIN public.proyectos pr        ON pr.id = er.id_proyecto
           LEFT JOIN public.personas du         ON du.id = er.id_persona_duena_lead
           LEFT JOIN public.usuarios us         ON us.auth_user_id = a.id_propietario
           LEFT JOIN public.crm_estados_lead el ON el.id = a.id_estatus_lead
           WHERE er.id_persona = ca.id AND er.activo AND er.id_tipo_entidad = 7
         ), '[]'::jsonb)
  FROM candidatas ca;
END;
$function$;

COMMENT ON FUNCTION public.buscar_prospecto_existente(text,text,uuid) IS
  'Duplicados de prospecto para el alta del CRM y del Portal Agente: correo sin distinguir '
  'mayúsculas + últimos 10 dígitos del teléfono. SECURITY DEFINER a propósito, para poder '
  'nombrar al dueño de un lead que RLS oculta, sin exponer el registro completo. '
  'p_auth_user_id permite impersonar: fn_agente_actual exige current_puede_impersonar(), '
  'y de él sale el es_mio de cada lead.';

-- Toda función nueva en public nace con EXECUTE para PUBLIC (y por tanto anon).
REVOKE ALL ON FUNCTION public.buscar_prospecto_existente(text,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.buscar_prospecto_existente(text,text,uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.buscar_prospecto_existente(text,text,uuid) TO authenticated;

COMMIT;

-- =============================================================================
-- BLOQUE B (NO EJECUTAR) — Correo único sin importar mayúsculas
-- =============================================================================
-- `personas_email_key` es UNIQUE sobre la columna, no sobre lower(email): por eso
-- `Janethwirth@gmail.com` y `janethwirth@gmail.com` conviven. Bloqueado: hoy hay
-- 6 grupos / 12 filas duplicadas — el índice falla mientras existan.
-- Fusionar personas mueve entidades_relacionadas, crm_leads_atribucion, crm_negocios,
-- ofertas, documentos y compradores, y decide de qué agente es la comisión: es una
-- decisión de negocio, no un DML automático. Va en su propia migración, ya depurado.
--
-- CREATE UNIQUE INDEX CONCURRENTLY uq_personas_email_lower
--   ON public.personas (lower(btrim(email)))
--   WHERE email IS NOT NULL AND btrim(email) <> '';
-- -- Con el índice arriba, personas_email_key queda redundante (más laxo):
-- DROP INDEX CONCURRENTLY IF EXISTS personas_email_key;

-- =============================================================================
-- BLOQUE C (NO EJECUTAR) — Teléfono único
-- =============================================================================
-- Sigue bloqueado: 225 grupos de teléfono repetido en personas activas (eran 212 el
-- 2026-08-11). Además el teléfono repetido puede ser legítimo (familiares).
--
-- CREATE UNIQUE INDEX CONCURRENTLY uq_personas_tel10_activas
--   ON public.personas (right(regexp_replace(telefono, '[^0-9]', '', 'g'), 10))
--   WHERE activo = true AND telefono IS NOT NULL
--     AND length(regexp_replace(telefono, '[^0-9]', '', 'g')) >= 10;

-- =============================================================================
-- BLOQUE D (NO EJECUTAR) — Backfill del dueño faltante en entidades_relacionadas
-- =============================================================================
-- 57 filas tienen dueño solo en la atribución y quedan ocultas por RLS para cualquier
-- rol sin ver_todos_prospectos_compradores. El backfill requiere aprobación explícita
-- y no resuelve los 3 dueños sin usuarios.id_persona (joseramon.escobar 42,
-- luz.ochoa 13, tomas.peterson 1): a ellos hay que ligarles persona primero.
--
-- UPDATE public.entidades_relacionadas er
--    SET id_persona_duena_lead = public.fn_persona_de_auth_user(a.id_propietario)
--   FROM public.crm_leads_atribucion a
--  WHERE a.id_entidad_relacionada = er.id
--    AND a.activo AND er.activo AND er.id_tipo_entidad = 7
--    AND er.id_persona_duena_lead IS NULL
--    AND a.id_propietario IS NOT NULL
--    AND public.fn_persona_de_auth_user(a.id_propietario) IS NOT NULL;
