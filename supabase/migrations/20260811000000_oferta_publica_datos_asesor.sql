-- =============================================================================
-- Oferta pública: datos del asesor y montos autoritativos para `anon`
-- =============================================================================
-- La página pública de la oferta (https://ofertas.sozu.com/oferta/O-XXXXXX/<token>)
-- corre sin sesión, como `anon`. Hoy `get_oferta_financials(integer)` solo tiene
-- EXECUTE para authenticated/service_role, así que el .rpc() devuelve 403: la
-- tarjeta del asesor sale sin foto, sin frase y sin teléfono, y los montos del
-- plan caen al cálculo en TS (pueden no coincidir con los que ve el asesor).
--
-- Se abre la RPC, no la tabla `usuarios`: esa tabla tiene el directorio completo
-- del staff (emails, teléfonos, roles). La función es SECURITY DEFINER, STABLE y
-- solo lee; su llave `agente` expone únicamente los campos que ya se pintan en la
-- página pública.
--
-- Nota de enumeración: con este grant, `anon` puede pedir la oferta N y recibir
-- precios + contacto del asesor. Esa superficie ya existe por `ofertas`,
-- `propiedades`, `proyectos`, `esquemas_pago` y `modelos`, que tienen policies de
-- lectura para anon/public. El token de `reservaciones` sigue siendo la credencial
-- de lo que muta o cobra (get_apartado_status, update_lead_datos) y no cambia aquí.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §A. EXECUTE para anon sobre get_oferta_financials(integer)
-- -----------------------------------------------------------------------------

-- Self-verifying: si la firma no existe (o cambió), abortar en vez de dejar el
-- grant a medias y romper el CI silenciosamente.
DO $$
BEGIN
  IF to_regprocedure('public.get_oferta_financials(integer)') IS NULL THEN
    RAISE EXCEPTION
      'Anchor no encontrado: public.get_oferta_financials(integer) no existe; revisar la firma antes de otorgar EXECUTE a anon';
  END IF;

  IF NOT (SELECT p.prosecdef
          FROM pg_proc p
          WHERE p.oid = 'public.get_oferta_financials(integer)'::regprocedure) THEN
    RAISE EXCEPTION
      'public.get_oferta_financials(integer) dejó de ser SECURITY DEFINER; sin eso el grant a anon no sirve y expone RLS de usuarios';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_oferta_financials(integer) TO anon;

COMMENT ON FUNCTION public.get_oferta_financials(integer) IS
  'Desglose financiero autoritativo + datos de contacto del asesor de una oferta. '
  'SECURITY DEFINER: la usa la página pública de la oferta como anon, para no abrir '
  'la tabla usuarios (que tiene el directorio completo del staff).';

-- -----------------------------------------------------------------------------
-- §B. Plano del nivel visible en la oferta pública
-- -----------------------------------------------------------------------------
-- `edificios_niveles_planos` es material de marketing (imagen del nivel +
-- polígonos de las unidades), sin datos personales. Sin esta policy el plano con
-- la unidad resaltada no carga para el prospecto sin sesión.

DROP POLICY IF EXISTS "Public can view active edificios_niveles_planos"
  ON public.edificios_niveles_planos;

CREATE POLICY "Public can view active edificios_niveles_planos"
  ON public.edificios_niveles_planos
  FOR SELECT
  TO anon, authenticated
  USING (activo = true);

COMMIT;

-- =============================================================================
-- Validación (read-only, correr después del deploy)
-- =============================================================================
-- 1) El grant quedó → anon_exec = true
--    SELECT p.proname, p.prosecdef,
--           has_function_privilege('anon', p.oid, 'execute') AS anon_exec,
--           p.proacl::text
--    FROM pg_proc p
--    WHERE p.pronamespace = 'public'::regnamespace
--      AND p.proname = 'get_oferta_financials';
--
-- 2) `usuarios` NO se abrió a anon → solo la policy de rol 23
--    SELECT policyname, roles::text, cmd, qual
--    FROM pg_policies
--    WHERE schemaname = 'public' AND tablename = 'usuarios' AND cmd = 'SELECT';
--
-- 3) §B
--    SELECT policyname, roles::text, cmd, qual
--    FROM pg_policies
--    WHERE schemaname = 'public' AND tablename = 'edificios_niveles_planos';
--
-- UAT (transacción desechable, sustituir 3010 por una oferta real con foto):
--    BEGIN;
--      SET LOCAL ROLE anon;
--      SELECT jsonb_pretty(public.get_oferta_financials(3010) -> 'agente');
--      SELECT (public.get_oferta_financials(3010)) - 'planes' AS cabecera;
--      SELECT count(*) AS staff_visible_para_anon
--      FROM public.usuarios WHERE rol_id <> 23;   -- esperado: 0
--    ROLLBACK;
-- =============================================================================
