-- Fix: restaurar lectura por ROL de ver_filtros_avanzados_eliminados en get_current_user_profile
--
-- Contexto: la migración 20260527000006_fix_usuarios_columnas_y_get_current_user_profile
-- (que arreglaba el error de login "column u.id_notario does not exist") agregó de paso la
-- columna usuarios.ver_filtros_avanzados_eliminados (NOT NULL DEFAULT false) y cambió la
-- función para leer ese flag desde usuarios (u.) en vez de roles (r.).
--
-- Esa columna en usuarios quedó con default false y nunca se pobló -> los 1633 usuarios
-- activos la tienen en false. El permiso se administra por ROL (UI RolesPermisos ->
-- roles.ver_filtros_avanzados_eliminados) y todo el frontend asume per-rol. Resultado:
-- filtros avanzados y pestaña "Eliminados" en /admin/propiedades quedaron ocultos para todos
-- los roles excepto Super Administrador (que se salva por el `isSuperAdmin ||` en el frontend).
--
-- Fix: la función vuelve a leer desde roles (r.) con COALESCE(...,true) como respaldo,
-- conservando el resto de la definición (campos notario/jurídico, joins, filtro auth.email()).
-- Único cambio respecto a 20260527000006: la línea de ver_filtros_avanzados_eliminados.
--
-- La columna usuarios.ver_filtros_avanzados_eliminados queda huérfana (sin lector). Limpieza
-- opcional posterior, fuera de alcance de esta migración:
--   ALTER TABLE public.usuarios DROP COLUMN ver_filtros_avanzados_eliminados;

CREATE OR REPLACE FUNCTION public.get_current_user_profile()
RETURNS TABLE(
  email                           TEXT,
  nombre                          TEXT,
  rol_id                          INTEGER,
  rol_nombre                      TEXT,
  debe_cambiar_password           BOOLEAN,
  id_persona                      INTEGER,
  activo                          BOOLEAN,
  ver_todos_prospectos_compradores BOOLEAN,
  ver_filtros_avanzados_eliminados BOOLEAN,
  id_notario                      INTEGER,
  notaria_nombre                  TEXT,
  id_perfil_juridico              BIGINT,
  perfil_juridico_nombre          TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    u.email::TEXT,
    u.nombre::TEXT,
    u.rol_id::INTEGER,
    r.nombre::TEXT                           AS rol_nombre,
    u.debe_cambiar_password::BOOLEAN,
    u.id_persona::INTEGER,
    u.activo::BOOLEAN,
    u.ver_todos_prospectos_compradores::BOOLEAN,
    COALESCE(r.ver_filtros_avanzados_eliminados, true)::BOOLEAN AS ver_filtros_avanzados_eliminados,
    u.id_notario::INTEGER,
    n.notaria::TEXT                          AS notaria_nombre,
    j.id::BIGINT                             AS id_perfil_juridico,
    j.nombre_completo::TEXT                  AS perfil_juridico_nombre
  FROM public.usuarios u
  JOIN  public.roles    r ON r.id  = u.rol_id
  LEFT JOIN public.notarios n
         ON n.id     = u.id_notario
        AND n.activo = TRUE
  LEFT JOIN public.perfiles_juridicos j
         ON j.email  = u.email
        AND j.activo = TRUE
  WHERE u.email  = auth.email()
    AND u.activo = TRUE
  LIMIT 1;
END;
$$;
