-- Motor de Comisiones compartido — rediseño relacional (canales + matriz canal×puesto)
-- Fecha: 2026-07-14
--
-- Reemplaza el diseño espejo-del-front (comisiones_canales id text + comisiones_escenarios
-- jsonb) por un modelo relacional:
--   - comisiones_canales: id bigint IDENTITY + codigo UNIQUE (convención del proyecto), sin
--     jsonb, sin id_padre/permite_subcanales (no se usan hoy).
--   - comisiones_reglas: matriz base canal × puesto (roles_organizacionales), FK reales,
--     UNIQUE(id_canal, id_rol). Una sola matriz compartida, independiente de escenarios.
--   - comisiones_escenarios / perfil / historial: fuera de alcance por ahora (no se crean).
--
-- DROP previo de las tablas del diseño anterior (si se llegaron a crear): no tienen datos
-- reales (el front usa localStorage hasta que exista este esquema). Idempotente:
-- DROP ... IF EXISTS + seed ON CONFLICT. Sin BEGIN/COMMIT (CI/CD envuelve en tx).
-- Requiere roles_organizacionales (ya versionada).

-- Limpieza del diseño anterior (orden: dependientes primero).
DROP TABLE IF EXISTS public.comisiones_reglas;
DROP TABLE IF EXISTS public.comisiones_escenarios;
DROP TABLE IF EXISTS public.comisiones_canales;

-- ================================================================
-- 1. Canales de Venta — catálogo relacional (id IDENTITY, sin JSON)
-- ================================================================
CREATE TABLE public.comisiones_canales (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo                      text UNIQUE,
  nombre                      text NOT NULL,
  descripcion                 text,
  categoria                   text,
  comision_externa_pct        numeric(6,2) NOT NULL DEFAULT 0,
  comision_min_pct            numeric(6,2) NOT NULL DEFAULT 0,
  comision_max_pct            numeric(6,2) NOT NULL DEFAULT 0,
  comision_base_pct           numeric(6,2) NOT NULL DEFAULT 0,
  participa_escalonamiento    boolean NOT NULL DEFAULT true,
  participa_bonos             boolean NOT NULL DEFAULT true,
  participa_simuladores       boolean NOT NULL DEFAULT true,
  requiere_onboarding         boolean NOT NULL DEFAULT false,
  requiere_capacitacion       boolean NOT NULL DEFAULT false,
  requiere_aprobacion         boolean NOT NULL DEFAULT false,
  proteccion_leads_dias       integer NOT NULL DEFAULT 0,
  activo                      boolean NOT NULL DEFAULT true,
  fecha_creacion              timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion         timestamptz NOT NULL DEFAULT now()
);

-- Semilla: mismos 5 canales que hoy existen mock en seed-data.ts (idempotente por codigo).
INSERT INTO public.comisiones_canales
  (codigo, nombre, comision_externa_pct, comision_min_pct, comision_max_pct, activo) VALUES
  ('inmobiliaria', 'Inmobiliaria Externa', 4,   3.5, 5,   true),
  ('broker',       'Broker Independiente', 2.5, 2,   3,   true),
  ('embajador',    'Embajador',            1,   0.5, 1.5, true),
  ('referido',     'Referido',             1,   0.5, 1.5, true),
  ('interno',      'Canal Interno',        0,   0,   0,   true)
ON CONFLICT (codigo) DO NOTHING;

-- ================================================================
-- 2. Comisiones — matriz base canal × puesto (roles_organizacionales)
--    Reemplaza reglas_comision jsonb; UNA matriz compartida, sin escenario.
-- ================================================================
CREATE TABLE public.comisiones_reglas (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_canal            bigint NOT NULL REFERENCES public.comisiones_canales(id),
  id_rol              bigint NOT NULL REFERENCES public.roles_organizacionales(id),
  porcentaje          numeric(6,2) NOT NULL DEFAULT 0,
  pool                text NOT NULL DEFAULT 'project' CHECK (pool IN ('sozu','project')),
  activo              boolean NOT NULL DEFAULT true,
  fecha_creacion      timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id_canal, id_rol)
);

CREATE INDEX idx_comisiones_reglas_canal ON public.comisiones_reglas (id_canal);
CREATE INDEX idx_comisiones_reglas_rol   ON public.comisiones_reglas (id_rol);
