-- Catálogo de roles organizacionales + directorio de puestos (Estructura de Comisiones)
-- Fecha: 2026-07-11
--
-- Tablas para la pestaña "Directorio de Personal". Independientes de roles/usuarios.rol_id
-- (auth/permisos) — no se tocan ni relacionan. email_usuario referencia usuarios(email)
-- (la PK de usuarios es email, no id).
--
-- Idempotente: CREATE TABLE/INDEX IF NOT EXISTS + seed con guard por nombre. Sin BEGIN/COMMIT.
-- NOTA: id_proyecto es INTEGER (proyectos.id es integer, no bigint) para que el FK coincida.

-- ================================================================
-- 1. Catálogo de roles de empresa (Director, Asesor, etc.)
-- ================================================================
CREATE TABLE IF NOT EXISTS public.roles_organizacionales (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre              text NOT NULL,
  tipo                text NOT NULL CHECK (tipo IN ('strategic','operative','support')),
  pertenece_a         text NOT NULL CHECK (pertenece_a IN ('sozu_central','project')),
  participa_comision  boolean NOT NULL DEFAULT true,
  activo              boolean NOT NULL DEFAULT true,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now()
);

-- Semilla (mismo catálogo que el mock de seed-data.ts). Guard por nombre → idempotente.
INSERT INTO public.roles_organizacionales (nombre, tipo, pertenece_a, participa_comision)
SELECT v.nombre, v.tipo, v.pertenece_a, v.participa
FROM (VALUES
  ('Director SOZU',                  'strategic', 'sozu_central', true),
  ('Marketing',                      'operative', 'sozu_central', false),
  ('Alianzas/Onboarding',            'operative', 'sozu_central', true),
  ('Data & IA',                      'support',   'sozu_central', false),
  ('Director Comercial Desarrollo',  'strategic', 'project',      true),
  ('Admin Comercial',                'operative', 'project',      true),
  ('Asesor de Ventas',               'operative', 'project',      true)
) AS v(nombre, tipo, pertenece_a, participa)
WHERE NOT EXISTS (
  SELECT 1 FROM public.roles_organizacionales r WHERE r.nombre = v.nombre
);

-- ================================================================
-- 2. Directorio de puestos asignados (quién ocupa cada rol)
-- ================================================================
CREATE TABLE IF NOT EXISTS public.puestos_organizacionales (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_rol              bigint NOT NULL REFERENCES public.roles_organizacionales(id),
  id_proyecto         integer REFERENCES public.proyectos(id),   -- NULL = SOZU Central
  email_usuario       text REFERENCES public.usuarios(email),    -- usuario real vinculado (nullable: puesto vacante o sin cuenta aún)
  nombre_ocupante     text,                                       -- nombre libre si aún no tiene cuenta en `usuarios`
  sueldo_base         numeric(12,2) NOT NULL DEFAULT 0,
  bono_fijo           numeric(12,2) NOT NULL DEFAULT 0,
  prestaciones_pct    numeric(5,2) NOT NULL DEFAULT 0,
  fecha_inicio        date,
  activo              boolean NOT NULL DEFAULT true,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_puestos_organizacionales_rol ON public.puestos_organizacionales (id_rol);
CREATE INDEX IF NOT EXISTS idx_puestos_organizacionales_proyecto ON public.puestos_organizacionales (id_proyecto);
CREATE INDEX IF NOT EXISTS idx_puestos_organizacionales_usuario ON public.puestos_organizacionales (email_usuario);
