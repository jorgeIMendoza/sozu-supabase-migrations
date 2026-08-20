-- Unifica las cotizaciones de un cliente en UN negocio: uno por CLIENTE + PROYECTO,
-- no uno por unidad. El trigger de ofertas creaba un negocio nativo por cada unidad
-- ofertada (pipeline "Ventas SOZU"), multiplicando negocios de un mismo cliente/proyecto.
-- Ahora, si el cliente ya tiene negocio nativo, la nueva oferta se ENGANCHA a ese negocio
-- (las ofertas siguen visibles en el panel "Cotizaciones", que consulta por cliente).
--
-- Tres partes:
--   1) Backfill: fusiona los negocios nativos duplicados por contacto.
--   2) Índices únicos: de (contacto, unidad)/(contacto, producto) a (contacto).
--   3) Trigger fn_crm_negocio_desde_oferta: dedup por contacto (no por unidad).
--
-- Notas de diseño verificadas contra prod (2026-08-20):
--   * El trigger fija id_entidad_relacionada = contacto tipo 7 (Prospecto), que es ÚNICO por
--     (persona, proyecto). Por eso todos los negocios nativos que comparten contacto son del
--     MISMO proyecto: fusionar "por contacto" == "por cliente+proyecto", sin mezclar proyectos.
--   * "Nativo" == negocio con id_oferta IS NOT NULL. En prod SOLO el pipeline "Ventas SOZU"
--     tiene id_oferta (1514/1514); HubSpot (Daiku Ventas) y los demás tienen 0. Por eso el
--     índice y el backfill se acotan con `id_oferta IS NOT NULL` (inmutable, sin subconsulta al
--     pipeline) y NO tocan los negocios de HubSpot.
--   * Impacto en prod: 1541 negocios nativos, 0 sin contacto, 232 contactos con duplicados;
--     se conservan 232 ganadores y se DESACTIVAN 631 (activo=false, reversible, NO se borra).
--   * Ganador del grupo: etapa más avanzada (orden DESC), desempate por id más bajo (el
--     original). Recibe la suma de ofertas_count del grupo; los demás se desactivan.
--   * Las ofertas de los negocios desactivados NO se pierden: la tabla ofertas queda intacta y
--     el panel "Cotizaciones" las lista por cliente.
--   * Idempotente: re-ejecutar no vuelve a fusionar (ya no hay grupos > 1) y usa IF (NOT) EXISTS.

BEGIN;

-- ── PARTE 1: Backfill — fusiona los negocios nativos duplicados por contacto ──────────────
-- El orden de ganador (orden de etapa DESC, id ASC) NO depende de ofertas_count, así que
-- actualizar el contador del ganador (1a) no altera la selección de perdedores (1b).

-- 1a) El ganador de cada grupo recibe la suma de ofertas_count del grupo.
WITH ranked AS (
  SELECT n.id,
         row_number() OVER (PARTITION BY n.id_entidad_relacionada
                            ORDER BY e.orden DESC NULLS LAST, n.id ASC) AS rn,
         count(*)             OVER (PARTITION BY n.id_entidad_relacionada) AS grupo,
         sum(n.ofertas_count) OVER (PARTITION BY n.id_entidad_relacionada) AS total
  FROM public.crm_negocios n
  LEFT JOIN public.crm_pipeline_etapas e ON e.id = n.id_etapa
  WHERE n.activo AND n.id_oferta IS NOT NULL AND n.id_entidad_relacionada IS NOT NULL
)
UPDATE public.crm_negocios n
SET ofertas_count = r.total
FROM ranked r
WHERE n.id = r.id AND r.rn = 1 AND r.grupo > 1;

-- 1b) Desactiva a los perdedores (todos los del grupo menos el ganador).
WITH ranked AS (
  SELECT n.id,
         row_number() OVER (PARTITION BY n.id_entidad_relacionada
                            ORDER BY e.orden DESC NULLS LAST, n.id ASC) AS rn,
         count(*)     OVER (PARTITION BY n.id_entidad_relacionada) AS grupo
  FROM public.crm_negocios n
  LEFT JOIN public.crm_pipeline_etapas e ON e.id = n.id_etapa
  WHERE n.activo AND n.id_oferta IS NOT NULL AND n.id_entidad_relacionada IS NOT NULL
)
UPDATE public.crm_negocios n
SET activo = false
FROM ranked r
WHERE n.id = r.id AND r.grupo > 1 AND r.rn > 1;

-- ── PARTE 2: Índices únicos — de (contacto, unidad) a (contacto) ──────────────────────────
-- Quita el grano por unidad; el nuevo grano es un negocio nativo activo por contacto.
DROP INDEX IF EXISTS public.crm_negocios_unidad_uk;
DROP INDEX IF EXISTS public.crm_negocios_producto_uk;

CREATE UNIQUE INDEX IF NOT EXISTS crm_negocios_contacto_uk
  ON public.crm_negocios (id_entidad_relacionada)
  WHERE (activo AND id_entidad_relacionada IS NOT NULL AND id_oferta IS NOT NULL);

COMMENT ON INDEX public.crm_negocios_contacto_uk IS
  'Un negocio nativo (con oferta) activo por contacto = cliente+proyecto. Reemplaza a '
  'crm_negocios_unidad_uk/producto_uk (grano por unidad). No aplica a negocios de HubSpot '
  '(id_oferta NULL).';

-- ── PARTE 3: Trigger — engancha la nueva oferta al negocio del cliente ────────────────────
CREATE OR REPLACE FUNCTION public.fn_crm_negocio_desde_oferta()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_pipeline   integer;
  v_etapa      integer;
  v_proyecto   integer;
  v_id_er      bigint;
  v_auth       uuid;
  v_nombre     text;
  v_valor      numeric;
  v_id_negocio integer;
BEGIN
  IF NOT NEW.activo OR NEW.id_persona_lead IS NULL THEN RETURN NEW; END IF;
  IF NEW.id_propiedad IS NULL AND NEW.id_producto IS NULL THEN RETURN NEW; END IF;

  SELECT id INTO v_pipeline FROM public.crm_pipelines WHERE clave = 'ventas_sozu';
  v_etapa := public.fn_crm_etapa('oferta_enviada');
  IF v_pipeline IS NULL OR v_etapa IS NULL THEN RETURN NEW; END IF;

  SELECT e.id_proyecto INTO v_proyecto
  FROM public.propiedades p
  JOIN public.edificios_modelos em ON em.id = p.id_edificio_modelo
  JOIN public.edificios e          ON e.id  = em.id_edificio
  WHERE p.id = NEW.id_propiedad;

  IF v_proyecto IS NULL AND NEW.id_producto IS NOT NULL THEN
    SELECT ps.id_proyecto INTO v_proyecto
    FROM public.productos_servicios ps WHERE ps.id = NEW.id_producto;
  END IF;

  -- Contacto (capa 1) de esa persona en ese proyecto. Si no existe se CREA: una oferta implica
  -- que esa persona es prospecto de ese proyecto, y sin contacto la llave del negocio queda
  -- incompleta (los únicos parciales del 02 no cubren NULL) y el Portal Agente no lo vería.
  SELECT er.id INTO v_id_er
  FROM public.entidades_relacionadas er
  WHERE er.activo AND er.id_tipo_entidad = 7
    AND er.id_persona = NEW.id_persona_lead
    AND er.id_proyecto IS NOT DISTINCT FROM v_proyecto
  ORDER BY er.fecha_creacion
  LIMIT 1;

  IF v_id_er IS NULL THEN
    INSERT INTO public.entidades_relacionadas
      (id_persona, id_tipo_entidad, id_proyecto, id_persona_duena_lead, activo)
    SELECT NEW.id_persona_lead, 7, v_proyecto,
           (SELECT u.id_persona FROM public.usuarios u
            WHERE lower(u.email) = lower(NEW.email_creador) ORDER BY u.activo DESC LIMIT 1),
           true
    WHERE NOT EXISTS (
      SELECT 1 FROM public.entidades_relacionadas er
      WHERE er.activo AND er.id_tipo_entidad = 7
        AND er.id_persona = NEW.id_persona_lead
        AND er.id_proyecto IS NOT DISTINCT FROM v_proyecto)
    ON CONFLICT DO NOTHING;

    SELECT er.id INTO v_id_er
    FROM public.entidades_relacionadas er
    WHERE er.activo AND er.id_tipo_entidad = 7
      AND er.id_persona = NEW.id_persona_lead
      AND er.id_proyecto IS NOT DISTINCT FROM v_proyecto
    ORDER BY er.fecha_creacion
    LIMIT 1;
    -- El alta dispara trg_crm_sync_dueno_desde_er (04), que crea su fila de atribución.
  END IF;

  SELECT u.auth_user_id INTO v_auth
  FROM public.usuarios u
  WHERE lower(u.email) = lower(NEW.email_creador) AND u.auth_user_id IS NOT NULL
  ORDER BY u.activo DESC, u.auth_user_id LIMIT 1;

  SELECT coalesce(pr.nombre,'') || ' ' || coalesce(p.numero_propiedad, ps.nombre, '') ||
         ' - ' || coalesce(per.nombre_legal, per.nombre_comercial, 'Sin nombre'),
         coalesce(p.precio_lista, ps.precio_lista)
    INTO v_nombre, v_valor
  FROM public.personas per
  LEFT JOIN public.propiedades p          ON p.id  = NEW.id_propiedad
  LEFT JOIN public.productos_servicios ps ON ps.id = NEW.id_producto
  LEFT JOIN public.proyectos pr           ON pr.id = v_proyecto
  WHERE per.id = NEW.id_persona_lead;

  -- Un negocio por CLIENTE + PROYECTO: si el contacto ya tiene un negocio nativo (con oferta),
  -- TODA nueva oferta de ese cliente/proyecto se ENGANCHA a ese negocio (unifica cotizaciones);
  -- ya NO se crea uno por unidad. (Antes: dedup por (contacto, propiedad).) El panel
  -- "Cotizaciones" lista todas las ofertas del cliente, así que no se pierde detalle por unidad.
  IF v_id_er IS NOT NULL THEN
    SELECT n.id INTO v_id_negocio
    FROM public.crm_negocios n
    WHERE n.activo
      AND n.id_entidad_relacionada = v_id_er
      AND n.id_oferta IS NOT NULL
    ORDER BY n.id
    LIMIT 1;
  END IF;

  IF v_id_negocio IS NOT NULL THEN
    UPDATE public.crm_negocios
    SET id_oferta     = NEW.id,
        valor         = coalesce(v_valor, valor),
        ofertas_count = ofertas_count + 1
    WHERE id = v_id_negocio;
    RETURN NEW;                              -- la etapa NO retrocede: la mueven los hechos
  END IF;

  -- `id_producto` SOLO cuando no hay unidad: si la oferta trae las dos cosas, el producto es
  -- un accesorio de la unidad (bodega, estacionamiento) y guardarlo aquí duplicaría el grano.
  INSERT INTO public.crm_negocios
    (nombre, id_pipeline, id_etapa, id_oferta, id_propiedad, id_producto,
     id_entidad_relacionada, id_usuario_propietario, valor, moneda, activo,
     ofertas_count, requiere_triage)
  VALUES
    (coalesce(v_nombre, 'Negocio ' || NEW.id), v_pipeline, v_etapa, NEW.id,
     NEW.id_propiedad,
     CASE WHEN NEW.id_propiedad IS NULL THEN NEW.id_producto END,
     v_id_er, v_auth, v_valor, 'MXN', true,
     1, (v_id_er IS NULL OR v_auth IS NULL))
  ON CONFLICT DO NOTHING;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'fn_crm_negocio_desde_oferta (oferta=%): %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$function$;

-- Función de trigger: no debe ser invocable como RPC (nace con EXECUTE a PUBLIC por default).
REVOKE ALL ON FUNCTION public.fn_crm_negocio_desde_oferta() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_crm_negocio_desde_oferta() FROM anon;
REVOKE ALL ON FUNCTION public.fn_crm_negocio_desde_oferta() FROM authenticated;

-- ── Self-verify: si el backfill o el índice no quedaron, aborta antes de COMMIT ───────────
DO $verify$
DECLARE v_dups int;
BEGIN
  SELECT count(*) INTO v_dups FROM (
    SELECT id_entidad_relacionada
    FROM public.crm_negocios
    WHERE activo AND id_oferta IS NOT NULL AND id_entidad_relacionada IS NOT NULL
    GROUP BY id_entidad_relacionada
    HAVING count(*) > 1
  ) d;
  IF v_dups > 0 THEN
    RAISE EXCEPTION 'Backfill incompleto: % contacto(s) con negocios nativos activos duplicados', v_dups;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'crm_negocios_contacto_uk'
  ) THEN
    RAISE EXCEPTION 'crm_negocios_contacto_uk no quedó creado';
  END IF;
END
$verify$;

COMMIT;
