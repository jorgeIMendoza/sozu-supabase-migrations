-- Landing Margot Web — RPC de datos (renombra web_landing_margot -> landing_margot_rpc)
-- Fecha: 2026-07-20
--
-- Convención de nombres para RPCs de landings estáticos: landing_<proyecto>_rpc, para
-- saber de un vistazo dónde se usa (repo margot-web, script scripts/fetch-margot.mjs,
-- build-time con anon key). Ver runbook Margot Web §5.2.
--
-- Función pública SECURITY DEFINER: única puerta de datos de marketing curado para anon
-- cuando RLS esté activo en las tablas del landing. Cuerpo idéntico al vivo (proyecto 1743).
--
-- Adopta en historial de migraciones la función que se creó ad-hoc (execute_sql) como
-- web_landing_margot y la renombra a la convención. Idempotente: CREATE OR REPLACE del
-- nuevo nombre + DROP FUNCTION IF EXISTS del viejo.
--
-- IMPACTO EN FRONT (repo margot-web, aplicar en el mismo despliegue):
--   - scripts/fetch-margot.mjs: supabase.rpc('web_landing_margot') -> 'landing_margot_rpc'
--   - curl de validación / cualquier fetch en cliente futuro: /rpc/landing_margot_rpc

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
          'm2', pr.m2_interiores,
          'm2Ext', pr.m2_exteriores,
          'price', round(pr.precio_lista)::bigint,
          'status', ed.nombre
        ) order by pr.numero_piso
      ), '[]'::jsonb)
      from propiedades pr
      join edificios e on e.id = pr.id_edificio_modelo and e.id_proyecto = 1743
      left join estatus_disponibilidad ed on ed.id = pr.id_estatus_disponibilidad
      where pr.activo and pr.es_aprobado and pr.id_estatus_disponibilidad = 2
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

-- Elimina el nombre viejo ad-hoc (ya reemplazado por landing_margot_rpc)
DROP FUNCTION IF EXISTS public.web_landing_margot();
