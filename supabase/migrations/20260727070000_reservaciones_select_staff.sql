-- =============================================================================
-- reservaciones — política de SELECT para el personal del panel
--
-- Corrige el efecto secundario de 20260727050000, que eliminó
-- public_read_by_id (la única política de SELECT de la tabla).
--
-- Con RLS activa, Postgres exige política de SELECT para devolver la fila de un
-- INSERT ... RETURNING, que es como PostgREST inserta. Sin ella, generar una
-- oferta digital desde el panel falla con:
--   42501 new row violates row-level security policy for table "reservaciones"
-- aunque el WITH CHECK de auth_insert (auth.role() = 'authenticated') se cumpla.
-- El panel necesita el RETURNING: sin el token no puede armar el link del cliente.
--
-- Verificado read-only contra prod (2026-07-27):
--   · usuarios tiene auth_user_id, rol_id, activo.
--   · roles.id = 23 → 'Cliente' (620 usuarios activos);
--     roles.id = 36 → 'Socio Bancario'.
--   · La subconsulta a usuarios no necesita helper SECURITY DEFINER: usuarios
--     tiene la política "Users can view own record" (auth_user_id = auth.uid()),
--     así que el propio renglón es visible y no hay recursión de RLS.
--   · Quien genera ofertas digitales (últimos 90 días) son los roles
--     3 Agente Inmobiliario, 1 Super Administrador, 30 Admin Soporte,
--     2 Administrador de Proyecto, 12 Administrador de cobranza,
--     9 Agente Interno y 7 Administrador de finanzas/legal: todos pasan.
--
-- Se excluye 36 Socio Bancario además de 23 Cliente (el spec solo excluía 23):
-- es el rol al que la serie de seguridad de 20260727020000 le está cerrando el
-- acceso, y no tiene nada que hacer leyendo tokens de clientes. Hoy tiene 0
-- usuarios activos, así que no rompe a nadie.
--
-- No se usa user_has_internal_role(auth.uid()) aunque sería lo idiomático:
-- es_rol_interno = false solo en 19 Directores, 23 Cliente y 36 Socio Bancario,
-- así que bloquearía al rol 19 sin motivo.
--
-- anon no gana nada: sigue sin privilegios de tabla (los revocó 20260727050000)
-- y el flujo público va por las funciones SECURITY DEFINER
-- (get_apartado_status, update_lead_datos, get_reservacion_publica,
-- guardar_datos_reservacion).
--
-- Idempotente: DROP POLICY IF EXISTS + CREATE.
-- =============================================================================

DROP POLICY IF EXISTS reservaciones_select_staff ON public.reservaciones;

CREATE POLICY reservaciones_select_staff
  ON public.reservaciones
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid()
        AND u.activo = true
        AND u.rol_id NOT IN (23, 36)   -- 23 = Cliente, 36 = Socio Bancario
    )
  );

COMMENT ON POLICY reservaciones_select_staff ON public.reservaciones IS
  'Lectura de reservaciones para el personal del panel (agentes, admins). '
  'Necesaria además para que INSERT ... RETURNING devuelva el token al generar '
  'la oferta digital. Excluye Cliente (23) y Socio Bancario (36). anon no tiene '
  'acceso: el flujo público va por las funciones SECURITY DEFINER '
  '(get_apartado_status, update_lead_datos, get_reservacion_publica, '
  'guardar_datos_reservacion).';

-- -----------------------------------------------------------------------------
-- Self-verifying: aborta el CI si la política no quedó como se espera.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  -- La política existe, es de SELECT y aplica solo a authenticated.
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'reservaciones'
      AND policyname = 'reservaciones_select_staff'
      AND cmd = 'SELECT'
      AND roles::text = '{authenticated}'
  ) THEN
    RAISE EXCEPTION 'Falta la política reservaciones_select_staff (SELECT, authenticated)';
  END IF;

  -- No reaparecieron las políticas públicas que cerró 20260727050000.
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'reservaciones'
      AND policyname IN ('public_read_by_id', 'update_solo_pendiente')
  ) THEN
    RAISE EXCEPTION 'Siguen existiendo políticas públicas en reservaciones';
  END IF;

  -- anon sigue sin privilegios de tabla.
  IF has_table_privilege('anon', 'public.reservaciones', 'SELECT')
     OR has_table_privilege('anon', 'public.reservaciones', 'INSERT')
     OR has_table_privilege('anon', 'public.reservaciones', 'UPDATE')
     OR has_table_privilege('anon', 'public.reservaciones', 'DELETE') THEN
    RAISE EXCEPTION 'anon recuperó privilegios sobre reservaciones';
  END IF;
END
$$;
