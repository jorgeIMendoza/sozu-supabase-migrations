-- Seguridad · Socio Bancario — cerrar ESCRITURA anónima en las policies passthrough (Fase 2)
-- Fecha: 2026-07-27
--
-- Hallazgo CRÍTICO §2 de la auditoría: las policies `<t>_passthrough_no_socio` son
--   FOR ALL TO anon, authenticated  USING (current_socio_bancario_id() IS NULL)
-- Para anon, current_socio_bancario_id() = NULL → IS NULL = true → anon puede SELECT, INSERT,
-- UPDATE y DELETE sin sesión (p.ej. DELETE FROM cuentas_cobranza/propiedades). Se escribió para
-- EXCLUIR al socio y de paso abrió la tabla al mundo.
--
-- FIX (sobre el modelo M:N vivo): partir cada passthrough en dos:
--   · <t>_passthrough_select  FOR SELECT TO anon, authenticated  USING (csbid IS NULL)
--       → conserva la lectura de no-socios, incluida la del SITIO PÚBLICO (anon). El socio no
--         entra por aquí (csbid NOT NULL); su lectura scopeada sigue en <t>_socio_select.
--   · <t>_passthrough_write   FOR ALL   TO authenticated         USING/CHECK (csbid IS NULL)
--       → escritura solo para authenticated NO-socio. anon queda SIN policy de escritura → RLS
--         la niega. socio (csbid NOT NULL) tampoco escribe.
--
-- Alcance deliberado: solo cierra la ESCRITURA anónima (lo CRÍTICO). NO cambia la LECTURA anon
-- (requiere el allowlist del sitio público, §9/§10 — pendiente): cuentas_cobranza/compradores/
-- documentos siguen leíbles por anon hasta esa fase. No se tocan los grants de tabla (la
-- ausencia de policy de escritura para anon basta para negar bajo RLS).
--
-- Idempotente: DROP POLICY IF EXISTS + CREATE; ENABLE RLS no-op. Sin BEGIN/COMMIT.
-- Las <t>_socio_select (de 20260720010000) se conservan intactas.

-- ── proyectos ────────────────────────────────────────────────
ALTER TABLE public.proyectos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS proyectos_passthrough_no_socio ON public.proyectos;
DROP POLICY IF EXISTS proyectos_passthrough_select ON public.proyectos;
CREATE POLICY proyectos_passthrough_select ON public.proyectos
  FOR SELECT TO anon, authenticated USING (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS proyectos_passthrough_write ON public.proyectos;
CREATE POLICY proyectos_passthrough_write ON public.proyectos
  FOR ALL TO authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

-- ── edificios ────────────────────────────────────────────────
ALTER TABLE public.edificios ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS edificios_passthrough_no_socio ON public.edificios;
DROP POLICY IF EXISTS edificios_passthrough_select ON public.edificios;
CREATE POLICY edificios_passthrough_select ON public.edificios
  FOR SELECT TO anon, authenticated USING (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS edificios_passthrough_write ON public.edificios;
CREATE POLICY edificios_passthrough_write ON public.edificios
  FOR ALL TO authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

-- ── edificios_modelos ────────────────────────────────────────
ALTER TABLE public.edificios_modelos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS edificios_modelos_passthrough_no_socio ON public.edificios_modelos;
DROP POLICY IF EXISTS edificios_modelos_passthrough_select ON public.edificios_modelos;
CREATE POLICY edificios_modelos_passthrough_select ON public.edificios_modelos
  FOR SELECT TO anon, authenticated USING (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS edificios_modelos_passthrough_write ON public.edificios_modelos;
CREATE POLICY edificios_modelos_passthrough_write ON public.edificios_modelos
  FOR ALL TO authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

-- ── modelos ──────────────────────────────────────────────────
ALTER TABLE public.modelos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS modelos_passthrough_no_socio ON public.modelos;
DROP POLICY IF EXISTS modelos_passthrough_select ON public.modelos;
CREATE POLICY modelos_passthrough_select ON public.modelos
  FOR SELECT TO anon, authenticated USING (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS modelos_passthrough_write ON public.modelos;
CREATE POLICY modelos_passthrough_write ON public.modelos
  FOR ALL TO authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

-- ── propiedades ──────────────────────────────────────────────
ALTER TABLE public.propiedades ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS propiedades_passthrough_no_socio ON public.propiedades;
DROP POLICY IF EXISTS propiedades_passthrough_select ON public.propiedades;
CREATE POLICY propiedades_passthrough_select ON public.propiedades
  FOR SELECT TO anon, authenticated USING (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS propiedades_passthrough_write ON public.propiedades;
CREATE POLICY propiedades_passthrough_write ON public.propiedades
  FOR ALL TO authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

-- ── cuentas_cobranza ─────────────────────────────────────────
ALTER TABLE public.cuentas_cobranza ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cuentas_cobranza_passthrough_no_socio ON public.cuentas_cobranza;
DROP POLICY IF EXISTS cuentas_cobranza_passthrough_select ON public.cuentas_cobranza;
CREATE POLICY cuentas_cobranza_passthrough_select ON public.cuentas_cobranza
  FOR SELECT TO anon, authenticated USING (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS cuentas_cobranza_passthrough_write ON public.cuentas_cobranza;
CREATE POLICY cuentas_cobranza_passthrough_write ON public.cuentas_cobranza
  FOR ALL TO authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

-- ── ofertas ──────────────────────────────────────────────────
ALTER TABLE public.ofertas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ofertas_passthrough_no_socio ON public.ofertas;
DROP POLICY IF EXISTS ofertas_passthrough_select ON public.ofertas;
CREATE POLICY ofertas_passthrough_select ON public.ofertas
  FOR SELECT TO anon, authenticated USING (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS ofertas_passthrough_write ON public.ofertas;
CREATE POLICY ofertas_passthrough_write ON public.ofertas
  FOR ALL TO authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

-- ── productos_servicios ──────────────────────────────────────
ALTER TABLE public.productos_servicios ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS productos_servicios_passthrough_no_socio ON public.productos_servicios;
DROP POLICY IF EXISTS productos_servicios_passthrough_select ON public.productos_servicios;
CREATE POLICY productos_servicios_passthrough_select ON public.productos_servicios
  FOR SELECT TO anon, authenticated USING (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS productos_servicios_passthrough_write ON public.productos_servicios;
CREATE POLICY productos_servicios_passthrough_write ON public.productos_servicios
  FOR ALL TO authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

-- ── bodegas ──────────────────────────────────────────────────
ALTER TABLE public.bodegas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bodegas_passthrough_no_socio ON public.bodegas;
DROP POLICY IF EXISTS bodegas_passthrough_select ON public.bodegas;
CREATE POLICY bodegas_passthrough_select ON public.bodegas
  FOR SELECT TO anon, authenticated USING (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS bodegas_passthrough_write ON public.bodegas;
CREATE POLICY bodegas_passthrough_write ON public.bodegas
  FOR ALL TO authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

-- ── estacionamientos ─────────────────────────────────────────
ALTER TABLE public.estacionamientos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS estacionamientos_passthrough_no_socio ON public.estacionamientos;
DROP POLICY IF EXISTS estacionamientos_passthrough_select ON public.estacionamientos;
CREATE POLICY estacionamientos_passthrough_select ON public.estacionamientos
  FOR SELECT TO anon, authenticated USING (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS estacionamientos_passthrough_write ON public.estacionamientos;
CREATE POLICY estacionamientos_passthrough_write ON public.estacionamientos
  FOR ALL TO authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

-- ── videos_youtube ───────────────────────────────────────────
ALTER TABLE public.videos_youtube ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS videos_youtube_passthrough_no_socio ON public.videos_youtube;
DROP POLICY IF EXISTS videos_youtube_passthrough_select ON public.videos_youtube;
CREATE POLICY videos_youtube_passthrough_select ON public.videos_youtube
  FOR SELECT TO anon, authenticated USING (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS videos_youtube_passthrough_write ON public.videos_youtube;
CREATE POLICY videos_youtube_passthrough_write ON public.videos_youtube
  FOR ALL TO authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

-- ── multimedias_proyecto ─────────────────────────────────────
ALTER TABLE public.multimedias_proyecto ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS multimedias_proyecto_passthrough_no_socio ON public.multimedias_proyecto;
DROP POLICY IF EXISTS multimedias_proyecto_passthrough_select ON public.multimedias_proyecto;
CREATE POLICY multimedias_proyecto_passthrough_select ON public.multimedias_proyecto
  FOR SELECT TO anon, authenticated USING (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS multimedias_proyecto_passthrough_write ON public.multimedias_proyecto;
CREATE POLICY multimedias_proyecto_passthrough_write ON public.multimedias_proyecto
  FOR ALL TO authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

-- ── compradores ──────────────────────────────────────────────
ALTER TABLE public.compradores ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS compradores_passthrough_no_socio ON public.compradores;
DROP POLICY IF EXISTS compradores_passthrough_select ON public.compradores;
CREATE POLICY compradores_passthrough_select ON public.compradores
  FOR SELECT TO anon, authenticated USING (public.current_socio_bancario_id() IS NULL);
DROP POLICY IF EXISTS compradores_passthrough_write ON public.compradores;
CREATE POLICY compradores_passthrough_write ON public.compradores
  FOR ALL TO authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

-- ================================================================
-- documentos: quitar anon de INSERT/UPDATE (dejar solo authenticated).
--   SELECT se conserva (anon lo lee hoy; su scoping va con el allowlist §9/§10).
-- ================================================================
DROP POLICY IF EXISTS "Usuarios pueden insertar documentos" ON public.documentos;
CREATE POLICY "Usuarios pueden insertar documentos" ON public.documentos
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (public.current_socio_bancario_id() IS NULL);

DROP POLICY IF EXISTS "Usuarios pueden actualizar documentos" ON public.documentos;
CREATE POLICY "Usuarios pueden actualizar documentos" ON public.documentos
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (public.current_socio_bancario_id() IS NULL)
  WITH CHECK (public.current_socio_bancario_id() IS NULL);
