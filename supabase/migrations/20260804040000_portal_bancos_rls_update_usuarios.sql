-- Portal Bancos → Equipo: permitir que un Supervisor Banco administre a los
-- ejecutivos de SU banco.
--
-- Problema: `public.usuarios` solo tiene políticas de UPDATE para Super Admin
-- ("Super admins can update users"), para dueños de inmobiliaria y para el propio
-- registro ("Users can update own record"). Un Supervisor Banco que desactivaba,
-- reactivaba, renombraba o cambiaba el rol de un ejecutivo desde
-- /admin/portal-bancos/equipo hacía un UPDATE que RLS filtraba: 0 filas afectadas
-- y NINGÚN error, así que la UI mostraba "Ejecutivo desactivado" mientras la fila
-- seguía intacta y el ejecutivo permanecía en el listado.
--
-- Solución: política de UPDATE acotada al banco del supervisor. Los ids de los
-- roles de banco difieren entre ambientes, así que se detectan por NOMBRE (mismo
-- criterio que useBancoRoles / portalHostAccess / create-user).
--
-- Las funciones auxiliares son SECURITY DEFINER a propósito: una política sobre
-- `usuarios` que consultara `usuarios` directamente entraría en recursión de RLS.

-- ── 1. Banco del supervisor autenticado ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.current_user_supervised_bank()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT u.id_banco
  FROM public.usuarios u
  JOIN public.roles r ON r.id = u.rol_id
  WHERE u.auth_user_id = auth.uid()
    AND u.activo = true
    AND u.id_banco IS NOT NULL
    AND lower(btrim(r.nombre)) LIKE 'supervisor banco%'
  LIMIT 1;
$function$;

COMMENT ON FUNCTION public.current_user_supervised_bank() IS
  'id_banco del usuario autenticado si su rol es Supervisor Banco; NULL en cualquier otro caso. Usada por la política de UPDATE de usuarios del Portal Bancos.';

REVOKE ALL ON FUNCTION public.current_user_supervised_bank() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_supervised_bank() TO authenticated, service_role;

-- ── 2. ¿El rol es de banco? ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.is_rol_de_banco(p_rol_id integer)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.roles r
    WHERE r.id = p_rol_id
      AND (
        lower(btrim(r.nombre)) LIKE 'supervisor banco%'
        OR lower(btrim(r.nombre)) LIKE 'operador banco%'
      )
  );
$function$;

COMMENT ON FUNCTION public.is_rol_de_banco(integer) IS
  'true si el rol indicado es Supervisor Banco u Operador Banco (detección por nombre: los ids difieren entre ambientes).';

REVOKE ALL ON FUNCTION public.is_rol_de_banco(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_rol_de_banco(integer) TO authenticated, service_role;

-- ── 3. Política de UPDATE ────────────────────────────────────────────────────
-- Acotada por tres lados:
--   · solo filas del MISMO banco que supervisa quien ejecuta;
--   · solo filas cuyo rol es de banco (no puede tocar administradores internos);
--   · nunca su propia fila — para eso ya existe "Users can update own record",
--     y así un supervisor no se desactiva a sí mismo por esta vía.
-- El WITH CHECK repite las condiciones sobre la fila RESULTANTE, de modo que no
-- pueda mover un ejecutivo a otro banco ni escalarlo a un rol que no sea de banco.
DROP POLICY IF EXISTS "Bank supervisors can update own bank users" ON public.usuarios;
CREATE POLICY "Bank supervisors can update own bank users" ON public.usuarios
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (
    id_banco IS NOT NULL
    AND id_banco = public.current_user_supervised_bank()
    AND public.is_rol_de_banco(rol_id)
    AND auth_user_id IS DISTINCT FROM auth.uid()
  )
  WITH CHECK (
    id_banco IS NOT NULL
    AND id_banco = public.current_user_supervised_bank()
    AND public.is_rol_de_banco(rol_id)
    AND auth_user_id IS DISTINCT FROM auth.uid()
  );
