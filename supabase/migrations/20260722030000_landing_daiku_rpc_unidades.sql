-- Landing Daiku — reemplaza bloque 'modelos' por 'unidades' en landing_daiku_rpc
-- Fecha: 2026-07-22
--
-- MOTIVO:
--   La landing pasa de mostrar modelos a listar unidades (propiedades) disponibles con
--   precio, m2, piso, modelo y estacionamientos. Se elimina la key 'modelos' y se agrega
--   'unidades'. Resto de nodos (proyecto/amenidades/avances/ubicacion/showroom) sin cambios.
--
-- FUENTE unidades (project 1453):
--   propiedades p JOIN edificios_modelos em JOIN edificios e JOIN modelos m
--   WHERE e.id_proyecto = 1453 AND p.activo
--     AND p.id_estatus_disponibilidad IN (1,2,3)  -- Inventario/Disponible/Listo
--     AND m.nombre <> 'F'                          -- oculta Modelo F
--   Orden: precio_lista asc nulls last.
--   piso = numero_piso con no-dígitos removidos -> int (hoy son "1".."13").
--   estacionamientos = count de cajones ACTIVOS de la propiedad (se filtra es.activo:
--     hay 1 unidad con cajón inactivo; sin el filtro se sobre-contaría — ver PR/nota).
--   imagen = coalesce(p.url_imagen_portada, m.url_imagen_portada).
--   descripcion = coalesce(p.descripcion, m.descripcion) (copy de marketing, no PII).
--
-- SEGURIDAD / NEGOCIO:
--   Este cambio EXPONE precio_lista por unidad al público (anon). Es intencional según la
--   spec (contrato 'precio'). Rango actual: ~4.3M–9.5M MXN. Validado read-only 2026-07-22.
--
-- Base = definición viva de prod (fuente de verdad). Columnas verificadas:
--   propiedades(id,numero_propiedad,numero_piso,m2_interiores,m2_exteriores,precio_lista,
--   url_imagen_portada,descripcion,activo,id_edificio_modelo,id_estatus_disponibilidad),
--   estacionamientos(id_propiedad,activo), edificios(id,id_proyecto),
--   edificios_modelos(id,id_edificio,id_modelo),
--   modelos(nombre,descripcion,numero_recamaras,numero_completo_banos,url_imagen_portada).
--
-- CREATE OR REPLACE => idempotente. Re-aplica revoke/grant. Self-verify: aborta si la def
--   resultante no contiene 'unidades' o si perdió algún nodo público.

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
    'unidades', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'numero', p.numero_propiedad,
        'piso', nullif(regexp_replace(coalesce(p.numero_piso,''), '\D', '', 'g'), '')::int,
        'm2', p.m2_interiores, 'm2_ext', p.m2_exteriores, 'precio', p.precio_lista,
        'modelo', m.nombre, 'recamaras', m.numero_recamaras, 'banos', m.numero_completo_banos,
        'estacionamientos', (select count(*) from estacionamientos es where es.id_propiedad = p.id and es.activo),
        'imagen', coalesce(p.url_imagen_portada, m.url_imagen_portada),
        'descripcion', coalesce(p.descripcion, m.descripcion)
      ) order by p.precio_lista asc nulls last)
      from propiedades p
        join edificios_modelos em on em.id = p.id_edificio_modelo
        join edificios e on e.id = em.id_edificio
        join modelos m on m.id = em.id_modelo, pid
      where e.id_proyecto = pid.id and p.activo
        and p.id_estatus_disponibilidad in (1,2,3) and m.nombre <> 'F'), '[]'::jsonb)
  );
$function$;

REVOKE ALL ON FUNCTION public.landing_daiku_rpc() FROM public;
GRANT EXECUTE ON FUNCTION public.landing_daiku_rpc() TO anon, authenticated;

-- Self-verify: la def resultante debe contener 'unidades' y conservar los nodos públicos.
DO $$
DECLARE d text := pg_get_functiondef('public.landing_daiku_rpc()'::regprocedure);
BEGIN
  IF position('''unidades''' in d) = 0 THEN
    RAISE EXCEPTION 'landing_daiku_rpc: falta key unidades tras el replace';
  END IF;
  IF position('''proyecto''' in d) = 0 OR position('''amenidades''' in d) = 0
     OR position('''avances''' in d) = 0 OR position('''showroom''' in d) = 0 THEN
    RAISE EXCEPTION 'landing_daiku_rpc: regresión, falta un nodo público tras el replace';
  END IF;
END $$;
