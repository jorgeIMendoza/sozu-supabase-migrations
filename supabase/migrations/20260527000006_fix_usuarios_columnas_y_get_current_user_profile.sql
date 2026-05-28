-- Fix: columnas faltantes en usuarios + get_current_user_profile
-- Contexto: la función get_current_user_profile fallaba al hacer login con
--   "column u.id_notario does not exist"
-- porque la tabla usuarios carecía de 3 columnas que la función referenciaba.
-- Esta migración las agrega y recrea la función usando las columnas reales.
-- Requisito: public.notarios debe existir.

-- ════════════════════════════════════════════════════════════════════════════
--  PASO 1: Agregar columnas faltantes a public.usuarios
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.usuarios
  ADD COLUMN IF NOT EXISTS ver_todos_prospectos_compradores BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS ver_filtros_avanzados_eliminados BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS id_notario                       INTEGER REFERENCES public.notarios(id);


-- ════════════════════════════════════════════════════════════════════════════
--  PASO 2: Recrear get_current_user_profile usando las columnas reales
-- ════════════════════════════════════════════════════════════════════════════
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
    u.ver_filtros_avanzados_eliminados::BOOLEAN,
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
