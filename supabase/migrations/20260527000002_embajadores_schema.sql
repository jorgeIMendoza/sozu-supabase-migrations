-- Módulo Embajadores — tipos de entidad, rol, tablas embajadores y referidos.
-- Requisito: public.personas debe existir. set_fecha_actualizacion() creada en 20260527000001.

CREATE OR REPLACE FUNCTION public.set_fecha_actualizacion()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.fecha_actualizacion = NOW();
  RETURN NEW;
END;
$$;


-- ════════════════════════════════════════════════════════════════════════════
--  PASO 1: Tipo de entidad — Embajador
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO public.tipos_entidad (nombre, activo)
SELECT 'Embajador', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.tipos_entidad WHERE nombre = 'Embajador'
);


-- ════════════════════════════════════════════════════════════════════════════
--  PASO 2: Rol — Embajador (externo)
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO public.roles (
  nombre, es_rol_interno, activo,
  ver_todos_prospectos_compradores,
  ver_todos_proyectos_propiedades,
  ver_filtros_avanzados_eliminados,
  ver_todos_duenos,
  configurar_citas
)
SELECT 'Embajador', false, true, false, false, false, false, false
WHERE NOT EXISTS (
  SELECT 1 FROM public.roles WHERE nombre = 'Embajador'
);


-- ════════════════════════════════════════════════════════════════════════════
--  FUNCIÓN: Auto-generar código EMB-XXXX
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.gen_embajador_codigo()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  next_num INTEGER;
BEGIN
  IF NEW.codigo IS NULL OR NEW.codigo = '' THEN
    SELECT COALESCE(MAX(CAST(SUBSTRING(codigo FROM 5) AS INTEGER)), 2030) + 1
    INTO next_num
    FROM public.embajadores
    WHERE codigo ~ '^EMB-[0-9]+$';
    NEW.codigo = 'EMB-' || LPAD(next_num::TEXT, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;


-- ════════════════════════════════════════════════════════════════════════════
--  TABLA 1: embajadores
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.embajadores (
  id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_persona          INTEGER     NOT NULL UNIQUE REFERENCES public.personas(id),
  codigo              TEXT        UNIQUE,
  empresa             TEXT,
  tipo                TEXT        NOT NULL DEFAULT 'otro'
                        CHECK (tipo IN (
                          'cliente','socio','aliado',
                          'referidor_externo','colaborador','otro'
                        )),
  pct_comision        NUMERIC(5,2)  NOT NULL DEFAULT 0,
  monto_fijo          NUMERIC(12,2),
  trigger_comision    TEXT        NOT NULL DEFAULT 'escrituracion'
                        CHECK (trigger_comision IN (
                          'apartado','promesa','enganche','escrituracion'
                        )),
  dias_proteccion     INTEGER     NOT NULL DEFAULT 30,
  notas               TEXT,
  estatus             TEXT        NOT NULL DEFAULT 'pendiente'
                        CHECK (estatus IN ('activo','inactivo','pendiente')),
  documentos_pago     JSONB       NOT NULL DEFAULT '[]'::jsonb,
  activo              BOOLEAN     NOT NULL DEFAULT true,
  fecha_creacion      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER embajadores_gen_codigo
  BEFORE INSERT ON public.embajadores
  FOR EACH ROW EXECUTE FUNCTION public.gen_embajador_codigo();

CREATE TRIGGER embajadores_updated_at
  BEFORE UPDATE ON public.embajadores
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

CREATE INDEX embajadores_estatus_idx
  ON public.embajadores(estatus)
  WHERE activo = true;


-- ════════════════════════════════════════════════════════════════════════════
--  TABLA 2: embajadores_referidos
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.embajadores_referidos (
  id                          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_embajador                BIGINT      NOT NULL REFERENCES public.embajadores(id),
  id_persona_cliente          INTEGER     NOT NULL REFERENCES public.personas(id),

  tipo_interes                TEXT        NOT NULL DEFAULT 'indefinido'
                                CHECK (tipo_interes IN (
                                  'vivir','inversion','patrimonial','indefinido'
                                )),
  producto_interes            TEXT,
  relacion_embajador          TEXT,
  comentarios                 TEXT,
  consentimiento              BOOLEAN     NOT NULL DEFAULT false,

  estatus                     TEXT        NOT NULL DEFAULT 'registrado'
                                CHECK (estatus IN (
                                  'registrado','validado','contactado',
                                  'cita_agendada','cita_realizada','en_seguimiento',
                                  'apartado','promesa_firmada','venta_cerrada',
                                  'comision_generada','comision_pagada',
                                  'descartado','duplicado'
                                )),

  -- Asesor SOZU asignado para seguimiento interno
  id_asesor_asignado          TEXT,       -- email del asesor
  nombre_asesor               TEXT,
  rol_asesor                  TEXT,
  telefono_asesor             TEXT,
  email_asesor                TEXT,
  estatus_asignacion          TEXT        NOT NULL DEFAULT 'sin_asignar'
                                CHECK (estatus_asignacion IN (
                                  'sin_asignar','asignado',
                                  'en_seguimiento','reasignado','pausado'
                                )),
  fecha_asignacion            TIMESTAMPTZ,
  ultima_actualizacion_asesor TIMESTAMPTZ,

  estatus_proteccion          TEXT        NOT NULL DEFAULT 'pendiente'
                                CHECK (estatus_proteccion IN (
                                  'protegido','pendiente',
                                  'duplicado_revision','no_valido'
                                )),

  notas_internas              JSONB       NOT NULL DEFAULT '[]'::jsonb,
  comentarios_publicos        TEXT,
  proximo_paso                TEXT,

  monto_venta                 NUMERIC(15,2),
  monto_comision              NUMERIC(12,2) NOT NULL DEFAULT 0,
  estatus_comision            TEXT        NOT NULL DEFAULT 'potencial'
                                CHECK (estatus_comision IN (
                                  'potencial','generada',
                                  'autorizada','pagada','cancelada'
                                )),
  fecha_pago_estimada         DATE,
  fecha_pago                  DATE,

  audit_trail                 JSONB       NOT NULL DEFAULT '[]'::jsonb,

  activo                      BOOLEAN     NOT NULL DEFAULT true,
  fecha_creacion              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER embajadores_referidos_updated_at
  BEFORE UPDATE ON public.embajadores_referidos
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

CREATE INDEX embajadores_referidos_embajador_idx
  ON public.embajadores_referidos(id_embajador)
  WHERE activo = true;

CREATE INDEX embajadores_referidos_estatus_idx
  ON public.embajadores_referidos(estatus)
  WHERE activo = true;

CREATE INDEX embajadores_referidos_asignacion_idx
  ON public.embajadores_referidos(estatus_asignacion)
  WHERE activo = true AND estatus NOT IN ('descartado','duplicado');


-- ════════════════════════════════════════════════════════════════════════════
--  RLS
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.embajadores           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.embajadores_referidos ENABLE ROW LEVEL SECURITY;

-- embajadores
CREATE POLICY "embajadores_select"
  ON public.embajadores FOR SELECT USING (true);
CREATE POLICY "embajadores_insert"
  ON public.embajadores FOR INSERT WITH CHECK (true);
CREATE POLICY "embajadores_update"
  ON public.embajadores FOR UPDATE USING (true);

-- embajadores_referidos
CREATE POLICY "embajadores_referidos_select"
  ON public.embajadores_referidos FOR SELECT USING (true);
CREATE POLICY "embajadores_referidos_insert"
  ON public.embajadores_referidos FOR INSERT WITH CHECK (true);
CREATE POLICY "embajadores_referidos_update"
  ON public.embajadores_referidos FOR UPDATE USING (true);
