-- Módulo Embajadores
-- Patrón: personas + entidades_relacionadas (tipo "Embajador") + embajadores_config + usuarios (rol 25)
-- Requisitos: personas, entidades_relacionadas y set_fecha_actualizacion() deben existir.
-- El rol "Embajador" (id=25) ya existe — NO se recrea.

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
--  FUNCIÓN: Auto-generar código EMB-XXXX en embajadores_config
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.gen_embajador_codigo()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  next_num INTEGER;
BEGIN
  IF NEW.codigo IS NULL OR NEW.codigo = '' THEN
    SELECT COALESCE(MAX(CAST(SUBSTRING(codigo FROM 5) AS INTEGER)), 2030) + 1
    INTO next_num
    FROM public.embajadores_config
    WHERE codigo ~ '^EMB-[0-9]+$';
    NEW.codigo = 'EMB-' || LPAD(next_num::TEXT, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;


-- ════════════════════════════════════════════════════════════════════════════
--  TABLA 1: embajadores_config
--  Extensión 1:1 de entidades_relacionadas para campos específicos del embajador.
--  La FK es la PK (id_entidad_relacionada = PK de la fila de entidades_relacionadas).
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.embajadores_config (
  id_entidad_relacionada  BIGINT         PRIMARY KEY
                            REFERENCES public.entidades_relacionadas(id) ON DELETE CASCADE,
  codigo                  TEXT           UNIQUE,
  empresa                 TEXT,
  tipo                    TEXT           NOT NULL DEFAULT 'otro'
                            CHECK (tipo IN (
                              'cliente','socio','aliado',
                              'referidor_externo','colaborador','otro'
                            )),
  pct_comision            NUMERIC(5,2)   NOT NULL DEFAULT 0,
  monto_fijo              NUMERIC(12,2),
  trigger_comision        TEXT           NOT NULL DEFAULT 'enganche'
                            CHECK (trigger_comision IN (
                              'apartado','promesa','enganche','escrituracion'
                            )),
  dias_proteccion         INTEGER        NOT NULL DEFAULT 90,
  notas                   TEXT,
  documentos_pago         JSONB          NOT NULL DEFAULT '[]'::jsonb,
  estatus                 TEXT           NOT NULL DEFAULT 'pendiente'
                            CHECK (estatus IN ('activo','inactivo','pendiente')),
  fecha_actualizacion     TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE TRIGGER embajadores_config_gen_codigo
  BEFORE INSERT ON public.embajadores_config
  FOR EACH ROW EXECUTE FUNCTION public.gen_embajador_codigo();

CREATE TRIGGER embajadores_config_updated_at
  BEFORE UPDATE ON public.embajadores_config
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

ALTER TABLE public.embajadores_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "embajadores_config_select"
  ON public.embajadores_config FOR SELECT USING (true);
CREATE POLICY "embajadores_config_insert"
  ON public.embajadores_config FOR INSERT WITH CHECK (true);
CREATE POLICY "embajadores_config_update"
  ON public.embajadores_config FOR UPDATE USING (true);


-- ════════════════════════════════════════════════════════════════════════════
--  TABLA 2: embajadores_referidos
--  Bridge: prospecto (via entidades_relacionadas) ↔ embajador ↔ asesor SOZU
--  id_entidad_relacionada → fila del prospecto en entidades_relacionadas
--  id_persona_embajador   → personas.id del embajador que registró el lead
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.embajadores_referidos (
  id                          BIGINT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

  -- FK a la fila del prospecto en entidades_relacionadas
  id_entidad_relacionada      BIGINT          NOT NULL
                                REFERENCES public.entidades_relacionadas(id) ON DELETE CASCADE,
  -- FK a la fila del embajador en entidades_relacionadas (= Ambassador.id en el frontend)
  id_entidad_relacionada_emb  BIGINT          NOT NULL
                                REFERENCES public.entidades_relacionadas(id),
  -- FK a la persona del embajador (dueño del lead en entidades_relacionadas.id_persona_duena_lead)
  id_persona_embajador        INTEGER         NOT NULL
                                REFERENCES public.personas(id),

  -- Datos del referido
  tipo_interes                TEXT            NOT NULL DEFAULT 'indefinido'
                                CHECK (tipo_interes IN (
                                  'vivir','inversion','patrimonial','indefinido'
                                )),
  producto_interes            TEXT,
  relacion_embajador          TEXT,
  comentarios                 TEXT,
  consentimiento              BOOLEAN         NOT NULL DEFAULT false,

  -- Estatus de seguimiento
  estatus                     TEXT            NOT NULL DEFAULT 'registrado'
                                CHECK (estatus IN (
                                  'registrado','validado','contactado',
                                  'cita_agendada','cita_realizada','en_seguimiento',
                                  'apartado','promesa_firmada','venta_cerrada',
                                  'comision_generada','comision_pagada',
                                  'descartado','duplicado'
                                )),
  estatus_proteccion          TEXT            NOT NULL DEFAULT 'pendiente'
                                CHECK (estatus_proteccion IN (
                                  'protegido','pendiente',
                                  'duplicado_revision','no_valido'
                                )),

  -- Asesor SOZU asignado
  id_persona_asesor           INTEGER         REFERENCES public.personas(id),
  id_asesor_asignado          TEXT,            -- email del asesor (clave usada en proyectos_acceso)
  nombre_asesor               TEXT,
  rol_asesor                  TEXT,
  telefono_asesor             TEXT,
  email_asesor                TEXT,
  estatus_asignacion          TEXT            NOT NULL DEFAULT 'sin_asignar'
                                CHECK (estatus_asignacion IN (
                                  'sin_asignar','asignado',
                                  'en_seguimiento','reasignado','pausado'
                                )),
  fecha_asignacion            TIMESTAMPTZ,
  ultima_actualizacion_asesor TIMESTAMPTZ,

  -- Comisión
  monto_venta                 NUMERIC(15,2),
  monto_comision              NUMERIC(12,2)   NOT NULL DEFAULT 0,
  estatus_comision            TEXT            NOT NULL DEFAULT 'potencial'
                                CHECK (estatus_comision IN (
                                  'potencial','generada','autorizada','pagada','cancelada'
                                )),
  fecha_pago_estimada         DATE,
  fecha_pago                  DATE,

  -- Notas y auditoría
  notas_internas              JSONB           NOT NULL DEFAULT '[]'::jsonb,
  comentarios_publicos        TEXT,
  proximo_paso                TEXT,
  audit_trail                 JSONB           NOT NULL DEFAULT '[]'::jsonb,

  activo                      BOOLEAN         NOT NULL DEFAULT true,
  fecha_creacion              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  fecha_actualizacion         TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TRIGGER embajadores_referidos_updated_at
  BEFORE UPDATE ON public.embajadores_referidos
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

CREATE INDEX embajadores_referidos_embajador_idx
  ON public.embajadores_referidos(id_persona_embajador)
  WHERE activo = true;

CREATE INDEX embajadores_referidos_asesor_idx
  ON public.embajadores_referidos(id_persona_asesor)
  WHERE activo = true AND id_persona_asesor IS NOT NULL;

CREATE INDEX embajadores_referidos_estatus_idx
  ON public.embajadores_referidos(estatus)
  WHERE activo = true;

ALTER TABLE public.embajadores_referidos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "embajadores_referidos_select"
  ON public.embajadores_referidos FOR SELECT USING (true);
CREATE POLICY "embajadores_referidos_insert"
  ON public.embajadores_referidos FOR INSERT WITH CHECK (true);
CREATE POLICY "embajadores_referidos_update"
  ON public.embajadores_referidos FOR UPDATE USING (true);
