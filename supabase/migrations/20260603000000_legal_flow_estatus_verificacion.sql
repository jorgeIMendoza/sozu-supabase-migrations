-- SOZU Legal Flow — columnas de estatus de verificación por sección/fila.
--
-- Las acciones Validar/Rechazar del detalle de expediente (CaseDetail.tsx) hoy
-- sólo escriben en legal_flow_bitacora. Para reflejar el estatus en el Admin
-- Panel y el Portal Cliente sin leer la bitácora, se agregan columnas reales por
-- fila en las tablas de origen.
--
-- Dominio de estatus (mismo que ya usa documentos.id_estatus_verificacion):
--   1 = Pendiente · 2 = Validado · 3 = Rechazado · 4 = Expirado
--
-- Scopes de la bitácora → columna destino:
--   comprador_basica    → personas.datos_basicos_estatus_verificacion
--   comprador_direccion → personas.direccion_estatus_verificacion
--   comprador_fiscal    → personas.datos_fiscales_estatus_verificacion
--   (cuenta bancaria)   → cuentas_bancarias.id_estatus_verificacion
--   documento           → ya existe documentos.id_estatus_verificacion (no se toca)
--
-- Nota de sintaxis: PostgreSQL NO soporta `ADD CONSTRAINT IF NOT EXISTS`, por eso
-- los CHECK se crean dentro de bloques DO guardados contra pg_constraint
-- (idempotente y re-ejecutable sin error).

-- 1) personas: tres columnas, una por sección.
ALTER TABLE public.personas
  ADD COLUMN IF NOT EXISTS datos_basicos_estatus_verificacion   smallint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS direccion_estatus_verificacion       smallint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS datos_fiscales_estatus_verificacion  smallint NOT NULL DEFAULT 1;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_personas_datos_basicos_estatus') THEN
    ALTER TABLE public.personas
      ADD CONSTRAINT chk_personas_datos_basicos_estatus
      CHECK (datos_basicos_estatus_verificacion IN (1, 2, 3, 4));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_personas_direccion_estatus') THEN
    ALTER TABLE public.personas
      ADD CONSTRAINT chk_personas_direccion_estatus
      CHECK (direccion_estatus_verificacion IN (1, 2, 3, 4));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_personas_datos_fiscales_estatus') THEN
    ALTER TABLE public.personas
      ADD CONSTRAINT chk_personas_datos_fiscales_estatus
      CHECK (datos_fiscales_estatus_verificacion IN (1, 2, 3, 4));
  END IF;
END $$;

COMMENT ON COLUMN public.personas.datos_basicos_estatus_verificacion IS
  '1=Pendiente · 2=Validado · 3=Rechazado · 4=Expirado. Lo actualiza SOZU Legal Flow al validar/rechazar la sección Básica de un comprador y se consulta desde Admin Panel / Portal Cliente.';
COMMENT ON COLUMN public.personas.direccion_estatus_verificacion IS
  '1=Pendiente · 2=Validado · 3=Rechazado · 4=Expirado. Análogo para la sección Dirección.';
COMMENT ON COLUMN public.personas.datos_fiscales_estatus_verificacion IS
  '1=Pendiente · 2=Validado · 3=Rechazado · 4=Expirado. Análogo para la sección Fiscal.';

-- 2) cuentas_bancarias: una sola columna.
ALTER TABLE public.cuentas_bancarias
  ADD COLUMN IF NOT EXISTS id_estatus_verificacion smallint NOT NULL DEFAULT 1;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_ctas_bancarias_estatus_verificacion') THEN
    ALTER TABLE public.cuentas_bancarias
      ADD CONSTRAINT chk_ctas_bancarias_estatus_verificacion
      CHECK (id_estatus_verificacion IN (1, 2, 3, 4));
  END IF;
END $$;

COMMENT ON COLUMN public.cuentas_bancarias.id_estatus_verificacion IS
  '1=Pendiente · 2=Validado · 3=Rechazado · 4=Expirado. Lo actualiza SOZU Legal Flow al validar/rechazar una cuenta y se consulta desde Admin Panel / Portal Cliente.';

-- 3) Recarga del schema cache de PostgREST.
NOTIFY pgrst, 'reload schema';
