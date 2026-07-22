-- Landing Daiku — RPC pública de solo lectura que alimenta la landing daiku-web.
-- Fecha: 2026-07-22
--
-- OBJETIVO:
--   Exponer en un solo llamado toda la data pública del desarrollo Daiku
--   (proyecto, amenidades, avances de obra, ubicación, showroom y modelos) para que
--   la landing la consuma vía POST /rest/v1/rpc/landing_daiku_rpc con la clave anon.
--
-- SEGURIDAD:
--   SECURITY DEFINER + search_path fijo, id_proyecto = 1453 fijado internamente (no
--   acepta parámetros → no permite leer otros proyectos). La mayoría de las tablas base
--   tienen RLS ON, por lo que anon NO puede leerlas directo: este RPC (como definer) es
--   la vía controlada. Devuelve solo campos públicos (nada de precios/PII/datos internos).
--   Se revoca a public y se otorga EXECUTE solo a anon/authenticated.
--
-- MAPEO (project_id = 1453), verificado read-only contra prod 2026-07-22:
--   proyecto  <- proyectos (id=1453)
--   amenidades<- amenidades_proyectos ap JOIN amenidades a; imagen=coalesce(ap.url_imagen,a.url)
--   avances   <- multimedias_proyecto cat 2 (Avances de obra), activo+es_imagen, SOLO el
--                último lote (fecha_actualizacion::date = fecha máx); actualizado=DD/MM/YYYY
--   ubicacion <- puntos_interes_proyecto
--   showroom  <- showrooms_proyecto (LIMIT 1)
--   modelos   <- modelos; una sola imagen = coalesce(portada, 1a multimedia_modelo activa)
--
-- Columnas verificadas en prod: proyectos(nombre,direccion,latitud,longitud,url_logo,
--   instagram_handle,facebook_handle,youtube_handle,slogan), amenidades_proyectos(
--   id_proyecto,id_amenidad,url_imagen,activo), amenidades(id,nombre,url),
--   multimedias_proyecto(id_proyecto,url,activo,es_imagen,id_categoria,fecha_actualizacion),
--   puntos_interes_proyecto(id_proyecto,nombre,distancia_km,activo),
--   showrooms_proyecto(id_proyecto,nombre,descripcion_direccion,horarios,latitud,longitud,activo),
--   modelos(id,id_proyecto,nombre,descripcion,numero_recamaras,numero_completo_banos,
--   numero_medio_bano,url_imagen_portada,activo), multimedias_modelo(id_modelo,url,activo,es_imagen).
--
-- CREATE OR REPLACE => idempotente. Re-aplica revoke/grant. Bloque final self-verifying:
--   aborta (RAISE EXCEPTION) si la def resultante no contiene las keys esperadas.
--
-- DRIFT dev<->prod (2026-07-22): showrooms_proyecto.horarios (text NULL) existe en prod
--   pero falta en dev (fue añadida a prod fuera del flujo de migraciones). Como el cuerpo
--   LANGUAGE sql se valida al crear la función, sin la columna el CREATE aborta en dev.
--   El ALTER guardado abajo es no-op en prod (IF NOT EXISTS) y añade la columna en dev,
--   dejando ambos idénticos antes de crear el RPC.

ALTER TABLE public.showrooms_proyecto ADD COLUMN IF NOT EXISTS horarios text;

CREATE OR REPLACE FUNCTION public.landing_daiku_rpc()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  with pid as (select 1453::int as id)
  select jsonb_build_object(
    'proyecto', (
      select jsonb_build_object(
        'nombre', p.nombre, 'direccion', p.direccion,
        'latitud', p.latitud, 'longitud', p.longitud,
        'logo', p.url_logo, 'instagram', p.instagram_handle,
        'facebook', p.facebook_handle, 'youtube', p.youtube_handle, 'slogan', p.slogan)
      from proyectos p, pid where p.id = pid.id
    ),
    'amenidades', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', a.nombre,
             'imagen', coalesce(ap.url_imagen, a.url)) order by ap.id)
      from amenidades_proyectos ap join amenidades a on a.id = ap.id_amenidad, pid
      where ap.id_proyecto = pid.id and ap.activo), '[]'::jsonb),
    'avances', (
      with lote as (
        select mp.url, mp.fecha_actualizacion, mp.fecha_actualizacion::date as dia
        from multimedias_proyecto mp, pid
        where mp.id_proyecto = pid.id and mp.activo and mp.es_imagen and mp.id_categoria = 2
      ), ultimo as (select max(dia) as dia from lote)
      select jsonb_build_object(
        'actualizado', (select to_char(dia, 'DD/MM/YYYY') from ultimo),
        'imagenes', coalesce((
          select jsonb_agg(l.url order by l.fecha_actualizacion)
          from lote l, ultimo u where l.dia = u.dia), '[]'::jsonb))),
    'ubicacion', jsonb_build_object('puntos', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', pi.nombre, 'distancia_km', pi.distancia_km) order by pi.distancia_km)
      from puntos_interes_proyecto pi, pid
      where pi.id_proyecto = pid.id and pi.activo), '[]'::jsonb)),
    'showroom', (
      select jsonb_build_object('nombre', s.nombre, 'direccion', s.descripcion_direccion,
             'horarios', s.horarios, 'latitud', s.latitud, 'longitud', s.longitud)
      from showrooms_proyecto s, pid where s.id_proyecto = pid.id and s.activo
      order by s.id limit 1),
    'modelos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nombre', m.nombre, 'descripcion', m.descripcion,
        'recamaras', m.numero_recamaras, 'banos', m.numero_completo_banos, 'medio_bano', m.numero_medio_bano,
        'imagen', coalesce(m.url_imagen_portada,
           (select mm.url from multimedias_modelo mm
            where mm.id_modelo = m.id and mm.activo and mm.es_imagen order by mm.id limit 1))
      ) order by m.id)
      from modelos m, pid where m.id_proyecto = pid.id and m.activo), '[]'::jsonb)
  );
$function$;

REVOKE ALL ON FUNCTION public.landing_daiku_rpc() FROM public;
GRANT EXECUTE ON FUNCTION public.landing_daiku_rpc() TO anon, authenticated;

-- Self-verify: la def resultante debe contener las keys esperadas, o abortar.
DO $$
DECLARE d text := pg_get_functiondef('public.landing_daiku_rpc()'::regprocedure);
BEGIN
  IF position('''proyecto''' in d) = 0 THEN
    RAISE EXCEPTION 'landing_daiku_rpc: falta key proyecto tras el replace';
  END IF;
  IF position('''amenidades''' in d) = 0 THEN
    RAISE EXCEPTION 'landing_daiku_rpc: falta key amenidades tras el replace';
  END IF;
  IF position('''avances''' in d) = 0 THEN
    RAISE EXCEPTION 'landing_daiku_rpc: falta key avances tras el replace';
  END IF;
  IF position('''modelos''' in d) = 0 THEN
    RAISE EXCEPTION 'landing_daiku_rpc: falta key modelos tras el replace';
  END IF;
END $$;
