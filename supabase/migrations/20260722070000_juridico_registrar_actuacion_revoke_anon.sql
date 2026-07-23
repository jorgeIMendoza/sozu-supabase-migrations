-- Portal Jurídico Fase 2 · T1 · REVOKE anon de registrar_actuacion
-- Fecha: 2026-07-22
--
-- Hallazgo B3: la instancia Supabase self-hosted aplica ALTER DEFAULT PRIVILEGES que otorga
-- EXECUTE a anon en toda función nueva. El REVOKE FROM PUBLIC de la migración previa
-- (20260722060000) no elimina los grants por-rol ya escritos. Este statement cierra el gap.
--
-- Depende de 20260722060000 (registrar_actuacion). Idempotente (REVOKE es no-op si no hay grant).
-- Sin BEGIN/COMMIT (CI/CD envuelve en tx).

REVOKE ALL ON FUNCTION public.registrar_actuacion(
  BIGINT, TEXT, TEXT, DATE, TEXT, TEXT, TEXT, BIGINT
) FROM anon;
