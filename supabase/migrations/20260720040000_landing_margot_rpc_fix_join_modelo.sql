-- Landing Margot — corrige join de unidades en landing_margot_rpc + agrega modelo real
-- Fecha: 2026-07-20
--
-- BUG (verificado prod 2026-07-20): la versión previa (migración 20260720030000, y la
-- función ad-hoc original) unía propiedades.id_edificio_modelo a edificios.id, cuando el
-- FK real es propiedades.id_edificio_modelo -> edificios_modelos.id. Devolvía 4 unidades
-- equivocadas. El join correcto (edificios_modelos -> edificios/modelos) devuelve las 5
-- disponibles reales (= panel admin). Verificado: viejo_join=4, nuevo_join=5.
--
-- Cambios en el nodo 'units':
--  - join real: propiedades -> edificios_modelos -> edificios (id_proyecto=1743) + modelos
--  - se quita el filtro es_aprobado (admin cuenta "Disponible" = id_estatus_disponibilidad=2
--    + activo). Disponible id 2.
--  - agrega por unidad: modelo (m.nombre), rec (numero_recamaras), banos
--    (numero_completo_banos), loft (m2_loft).
-- Resto de nodos (project/points/video/models) sin cambios.
--
-- CREATE OR REPLACE => idempotente; conserva grants existentes (anon/authenticated).
-- Re-aplica revoke/grant por seguridad. Front margot-web ya consume el modelo real
-- (scripts/fetch-margot.mjs ya no infiere por m²).

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
          'status', ed.nombre
        ) order by pr.numero_piso
      ), '[]'::jsonb)
      from propiedades pr
      join edificios_modelos em on em.id = pr.id_edificio_modelo
      join edificios e on e.id = em.id_edificio and e.id_proyecto = 1743
      join modelos m on m.id = em.id_modelo
      left join estatus_disponibilidad ed on ed.id = pr.id_estatus_disponibilidad
      where pr.activo and pr.id_estatus_disponibilidad = 2   -- 2 = Disponible
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
    )
  );
$function$;

REVOKE ALL ON FUNCTION public.landing_margot_rpc() FROM public;
GRANT EXECUTE ON FUNCTION public.landing_margot_rpc() TO anon, authenticated;
