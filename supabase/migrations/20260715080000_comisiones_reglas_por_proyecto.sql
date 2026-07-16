-- Comisiones por proyecto: reglas canal×puesto por proyecto + quitar dimensión de escenario
-- Fecha: 2026-07-15
--
-- 1) comisiones_propuestas/comisiones_validaciones: se elimina la dimensión "escenario"
--    (los escenarios son solo para Simulación, no para la estructura real). Pasa de una
--    propuesta por (proyecto, escenario) a una única por proyecto. 0 filas en dev → sin
--    migración de datos.
-- 2) comisiones_reglas: matriz canal×puesto ahora POR PROYECTO (add id_proyecto, unique
--    (id_canal,id_rol,id_proyecto)). Las 32 filas existentes están en 0% → se truncan.
--
-- Nota: la config Modo A/B + Comisión Total por proyecto (comisiones_motor_config) se maneja
-- desde el front; no se crea aquí.
--
-- Idempotente: DROP ... IF EXISTS, CREATE ... IF NOT EXISTS, ADD CONSTRAINT con guard.
-- Sin BEGIN/COMMIT (CI/CD envuelve en tx). Verificado en dev: proyectos.id=integer,
-- reglas 32 filas sin id_proyecto.

-- ================================================================
-- 1. comisiones_propuestas / comisiones_validaciones — quitar escenario
-- ================================================================
ALTER TABLE public.comisiones_propuestas
  DROP CONSTRAINT IF EXISTS comisiones_propuestas_id_proyecto_escenario_id_key;
ALTER TABLE public.comisiones_propuestas DROP COLUMN IF EXISTS escenario_id;
ALTER TABLE public.comisiones_propuestas DROP COLUMN IF EXISTS escenario_nombre;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.comisiones_propuestas'::regclass
      AND conname = 'comisiones_propuestas_id_proyecto_key'
  ) THEN
    ALTER TABLE public.comisiones_propuestas
      ADD CONSTRAINT comisiones_propuestas_id_proyecto_key UNIQUE (id_proyecto);
  END IF;
END $$;

ALTER TABLE public.comisiones_validaciones DROP COLUMN IF EXISTS escenario_id;
ALTER TABLE public.comisiones_validaciones DROP COLUMN IF EXISTS escenario_nombre;

-- ================================================================
-- 2. comisiones_reglas — matriz canal×puesto POR PROYECTO
--    (32 filas existentes en 0% → truncar; nueva unique con id_proyecto)
-- ================================================================
TRUNCATE TABLE public.comisiones_reglas;

ALTER TABLE public.comisiones_reglas
  ADD COLUMN IF NOT EXISTS id_proyecto integer NOT NULL REFERENCES public.proyectos(id);

ALTER TABLE public.comisiones_reglas
  DROP CONSTRAINT IF EXISTS comisiones_reglas_id_canal_id_rol_key;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.comisiones_reglas'::regclass
      AND conname = 'comisiones_reglas_canal_rol_proyecto_key'
  ) THEN
    ALTER TABLE public.comisiones_reglas
      ADD CONSTRAINT comisiones_reglas_canal_rol_proyecto_key UNIQUE (id_canal, id_rol, id_proyecto);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_comisiones_reglas_proyecto ON public.comisiones_reglas (id_proyecto);
