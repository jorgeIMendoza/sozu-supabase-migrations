-- Preferencia del cliente para activar/desactivar push
-- Fecha: 2026-07-15
--
-- El cliente puede apagar las notificaciones push desde la app (Perfil → Notificaciones).
-- La preferencia vive por id_persona; el dispatch (notificaciones-push) excluye a quienes
-- tengan push_activo=false. Sin fila = push activo (default true). Los tokens NO se dan de
-- baja (reactivar es instantáneo).
--
-- Solo service_role (edge functions) toca esta tabla; RLS on sin policies.
-- Idempotente: CREATE TABLE IF NOT EXISTS. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

CREATE TABLE IF NOT EXISTS public.push_preferencias_cliente (
  id_persona   bigint NOT NULL,
  push_activo  boolean NOT NULL DEFAULT true,
  updated_at   timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT push_preferencias_cliente_pkey PRIMARY KEY (id_persona)
);

ALTER TABLE public.push_preferencias_cliente ENABLE ROW LEVEL SECURITY;
