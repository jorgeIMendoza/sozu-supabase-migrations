-- Portal Bancos: usuarios vinculados a un banco
--
-- 1. Columna usuarios.id_banco (FK a bancos) para usuarios con rol
--    "Supervisor Banco" u "Operador Banco".
-- 2. Seed idempotente de ambos roles (por nombre; roles.id es IDENTITY ALWAYS,
--    nunca se fija manualmente).
-- 3. get_current_user_profile devuelve id_banco y banco_nombre para que el
--    Portal Bancos haga scope por el banco del usuario.

-- ── 1. Columna id_banco ──────────────────────────────────────────────────────
ALTER TABLE public.usuarios
  ADD COLUMN IF NOT EXISTS id_banco integer REFERENCES public.bancos(id);

COMMENT ON COLUMN public.usuarios.id_banco IS
  'Banco al que pertenece el usuario (roles Supervisor Banco / Operador Banco)';

-- ── 2. Roles Supervisor Banco / Operador Banco ───────────────────────────────
INSERT INTO public.roles (nombre, es_rol_interno, activo)
SELECT v.nombre, true, true
FROM (VALUES ('Supervisor Banco'), ('Operador Banco')) AS v(nombre)
WHERE NOT EXISTS (
  SELECT 1 FROM public.roles r WHERE r.nombre = v.nombre
);

-- ── 3. get_current_user_profile con id_banco / banco_nombre ─────────────────
-- Cambia la firma de retorno (columnas nuevas al final) → requiere DROP previo.
DROP FUNCTION IF EXISTS public.get_current_user_profile();

CREATE FUNCTION public.get_current_user_profile()
 RETURNS TABLE(
   email text,
   nombre text,
   rol_id integer,
   rol_nombre text,
   debe_cambiar_password boolean,
   id_persona integer,
   activo boolean,
   ver_todos_prospectos_compradores boolean,
   ver_filtros_avanzados_eliminados boolean,
   id_notario integer,
   notaria_nombre text,
   id_perfil_juridico bigint,
   perfil_juridico_nombre text,
   puede_impersonar boolean,
   administrar_app_clientes boolean,
   id_banco integer,
   banco_nombre text
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
    -- Flag EFECTIVO: usuario OR rol, espejo de can_view_all_prospects() (que lee el flag del rol).
    (COALESCE(u.ver_todos_prospectos_compradores, false)
       OR COALESCE(r.ver_todos_prospectos_compradores, false))::BOOLEAN
                                             AS ver_todos_prospectos_compradores,
    COALESCE(r.ver_filtros_avanzados_eliminados, true)::BOOLEAN AS ver_filtros_avanzados_eliminados,
    u.id_notario::INTEGER,
    n.notaria::TEXT                          AS notaria_nombre,
    j.id::BIGINT                             AS id_perfil_juridico,
    j.nombre_completo::TEXT                  AS perfil_juridico_nombre,
    COALESCE(r.puede_impersonar, false)::BOOLEAN AS puede_impersonar,
    COALESCE(r.administrar_app_clientes, false)::BOOLEAN AS administrar_app_clientes,
    u.id_banco::INTEGER,
    b.nombre::TEXT                           AS banco_nombre
  FROM public.usuarios u
  JOIN  public.roles    r ON r.id  = u.rol_id
  LEFT JOIN public.notarios n
         ON n.id     = u.id_notario
        AND n.activo = TRUE
  LEFT JOIN public.perfiles_juridicos j
         ON j.email  = u.email
        AND j.activo = TRUE
  LEFT JOIN public.bancos b
         ON b.id     = u.id_banco
  WHERE u.email  = auth.email()
    AND u.activo = TRUE
  LIMIT 1;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_current_user_profile() TO anon, authenticated, service_role;
