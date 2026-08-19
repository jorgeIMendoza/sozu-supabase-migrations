-- Landing Margot: RPC pública al contrato estándar v3 (2 de 3).
-- Fecha: 2026-08-19
--
-- Homologa `landing_margot_rpc()` al contrato único que comparten los tres landings
-- (bottura id 2, margot id 1743, daiku id 1453). La estructura del JSON es IDÉNTICA en los
-- tres: cambian el nombre de la función y el id del proyecto, no las llaves. Así el frontend
-- es el mismo y solo se pule diseño y copy.
--
-- Llaves en inglés y camelCase (precioM2, m2Ext), que es lo que ya consumen dos de los tres
-- frontends. Las listas nunca llegan en null: sin filas va []. Los objetos opcionales
-- (progress, showroom) sí pueden ser null.
--
-- Riesgo: Bajo: el frontend tolera los campos nuevos y solo gana datos.
--
-- Medido read-only en prod (tzmhgfjmddkfyffkkmto) el 2026-08-19:
--   units 5 · models 6 (0 con tour360, 0 con plano) · amenities 9 (9 con foto) · points 3 · videos 20 · gallery 12 · progress 0 fotos (null) · showroom 0 (null)
--
-- ESTA ES LA UNICA DE LAS TRES QUE NO ES PURO ANADIDO: quita una llave.
--
--   · `video` (una sola cadena, el link mas reciente) SALE del contrato y entra `videos`, la
--     lista completa con nombre y link, ordenada del mas reciente al mas viejo. Margot tiene
--     20. Cualquier consumidor que lea `data.video` se queda sin dato.
--
--     El frontend ya es tolerante: margot-web/src/lib/landing.ts resuelve
--     `videoUrl: d.videos?.[0]?.link || d.video || ''`, y su unico consumidor
--     (ObraLink.svelte) cae al canal de YouTube del proyecto si no hay ninguno de los dos.
--     Asi que aplicar no rompe nada visible, y el rollback tampoco: el parseo lee las dos
--     formas. Pero quien toque ese parseo despues necesita saber que la llave cambio.
--
--   · `models` deja de filtrarse por `url_imagen_portada is not null`, que es la regla 9:
--     filtrar por completitud dentro de la RPC esconde inventario, y la decision es del
--     frontend. ESTO SI MUEVE EL CONTEO: margot pasa de 5 a 6 modelos.
--
--     El sexto es Office (id 2237), medido en prod el 2026-08-19: activo, 0 recamaras,
--     0 banos, SIN portada y con 0 unidades disponibles (2 activas, ninguna en estatus 2).
--     Hoy la RPC lo esconde por no tener portada; a partir de aqui lo devuelve y quien
--     decide si se pinta es el front, que ya filtra `models` por inventario -- y con 0
--     disponibles Office no pasa ese filtro. Los otros cinco (Joy, Heart, Kind, Breath,
--     Soft) si traen portada. Ver el hallazgo 8 de "decisiones de datos pendientes".
--
-- progress y showroom llegan en null (0 fotos de obra, 0 salas de venta).
--
-- La función se queda STABLE SECURITY DEFINER con search_path fijado y con EXECUTE para anon:
-- el landing la llama con la clave publicable, sin sesión de usuario. CREATE OR REPLACE
-- conserva el ACL vigente ({postgres, anon, authenticated, service_role}).

BEGIN;

DO $anchor$
BEGIN
  IF to_regprocedure('public.landing_margot_rpc()') IS NULL THEN
    RAISE EXCEPTION 'public.landing_margot_rpc() no existe: esta migración la reemplaza, no la crea de cero.';
  END IF;
END
$anchor$;

CREATE OR REPLACE FUNCTION public.landing_margot_rpc()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- El id_proyecto aparece UNA sola vez. Copiar esta función para otro landing es cambiar
  -- dos cosas: el nombre y este número.
  with pid as (select 1743::int as id)
  select jsonb_build_object(
    'project', (
      select jsonb_build_object(
        'name', p.nombre,
        'slogan', nullif(trim(coalesce(p.slogan, '')), ''),
        'description', regexp_replace(coalesce(p.descripcion, ''), '\s+', ' ', 'g'),
        'address', p.direccion,
        'lat', p.latitud,
        'lng', p.longitud,
        -- Si el proyecto no publica su precio por m2, aquí va null. No es decisión del landing.
        'precioM2', case when coalesce(p.mostrar_precio_m2_en_oferta, false)
                         then p.precio_m2_actual else null end,
        'entrega', p.fecha_entrega_proyecto,
        'logo', p.url_logo,
        'portada', p.url_imagen_portada,
        'social', jsonb_build_object(
          'web', nullif(trim(coalesce(p.url_sitio_web, '')), ''),
          'instagram', nullif(trim(coalesce(p.instagram_handle, '')), ''),
          'facebook', nullif(trim(coalesce(p.facebook_handle, '')), ''),
          'youtube', nullif(trim(coalesce(p.youtube_handle, '')), '')))
      from proyectos p, pid where p.id = pid.id),

    'units', coalesce((
      select jsonb_agg(jsonb_build_object(
        'numero', trim(pr.numero_propiedad),
        'floor', trim(pr.numero_piso),
        'modelo', m.nombre,
        'rec', m.numero_recamaras,
        'banos', m.numero_completo_banos,
        'm2', pr.m2_interiores,
        'm2Ext', pr.m2_exteriores,
        'loft', pr.m2_loft,
        'price', round(pr.precio_lista)::bigint,
        'status', ed.nombre,
        -- La portada de la propiedad manda; si no tiene, la del modelo.
        'image', coalesce(pr.url_imagen_portada, m.url_imagen_portada),
        'parking', (
          select jsonb_build_object(
            'count', count(*),
            'tipo', string_agg(distinct te.nombre, '/'),
            'incluido', coalesce(bool_and(es.es_incluido), false))
          from estacionamientos es
          left join tipos_estacionamiento te on te.id = es.id_tipo
          where es.id_propiedad = pr.id and es.activo)
      ) order by pr.numero_piso)
      from propiedades pr
      join edificios_modelos em on em.id = pr.id_edificio_modelo
      join edificios e on e.id = em.id_edificio
      join modelos m on m.id = em.id_modelo
      left join estatus_disponibilidad ed on ed.id = pr.id_estatus_disponibilidad, pid
      where e.id_proyecto = pid.id and pr.activo and pr.id_estatus_disponibilidad = 2
    ), '[]'::jsonb),

    -- Sin filtro de completitud: `models` NO se filtra por "tiene portada". Filtrar aquí
    -- esconde inventario; quien decide qué mostrar es el frontend.
    'models', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nombre', m.nombre,
        'rec', m.numero_recamaras,
        'banos', m.numero_completo_banos,
        'descripcion', regexp_replace(coalesce(m.descripcion, ''), '\s+', ' ', 'g'),
        'portada', m.url_imagen_portada,
        'tour360', nullif(trim(coalesce(m.url_tour_360, '')), ''),
        'plano', m.plano_arquitectonico,
        'imagenes', coalesce((
          select jsonb_agg(mm.url order by mm.id)
          from multimedias_modelo mm
          where mm.id_modelo = m.id and mm.activo and mm.es_imagen), '[]'::jsonb)
      ) order by m.id)
      from modelos m, pid where m.id_proyecto = pid.id and m.activo
    ), '[]'::jsonb),

    -- `image` es fotografía y `icon` es pictograma. Sin coalesce entre ellos: mezclarlos
    -- hace que el landing pinte un icono estirado como si fuera foto.
    'amenities', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nombre', a.nombre, 'image', ap.url_imagen, 'icon', a.url) order by a.nombre)
      from amenidades_proyectos ap
      join amenidades a on a.id = ap.id_amenidad, pid
      where ap.id_proyecto = pid.id and ap.activo
    ), '[]'::jsonb),

    'points', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', pt.nombre, 'km', pt.distancia_km)
             order by pt.distancia_km)
      from puntos_interes_proyecto pt, pid
      where pt.id_proyecto = pid.id and pt.activo
    ), '[]'::jsonb),

    'videos', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', v.nombre, 'link', v.link)
             order by v.fecha_creacion desc)
      from videos_youtube v, pid where v.id_proyecto = pid.id and v.activo
    ), '[]'::jsonb),

    -- Categoría 2 = «Avances de obra»: va en `progress`, nunca en la galería.
    'gallery', coalesce((
      select jsonb_agg(jsonb_build_object('url', mp.url, 'categoria', cm.nombre) order by mp.id)
      from multimedias_proyecto mp
      left join categorias_multimedia_proyecto cm on cm.id = mp.id_categoria, pid
      where mp.id_proyecto = pid.id and mp.activo and mp.es_imagen
        and coalesce(mp.id_categoria, 0) <> 2
    ), '[]'::jsonb),

    -- Solo el lote más reciente, con la fecha ya formateada. null si no hay fotos de obra:
    -- los objetos opcionales sí pueden ser null, las listas nunca.
    'progress', (
      with lote as (
        select mp.url, mp.fecha_actualizacion, mp.fecha_actualizacion::date as dia
        from multimedias_proyecto mp, pid
        where mp.id_proyecto = pid.id and mp.activo and mp.es_imagen and mp.id_categoria = 2
      ), ultimo as (select max(dia) as dia from lote)
      select case when (select dia from ultimo) is null then null else jsonb_build_object(
        'actualizado', (select to_char(dia, 'DD/MM/YYYY') from ultimo),
        'imagenes', coalesce((
          select jsonb_agg(l.url order by l.fecha_actualizacion)
          from lote l, ultimo u where l.dia = u.dia), '[]'::jsonb)) end),

    'showroom', (
      select jsonb_build_object(
        'nombre', s.nombre, 'direccion', s.descripcion_direccion,
        'horarios', s.horarios, 'lat', s.latitud, 'lng', s.longitud)
      from showrooms_proyecto s, pid
      where s.id_proyecto = pid.id and s.activo
      order by s.id limit 1)
  );
$function$;

DO $verify$
DECLARE
  v_json    jsonb;
  v_llaves  text[];
  v_esperadas text[] := array['amenities','gallery','models','points','progress','project','showroom','units','videos'];
  v_faltan  text;
  v_oid     oid := 'public.landing_margot_rpc()'::regprocedure;
BEGIN
  -- La función es STABLE y no escribe: llamarla aquí es la verificación más barata que hay.
  v_json := public.landing_margot_rpc();

  SELECT array_agg(k ORDER BY k) INTO v_llaves FROM jsonb_object_keys(v_json) k;
  IF v_llaves IS DISTINCT FROM v_esperadas THEN
    RAISE EXCEPTION 'Las llaves del contrato no coinciden. Esperadas: %. Obtenidas: %',
      v_esperadas, v_llaves;
  END IF;

  -- Ninguna lista puede llegar en null: el frontend no defiende contra null.
  SELECT string_agg(x.llave, ', ' ORDER BY x.llave) INTO v_faltan
  FROM (VALUES ('units'),('models'),('amenities'),('points'),('videos'),('gallery')) AS x(llave)
  WHERE jsonb_typeof(v_json -> x.llave) IS DISTINCT FROM 'array';
  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'Estas llaves no llegaron como array: %', v_faltan;
  END IF;

  -- La galería no puede traer una sola foto de la categoría 2 («Avances de obra»).
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_json -> 'gallery') g
    JOIN public.multimedias_proyecto mp ON mp.url = g ->> 'url'
    WHERE mp.id_categoria = 2
  ) THEN
    RAISE EXCEPTION 'gallery trae fotos de avance de obra: van en progress, no en la galería.';
  END IF;

  -- amenities.image (foto) y amenities.icon (pictograma) no se mezclan. Si alguna trae la
  -- misma cadena en las dos, hubo un coalesce de por medio.
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_json -> 'amenities') a
    WHERE a ->> 'image' IS NOT NULL AND a ->> 'image' = a ->> 'icon'
  ) THEN
    RAISE EXCEPTION 'amenities.image y amenities.icon traen el mismo valor: no se hace coalesce entre foto y pictograma.';
  END IF;

  -- La llama el landing con la clave publicable, sin sesión: anon tiene que poder ejecutarla.
  IF NOT has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'anon no puede ejecutar landing_margot_rpc: el landing responderia 404.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND p.prosecdef AND p.provolatile = 's' AND p.proconfig IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'landing_margot_rpc no quedó STABLE SECURITY DEFINER con search_path fijado.';
  END IF;
END
$verify$;
COMMIT;

-- ---------------------------------------------------------------------------
-- Rollback: definición vigente en prod ANTES de esta migración
-- ---------------------------------------------------------------------------
-- Capturada con pg_get_functiondef el 2026-08-19. CREATE OR REPLACE sobrescribe el cuerpo
-- anterior, así que esta copia es el único rollback fiable. Para revertir, ejecutar tal cual:
--
--   CREATE OR REPLACE FUNCTION public.landing_margot_rpc()
--    RETURNS jsonb
--    LANGUAGE sql
--    STABLE SECURITY DEFINER
--    SET search_path TO 'public'
--   AS $function$
--     select jsonb_build_object(
--       'project', (
--         select jsonb_build_object(
--           'name', p.nombre,
--           'description', regexp_replace(coalesce(p.descripcion,''), '\s+', ' ', 'g'),
--           'address', p.direccion,
--           'lat', p.latitud,
--           'lng', p.longitud,
--           'precioM2', p.precio_m2_actual
--         )
--         from proyectos p where p.id = 1743
--       ),
--       'units', (
--         select coalesce(jsonb_agg(
--           jsonb_build_object(
--             'numero', trim(pr.numero_propiedad),
--             'floor', trim(pr.numero_piso),
--             'modelo', m.nombre,
--             'rec', m.numero_recamaras,
--             'banos', m.numero_completo_banos,
--             'm2', pr.m2_interiores,
--             'm2Ext', pr.m2_exteriores,
--             'loft', pr.m2_loft,
--             'price', round(pr.precio_lista)::bigint,
--             'status', ed.nombre,
--             'parking', (
--               select jsonb_build_object(
--                 'count', count(*),
--                 'tipo', string_agg(distinct te.nombre, '/'),
--                 'incluido', coalesce(bool_and(e.es_incluido), false)
--               )
--               from estacionamientos e
--               left join tipos_estacionamiento te on te.id = e.id_tipo
--               where e.id_propiedad = pr.id and e.activo
--             )
--           ) order by pr.numero_piso
--         ), '[]'::jsonb)
--         from propiedades pr
--         join edificios_modelos em on em.id = pr.id_edificio_modelo
--         join edificios e on e.id = em.id_edificio and e.id_proyecto = 1743
--         join modelos m on m.id = em.id_modelo
--         left join estatus_disponibilidad ed on ed.id = pr.id_estatus_disponibilidad
--         where pr.activo and pr.id_estatus_disponibilidad = 2
--       ),
--       'points', (
--         select coalesce(jsonb_agg(
--           jsonb_build_object('nombre', nombre, 'km', distancia_km) order by distancia_km
--         ), '[]'::jsonb)
--         from puntos_interes_proyecto where id_proyecto = 1743 and activo
--       ),
--       'video', (
--         select link from videos_youtube
--         where id_proyecto = 1743 and activo order by fecha_creacion desc limit 1
--       ),
--       'models', (
--         select coalesce(jsonb_agg(
--           jsonb_build_object(
--             'nombre', m.nombre,
--             'rec', m.numero_recamaras,
--             'portada', m.url_imagen_portada,
--             'imagenes', (
--               select coalesce(jsonb_agg(mm.url order by mm.id), '[]'::jsonb)
--               from multimedias_modelo mm
--               where mm.id_modelo = m.id and mm.activo and mm.es_imagen
--             )
--           ) order by m.id
--         ), '[]'::jsonb)
--         from modelos m where m.id_proyecto = 1743 and m.activo and m.url_imagen_portada is not null
--       ),
--       'amenities', (
--         select coalesce(jsonb_agg(
--           jsonb_build_object('nombre', a.nombre, 'image', ap.url_imagen, 'icon', a.url) order by a.nombre
--         ), '[]'::jsonb)
--         from amenidades_proyectos ap
--         join amenidades a on a.id = ap.id_amenidad
--         where ap.id_proyecto = 1743 and ap.activo
--       )
--     );
--   $function$
