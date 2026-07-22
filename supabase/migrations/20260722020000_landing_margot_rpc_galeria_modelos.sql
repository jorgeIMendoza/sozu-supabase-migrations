-- Landing Margot — agrega galería de imágenes por modelo (key 'imagenes' en 'models')
-- Fecha: 2026-07-22
--
-- MOTIVO:
--   La landing (detalle de unidad) ya soporta galería con lightbox, pero el RPC solo
--   devuelve 'portada' (1 imagen) por modelo. Este cambio agrega 'imagenes': arreglo de
--   URLs de las imágenes activas del modelo (multimedias_modelo). El front pone la portada
--   primero y deduplica, así que 'imagenes' puede o no incluir la portada.
--
-- CAMBIO (aditivo, solo bloque 'models'):
--   + key 'imagenes' = jsonb_agg(mm.url order by mm.id) de multimedias_modelo
--     where id_modelo = m.id and activo and es_imagen. Resto de 'models' sin cambios.
--   El filtro de modelos se mantiene (activo and url_imagen_portada is not null); "Office"
--   (sin portada) sigue excluido — decisión de Eduardo, no se cambia aquí.
--   Nodos project/units/points/video/amenities: SIN cambios.
--
-- Base = definición viva de prod (fuente de verdad), verificada read-only 2026-07-22.
-- Data verificada (project 1743): Joy 7, Heart 9, Kind 8, Breath 11, Soft 8 imágenes activas.
-- Columnas verificadas: multimedias_modelo(id_modelo, url, activo, es_imagen).
--
-- CREATE OR REPLACE => idempotente; conserva grants. Re-aplica revoke/grant por seguridad.
-- Bloque final self-verifying: aborta si la def resultante no conserva las keys clave.

CREATE OR REPLACE FUNCTION public.landing_margot_rpc()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'project', (
      select jsonb_build_object(
        'name', p.nombre,
        'description', regexp_replace(coalesce(p.descripcion,''), '\s+', ' ', 'g'),
        'address', p.direccion,
        'lat', p.latitud,
        'lng', p.longitud,
        'precioM2', p.precio_m2_actual
      )
      from proyectos p where p.id = 1743
    ),
    'units', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
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
          'parking', (
            select jsonb_build_object(
              'count', count(*),
              'tipo', string_agg(distinct te.nombre, '/'),
              'incluido', coalesce(bool_and(e.es_incluido), false)
            )
            from estacionamientos e
            left join tipos_estacionamiento te on te.id = e.id_tipo
            where e.id_propiedad = pr.id and e.activo
          )
        ) order by pr.numero_piso
      ), '[]'::jsonb)
      from propiedades pr
      join edificios_modelos em on em.id = pr.id_edificio_modelo
      join edificios e on e.id = em.id_edificio and e.id_proyecto = 1743
      join modelos m on m.id = em.id_modelo
      left join estatus_disponibilidad ed on ed.id = pr.id_estatus_disponibilidad
      where pr.activo and pr.id_estatus_disponibilidad = 2
    ),
    'points', (
      select coalesce(jsonb_agg(
        jsonb_build_object('nombre', nombre, 'km', distancia_km) order by distancia_km
      ), '[]'::jsonb)
      from puntos_interes_proyecto where id_proyecto = 1743 and activo
    ),
    'video', (
      select link from videos_youtube
      where id_proyecto = 1743 and activo order by fecha_creacion desc limit 1
    ),
    'models', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'nombre', m.nombre,
          'rec', m.numero_recamaras,
          'portada', m.url_imagen_portada,
          'imagenes', (
            select coalesce(jsonb_agg(mm.url order by mm.id), '[]'::jsonb)
            from multimedias_modelo mm
            where mm.id_modelo = m.id and mm.activo and mm.es_imagen
          )
        ) order by m.id
      ), '[]'::jsonb)
      from modelos m where m.id_proyecto = 1743 and m.activo and m.url_imagen_portada is not null
    ),
    'amenities', (
      select coalesce(jsonb_agg(
        jsonb_build_object('nombre', a.nombre, 'image', ap.url_imagen, 'icon', a.url) order by a.nombre
      ), '[]'::jsonb)
      from amenidades_proyectos ap
      join amenidades a on a.id = ap.id_amenidad
      where ap.id_proyecto = 1743 and ap.activo
    )
  );
$function$;

REVOKE ALL ON FUNCTION public.landing_margot_rpc() FROM public;
GRANT EXECUTE ON FUNCTION public.landing_margot_rpc() TO anon, authenticated;

-- Self-verify: la def resultante debe conservar las keys clave, o abortar.
DO $$
DECLARE d text := pg_get_functiondef('public.landing_margot_rpc()'::regprocedure);
BEGIN
  IF position('''imagenes''' in d) = 0 THEN
    RAISE EXCEPTION 'landing_margot_rpc: falta key imagenes tras el replace';
  END IF;
  IF position('''amenities''' in d) = 0 THEN
    RAISE EXCEPTION 'landing_margot_rpc: regresión, falta key amenities tras el replace';
  END IF;
  IF position('''parking''' in d) = 0 THEN
    RAISE EXCEPTION 'landing_margot_rpc: regresión, falta key parking tras el replace';
  END IF;
END $$;
