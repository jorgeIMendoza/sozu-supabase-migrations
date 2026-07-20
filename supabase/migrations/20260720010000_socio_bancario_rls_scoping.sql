-- Socios Bancarios · RLS de scoping por desarrollo en las tablas del portal
-- Fecha: 2026-07-20
--
-- Frontera server-side del Portal Socio Bancario (modelo M:N). Depende de
-- 20260720000000_socio_bancario_modelo_mn.sql (tablas + helpers current_socio_bancario_id()
-- y socio_desarrollos_activos()).
--
-- PATRÓN por tabla (permisivo, OR):
--   · passthrough  FOR ALL a anon+authenticated  USING/CHECK current_socio_bancario_id() IS NULL
--       → todo el que NO es socio (incluye anon de la oferta pública y todos los roles
--         internos) conserva EXACTAMENTE el acceso que tenía con RLS off (lectura y escritura).
--   · socio_select FOR SELECT a authenticated  USING <proyecto de la fila> ∈ socio_desarrollos_activos()
--       → el socio bancario solo LEE filas de sus desarrollos activos; no puede escribir
--         (ninguna política de escritura aplica cuando current_socio_bancario_id() no es NULL).
--
-- ⚠️ ALTO IMPACTO: activa RLS en tablas núcleo (inventario/ventas) que hoy están en RLS off.
--    El passthrough preserva el comportamiento de no-socios, pero DEBE probarse en DEV antes
--    de prod: (a) oferta pública con anon, (b) escritura de admin/agente sobre propiedades/
--    cuentas/ofertas/documentos, (c) login como socio → solo ve su desarrollo, 0 filas ajenas.
--    Las Edge Functions usan service_role → omiten RLS (no se afectan).
--
-- COBERTURA:
--    · 13 tablas en RLS off → patrón passthrough + socio_select (activa RLS).
--    · documentos → YA tenía RLS con policies USING(true); se REESCRIBEN sus 4 policies
--      base para restringir al socio (no un passthrough, que no restringiría).
-- DIFERIDAS a propósito (ya tienen RLS y requieren reescritura bespoke + prueba en dev):
--    · personas, cuentas_bancarias (RLS de 20260717140000; el patrón permisivo aflojaría
--      sus restricciones de escritura).
--    · entidades_relacionadas (policy SELECT compleja de baseline_rls; ver bloque abajo).
--    Hasta que se hagan, el socio ve esas 3 como cualquier authenticated (scoping app-level).
--
-- Idempotente: ENABLE RLS (no-op si ya on), DROP POLICY IF EXISTS + CREATE, CREATE OR REPLACE.
-- Sin BEGIN/COMMIT (CI/CD envuelve en tx).

-- ================================================================
-- Helpers de pertenencia a los desarrollos del socio
-- ================================================================
CREATE OR REPLACE FUNCTION public.socio_tiene_proyecto(p_id_proyecto integer)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p_id_proyecto IN (SELECT public.socio_desarrollos_activos());
$$;

CREATE OR REPLACE FUNCTION public.socio_tiene_edificio(p_id_edificio integer)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.edificios e
    WHERE e.id = p_id_edificio
      AND e.id_proyecto IN (SELECT public.socio_desarrollos_activos())
  );
$$;

-- p_id_propiedad es bigint: propiedades.id es bigint. Los id_propiedad integer de otras
-- tablas (cuentas_cobranza, ofertas, bodegas, estacionamientos) suben por cast implícito.
-- DROP de la firma integer previa (si algún ambiente la creó) para no dejar overload duplicado.
DROP FUNCTION IF EXISTS public.socio_tiene_propiedad(integer);
CREATE OR REPLACE FUNCTION public.socio_tiene_propiedad(p_id_propiedad bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.propiedades p
    JOIN public.edificios_modelos em ON em.id = p.id_edificio_modelo
    JOIN public.edificios e          ON e.id  = em.id_edificio
    WHERE p.id = p_id_propiedad
      AND e.id_proyecto IN (SELECT public.socio_desarrollos_activos())
  );
$$;

CREATE OR REPLACE FUNCTION public.socio_tiene_cuenta(p_id_cuenta bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.cuentas_cobranza c
    WHERE c.id = p_id_cuenta
      AND public.socio_tiene_propiedad(c.id_propiedad)
  );
$$;

GRANT EXECUTE ON FUNCTION public.socio_tiene_proyecto(integer)  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.socio_tiene_edificio(integer)  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.socio_tiene_propiedad(bigint)  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.socio_tiene_cuenta(bigint)     TO anon, authenticated;

-- ================================================================
-- proyectos (id directo)
-- ================================================================
ALTER TABLE public.proyectos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS proyectos_passthrough_no_socio ON public.proyectos;
CREATE POLICY proyectos_passthrough_no_socio ON public.proyectos
  FOR ALL TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS proyectos_socio_select ON public.proyectos;
CREATE POLICY proyectos_socio_select ON public.proyectos
  FOR SELECT TO authenticated
  USING (public.socio_tiene_proyecto(id));

-- ================================================================
-- edificios (id_proyecto)
-- ================================================================
ALTER TABLE public.edificios ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS edificios_passthrough_no_socio ON public.edificios;
CREATE POLICY edificios_passthrough_no_socio ON public.edificios
  FOR ALL TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS edificios_socio_select ON public.edificios;
CREATE POLICY edificios_socio_select ON public.edificios
  FOR SELECT TO authenticated
  USING (public.socio_tiene_proyecto(id_proyecto));

-- ================================================================
-- edificios_modelos (id_edificio → edificios.id_proyecto)
-- ================================================================
ALTER TABLE public.edificios_modelos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS edificios_modelos_passthrough_no_socio ON public.edificios_modelos;
CREATE POLICY edificios_modelos_passthrough_no_socio ON public.edificios_modelos
  FOR ALL TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS edificios_modelos_socio_select ON public.edificios_modelos;
CREATE POLICY edificios_modelos_socio_select ON public.edificios_modelos
  FOR SELECT TO authenticated
  USING (public.socio_tiene_edificio(id_edificio));

-- ================================================================
-- modelos (id_proyecto directo)
-- ================================================================
ALTER TABLE public.modelos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS modelos_passthrough_no_socio ON public.modelos;
CREATE POLICY modelos_passthrough_no_socio ON public.modelos
  FOR ALL TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS modelos_socio_select ON public.modelos;
CREATE POLICY modelos_socio_select ON public.modelos
  FOR SELECT TO authenticated
  USING (public.socio_tiene_proyecto(id_proyecto));

-- ================================================================
-- propiedades (id_edificio_modelo → edificios_modelos → edificios.id_proyecto)
-- ================================================================
ALTER TABLE public.propiedades ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS propiedades_passthrough_no_socio ON public.propiedades;
CREATE POLICY propiedades_passthrough_no_socio ON public.propiedades
  FOR ALL TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS propiedades_socio_select ON public.propiedades;
CREATE POLICY propiedades_socio_select ON public.propiedades
  FOR SELECT TO authenticated
  USING (public.socio_tiene_propiedad(id));

-- ================================================================
-- cuentas_cobranza (id_propiedad → propiedad)
-- ================================================================
ALTER TABLE public.cuentas_cobranza ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cuentas_cobranza_passthrough_no_socio ON public.cuentas_cobranza;
CREATE POLICY cuentas_cobranza_passthrough_no_socio ON public.cuentas_cobranza
  FOR ALL TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS cuentas_cobranza_socio_select ON public.cuentas_cobranza;
CREATE POLICY cuentas_cobranza_socio_select ON public.cuentas_cobranza
  FOR SELECT TO authenticated
  USING (public.socio_tiene_propiedad(id_propiedad));

-- ================================================================
-- ofertas (id_propiedad → propiedad)
-- ================================================================
ALTER TABLE public.ofertas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ofertas_passthrough_no_socio ON public.ofertas;
CREATE POLICY ofertas_passthrough_no_socio ON public.ofertas
  FOR ALL TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS ofertas_socio_select ON public.ofertas;
CREATE POLICY ofertas_socio_select ON public.ofertas
  FOR SELECT TO authenticated
  USING (public.socio_tiene_propiedad(id_propiedad));

-- ================================================================
-- documentos (id_proyecto directo)
--   YA tenía RLS on con policies permisivas USING(true) (baseline_rls 20260513000003).
--   Un passthrough adicional NO restringiría al socio (OR con true = ve todo), así que se
--   REESCRIBEN las 4 policies base: no-socios conservan USING(true); el socio queda
--   restringido a su desarrollo en SELECT y bloqueado en escritura.
-- ================================================================
-- (RLS ya está habilitado; no se re-habilita)
DROP POLICY IF EXISTS "Usuarios pueden ver documentos" ON public.documentos;
CREATE POLICY "Usuarios pueden ver documentos" ON public.documentos
  AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL OR public.socio_tiene_proyecto(id_proyecto));

DROP POLICY IF EXISTS "Usuarios pueden insertar documentos" ON public.documentos;
CREATE POLICY "Usuarios pueden insertar documentos" ON public.documentos
  AS PERMISSIVE FOR INSERT TO anon, authenticated
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

DROP POLICY IF EXISTS "Usuarios pueden actualizar documentos" ON public.documentos;
CREATE POLICY "Usuarios pueden actualizar documentos" ON public.documentos
  AS PERMISSIVE FOR UPDATE TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

DROP POLICY IF EXISTS "Usuarios autenticados pueden eliminar documentos" ON public.documentos;
CREATE POLICY "Usuarios autenticados pueden eliminar documentos" ON public.documentos
  AS PERMISSIVE FOR DELETE TO authenticated
  USING (public.current_socio_bancario_id() IS NULL);

-- ================================================================
-- productos_servicios (id_proyecto directo)
-- ================================================================
ALTER TABLE public.productos_servicios ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS productos_servicios_passthrough_no_socio ON public.productos_servicios;
CREATE POLICY productos_servicios_passthrough_no_socio ON public.productos_servicios
  FOR ALL TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS productos_servicios_socio_select ON public.productos_servicios;
CREATE POLICY productos_servicios_socio_select ON public.productos_servicios
  FOR SELECT TO authenticated
  USING (public.socio_tiene_proyecto(id_proyecto));

-- ================================================================
-- bodegas (id_propiedad → propiedad)
-- ================================================================
ALTER TABLE public.bodegas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bodegas_passthrough_no_socio ON public.bodegas;
CREATE POLICY bodegas_passthrough_no_socio ON public.bodegas
  FOR ALL TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS bodegas_socio_select ON public.bodegas;
CREATE POLICY bodegas_socio_select ON public.bodegas
  FOR SELECT TO authenticated
  USING (public.socio_tiene_propiedad(id_propiedad));

-- ================================================================
-- estacionamientos (id_propiedad → propiedad)
-- ================================================================
ALTER TABLE public.estacionamientos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS estacionamientos_passthrough_no_socio ON public.estacionamientos;
CREATE POLICY estacionamientos_passthrough_no_socio ON public.estacionamientos
  FOR ALL TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS estacionamientos_socio_select ON public.estacionamientos;
CREATE POLICY estacionamientos_socio_select ON public.estacionamientos
  FOR SELECT TO authenticated
  USING (public.socio_tiene_propiedad(id_propiedad));

-- ================================================================
-- videos_youtube (id_proyecto directo)
-- ================================================================
ALTER TABLE public.videos_youtube ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS videos_youtube_passthrough_no_socio ON public.videos_youtube;
CREATE POLICY videos_youtube_passthrough_no_socio ON public.videos_youtube
  FOR ALL TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS videos_youtube_socio_select ON public.videos_youtube;
CREATE POLICY videos_youtube_socio_select ON public.videos_youtube
  FOR SELECT TO authenticated
  USING (public.socio_tiene_proyecto(id_proyecto));

-- ================================================================
-- multimedias_proyecto (id_proyecto directo)
-- ================================================================
ALTER TABLE public.multimedias_proyecto ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS multimedias_proyecto_passthrough_no_socio ON public.multimedias_proyecto;
CREATE POLICY multimedias_proyecto_passthrough_no_socio ON public.multimedias_proyecto
  FOR ALL TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS multimedias_proyecto_socio_select ON public.multimedias_proyecto;
CREATE POLICY multimedias_proyecto_socio_select ON public.multimedias_proyecto
  FOR SELECT TO authenticated
  USING (public.socio_tiene_proyecto(id_proyecto));

-- ================================================================
-- entidades_relacionadas — DIFERIDA a propósito.
--   YA tiene RLS on con una policy SELECT compleja (baseline_rls: is_admin_user() OR
--   can_view_all_prospects() OR id_tipo_entidad NOT IN (2,7) OR agente-dueño-del-lead).
--   Para un socio, la rama "id_tipo_entidad NOT IN (2,7)" le dejaría ver entidades de
--   TODOS los proyectos. Restringirlo exige reescribir esa policy exacta y probarla;
--   se hace en migración aparte para no romper prospectos/agentes. Hasta entonces el
--   socio ve entidades_relacionadas como cualquier authenticated (scoping app-level).
-- ================================================================

-- ================================================================
-- compradores (id_cuenta_cobranza → cuenta → propiedad)
-- ================================================================
ALTER TABLE public.compradores ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS compradores_passthrough_no_socio ON public.compradores;
CREATE POLICY compradores_passthrough_no_socio ON public.compradores
  FOR ALL TO anon, authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS compradores_socio_select ON public.compradores;
CREATE POLICY compradores_socio_select ON public.compradores
  FOR SELECT TO authenticated
  USING (public.socio_tiene_cuenta(id_cuenta_cobranza));
