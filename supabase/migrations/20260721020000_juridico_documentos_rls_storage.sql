-- Portal Jurídico Fase 1 · DDL-5 · Documentos jurídicos: columnas, RLS, triggers, índices,
--                                     bucket y RLS de Storage
-- Fecha: 2026-07-21
--
-- Consolida:
--   5.0 columnas nuevas en app_juridico_documentos (mime_type, tamano_bytes, numero_version).
--   5.A RLS de app_juridico_documentos → authenticated (SELECT todos; INSERT/UPDATE roles
--       jurídicos 1/18/26). Sin DELETE (se inhabilita con activo=false).
--   5.B trigger fecha_actualizacion en app_juridico_documentos.
--   5.C triggers fecha_actualizacion en audiencias, acuerdos, asignaciones, perfiles.
--       (demandas_timeline EXCLUIDA — inmutable, sin UPDATE por diseño.)
--   5.F índices (búsqueda por demanda + único parcial nombre por demanda vigente).
--   5.D bucket privado documentos-juridicos.
--   5.E RLS de storage.objects para ese bucket (SELECT/INSERT/UPDATE roles 1/18/26; DELETE rol 1).
--
-- Idempotente: ADD COLUMN IF NOT EXISTS, DROP POLICY/TRIGGER IF EXISTS + CREATE, CREATE INDEX
-- IF NOT EXISTS, INSERT bucket ON CONFLICT DO NOTHING. Sin CONCURRENTLY (no corre en tx; el
-- índice único parcial es rápido y CI/CD envuelve en tx). Sin BEGIN/COMMIT.
-- Requiere public.set_fecha_actualizacion().

-- ================================================================
-- 5.0 — Columnas nuevas
-- ================================================================
ALTER TABLE public.app_juridico_documentos
  ADD COLUMN IF NOT EXISTS mime_type      text    NULL,
  ADD COLUMN IF NOT EXISTS tamano_bytes   bigint  NULL,
  ADD COLUMN IF NOT EXISTS numero_version integer NOT NULL DEFAULT 1;

-- ================================================================
-- 5.A — RLS app_juridico_documentos (reemplaza políticas previas)
-- ================================================================
ALTER TABLE public.app_juridico_documentos ENABLE ROW LEVEL SECURITY;

-- Eliminar TODAS las políticas existentes (nombres desconocidos: patrón genérico).
DO $$
DECLARE pol RECORD;
BEGIN
  FOR pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'app_juridico_documentos'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.app_juridico_documentos', pol.policyname);
  END LOOP;
END $$;

CREATE POLICY "juridico_auth_select_documentos" ON public.app_juridico_documentos
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "juridico_rol_insert_documentos" ON public.app_juridico_documentos
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.usuarios u
            WHERE u.auth_user_id = auth.uid() AND u.rol_id IN (1, 18, 26) AND u.activo = true)
  );

CREATE POLICY "juridico_rol_update_documentos" ON public.app_juridico_documentos
  FOR UPDATE TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.usuarios u
            WHERE u.auth_user_id = auth.uid() AND u.rol_id IN (1, 18, 26) AND u.activo = true)
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.usuarios u
            WHERE u.auth_user_id = auth.uid() AND u.rol_id IN (1, 18, 26) AND u.activo = true)
  );

-- ================================================================
-- 5.B / 5.C — Triggers fecha_actualizacion
-- ================================================================
DROP TRIGGER IF EXISTS set_app_juridico_documentos_fecha_actualizacion ON public.app_juridico_documentos;
CREATE TRIGGER set_app_juridico_documentos_fecha_actualizacion
  BEFORE UPDATE ON public.app_juridico_documentos
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

DROP TRIGGER IF EXISTS set_app_juridico_audiencias_fecha_actualizacion ON public.app_juridico_audiencias;
CREATE TRIGGER set_app_juridico_audiencias_fecha_actualizacion
  BEFORE UPDATE ON public.app_juridico_audiencias
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

DROP TRIGGER IF EXISTS set_app_juridico_acuerdos_fecha_actualizacion ON public.app_juridico_acuerdos;
CREATE TRIGGER set_app_juridico_acuerdos_fecha_actualizacion
  BEFORE UPDATE ON public.app_juridico_acuerdos
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

DROP TRIGGER IF EXISTS set_asignaciones_juridico_fecha_actualizacion ON public.asignaciones_juridico;
CREATE TRIGGER set_asignaciones_juridico_fecha_actualizacion
  BEFORE UPDATE ON public.asignaciones_juridico
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

DROP TRIGGER IF EXISTS set_perfiles_juridicos_fecha_actualizacion ON public.perfiles_juridicos;
CREATE TRIGGER set_perfiles_juridicos_fecha_actualizacion
  BEFORE UPDATE ON public.perfiles_juridicos
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- ================================================================
-- 5.F — Índices
-- ================================================================
CREATE INDEX IF NOT EXISTS idx_app_juridico_documentos_demanda
  ON public.app_juridico_documentos (id_demanda) WHERE activo = true;

-- Único parcial: sin duplicados de nombre por demanda activa+vigente; permite históricos
-- (activo=false) con el mismo nombre → flujo de reemplazo de versión.
CREATE UNIQUE INDEX IF NOT EXISTS uidx_app_juridico_documentos_demanda_nombre_vigente
  ON public.app_juridico_documentos (id_demanda, nombre_archivo)
  WHERE activo = true AND es_vigente = true;

-- ================================================================
-- 5.D — Bucket privado documentos-juridicos
-- ================================================================
INSERT INTO storage.buckets (id, name, public, avif_autodetection, file_size_limit, allowed_mime_types)
VALUES (
  'documentos-juridicos', 'documentos-juridicos', false, false, 52428800,
  ARRAY[
    'application/pdf', 'image/jpeg', 'image/png', 'image/webp',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  ]
)
ON CONFLICT (id) DO NOTHING;

-- ================================================================
-- 5.E — RLS de storage.objects para el bucket documentos-juridicos
-- ================================================================
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "juridico_docs_select" ON storage.objects;
CREATE POLICY "juridico_docs_select" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'documentos-juridicos' AND
    EXISTS (SELECT 1 FROM public.usuarios u
            WHERE u.auth_user_id = auth.uid() AND u.rol_id IN (1, 18, 26) AND u.activo = true)
  );

DROP POLICY IF EXISTS "juridico_docs_insert" ON storage.objects;
CREATE POLICY "juridico_docs_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'documentos-juridicos' AND
    EXISTS (SELECT 1 FROM public.usuarios u
            WHERE u.auth_user_id = auth.uid() AND u.rol_id IN (1, 18, 26) AND u.activo = true)
  );

DROP POLICY IF EXISTS "juridico_docs_update" ON storage.objects;
CREATE POLICY "juridico_docs_update" ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'documentos-juridicos' AND
    EXISTS (SELECT 1 FROM public.usuarios u
            WHERE u.auth_user_id = auth.uid() AND u.rol_id IN (1, 18, 26) AND u.activo = true)
  )
  WITH CHECK (
    bucket_id = 'documentos-juridicos' AND
    EXISTS (SELECT 1 FROM public.usuarios u
            WHERE u.auth_user_id = auth.uid() AND u.rol_id IN (1, 18, 26) AND u.activo = true)
  );

DROP POLICY IF EXISTS "juridico_docs_delete" ON storage.objects;
CREATE POLICY "juridico_docs_delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'documentos-juridicos' AND
    EXISTS (SELECT 1 FROM public.usuarios u
            WHERE u.auth_user_id = auth.uid() AND u.rol_id = 1 AND u.activo = true)
  );
