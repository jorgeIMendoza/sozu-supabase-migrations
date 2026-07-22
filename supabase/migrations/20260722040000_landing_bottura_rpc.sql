-- Landing Bottura — RPC pública de solo lectura para el landing bottura-web
-- Fecha: 2026-07-22
--
-- OBJETIVO:
--   Devolver en un solo llamado el proyecto, el inventario de unidades vendibles y las
--   amenidades de Bottura (proyectos.id = 2). Estándar idéntico a landing_margot_rpc.
--   Consumo: POST /rest/v1/rpc/landing_bottura_rpc con clave anon.
--
-- SEGURIDAD:
--   SECURITY DEFINER + search_path fijo; id_proyecto = 2 fijado internamente (sin
--   parámetros → no permite leer otros proyectos). anon no accede a las tablas base:
--   solo a esta función. REVOKE public + GRANT EXECUTE a anon/authenticated.
--   Devuelve solo campos públicos (nada de costos internos, propietario, notas).
--
-- CONTRATO: { project{name,description,address}, units[]{numero,floor,modelo,rec,banos,
--   m2,m2Ext,price,status,image,parking{count,tipo,incluido}}, amenities[]{nombre,image} }.
--   points/video de margot no aplican en Bottura → omitidos.
--
-- FUENTE (project 2), verificado read-only 2026-07-22:
--   units  <- propiedades JOIN edificios_modelos JOIN edificios(id_proyecto=2) JOIN modelos,
--             estatus disponible (id_estatus_disponibilidad = 2, mismo criterio que margot).
--             image = coalesce(propiedad.url_imagen_portada, modelo.url_imagen_portada).
--             parking = cajones ACTIVOS: count, tipo(s) (string_agg), incluido (bool_and).
--   amenities <- amenidades_proyectos ap JOIN amenidades a; image = coalesce(ap.url_imagen, a.url).
--
-- NOTAS DE DATOS (al escribir, project 2):
--   3 unidades Disponibles (modelo Gala), precio ~3.42M–3.47M MXN, 1 cajón Normal incluido.
--   units.image: hoy las portadas de propiedad son URLs legacy (api.sozu.com), no Supabase
--     Storage → el front las sirve tal cual (sin transform WebP/resize).
--   amenities.image: ap.url_imagen está NULL en las 10 amenidades → cae a a.url (íconos
--     genéricos legacy en Supabase Storage), no fotos propias de Bottura.
--
-- CREATE OR REPLACE => idempotente. Re-aplica revoke/grant. Self-verify: aborta si la def
--   resultante no contiene project/units/amenities.

CREATE OR REPLACE FUNCTION public.landing_bottura_rpc()
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
        'address', p.direccion
      )
      from proyectos p where p.id = 2
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
          'price', round(pr.precio_lista)::bigint,
          'status', ed.nombre,
          'image', coalesce(pr.url_imagen_portada, m.url_imagen_portada),
          'parking', (
            select jsonb_build_object(
              'count', count(*),
              'tipo', string_agg(distinct te.nombre, '/'),
              'incluido', coalesce(bool_and(es.es_incluido), false)
            )
            from estacionamientos es
            left join tipos_estacionamiento te on te.id = es.id_tipo
            where es.id_propiedad = pr.id and es.activo
          )
        ) order by pr.numero_piso
      ), '[]'::jsonb)
      from propiedades pr
      join edificios_modelos em on em.id = pr.id_edificio_modelo
      join edificios e on e.id = em.id_edificio and e.id_proyecto = 2
      join modelos m on m.id = em.id_modelo
      left join estatus_disponibilidad ed on ed.id = pr.id_estatus_disponibilidad
      where pr.activo and pr.id_estatus_disponibilidad = 2
    ),
    'amenities', (
      select coalesce(jsonb_agg(
        jsonb_build_object('nombre', a.nombre, 'image', coalesce(ap.url_imagen, a.url)) order by a.nombre
      ), '[]'::jsonb)
      from amenidades_proyectos ap
      join amenidades a on a.id = ap.id_amenidad
      where ap.id_proyecto = 2 and ap.activo
    )
  );
$function$;

REVOKE ALL ON FUNCTION public.landing_bottura_rpc() FROM public;
GRANT EXECUTE ON FUNCTION public.landing_bottura_rpc() TO anon, authenticated;

-- Self-verify: la def resultante debe contener las keys del contrato, o abortar.
DO $$
DECLARE d text := pg_get_functiondef('public.landing_bottura_rpc()'::regprocedure);
BEGIN
  IF position('''project''' in d) = 0 OR position('''units''' in d) = 0
     OR position('''amenities''' in d) = 0 THEN
    RAISE EXCEPTION 'landing_bottura_rpc: falta una key del contrato tras el replace';
  END IF;
END $$;
