-- Homologación CRM ↔ Portal Agente — 05: el negocio nace de la oferta y avanza por hechos
-- Fecha: 2026-08-07
-- REQUIERE: el 02 (columnas y únicos de crm_negocios) y el 03 (pipeline ventas_sozu).
--
-- El ciclo de vida de la venta se mueve solo, a partir de hechos verificables:
--   oferta                       -> nace el negocio en `oferta_enviada`, ciclo de vida `lead`
--   apartado aplicado            -> `apartado_pagado`, y AHÍ SÍ ciclo de vida `customer`
--   propiedad vendida/liquidada  -> `enganche_contrato` / `ganado`
--   motivo de no avance no recuperable -> `perdido`
--
-- La regla de negocio («mientras solo hay oferta, la persona sigue siendo prospecto») se
-- preserva en el CICLO DE VIDA, no en la existencia del registro: naciendo el negocio en el
-- apartado se perderían de vista el 82% de las ofertas, justo el tramo donde se cae el embudo.
--
-- ─── Verificado read-only contra prod (tzmhgfjmddkfyffkkmto, 2026-08-07) ──────
--   * 1,422 pares (persona, unidad) con oferta activa → ése es el número de negocios que crea
--     el backfill, no 2,854: las recotizaciones comparten negocio. 868 pares persona-proyecto,
--     de los cuales **333 no tienen contacto tipo 7** y los crea el paso 0 (cifra exacta del
--     documento). Cero ofertas activas sin proyecto resoluble.
--   * 508 pares (persona, unidad) con apartado aplicado.
--   * `crm_meta_conversion_stages` tiene 'customer' (id 5) y 'cierre_ganado' (id 6), los dos
--     inactivos: escribir el TEXTO es correcto y el trigger del CRM resuelve el id.
--   * `aplicaciones_pago` tiene `activo` y `es_multa` NOT NULL; `acuerdos_pago.id_concepto`
--     NOT NULL. Conceptos: 1 = Apartado.
--   * `uq_entrel_persona_tipo_proy_cuenta` es UNIQUE ... WHERE activo, con `id_proyecto` en la
--     llave: si el proyecto fuera NULL, dos filas NULL no colisionan (NULLs distintos en
--     btree). Hoy no aplica —no hay ofertas sin proyecto— pero por eso el alta de contacto se
--     protege con NOT EXISTS y no solo con ON CONFLICT.
--
-- ─── Cinco correcciones respecto al documento ────────────────────────────────
-- 1. EL APARTADO NO SE EMPAREJA POR `id_oferta`. Es el error que rompía el archivo: tanto el
--    trigger como el backfill hacían `n.id_oferta = cc.id_oferta`, pero `n.id_oferta` guarda
--    la oferta REPRESENTATIVA (la más reciente) mientras la cuenta de cobranza cuelga de la
--    oferta con la que se cerró. Medido en prod: de 508 cuentas con apartado aplicado, **444
--    (87%) NO coinciden** con la representativa. El resultado habría sido ~64 negocios en
--    `apartado_pagado` en vez de 508, y el mismo hueco en cada apartado futuro. Aquí se
--    empareja por (persona, unidad) —que sí recupera los 508— con respaldo por `id_oferta`
--    para los negocios sin contacto.
-- 2. ESTATUS 10 FUERA DE `ganado`. El documento se contradice: su catálogo lista 4, 5, 7, 8 y
--    9, pero el DDL mapea 7, 8, 9 y **10** a `ganado`. En prod el 10 es **«Asignado»** (30
--    propiedades), que no es un estado post-escrituración: marcarlo como cierre ganado al 100%
--    declararía vendida una unidad que no lo está. Se mapean 7, 8 y 9. Volver a incluirlo es
--    agregar un número si el negocio confirma que «Asignado» va después de escriturar.
-- 3. `perdido` NO PUEDE PISAR UN NEGOCIO GANADO. El documento permite `perdido` siempre, así
--    que registrar un motivo de no avance sobre una oferta vieja cerraría como perdida una
--    venta ya ganada. Ahora `perdido` solo aplica si el negocio no está en una etapa de cierre.
-- 4. LAS FUNCIONES NO NACEN PÚBLICAS. `fn_crm_avanzar_negocio` es SECURITY DEFINER y ESCRIBE;
--    toda función nueva en `public` recibe EXECUTE para `anon` y `authenticated`, así que
--    cualquiera con la publishable key podría mover cualquier negocio a `ganado`. Se revoca.
-- 5. EL CIERRE POR NO AVANCE TAMBIÉN SE EMPAREJA POR UNIDAD, por la misma razón que (1).
-- 6. `id_producto` SOLO SI NO HAY UNIDAD. Esto tumbó el primer intento de deploy en dev:
--        ERROR: duplicate key value violates unique constraint "crm_negocios_producto_uk"
--        Key (id_entidad_relacionada, id_producto)=(1909, 7) already exists.
--    En prod **1,162 ofertas activas traen propiedad Y producto, y CERO traen producto sin
--    propiedad**: el producto es un accesorio de la unidad (bodega, estacionamiento), no la
--    unidad. La persona 1208 tiene dos ofertas con propiedades distintas (4779 y 4793) y el
--    mismo producto 7, así que ambos negocios salían con el mismo (contacto, producto) y
--    chocaban contra el único del 02. El `NOT EXISTS` no lo atrapaba porque no ve las filas
--    del propio INSERT.
--    Se guarda `id_producto` únicamente cuando `id_propiedad` es NULL —que es lo que el modelo
--    dice: la llave es la unidad— y se agrega `ON CONFLICT DO NOTHING` como red.
--
-- Este archivo no toca `acuerdos_pago` (ya carga 7 triggers, dos de ellos con
-- `verificar_propiedad_vendida()` solapados) ni reactiva nada: `propiedades` tiene
-- `on_property_pagada_completamente` DESHABILITADO a propósito — nunca correr
-- `ALTER TABLE propiedades ENABLE TRIGGER ALL`.
--
-- Todos los triggers atrapan la excepción y siguen: generar una oferta, registrar un pago o
-- cambiar el estatus de una propiedad NUNCA puede fallar por el CRM. Por eso la consulta de
-- reconciliación del final es parte del diseño, no un extra.
--
-- Idempotente: CREATE OR REPLACE, DROP TRIGGER IF EXISTS + CREATE, backfills con NOT EXISTS y
-- avances monótonos. Sin BEGIN/COMMIT (el CI envuelve cada migración en transacción).

-- ─────────────────────────────────────────────────────────────────────
-- 1. Helpers
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_crm_etapa(p_clave text)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT e.id
  FROM public.crm_pipeline_etapas e
  JOIN public.crm_pipelines p ON p.id = e.id_pipeline
  WHERE p.clave = 'ventas_sozu' AND e.clave = p_clave AND e.activo
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.fn_crm_avanzar_negocio(p_id_negocio integer, p_clave_etapa text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id_etapa     integer := public.fn_crm_etapa(p_clave_etapa);
  v_orden_nuevo  integer;
  v_orden_actual integer;
  v_id_er        bigint;
  v_ciclo        text;
BEGIN
  IF v_id_etapa IS NULL THEN RETURN; END IF;

  SELECT e.orden INTO v_orden_nuevo FROM public.crm_pipeline_etapas e WHERE e.id = v_id_etapa;

  SELECT ea.orden, n.id_entidad_relacionada INTO v_orden_actual, v_id_er
  FROM public.crm_negocios n
  LEFT JOIN public.crm_pipeline_etapas ea ON ea.id = n.id_etapa
  WHERE n.id = p_id_negocio;

  IF p_clave_etapa = 'perdido' THEN
    -- Se puede perder desde cualquier etapa MENOS desde un cierre ya ganado (orden 90).
    -- Sin esta guarda, un motivo de no avance sobre una oferta vieja tumbaría una venta hecha.
    IF v_orden_actual IS NOT NULL AND v_orden_actual >= 90 THEN RETURN; END IF;
  ELSIF v_orden_actual IS NOT NULL AND v_orden_actual >= v_orden_nuevo THEN
    RETURN;                                   -- la etapa nunca retrocede
  END IF;

  UPDATE public.crm_negocios SET id_etapa = v_id_etapa WHERE id = p_id_negocio;

  -- Ciclo de vida derivado. Se escribe el TEXTO; el trigger del CRM
  -- (trg_crm_sync_etapa_ciclo_vida_id) resuelve id_etapa_ciclo_vida contra
  -- crm_meta_conversion_stages, donde 'customer' y 'cierre_ganado' existen (inactivos a
  -- propósito, para no doble-contar con HubSpot). NO escribir id_etapa_ciclo_vida a mano.
  IF v_orden_nuevo >= 70 AND v_orden_nuevo <> 99 AND v_id_er IS NOT NULL THEN
    v_ciclo := CASE WHEN v_orden_nuevo >= 90 THEN 'cierre_ganado' ELSE 'customer' END;
    UPDATE public.crm_leads_atribucion
    SET etapa_ciclo_vida = v_ciclo
    WHERE id_entidad_relacionada = v_id_er
      AND activo
      AND etapa_ciclo_vida IS DISTINCT FROM v_ciclo;
  END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────
-- 2. Oferta -> negocio
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_crm_negocio_desde_oferta()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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

  -- ¿Ya hay negocio para esta unidad? Entonces es una RECOTIZACIÓN: se actualiza la oferta
  -- vigente y el contador, NO se crea otro negocio.
  SELECT n.id INTO v_id_negocio
  FROM public.crm_negocios n
  WHERE n.activo
    AND n.id_entidad_relacionada IS NOT DISTINCT FROM v_id_er
    AND ((NEW.id_propiedad IS NOT NULL AND n.id_propiedad = NEW.id_propiedad)
      OR (NEW.id_propiedad IS NULL AND NEW.id_producto IS NOT NULL AND n.id_producto = NEW.id_producto))
  LIMIT 1;

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
  -- Ver «Corrección 6» en el encabezado.
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
$$;

DROP TRIGGER IF EXISTS trg_crm_negocio_desde_oferta ON public.ofertas;
CREATE TRIGGER trg_crm_negocio_desde_oferta
AFTER INSERT ON public.ofertas
FOR EACH ROW EXECUTE FUNCTION public.fn_crm_negocio_desde_oferta();

-- ─────────────────────────────────────────────────────────────────────
-- 3. Apartado aplicado -> etapa apartado_pagado
--    Empareja por (persona, unidad), NO por id_oferta (ver corrección 1).
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_crm_negocio_por_apartado()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record;
BEGIN
  IF coalesce(NEW.es_multa, false) OR NOT coalesce(NEW.activo, true) THEN RETURN NEW; END IF;

  FOR r IN
    WITH oferta_cuenta AS (
      SELECT o.id AS id_oferta, o.id_persona_lead, o.id_propiedad, o.id_producto
      FROM public.acuerdos_pago ap
      JOIN public.cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza AND cc.activo
      JOIN public.ofertas o           ON o.id  = cc.id_oferta
      WHERE ap.id = NEW.id_acuerdo_pago AND ap.id_concepto = 1
    )
    SELECT DISTINCT n.id
    FROM oferta_cuenta oc
    JOIN public.entidades_relacionadas er ON er.activo AND er.id_tipo_entidad = 7
                                         AND er.id_persona = oc.id_persona_lead
    JOIN public.crm_negocios n ON n.activo
                              AND n.id_entidad_relacionada = er.id
                              AND ((oc.id_propiedad IS NOT NULL AND n.id_propiedad = oc.id_propiedad)
                                OR (oc.id_propiedad IS NULL AND oc.id_producto IS NOT NULL
                                    AND n.id_producto = oc.id_producto))
    UNION
    SELECT DISTINCT n.id                       -- respaldo: negocios sin contacto
    FROM oferta_cuenta oc
    JOIN public.crm_negocios n ON n.activo AND n.id_oferta = oc.id_oferta
  LOOP
    PERFORM public.fn_crm_avanzar_negocio(r.id, 'apartado_pagado');
  END LOOP;
  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'fn_crm_negocio_por_apartado (aplicacion=%): %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_crm_negocio_por_apartado ON public.aplicaciones_pago;
CREATE TRIGGER trg_crm_negocio_por_apartado
AFTER INSERT ON public.aplicaciones_pago
FOR EACH ROW EXECUTE FUNCTION public.fn_crm_negocio_por_apartado();

-- ─────────────────────────────────────────────────────────────────────
-- 4. Estatus de la propiedad -> enganche_contrato / ganado
--    5 = Vendido -> enganche_contrato · 7 Escrituración, 8 Entregado, 9 Pagada completamente
--    -> ganado. El 10 («Asignado») queda FUERA a propósito: ver corrección 2.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_crm_negocio_por_estatus_propiedad()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_clave text;
  r record;
BEGIN
  IF NEW.id_estatus_disponibilidad IS NOT DISTINCT FROM OLD.id_estatus_disponibilidad THEN
    RETURN NEW;
  END IF;

  v_clave := CASE
    WHEN NEW.id_estatus_disponibilidad = 5           THEN 'enganche_contrato'
    WHEN NEW.id_estatus_disponibilidad IN (7, 8, 9)  THEN 'ganado'
    ELSE NULL
  END;
  IF v_clave IS NULL THEN RETURN NEW; END IF;

  FOR r IN SELECT id FROM public.crm_negocios WHERE activo AND id_propiedad = NEW.id
  LOOP
    PERFORM public.fn_crm_avanzar_negocio(r.id, v_clave);
  END LOOP;
  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'fn_crm_negocio_por_estatus_propiedad (propiedad=%): %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_crm_negocio_por_estatus_propiedad ON public.propiedades;
CREATE TRIGGER trg_crm_negocio_por_estatus_propiedad
AFTER UPDATE OF id_estatus_disponibilidad ON public.propiedades
FOR EACH ROW EXECUTE FUNCTION public.fn_crm_negocio_por_estatus_propiedad();

-- ─────────────────────────────────────────────────────────────────────
-- 5. Motivo de no avance NO recuperable -> etapa `perdido`
--    (motivos_no_avance_oferta + ofertas_no_avance, migración 20260804010000).
--    Los motivos recuperables no cierran nada: el lead sigue vivo.
-- ─────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF to_regclass('public.ofertas_no_avance') IS NULL
     OR to_regclass('public.motivos_no_avance_oferta') IS NULL THEN
    RAISE NOTICE 'ofertas_no_avance no existe: se omite el trigger de cierre por no avance';
    RETURN;
  END IF;

  EXECUTE $fn$
    CREATE OR REPLACE FUNCTION public.fn_crm_negocio_por_no_avance()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $body$
    DECLARE r record;
    BEGIN
      IF NOT coalesce(NEW.activo, true) THEN RETURN NEW; END IF;

      IF NOT EXISTS (
        SELECT 1 FROM public.motivos_no_avance_oferta m
        WHERE m.id = NEW.id_motivo AND m.es_recuperable = false
      ) THEN
        RETURN NEW;
      END IF;

      FOR r IN
        WITH o AS (SELECT id, id_persona_lead, id_propiedad, id_producto
                   FROM public.ofertas WHERE id = NEW.id_oferta)
        SELECT DISTINCT n.id
        FROM o
        JOIN public.entidades_relacionadas er ON er.activo AND er.id_tipo_entidad = 7
                                             AND er.id_persona = o.id_persona_lead
        JOIN public.crm_negocios n ON n.activo AND n.id_entidad_relacionada = er.id
                                  AND ((o.id_propiedad IS NOT NULL AND n.id_propiedad = o.id_propiedad)
                                    OR (o.id_propiedad IS NULL AND o.id_producto IS NOT NULL
                                        AND n.id_producto = o.id_producto))
        UNION
        SELECT DISTINCT n.id
        FROM o JOIN public.crm_negocios n ON n.activo AND n.id_oferta = o.id
      LOOP
        PERFORM public.fn_crm_avanzar_negocio(r.id, 'perdido');
      END LOOP;
      RETURN NEW;

    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'fn_crm_negocio_por_no_avance (oferta=%): %', NEW.id_oferta, SQLERRM;
      RETURN NEW;
    END;
    $body$;
  $fn$;

  EXECUTE 'DROP TRIGGER IF EXISTS trg_crm_negocio_por_no_avance ON public.ofertas_no_avance';
  EXECUTE 'CREATE TRIGGER trg_crm_negocio_por_no_avance
           AFTER INSERT OR UPDATE ON public.ofertas_no_avance
           FOR EACH ROW EXECUTE FUNCTION public.fn_crm_negocio_por_no_avance()';
END $$;

-- ─────────────────────────────────────────────────────────────────────
-- 6. Backfill 0: crear el contacto tipo 7 que falta (333 en prod)
-- ─────────────────────────────────────────────────────────────────────
WITH pares AS (
  SELECT DISTINCT o.id_persona_lead AS id_persona,
         coalesce(e.id_proyecto, ps.id_proyecto) AS id_proyecto,
         (SELECT u.id_persona FROM public.usuarios u
          WHERE lower(u.email) = lower(o.email_creador) ORDER BY u.activo DESC LIMIT 1) AS id_dueno
  FROM public.ofertas o
  LEFT JOIN public.propiedades p          ON p.id  = o.id_propiedad AND p.activo
  LEFT JOIN public.edificios_modelos em   ON em.id = p.id_edificio_modelo
  LEFT JOIN public.edificios e            ON e.id  = em.id_edificio
  LEFT JOIN public.productos_servicios ps ON ps.id = o.id_producto
  WHERE o.activo AND o.id_persona_lead IS NOT NULL
    AND (o.id_propiedad IS NOT NULL OR o.id_producto IS NOT NULL)
)
INSERT INTO public.entidades_relacionadas
  (id_persona, id_tipo_entidad, id_proyecto, id_persona_duena_lead, activo)
SELECT DISTINCT ON (pa.id_persona, pa.id_proyecto)
       pa.id_persona, 7, pa.id_proyecto, pa.id_dueno, true
FROM pares pa
WHERE NOT EXISTS (
  SELECT 1 FROM public.entidades_relacionadas er
  WHERE er.activo AND er.id_tipo_entidad = 7
    AND er.id_persona  = pa.id_persona
    AND er.id_proyecto IS NOT DISTINCT FROM pa.id_proyecto)
ORDER BY pa.id_persona, pa.id_proyecto, pa.id_dueno NULLS LAST
ON CONFLICT DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────
-- 7. Backfill 1: un negocio por (contacto, UNIDAD) — 1,422 pares en prod
-- ─────────────────────────────────────────────────────────────────────
WITH ofertas_ctx AS (
  SELECT o.id AS id_oferta, o.id_persona_lead, o.id_propiedad, o.id_producto, o.fecha_generacion,
         coalesce(e.id_proyecto, ps.id_proyecto) AS id_proyecto,
         coalesce(p.numero_propiedad, ps.nombre) AS unidad,
         coalesce(cc.precio_final, p.precio_lista, ps.precio_lista) AS valor,
         pr.nombre AS proyecto,
         coalesce(per.nombre_legal, per.nombre_comercial, 'Sin nombre') AS persona,
         u.auth_user_id
  FROM public.ofertas o
  JOIN public.personas per                ON per.id = o.id_persona_lead
  LEFT JOIN public.propiedades p          ON p.id   = o.id_propiedad
  LEFT JOIN public.productos_servicios ps ON ps.id  = o.id_producto
  LEFT JOIN public.edificios_modelos em   ON em.id  = p.id_edificio_modelo
  LEFT JOIN public.edificios e            ON e.id   = em.id_edificio
  LEFT JOIN public.proyectos pr           ON pr.id  = coalesce(e.id_proyecto, ps.id_proyecto)
  LEFT JOIN public.usuarios u             ON lower(u.email) = lower(o.email_creador)
                                         AND u.auth_user_id IS NOT NULL
  LEFT JOIN public.cuentas_cobranza cc    ON cc.id_oferta = o.id AND cc.activo
  WHERE o.activo AND o.id_persona_lead IS NOT NULL
    AND (o.id_propiedad IS NOT NULL OR o.id_producto IS NOT NULL)
),
con_contacto AS (
  SELECT oc.*, er.id AS id_er
  FROM ofertas_ctx oc
  LEFT JOIN public.entidades_relacionadas er
    ON er.activo AND er.id_tipo_entidad = 7
   AND er.id_persona  = oc.id_persona_lead
   AND er.id_proyecto IS NOT DISTINCT FROM oc.id_proyecto
),
representativa AS (
  SELECT DISTINCT ON (id_er, id_persona_lead, coalesce(id_propiedad, -id_producto)) *,
         count(*) OVER (PARTITION BY id_er, id_persona_lead, coalesce(id_propiedad, -id_producto)) AS n_ofertas
  FROM con_contacto
  ORDER BY id_er, id_persona_lead, coalesce(id_propiedad, -id_producto),
           fecha_generacion DESC NULLS LAST, id_oferta DESC
)
INSERT INTO public.crm_negocios
  (nombre, id_pipeline, id_etapa, id_oferta, id_propiedad, id_producto,
   id_entidad_relacionada, id_usuario_propietario, valor, moneda, activo,
   ofertas_count, requiere_triage)
SELECT
  coalesce(r.proyecto,'') || ' ' || coalesce(r.unidad,'') || ' - ' || r.persona,
  (SELECT id FROM public.crm_pipelines WHERE clave = 'ventas_sozu'),
  public.fn_crm_etapa('oferta_enviada'),
  r.id_oferta, r.id_propiedad,
  CASE WHEN r.id_propiedad IS NULL THEN r.id_producto END,   -- ver «Corrección 6»
  r.id_er, r.auth_user_id,
  r.valor, 'MXN', true, r.n_ofertas,
  (r.id_er IS NULL OR r.auth_user_id IS NULL)
FROM representativa r
WHERE NOT EXISTS (
  SELECT 1 FROM public.crm_negocios n
  WHERE n.activo
    AND n.id_entidad_relacionada IS NOT DISTINCT FROM r.id_er
    AND ((r.id_propiedad IS NOT NULL AND n.id_propiedad = r.id_propiedad)
      OR (r.id_propiedad IS NULL AND r.id_producto IS NOT NULL AND n.id_producto = r.id_producto)))
ON CONFLICT DO NOTHING;   -- red de seguridad: el NOT EXISTS no ve las filas de este mismo INSERT

-- ─────────────────────────────────────────────────────────────────────
-- 8. Backfill 2: avanzar por apartado ya aplicado (508 pares en prod).
--    Mismo emparejamiento por unidad que el trigger (corrección 1).
-- ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r record; v_n int := 0;
BEGIN
  FOR r IN
    WITH apartados AS (
      SELECT DISTINCT o.id AS id_oferta, o.id_persona_lead, o.id_propiedad, o.id_producto
      FROM public.cuentas_cobranza cc
      JOIN public.ofertas o            ON o.id = cc.id_oferta
      JOIN public.acuerdos_pago ap     ON ap.id_cuenta_cobranza = cc.id AND ap.id_concepto = 1
      JOIN public.aplicaciones_pago al ON al.id_acuerdo_pago = ap.id
                                      AND coalesce(al.es_multa,false) = false AND al.activo
      WHERE cc.activo AND o.id_persona_lead IS NOT NULL
    )
    SELECT DISTINCT n.id
    FROM apartados a
    JOIN public.entidades_relacionadas er ON er.activo AND er.id_tipo_entidad = 7
                                         AND er.id_persona = a.id_persona_lead
    JOIN public.crm_negocios n ON n.activo AND n.id_entidad_relacionada = er.id
                              AND ((a.id_propiedad IS NOT NULL AND n.id_propiedad = a.id_propiedad)
                                OR (a.id_propiedad IS NULL AND a.id_producto IS NOT NULL
                                    AND n.id_producto = a.id_producto))
    UNION
    SELECT DISTINCT n.id
    FROM apartados a JOIN public.crm_negocios n ON n.activo AND n.id_oferta = a.id_oferta
  LOOP
    PERFORM public.fn_crm_avanzar_negocio(r.id, 'apartado_pagado');
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'Negocios evaluados por apartado aplicado: %', v_n;
END $$;

-- ─────────────────────────────────────────────────────────────────────
-- 9. Backfill 3: avanzar por estatus actual de la propiedad (5 · 7,8,9)
-- ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.id,
           CASE WHEN p.id_estatus_disponibilidad = 5 THEN 'enganche_contrato' ELSE 'ganado' END AS clave
    FROM public.crm_negocios n
    JOIN public.propiedades p ON p.id = n.id_propiedad
    WHERE n.activo AND p.id_estatus_disponibilidad IN (5,7,8,9)
  LOOP
    PERFORM public.fn_crm_avanzar_negocio(r.id, r.clave);
  END LOOP;
END $$;

-- ─────────────────────────────────────────────────────────────────────
-- 10. Las funciones no nacen públicas (ver corrección 4)
-- ─────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.fn_crm_etapa(text)                       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_crm_avanzar_negocio(integer, text)    FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF to_regprocedure('public.fn_crm_negocio_por_no_avance()') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.fn_crm_negocio_por_no_avance() FROM PUBLIC, anon, authenticated';
  END IF;
END $$;

REVOKE ALL ON FUNCTION public.fn_crm_negocio_desde_oferta()            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_crm_negocio_por_apartado()            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_crm_negocio_por_estatus_propiedad()   FROM PUBLIC, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- 11. Self-verifying
-- ─────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF to_regprocedure('public.fn_crm_etapa(text)') IS NULL
     OR to_regprocedure('public.fn_crm_avanzar_negocio(integer,text)') IS NULL THEN
    RAISE EXCEPTION 'Faltan los helpers de etapa';
  END IF;

  IF public.fn_crm_etapa('oferta_enviada') IS NULL OR public.fn_crm_etapa('apartado_pagado') IS NULL THEN
    RAISE EXCEPTION 'El pipeline canónico no está aplicado: falta el archivo 03';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_crm_negocio_desde_oferta')
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_crm_negocio_por_apartado')
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_crm_negocio_por_estatus_propiedad') THEN
    RAISE EXCEPTION 'Faltan triggers de automatización de negocio';
  END IF;
END $$;

-- Rollback:
--   DROP TRIGGER IF EXISTS trg_crm_negocio_desde_oferta ON public.ofertas;
--   DROP TRIGGER IF EXISTS trg_crm_negocio_por_apartado ON public.aplicaciones_pago;
--   DROP TRIGGER IF EXISTS trg_crm_negocio_por_estatus_propiedad ON public.propiedades;
--   DROP TRIGGER IF EXISTS trg_crm_negocio_por_no_avance ON public.ofertas_no_avance;
--   DROP FUNCTION IF EXISTS public.fn_crm_negocio_desde_oferta();
--   DROP FUNCTION IF EXISTS public.fn_crm_negocio_por_apartado();
--   DROP FUNCTION IF EXISTS public.fn_crm_negocio_por_estatus_propiedad();
--   DROP FUNCTION IF EXISTS public.fn_crm_negocio_por_no_avance();
--   -- fn_crm_avanzar_negocio y fn_crm_etapa las usa el 06.
--   UPDATE public.crm_negocios SET activo = false
--   WHERE activo AND id_oferta IS NOT NULL
--     AND id_pipeline = (SELECT id FROM public.crm_pipelines WHERE clave = 'ventas_sozu');
--
-- RECONCILIACIÓN — correr tras el deploy y de forma periódica. Los triggers se tragan sus
-- errores a propósito (el CRM nunca puede tumbar una oferta ni un pago), así que ésta es la
-- red que detecta lo que falló en silencio. Debe dar 0 filas; si no, re-correr los bloques 8
-- y 9, que son idempotentes y solo avanzan etapas.
--   WITH apartados AS (
--     SELECT DISTINCT o.id_persona_lead, o.id_propiedad, o.id_producto
--     FROM public.cuentas_cobranza cc
--     JOIN public.ofertas o            ON o.id = cc.id_oferta
--     JOIN public.acuerdos_pago ap     ON ap.id_cuenta_cobranza = cc.id AND ap.id_concepto = 1
--     JOIN public.aplicaciones_pago al ON al.id_acuerdo_pago = ap.id
--                                     AND coalesce(al.es_multa,false) = false AND al.activo
--     WHERE cc.activo)
--   SELECT n.id, n.nombre, e.clave AS etapa_actual, 'apartado_aplicado' AS hecho_pendiente
--   FROM public.crm_negocios n
--   JOIN public.crm_pipeline_etapas e     ON e.id  = n.id_etapa
--   JOIN public.entidades_relacionadas er ON er.id = n.id_entidad_relacionada
--   JOIN apartados a ON a.id_persona_lead = er.id_persona
--                   AND ((a.id_propiedad IS NOT NULL AND n.id_propiedad = a.id_propiedad)
--                     OR (a.id_propiedad IS NULL AND n.id_producto = a.id_producto))
--   WHERE n.activo AND e.orden < 70
--   UNION ALL
--   SELECT n.id, n.nombre, e.clave, 'propiedad_' || p.id_estatus_disponibilidad
--   FROM public.crm_negocios n
--   JOIN public.crm_pipeline_etapas e ON e.id = n.id_etapa
--   JOIN public.propiedades p ON p.id = n.id_propiedad
--   WHERE n.activo AND p.id_estatus_disponibilidad IN (5,7,8,9)
--     AND e.orden < CASE WHEN p.id_estatus_disponibilidad = 5 THEN 80 ELSE 90 END;
