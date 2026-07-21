-- Portal Jurídico · Fase 2 v2.2 · Sección A — DDL estructural
-- Fecha: 2026-07-21
--
-- Secuencias + funciones de folio, catálogos (con semillas), 9 tablas núcleo, unique
-- indexes parciales, índices, triggers de auditoría (tablas mutables), ALTER de 3 tablas
-- existentes (demandas, app_juridico_documentos, asignaciones_juridico) + FKs, y ENABLE RLS.
-- Las políticas RLS van en la migración siguiente (20260721150000_..._rls_politicas).
--
-- NO incluye la Sección C (migración de datos de las 2 demandas activas): está comentada en
-- el .md y requiere validación del equipo jurídico (tipo_asunto/origen/posicion_sozu por
-- demanda) — se ejecuta manualmente. Tampoco incluye D (validación) ni E (rollback).
--
-- Tipos verificados (preflight): propiedades.id/entidades_relacionadas.id/perfiles_juridicos.id/
-- app_juridico_documentos.id = bigint; proyectos.id/personas.id = integer.
-- Idempotente: CREATE ... IF NOT EXISTS, ON CONFLICT DO NOTHING, CREATE OR REPLACE, DO-block
-- guards para FKs, ENABLE RLS no-op. Sin BEGIN/COMMIT (CI/CD envuelve en tx).
-- Requiere public.set_fecha_actualizacion().

-- ================================================================
-- A1. Secuencias de folios visibles
-- ================================================================
CREATE SEQUENCE IF NOT EXISTS public.seq_folio_expediente START WITH 1 INCREMENT BY 1 MINVALUE 1 NO MAXVALUE CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.seq_folio_asunto     START WITH 1 INCREMENT BY 1 MINVALUE 1 NO MAXVALUE CACHE 1;

-- ================================================================
-- A2. Funciones generadoras de folio
-- ================================================================
CREATE OR REPLACE FUNCTION public.gen_folio_expediente() RETURNS TEXT
LANGUAGE SQL VOLATILE SET search_path = public AS $$
  SELECT 'EXP-' || LPAD(nextval('public.seq_folio_expediente')::TEXT, 6, '0');
$$;

CREATE OR REPLACE FUNCTION public.gen_folio_asunto() RETURNS TEXT
LANGUAGE SQL VOLATILE SET search_path = public AS $$
  SELECT 'ASU-' || LPAD(nextval('public.seq_folio_asunto')::TEXT, 6, '0');
$$;

-- ================================================================
-- A3. Catálogos
-- ================================================================
CREATE TABLE IF NOT EXISTS public.cat_tipos_asunto (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo TEXT NOT NULL, nombre TEXT NOT NULL, descripcion TEXT NULL,
  activo BOOLEAN NOT NULL DEFAULT true,
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  creado_por TEXT NOT NULL, actualizado_por TEXT NOT NULL,
  CONSTRAINT cat_tipos_asunto_codigo_uq UNIQUE (codigo)
);
COMMENT ON TABLE public.cat_tipos_asunto IS 'Catálogo tipos de asunto jurídico. Fase 2 v2.2.';

CREATE TABLE IF NOT EXISTS public.cat_niveles_riesgo (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo TEXT NOT NULL, nombre TEXT NOT NULL, descripcion TEXT NULL, orden INTEGER NOT NULL,
  activo BOOLEAN NOT NULL DEFAULT true,
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  creado_por TEXT NOT NULL, actualizado_por TEXT NOT NULL,
  CONSTRAINT cat_niveles_riesgo_codigo_uq UNIQUE (codigo)
);
COMMENT ON TABLE public.cat_niveles_riesgo IS 'Catálogo niveles de riesgo jurídico. Fase 2 v2.2.';

CREATE TABLE IF NOT EXISTS public.cat_etapas_procesales (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_tipo_asunto BIGINT NOT NULL REFERENCES public.cat_tipos_asunto(id),
  codigo TEXT NOT NULL, nombre TEXT NOT NULL, orden INTEGER NOT NULL,
  es_terminal BOOLEAN NOT NULL DEFAULT false,
  activo BOOLEAN NOT NULL DEFAULT true,
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  creado_por TEXT NOT NULL, actualizado_por TEXT NOT NULL,
  CONSTRAINT cat_etapas_codigo_tipo_uq UNIQUE (codigo, id_tipo_asunto)
);
COMMENT ON TABLE public.cat_etapas_procesales IS 'Etapas procesales por tipo de asunto. Fase 2 v2.2.';

-- ================================================================
-- A4. Semillas de catálogos (idempotente)
-- ================================================================
INSERT INTO public.cat_tipos_asunto (codigo, nombre, descripcion, creado_por, actualizado_por) VALUES
  ('DEMANDA_CIVIL',      'Demanda civil',            'Demanda ante juzgado civil',              'jorge.mendoza@sozu.com', 'jorge.mendoza@sozu.com'),
  ('DEMANDA_MERCANTIL',  'Demanda mercantil',        'Demanda ante juzgado mercantil',          'jorge.mendoza@sozu.com', 'jorge.mendoza@sozu.com'),
  ('QUEJA_PROFECO',      'Queja Profeco',            'Queja ante Profeco como proveedor',       'jorge.mendoza@sozu.com', 'jorge.mendoza@sozu.com'),
  ('AMPARO',             'Amparo',                   'Juicio de amparo',                        'jorge.mendoza@sozu.com', 'jorge.mendoza@sozu.com'),
  ('RECURSO_APELACION',  'Recurso de apelación',     'Apelación de resolución primera instancia','jorge.mendoza@sozu.com', 'jorge.mendoza@sozu.com'),
  ('INCIDENTE_PROCESAL', 'Incidente procesal',       'Incidente dentro de un juicio',           'jorge.mendoza@sozu.com', 'jorge.mendoza@sozu.com'),
  ('MEDIACION',          'Mediación / conciliación', 'Procedimiento de mediación extrajudicial', 'jorge.mendoza@sozu.com', 'jorge.mendoza@sozu.com')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.cat_niveles_riesgo (codigo, nombre, descripcion, orden, creado_por, actualizado_por) VALUES
  ('BAJO',    'Bajo',    'Probabilidad de condena mínima.',      1, 'jorge.mendoza@sozu.com', 'jorge.mendoza@sozu.com'),
  ('MEDIO',   'Medio',   'Posible acuerdo o condena parcial.',   2, 'jorge.mendoza@sozu.com', 'jorge.mendoza@sozu.com'),
  ('ALTO',    'Alto',    'Alta probabilidad de condena.',        3, 'jorge.mendoza@sozu.com', 'jorge.mendoza@sozu.com'),
  ('CRITICO', 'Crítico', 'Impacto severo. Supervisión directa.', 4, 'jorge.mendoza@sozu.com', 'jorge.mendoza@sozu.com')
ON CONFLICT (codigo) DO NOTHING;

-- Etapas DEMANDA_CIVIL y DEMANDA_MERCANTIL (12 etapas idénticas)
INSERT INTO public.cat_etapas_procesales (id_tipo_asunto, codigo, nombre, orden, es_terminal, creado_por, actualizado_por)
SELECT ta.id, e.codigo, e.nombre, e.orden, e.terminal, 'jorge.mendoza@sozu.com', 'jorge.mendoza@sozu.com'
FROM public.cat_tipos_asunto ta
CROSS JOIN (VALUES
  ('PRESENTACION','Presentación',1,false), ('ADMISION','Admisión',2,false),
  ('EMPLAZAMIENTO','Emplazamiento',3,false), ('CONTESTACION','Contestación',4,false),
  ('PERIODO_PRUEBAS','Período de pruebas',5,false), ('AUDIENCIA_DESAHOGO','Audiencia de desahogo',6,false),
  ('ALEGATOS','Alegatos',7,false), ('SENTENCIA_PRIMERA','Sentencia primera inst.',8,false),
  ('RECURSO','Recurso de apelación',9,false), ('SENTENCIA_DEFINITIVA','Sentencia definitiva',10,false),
  ('EJECUCION','Ejecución de sentencia',11,false), ('CERRADO','Cerrado',12,true)
) AS e(codigo, nombre, orden, terminal)
WHERE ta.codigo IN ('DEMANDA_CIVIL','DEMANDA_MERCANTIL')
ON CONFLICT (codigo, id_tipo_asunto) DO NOTHING;

-- Etapas QUEJA_PROFECO (8 etapas)
INSERT INTO public.cat_etapas_procesales (id_tipo_asunto, codigo, nombre, orden, es_terminal, creado_por, actualizado_por)
SELECT ta.id, e.codigo, e.nombre, e.orden, e.terminal, 'jorge.mendoza@sozu.com', 'jorge.mendoza@sozu.com'
FROM public.cat_tipos_asunto ta
CROSS JOIN (VALUES
  ('QUEJA_RECIBIDA','Queja recibida',1,false), ('NOTIFICACION_PROVEEDOR','Notificación al proveedor',2,false),
  ('AUDIENCIA_CONCILIATORIA','Audiencia conciliatoria',3,false), ('ACUERDO_ALCANZADO','Acuerdo alcanzado',4,false),
  ('CUMPLIMIENTO_ACUERDO','Cumplimiento del acuerdo',5,false), ('SIN_ACUERDO_PROC_ADMIN','Sin acuerdo — Proc. admin.',6,false),
  ('RESOLUCION_PROFECO','Resolución Profeco',7,false), ('CERRADO_PROFECO','Cerrado',8,true)
) AS e(codigo, nombre, orden, terminal)
WHERE ta.codigo = 'QUEJA_PROFECO'
ON CONFLICT (codigo, id_tipo_asunto) DO NOTHING;

-- Etapas genéricas para AMPARO, RECURSO_APELACION, INCIDENTE_PROCESAL, MEDIACION (4 c/u)
INSERT INTO public.cat_etapas_procesales (id_tipo_asunto, codigo, nombre, orden, es_terminal, creado_por, actualizado_por)
SELECT ta.id, e.codigo, e.nombre, e.orden, e.terminal, 'jorge.mendoza@sozu.com', 'jorge.mendoza@sozu.com'
FROM public.cat_tipos_asunto ta
CROSS JOIN (VALUES
  ('INICIO','Inicio',1,false), ('EN_TRAMITE','En trámite',2,false),
  ('RESOLUCION','Resolución',3,false), ('CERRADO_GEN','Cerrado',4,true)
) AS e(codigo, nombre, orden, terminal)
WHERE ta.codigo IN ('AMPARO','RECURSO_APELACION','INCIDENTE_PROCESAL','MEDIACION')
ON CONFLICT (codigo, id_tipo_asunto) DO NOTHING;

-- ================================================================
-- A5. Tablas núcleo (9)
-- ================================================================
CREATE TABLE IF NOT EXISTS public.contrapartes (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tipo TEXT NOT NULL CHECK (tipo IN ('COMPRADOR','CONDOMINO','BANCO','PROVEEDOR','MUNICIPIO','PROFECO','TERCERO')),
  tipo_persona TEXT NOT NULL CHECK (tipo_persona IN ('FISICA','MORAL')),
  nombre TEXT NOT NULL, representante TEXT NULL, rfc TEXT NULL, email TEXT NULL, telefono TEXT NULL,
  id_entidad_relacionada BIGINT NULL REFERENCES public.entidades_relacionadas(id),
  id_cliente INTEGER NULL REFERENCES public.personas(id),
  notas TEXT NULL, activo BOOLEAN NOT NULL DEFAULT true,
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now(), fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  creado_por TEXT NOT NULL, actualizado_por TEXT NOT NULL
);
COMMENT ON TABLE public.contrapartes IS 'Entidad reutilizable de contrapartes procesales. Fase 2 v2.2.';

CREATE TABLE IF NOT EXISTS public.expedientes_juridicos (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_propiedad BIGINT NOT NULL REFERENCES public.propiedades(id),
  id_proyecto INTEGER NOT NULL REFERENCES public.proyectos(id),
  folio_visible TEXT NOT NULL DEFAULT public.gen_folio_expediente(),
  estado TEXT NOT NULL DEFAULT 'ACTIVO' CHECK (estado IN ('ACTIVO','CERRADO','ARCHIVADO')),
  prioridad TEXT NOT NULL DEFAULT 'NORMAL' CHECK (prioridad IN ('NORMAL','URGENTE','CRITICO')),
  fecha_apertura DATE NOT NULL DEFAULT CURRENT_DATE, fecha_cierre DATE NULL,
  observaciones_generales TEXT NULL, activo BOOLEAN NOT NULL DEFAULT true,
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now(), fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  creado_por TEXT NOT NULL, actualizado_por TEXT NOT NULL,
  CONSTRAINT expedientes_juridicos_folio_uq UNIQUE (folio_visible),
  CONSTRAINT expedientes_juridicos_cierre_ck CHECK ((estado = 'CERRADO' AND fecha_cierre IS NOT NULL) OR (estado != 'CERRADO'))
);
COMMENT ON TABLE public.expedientes_juridicos IS 'Expediente jurídico maestro. Anchor: propiedad + proyecto. Fase 2 v2.2.';

CREATE TABLE IF NOT EXISTS public.asuntos_juridicos (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_expediente BIGINT NOT NULL REFERENCES public.expedientes_juridicos(id),
  folio_visible TEXT NOT NULL DEFAULT public.gen_folio_asunto(),
  id_tipo_asunto BIGINT NOT NULL REFERENCES public.cat_tipos_asunto(id),
  origen TEXT NOT NULL CHECK (origen IN ('SOZU_ACTORA','COMPRADOR_ACTOR','PROFECO')),
  posicion_sozu TEXT NOT NULL CHECK (posicion_sozu IN ('ACTOR','DEMANDADO','PROMOVENTE','PROVEEDOR')),
  id_contraparte BIGINT NULL REFERENCES public.contrapartes(id),
  id_etapa_actual BIGINT NULL REFERENCES public.cat_etapas_procesales(id),
  id_nivel_riesgo_actual BIGINT NULL REFERENCES public.cat_niveles_riesgo(id),
  numero_asunto_externo TEXT NULL, autoridad TEXT NULL,
  fecha_presentacion DATE NULL, fecha_emplazamiento DATE NULL, fecha_limite_contestacion DATE NULL,
  monto_reclamado NUMERIC(15,2) NULL, resultado_esperado TEXT NULL,
  id_abogado_responsable BIGINT NULL REFERENCES public.perfiles_juridicos(id),
  observaciones TEXT NULL, activo BOOLEAN NOT NULL DEFAULT true,
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now(), fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  creado_por TEXT NOT NULL, actualizado_por TEXT NOT NULL,
  CONSTRAINT asuntos_juridicos_folio_uq UNIQUE (folio_visible)
);
COMMENT ON TABLE public.asuntos_juridicos IS 'Asunto procesal individual. N asuntos por expediente. Fase 2 v2.2.';

CREATE TABLE IF NOT EXISTS public.asuntos_detalle_demanda (
  id_asunto BIGINT PRIMARY KEY REFERENCES public.asuntos_juridicos(id),
  motivo TEXT NULL, numero_contrato TEXT NULL, monto_demandado NUMERIC(15,2) NULL,
  quien_recibio_emplazamiento TEXT NULL,
  forma_notificacion TEXT NULL CHECK (forma_notificacion IN ('personal','correo','estrados') OR forma_notificacion IS NULL),
  pretensiones TEXT NULL,
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now(), fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  creado_por TEXT NOT NULL, actualizado_por TEXT NOT NULL
);
COMMENT ON TABLE public.asuntos_detalle_demanda IS 'Campos específicos de demanda civil/mercantil. 1:1 con asuntos_juridicos. Fase 2 v2.2.';

CREATE TABLE IF NOT EXISTS public.profeco_expedientes (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_asunto BIGINT NOT NULL UNIQUE REFERENCES public.asuntos_juridicos(id),
  numero_expediente_profeco TEXT NULL, oficina_delegacion TEXT NULL, fecha_notificacion_profeco DATE NULL,
  motivo_queja TEXT NULL, fecha_audiencia_conciliatoria DATE NULL, propuesta_conciliacion TEXT NULL,
  resultado_audiencia TEXT NULL CHECK (resultado_audiencia IN ('ACUERDO','SIN_ACUERDO','APLAZADA') OR resultado_audiencia IS NULL),
  acuerdo_alcanzado BOOLEAN NULL, detalle_acuerdo TEXT NULL, fecha_cierre_profeco DATE NULL,
  activo BOOLEAN NOT NULL DEFAULT true,
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now(), fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  creado_por TEXT NOT NULL, actualizado_por TEXT NOT NULL
);
COMMENT ON TABLE public.profeco_expedientes IS 'Datos específicos de queja Profeco. 1:1 con asuntos_juridicos. Fase 2 v2.2.';

-- Bitácora INMUTABLE (sin fecha_actualizacion ni actualizado_por, sin UPDATE/DELETE)
CREATE TABLE IF NOT EXISTS public.actuaciones_procesales (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_asunto BIGINT NOT NULL REFERENCES public.asuntos_juridicos(id) ON DELETE CASCADE,
  tipo_actuacion TEXT NOT NULL CHECK (tipo_actuacion IN ('NOTIFICACION','CONTESTACION','AUDIENCIA','PRUEBA','RECURSO','RESOLUCION','CAMBIO_ETAPA','CORRECCION','APERTURA','OTRO')),
  origen TEXT NOT NULL CHECK (origen IN ('INTERNO','EXTERNO','JUZGADO','PROFECO','CLIENTE')),
  tipo_fuente TEXT NOT NULL DEFAULT 'MANUAL' CHECK (tipo_fuente IN ('MANUAL','IMPORTADA','IA')),
  etapa_al_momento BIGINT NULL REFERENCES public.cat_etapas_procesales(id),
  fecha_actuacion DATE NOT NULL, descripcion TEXT NOT NULL, resultado TEXT NULL,
  id_documento BIGINT NULL REFERENCES public.app_juridico_documentos(id),
  creado_por TEXT NOT NULL, fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.actuaciones_procesales IS 'Bitácora inmutable de actuaciones. Sin UPDATE ni DELETE. Fase 2 v2.2.';

CREATE TABLE IF NOT EXISTS public.estrategias_juridicas (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_asunto BIGINT NOT NULL REFERENCES public.asuntos_juridicos(id),
  numero_version INTEGER NOT NULL DEFAULT 1, contenido TEXT NOT NULL,
  estado TEXT NOT NULL DEFAULT 'BORRADOR' CHECK (estado IN ('BORRADOR','PROPUESTA','APROBADA','DESCARTADA')),
  aprobado_por TEXT NULL, fecha_aprobacion DATE NULL, comentarios TEXT NULL,
  es_vigente BOOLEAN NOT NULL DEFAULT true,
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now(), fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  creado_por TEXT NOT NULL, actualizado_por TEXT NOT NULL,
  CONSTRAINT estrategia_aprobacion_ck CHECK ((estado = 'APROBADA' AND aprobado_por IS NOT NULL) OR (estado != 'APROBADA'))
);
COMMENT ON TABLE public.estrategias_juridicas IS 'Estrategia jurídica versionable. Fase 2 v2.2.';

-- Historial de nivel de riesgo: INMUTABLE
CREATE TABLE IF NOT EXISTS public.historial_riesgo_asunto (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_asunto BIGINT NOT NULL REFERENCES public.asuntos_juridicos(id),
  id_nivel_riesgo BIGINT NOT NULL REFERENCES public.cat_niveles_riesgo(id),
  motivo TEXT NULL, evaluado_por TEXT NOT NULL,
  fecha_evaluacion DATE NOT NULL DEFAULT CURRENT_DATE, fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.historial_riesgo_asunto IS 'Historial inmutable de evaluaciones de riesgo. Fase 2 v2.2.';

-- Historial de asignaciones de abogado: INMUTABLE
CREATE TABLE IF NOT EXISTS public.historial_asignaciones_juridicas (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_asunto BIGINT NOT NULL REFERENCES public.asuntos_juridicos(id),
  id_abogado_anterior BIGINT NULL REFERENCES public.perfiles_juridicos(id),
  id_abogado_nuevo BIGINT NOT NULL REFERENCES public.perfiles_juridicos(id),
  fecha_asignacion DATE NOT NULL DEFAULT CURRENT_DATE, motivo TEXT NULL,
  asignado_por TEXT NOT NULL, fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.historial_asignaciones_juridicas IS 'Historial inmutable de asignaciones de responsable. Fase 2 v2.2.';

-- ================================================================
-- A6. Constraints parciales de unicidad
-- ================================================================
CREATE UNIQUE INDEX IF NOT EXISTS uix_expediente_activo_por_propiedad
  ON public.expedientes_juridicos (id_propiedad) WHERE estado = 'ACTIVO';
CREATE UNIQUE INDEX IF NOT EXISTS uix_estrategia_vigente_por_asunto
  ON public.estrategias_juridicas (id_asunto) WHERE es_vigente = true;

-- ================================================================
-- A7. Índices
-- ================================================================
CREATE INDEX IF NOT EXISTS idx_exp_jur_propiedad ON public.expedientes_juridicos (id_propiedad);
CREATE INDEX IF NOT EXISTS idx_exp_jur_proyecto  ON public.expedientes_juridicos (id_proyecto);
CREATE INDEX IF NOT EXISTS idx_exp_jur_estado    ON public.expedientes_juridicos (estado);
CREATE INDEX IF NOT EXISTS idx_asu_jur_expediente   ON public.asuntos_juridicos (id_expediente);
CREATE INDEX IF NOT EXISTS idx_asu_jur_tipo_asunto  ON public.asuntos_juridicos (id_tipo_asunto);
CREATE INDEX IF NOT EXISTS idx_asu_jur_abogado      ON public.asuntos_juridicos (id_abogado_responsable);
CREATE INDEX IF NOT EXISTS idx_asu_jur_nivel_riesgo ON public.asuntos_juridicos (id_nivel_riesgo_actual);
CREATE INDEX IF NOT EXISTS idx_asu_jur_fecha_limite ON public.asuntos_juridicos (fecha_limite_contestacion) WHERE fecha_limite_contestacion IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_act_proc_asunto      ON public.actuaciones_procesales (id_asunto);
CREATE INDEX IF NOT EXISTS idx_act_proc_fecha       ON public.actuaciones_procesales (fecha_actuacion);
CREATE INDEX IF NOT EXISTS idx_act_proc_tipo_fuente ON public.actuaciones_procesales (tipo_fuente);
CREATE INDEX IF NOT EXISTS idx_est_jur_asunto ON public.estrategias_juridicas (id_asunto);
CREATE INDEX IF NOT EXISTS idx_est_jur_estado ON public.estrategias_juridicas (estado);
CREATE INDEX IF NOT EXISTS idx_hist_riesgo_asunto ON public.historial_riesgo_asunto (id_asunto);
CREATE INDEX IF NOT EXISTS idx_hist_asig_asunto   ON public.historial_asignaciones_juridicas (id_asunto);
CREATE INDEX IF NOT EXISTS idx_contrapartes_entidad ON public.contrapartes (id_entidad_relacionada) WHERE id_entidad_relacionada IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_contrapartes_cliente ON public.contrapartes (id_cliente) WHERE id_cliente IS NOT NULL;

-- ================================================================
-- A8. Triggers de auditoría (solo tablas MUTABLES). set_fecha_actualizacion() ya existe.
-- ================================================================
CREATE OR REPLACE TRIGGER trg_cat_tipos_asunto_upd       BEFORE UPDATE ON public.cat_tipos_asunto       FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();
CREATE OR REPLACE TRIGGER trg_cat_niveles_riesgo_upd     BEFORE UPDATE ON public.cat_niveles_riesgo     FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();
CREATE OR REPLACE TRIGGER trg_cat_etapas_procesales_upd  BEFORE UPDATE ON public.cat_etapas_procesales  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();
CREATE OR REPLACE TRIGGER trg_contrapartes_upd           BEFORE UPDATE ON public.contrapartes           FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();
CREATE OR REPLACE TRIGGER trg_expedientes_juridicos_upd  BEFORE UPDATE ON public.expedientes_juridicos  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();
CREATE OR REPLACE TRIGGER trg_asuntos_juridicos_upd      BEFORE UPDATE ON public.asuntos_juridicos      FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();
CREATE OR REPLACE TRIGGER trg_asuntos_detalle_demanda_upd BEFORE UPDATE ON public.asuntos_detalle_demanda FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();
CREATE OR REPLACE TRIGGER trg_profeco_expedientes_upd    BEFORE UPDATE ON public.profeco_expedientes    FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();
CREATE OR REPLACE TRIGGER trg_estrategias_juridicas_upd  BEFORE UPDATE ON public.estrategias_juridicas  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();
-- actuaciones_procesales, historial_riesgo_asunto, historial_asignaciones_juridicas: INMUTABLES — sin trigger.

-- ================================================================
-- A9. ALTER de 3 tablas existentes (columnas de enlace nullable + FKs guardadas)
-- ================================================================
ALTER TABLE public.demandas
  ADD COLUMN IF NOT EXISTS id_expediente BIGINT NULL,
  ADD COLUMN IF NOT EXISTS id_asunto     BIGINT NULL;
ALTER TABLE public.app_juridico_documentos ADD COLUMN IF NOT EXISTS id_asunto BIGINT NULL;
ALTER TABLE public.asignaciones_juridico   ADD COLUMN IF NOT EXISTS id_expediente BIGINT NULL;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'demandas_id_expediente_fk' AND conrelid = 'public.demandas'::regclass) THEN
    ALTER TABLE public.demandas ADD CONSTRAINT demandas_id_expediente_fk FOREIGN KEY (id_expediente) REFERENCES public.expedientes_juridicos(id);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'demandas_id_asunto_fk' AND conrelid = 'public.demandas'::regclass) THEN
    ALTER TABLE public.demandas ADD CONSTRAINT demandas_id_asunto_fk FOREIGN KEY (id_asunto) REFERENCES public.asuntos_juridicos(id);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'app_juridico_documentos_id_asunto_fk' AND conrelid = 'public.app_juridico_documentos'::regclass) THEN
    ALTER TABLE public.app_juridico_documentos ADD CONSTRAINT app_juridico_documentos_id_asunto_fk FOREIGN KEY (id_asunto) REFERENCES public.asuntos_juridicos(id);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'asignaciones_juridico_id_expediente_fk' AND conrelid = 'public.asignaciones_juridico'::regclass) THEN
    ALTER TABLE public.asignaciones_juridico ADD CONSTRAINT asignaciones_juridico_id_expediente_fk FOREIGN KEY (id_expediente) REFERENCES public.expedientes_juridicos(id);
  END IF;
END $$;

-- ================================================================
-- A10. Habilitar RLS (políticas en la migración siguiente)
-- ================================================================
ALTER TABLE public.cat_tipos_asunto                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cat_niveles_riesgo              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cat_etapas_procesales           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contrapartes                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expedientes_juridicos           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.asuntos_juridicos               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.asuntos_detalle_demanda         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profeco_expedientes             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.actuaciones_procesales          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.estrategias_juridicas           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.historial_riesgo_asunto         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.historial_asignaciones_juridicas ENABLE ROW LEVEL SECURITY;
