-- Landing Margot — agrega amenidades (nivel proyecto) + estacionamiento (por unidad) a landing_margot_rpc
-- Fecha: 2026-07-21
--
-- CONTEXTO / RECONCILIACIÓN:
--   Esta versión (keys 'amenities' raíz + 'parking' dentro de units) ya fue aplicada por
--   error DIRECTO a prod (admin_sozu) en una sesión previa, SIN pasar por migraciones.
--   Prod tiene la def viva pero NO está registrada en supabase_migrations.schema_migrations.
--   Esta migración formaliza ese cambio: en prod es un no-op efectivo (CREATE OR REPLACE con
--   la MISMA def que ya está viva => idempotente, no rompe CI); en dev VPS aplica el cambio
--   que le falta, dejando dev == prod (md5 idéntico). Base = definición viva de prod
--   (fuente de verdad), verificada read-only 2026-07-21.
--
-- CAMBIO (aditivo, no toca keys existentes):
--   1. key 'amenities' (raíz): galería de amenidades del proyecto 1743 con imagen.
--      image = amenidades_proyectos.url_imagen ; icon = amenidades.url (PNG legacy).
--      El front filtra por image no nula (hoy 5 de 10 amenidades tienen imagen).
--   2. key 'parking' (dentro de cada unidad): count de cajones activos, tipo(s)
--      (Normal/Tandem/combinaciones), incluido = bool_and(es_incluido).
--   Resto de nodos (project/units-existente/points/video/models) sin cambios.
--
-- Columnas verificadas en prod: amenidades_proyectos(id_proyecto,id_amenidad,url_imagen,activo),
--   amenidades(id,nombre,url), estacionamientos(id_propiedad,id_tipo,es_incluido,activo),
--   tipos_estacionamiento(id,nombre).
--
-- CREATE OR REPLACE => idempotente; conserva grants. Re-aplica revoke/grant por seguridad.
-- Bloque final self-verifying: aborta (RAISE EXCEPTION) si la def resultante no contiene
-- ambas keys nuevas, para no dejar pasar un replace parcial en CI.

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
        jsonb_build_object('nombre', nombre, 'rec', numero_recamaras, 'portada', url_imagen_portada) order by id
      ), '[]'::jsonb)
      from modelos where id_proyecto = 1743 and activo and url_imagen_portada is not null
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

-- Self-verify: la def resultante debe contener ambas keys nuevas, o abortar.
DO $$
DECLARE d text := pg_get_functiondef('public.landing_margot_rpc()'::regprocedure);
BEGIN
  IF position('''amenities''' in d) = 0 THEN
    RAISE EXCEPTION 'landing_margot_rpc: falta key amenities tras el replace';
  END IF;
  IF position('''parking''' in d) = 0 THEN
    RAISE EXCEPTION 'landing_margot_rpc: falta key parking tras el replace';
  END IF;
END $$;
