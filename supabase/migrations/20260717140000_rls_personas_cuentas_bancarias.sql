-- RLS en personas + cuentas_bancarias — edición restringida a dueño / visor / agente dueño
-- ---------------------------------------------------------------------------------
-- Regla de negocio: modificar una persona (y su cuenta bancaria) solo puede:
--   1. El dueño (usuarios.id_persona = persona), o
--   2. Roles con acceso al visor (roles.puede_impersonar = true), o
--   3. El agente dueño del prospecto (entidades_relacionadas activa:
--      id_persona = persona, id_persona_duena_lead = persona del agente).
--
-- Hoy (verificado prod 2026-07-17): personas y cuentas_bancarias con RLS OFF.
-- personas TIENE una policy inerte "Allow all access to personas" (FOR ALL a public
-- USING true) que DEBE eliminarse: al activar RLS las policies son permisivas (OR),
-- y "Allow all" anularía toda restricción. cuentas_bancarias no tiene policies previas.
--
-- Decisiones (confirmadas con el usuario):
--  - personas SELECT abierto a anon + authenticated: la oferta digital pública lee
--    personas (desarrolladora/dueño, footer con url_sitio_web) sin login (anon key).
--  - cuentas_bancarias lectura RESTRINGIDA a dueño/visor (PII financiera): FOR ALL
--    cubre select+insert+update+delete con la misma condición.
--
-- Las Edge Functions usan service_role → omiten RLS (no se afectan).
-- personas: no se crea policy DELETE => con RLS on el DELETE físico queda denegado a
--   authenticated (hoy se permitía). PROBAR EN DEV si algún flujo borra personas.
-- Idempotente: CREATE OR REPLACE, ENABLE RLS (no-op si ya on), DROP POLICY IF EXISTS
--   antes de cada CREATE POLICY.
--
-- REVISAR/PROBAR EN DEV ANTES DE PROD: alta de prospecto, edición de prospecto,
-- perfil de agente (identidad/fiscal), alta de comprador, y la VISTA PÚBLICA de una
-- oferta (footer/desarrolladora) con anon.

-- ---------------------------------------------------------------------------------
-- Helpers (SECURITY DEFINER para leer usuarios/roles sin recursión de RLS)
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.current_persona_id()
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id_persona FROM public.usuarios WHERE auth_user_id = auth.uid() LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.current_puede_impersonar()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((
    SELECT r.puede_impersonar FROM public.usuarios u
    JOIN public.roles r ON r.id = u.rol_id
    WHERE u.auth_user_id = auth.uid() LIMIT 1
  ), false);
$$;

GRANT EXECUTE ON FUNCTION public.current_persona_id()      TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.current_puede_impersonar() TO anon, authenticated;

-- ---------------------------------------------------------------------------------
-- personas
-- ---------------------------------------------------------------------------------
ALTER TABLE public.personas ENABLE ROW LEVEL SECURITY;

-- CRÍTICO: eliminar la policy permisiva heredada; si no, RLS queda como no-op.
DROP POLICY IF EXISTS "Allow all access to personas" ON public.personas;

-- Lectura: abierta (incluye anon: oferta digital pública).
DROP POLICY IF EXISTS personas_select ON public.personas;
CREATE POLICY personas_select ON public.personas
  FOR SELECT TO anon, authenticated USING (true);

-- Alta: autenticados (agentes crean prospectos, admins crean personas).
DROP POLICY IF EXISTS personas_insert ON public.personas;
CREATE POLICY personas_insert ON public.personas
  FOR INSERT TO authenticated WITH CHECK (true);

-- Edición: dueño, o rol con visor, o agente dueño del prospecto.
DROP POLICY IF EXISTS personas_update ON public.personas;
CREATE POLICY personas_update ON public.personas
  FOR UPDATE TO authenticated
  USING (
    id = public.current_persona_id()
    OR public.current_puede_impersonar()
    OR EXISTS (
      SELECT 1 FROM public.entidades_relacionadas er
      WHERE er.id_persona = personas.id
        AND er.activo = true
        AND er.id_persona_duena_lead = public.current_persona_id()
    )
  )
  WITH CHECK (
    id = public.current_persona_id()
    OR public.current_puede_impersonar()
    OR EXISTS (
      SELECT 1 FROM public.entidades_relacionadas er
      WHERE er.id_persona = personas.id
        AND er.activo = true
        AND er.id_persona_duena_lead = public.current_persona_id()
    )
  );

-- ---------------------------------------------------------------------------------
-- cuentas_bancarias (lectura y escritura: dueño o rol con visor)
-- ---------------------------------------------------------------------------------
ALTER TABLE public.cuentas_bancarias ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cuentas_bancarias_all ON public.cuentas_bancarias;
CREATE POLICY cuentas_bancarias_all ON public.cuentas_bancarias
  FOR ALL TO authenticated
  USING ( id_persona = public.current_persona_id() OR public.current_puede_impersonar() )
  WITH CHECK ( id_persona = public.current_persona_id() OR public.current_puede_impersonar() );
