-- get_proyectos_publicados: proyectos publicados con modelos activos, multimedias,
-- edificios y propiedades anidadas.
--
-- NOTA: esta migración (version 20260608174557) se aplicó directamente en producción sin
-- commitearse al repo, rompiendo el deploy CI/CD con "Remote migration versions not found
-- in local migrations directory". Se recupera aquí (contenido exacto extraído de
-- supabase_migrations.schema_migrations en prod) para reconciliar el historial.

CREATE OR REPLACE FUNCTION public.get_proyectos_publicados()
 RETURNS json
 LANGUAGE sql
 STABLE
AS $function$
SELECT JSON_AGG(
  JSON_BUILD_OBJECT(
    'id', p.id,
    'nombre', p.nombre,
    'descripcion', p.descripcion,
    'direccion', p.direccion,
    'url_logo', p.url_logo,
    'url_imagen_portada', p.url_imagen_portada,
    'precio_m2_actual', p.precio_m2_actual,
    'fecha_lanzamiento_proyecto', p.fecha_lanzamiento_proyecto,
    'fecha_entrega', p.fecha_entrega,
    'latitud', p.latitud,
    'longitud', p.longitud,
    'activo', p.activo,
    'publicar', p.publicar,
    'id_estatus_proyecto', p.id_estatus_proyecto,
    'estatus_proyecto', (
      SELECT JSON_BUILD_OBJECT('nombre', ep.nombre)
      FROM estatus_proyecto ep
      WHERE ep.id = p.id_estatus_proyecto
    ),
    'multimedias_proyecto', (
      SELECT COALESCE(JSON_AGG(
        JSON_BUILD_OBJECT(
          'id', mp.id,
          'id_proyecto', mp.id_proyecto,
          'url', mp.url,
          'es_imagen', mp.es_imagen,
          'activo', mp.activo
        )
      ), '[]')
      FROM multimedias_proyecto mp
      WHERE mp.id_proyecto = p.id
    ),
    'modelos', (
      SELECT COALESCE(JSON_AGG(
        JSON_BUILD_OBJECT(
          'id', m.id,
          'nombre', m.nombre,
          'descripcion', m.descripcion,
          'numero_recamaras', m.numero_recamaras,
          'numero_completo_banos', m.numero_completo_banos,
          'numero_medio_bano', m.numero_medio_bano,
          'id_proyecto', m.id_proyecto,
          'activo', m.activo,
          'url_imagen_portada', COALESCE(
            (SELECT mm.url FROM multimedias_modelo mm
             WHERE mm.id_modelo = m.id
               AND mm.ver_como_imagen_de_propiedad = true
               AND mm.activo = true
             LIMIT 1),
            m.url_imagen_portada
          ),
          'plano_arquitectonico', COALESCE(
            (SELECT mm.url FROM multimedias_modelo mm
             WHERE mm.id_modelo = m.id
               AND mm.ver_como_ubicacion_en_oferta = true
               AND mm.activo = true
             LIMIT 1),
            m.plano_arquitectonico
          )
        )
      ), '[]')
      FROM modelos m
      WHERE m.id_proyecto = p.id AND m.activo = true
    ),
    'edificios', (
      SELECT COALESCE(JSON_AGG(
        JSON_BUILD_OBJECT(
          'id', e.id,
          'nombre', e.nombre,
          'activo', e.activo,
          'edificios_modelos', (
            SELECT COALESCE(JSON_AGG(
              JSON_BUILD_OBJECT(
                'id', em.id,
                'propiedades', (
                  SELECT COALESCE(JSON_AGG(
                    JSON_BUILD_OBJECT(
                      'id', prop.id,
                      'id_estatus_disponibilidad', prop.id_estatus_disponibilidad
                    )
                  ), '[]')
                  FROM propiedades prop
                  WHERE prop.id_edificio_modelo = em.id
                )
              )
            ), '[]')
            FROM edificios_modelos em
            WHERE em.id_edificio = e.id
          )
        )
      ), '[]')
      FROM edificios e
      WHERE e.id_proyecto = p.id AND e.activo = true
    )
  )
)
FROM proyectos p
WHERE p.publicar = true AND p.activo = true;
$function$
;
