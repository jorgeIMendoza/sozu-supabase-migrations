-- Portal Jurídico Fase 1 · RLS INSERT/UPDATE en audiencias y acuerdos
-- Fecha: 2026-07-17
--
-- Formaliza DDL-1 (Ejecuciones/ejecutar.md). Hoy ambas tablas solo tienen política
-- SELECT (abogado_lee_sus_*); faltan INSERT y UPDATE, así que el portal no puede
-- crear/editar. Se agregan 2 políticas por tabla (INSERT, UPDATE) que permiten la
-- escritura a usuarios activos con rol Super Administrador (1), Admin Legal (18) o
-- Jurídico (26).
--
-- Idempotente: CREATE POLICY no soporta IF NOT EXISTS → DROP POLICY IF EXISTS antes
-- de cada CREATE. ENABLE ROW LEVEL SECURITY es seguro de reejecutar (no-op si ya
-- está activo). Sin BEGIN/COMMIT (CI/CD envuelve en tx). Las verificaciones V-1..V-5
-- y la validación posterior del .md se omiten (SELECTs de solo lectura).
--
-- Nota: no se copian las políticas SELECT existentes; solo se añaden INSERT/UPDATE.

-- Asegurar RLS habilitado (V-5: si estuviera en false, esto lo activa).
ALTER TABLE public.app_juridico_audiencias ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_juridico_acuerdos   ENABLE ROW LEVEL SECURITY;

-- ================================================================
-- BLOQUE 1.A — app_juridico_audiencias
-- ================================================================
DROP POLICY IF EXISTS "juridico_ins_audiencias" ON public.app_juridico_audiencias;
CREATE POLICY "juridico_ins_audiencias" ON public.app_juridico_audiencias
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid()
        AND u.rol_id IN (1, 18, 26)
        AND u.activo = true
    )
  );

DROP POLICY IF EXISTS "juridico_upd_audiencias" ON public.app_juridico_audiencias;
CREATE POLICY "juridico_upd_audiencias" ON public.app_juridico_audiencias
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid()
        AND u.rol_id IN (1, 18, 26)
        AND u.activo = true
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid()
        AND u.rol_id IN (1, 18, 26)
        AND u.activo = true
    )
  );

-- ================================================================
-- BLOQUE 1.B — app_juridico_acuerdos
-- ================================================================
DROP POLICY IF EXISTS "juridico_ins_acuerdos" ON public.app_juridico_acuerdos;
CREATE POLICY "juridico_ins_acuerdos" ON public.app_juridico_acuerdos
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid()
        AND u.rol_id IN (1, 18, 26)
        AND u.activo = true
    )
  );

DROP POLICY IF EXISTS "juridico_upd_acuerdos" ON public.app_juridico_acuerdos;
CREATE POLICY "juridico_upd_acuerdos" ON public.app_juridico_acuerdos
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid()
        AND u.rol_id IN (1, 18, 26)
        AND u.activo = true
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid()
        AND u.rol_id IN (1, 18, 26)
        AND u.activo = true
    )
  );
