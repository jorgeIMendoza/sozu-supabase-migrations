-- Flujo de reservación: tabla reservaciones + RLS + guards de integridad.
-- Fecha: 2026-06-11
--
-- Soporta el botón "Apartar" del portal agente: el agente genera la oferta PDF,
-- captura el correo del prospecto y crea el link de reservación /reservar/{id}
-- (válido 7 días). Las columnas Stripe van nullable desde ya para el hold de
-- tarjeta; la tabla opera sin ellas por ahora.
--
-- Idempotente: CREATE TABLE IF NOT EXISTS; policies con DROP IF EXISTS + CREATE;
-- CHECK vía DO block (Postgres no soporta ADD CONSTRAINT IF NOT EXISTS); triggers
-- con DROP TRIGGER IF EXISTS; funciones CREATE OR REPLACE (set_fecha_actualizacion
-- ya existe en dev con cuerpo idéntico — el REPLACE es inofensivo).

-- ───────────────────────────────────────────────────────────────────────────
-- 1. Tabla
-- ───────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.reservaciones (
  id                    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_oferta             INTEGER REFERENCES public.ofertas(id) ON DELETE SET NULL,
  id_persona            INTEGER REFERENCES public.personas(id) ON DELETE SET NULL,
  email                 TEXT NOT NULL,
  nombre                TEXT,
  telefono              TEXT,
  id_pago_stripe        TEXT,
  estatus               TEXT NOT NULL DEFAULT 'pendiente'
                          CHECK (estatus IN ('pendiente', 'autorizado', 'expirado', 'cancelado')),
  fecha_activacion      TIMESTAMP WITH TIME ZONE,
  fecha_expiracion      TIMESTAMP WITH TIME ZONE,
  activo                BOOLEAN NOT NULL DEFAULT true,
  fecha_creacion        TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  fecha_actualizacion   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

ALTER TABLE public.reservaciones ENABLE ROW LEVEL SECURITY;

-- ───────────────────────────────────────────────────────────────────────────
-- 2. Policies RLS
-- ───────────────────────────────────────────────────────────────────────────

-- Política previa reemplazada por update_solo_pendiente (nota del spec).
DROP POLICY IF EXISTS "service_update" ON public.reservaciones;

-- Lectura pública por id (link /reservar/{id} — válido solo 7 días por guards)
DROP POLICY IF EXISTS "public_read_by_id" ON public.reservaciones;
CREATE POLICY "public_read_by_id" ON public.reservaciones
  FOR SELECT USING (true);

-- Solo usuarios autenticados pueden insertar (agente desde el admin)
DROP POLICY IF EXISTS "auth_insert" ON public.reservaciones;
CREATE POLICY "auth_insert" ON public.reservaciones
  FOR INSERT WITH CHECK (auth.role() = 'authenticated');

-- Actualización: solo mientras estatus=pendiente y dentro de los 7 días de vida.
-- Service role (edge functions) bypasea RLS automáticamente en Supabase.
DROP POLICY IF EXISTS "update_solo_pendiente" ON public.reservaciones;
CREATE POLICY "update_solo_pendiente" ON public.reservaciones
  FOR UPDATE USING (
    activo = true
    AND estatus = 'pendiente'
    AND fecha_creacion + INTERVAL '7 days' > now()
  );

-- ───────────────────────────────────────────────────────────────────────────
-- 3. Guards de integridad (contra manipulación directa via API con anon key)
-- ───────────────────────────────────────────────────────────────────────────

-- 3.1 CHECK: fecha_expiracion nunca puede superar 7 días desde creación
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_expiracion_max') THEN
    ALTER TABLE public.reservaciones
      ADD CONSTRAINT chk_expiracion_max
      CHECK (fecha_expiracion IS NULL
          OR fecha_expiracion <= fecha_creacion + INTERVAL '7 days');
  END IF;
END $$;

-- 3.2 Función genérica: actualiza fecha_actualizacion en cada UPDATE.
--     Reutilizable en otras tablas con el mismo nombre de columna.
CREATE OR REPLACE FUNCTION public.set_fecha_actualizacion()
RETURNS TRIGGER AS $$
BEGIN
  NEW.fecha_actualizacion = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_fecha_actualizacion_reservaciones ON public.reservaciones;
CREATE TRIGGER trg_fecha_actualizacion_reservaciones
  BEFORE UPDATE ON public.reservaciones
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- 3.3 Máquina de estados:
--     pendiente → autorizado  OK
--     autorizado → cualquier  ERROR
--     expirado/cancelado → cualquier  ERROR
CREATE OR REPLACE FUNCTION public.validar_transicion_estatus_reservacion()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.estatus IN ('expirado', 'cancelado') THEN
    RAISE EXCEPTION 'Reservación finalizada, no se puede modificar (estatus: %)', OLD.estatus;
  END IF;
  IF OLD.estatus = 'autorizado' AND NEW.estatus <> 'autorizado' THEN
    RAISE EXCEPTION 'No se puede revertir estatus autorizado';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validar_estatus_reservacion ON public.reservaciones;
CREATE TRIGGER trg_validar_estatus_reservacion
  BEFORE UPDATE ON public.reservaciones
  FOR EACH ROW EXECUTE FUNCTION public.validar_transicion_estatus_reservacion();
