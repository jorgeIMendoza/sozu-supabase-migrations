-- ============================================================================
-- Evidencia multimedia (fotos / videos) en los tickets del Portal de Tickets
-- de Seguimiento.
--
-- Reusa el bucket público existente `documentos` (sin límite de tamaño) con el
-- prefijo de ruta `tickets/<id_ticket>/...` — igual que el CRM reusa `documentos`
-- para sus adjuntos. Por eso esta migración SOLO agrega la tabla de registro;
-- no crea buckets ni políticas de storage.
--
-- Reglas de negocio:
--   • Ver / subir evidencia  → cualquier usuario autenticado.
--   • Borrar evidencia       → SOLO Super Admin (rol 1). Se hace con soft-delete
--                              (activo=false); NO se usa is_admin_user() porque
--                              esa función incluye también al rol 2.
--
-- Idempotente y self-guarded: se puede correr varias veces sin efectos.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.tickets_adjuntos (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_ticket        bigint NOT NULL REFERENCES public.tickets(id) ON DELETE CASCADE,
  tipo             text   NOT NULL CHECK (tipo IN ('foto', 'video')),
  url              text   NOT NULL,
  nombre           text,
  mime             text,
  tamano_bytes     bigint,
  id_usuario_autor uuid,
  fecha_creacion   timestamptz NOT NULL DEFAULT now(),
  activo           boolean     NOT NULL DEFAULT true
);

COMMENT ON TABLE public.tickets_adjuntos IS
  'Evidencia multimedia (fotos/videos) de los tickets. Archivos en el bucket documentos (tickets/<id_ticket>/).';

CREATE INDEX IF NOT EXISTS idx_tickets_adjuntos_ticket
  ON public.tickets_adjuntos (id_ticket) WHERE activo;

-- ── RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE public.tickets_adjuntos ENABLE ROW LEVEL SECURITY;

-- Ver: cualquier autenticado
DROP POLICY IF EXISTS tickets_adjuntos_select ON public.tickets_adjuntos;
CREATE POLICY tickets_adjuntos_select
  ON public.tickets_adjuntos
  FOR SELECT TO authenticated
  USING (true);

-- Insertar (subir evidencia): cualquier autenticado
DROP POLICY IF EXISTS tickets_adjuntos_insert ON public.tickets_adjuntos;
CREATE POLICY tickets_adjuntos_insert
  ON public.tickets_adjuntos
  FOR INSERT TO authenticated
  WITH CHECK (true);

-- Actualizar (soft-delete activo=false): SOLO Super Admin (rol 1)
DROP POLICY IF EXISTS tickets_adjuntos_update_superadmin ON public.tickets_adjuntos;
CREATE POLICY tickets_adjuntos_update_superadmin
  ON public.tickets_adjuntos
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid() AND u.rol_id = 1
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid() AND u.rol_id = 1
    )
  );

COMMIT;
