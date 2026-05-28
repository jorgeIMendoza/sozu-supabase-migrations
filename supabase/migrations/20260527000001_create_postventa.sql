-- Módulo de Postventa — Portal Escrituración SOZU
-- Requisito: public.entregas debe existir (20260519000002_create_entregas.sql).
-- set_fecha_actualizacion() ya existe; CREATE OR REPLACE es idempotente.

-- ════════════════════════════════════════════════════════════════════════════
--  PASO 0: Función de auditoría
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.set_fecha_actualizacion()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.fecha_actualizacion = NOW();
  RETURN NEW;
END;
$$;


-- ════════════════════════════════════════════════════════════════════════════
--  PASO 1: Tipo de entidad — Personal de mantenimiento
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO public.tipos_entidad (nombre, activo)
SELECT 'Personal de mantenimiento', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.tipos_entidad WHERE nombre = 'Personal de mantenimiento'
);


-- ════════════════════════════════════════════════════════════════════════════
--  TABLA 1: postventa_categorias_garantia
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.postventa_categorias_garantia (
  id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre              TEXT        NOT NULL,
  vigencia_dias       INTEGER     NOT NULL DEFAULT 365,
  sla_critico_horas   INTEGER     NOT NULL DEFAULT 4,
  sla_media_horas     INTEGER     NOT NULL DEFAULT 24,
  sla_baja_dias       INTEGER     NOT NULL DEFAULT 5,
  aplica_a            TEXT        NOT NULL DEFAULT 'TODAS'
                        CHECK (aplica_a IN (
                          'TODAS',
                          'CON_AA',
                          'CON_DAIKU',
                          'SEGUN_FABRICANTE'
                        )),
  activo              BOOLEAN     NOT NULL DEFAULT true,
  fecha_creacion      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER postventa_categorias_garantia_updated_at
  BEFORE UPDATE ON public.postventa_categorias_garantia
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- Seed: 9 categorías base
INSERT INTO public.postventa_categorias_garantia
  (nombre, vigencia_dias, sla_critico_horas, sla_media_horas, sla_baja_dias, aplica_a)
VALUES
  ('Eléctrica',           365, 4, 24, 5, 'TODAS'),
  ('Sanitaria',           365, 4, 24, 5, 'TODAS'),
  ('Hidráulica',          365, 4, 24, 5, 'TODAS'),
  ('HVAC',                180, 4, 24, 5, 'CON_AA'),
  ('Calentador / Boiler', 180, 4, 24, 5, 'TODAS'),
  ('Acabados',             90, 4, 24, 5, 'TODAS'),
  ('Carpintería',          90, 4, 24, 5, 'TODAS'),
  ('Paquete Muebles',      90, 4, 24, 5, 'CON_DAIKU'),
  ('Electrodomésticos',   365, 4, 24, 5, 'SEGUN_FABRICANTE');


-- ════════════════════════════════════════════════════════════════════════════
--  TABLA 2: postventa_categorias_personal
--  Relaciona una categoría de garantía con el personal de mantenimiento
--  asignado para atenderla. Se usa para sugerir el responsable al crear tickets.
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.postventa_categorias_personal (
  id                              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_postventa_categoria_garantia BIGINT  NOT NULL
                                    REFERENCES public.postventa_categorias_garantia(id),
  id_persona                      INTEGER NOT NULL
                                    REFERENCES public.personas(id),
  activo                          BOOLEAN     NOT NULL DEFAULT true,
  fecha_creacion                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER postventa_categorias_personal_updated_at
  BEFORE UPDATE ON public.postventa_categorias_personal
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

CREATE INDEX postventa_categorias_personal_categoria_idx
  ON public.postventa_categorias_personal(id_postventa_categoria_garantia)
  WHERE activo = true;


-- ════════════════════════════════════════════════════════════════════════════
--  TABLA 3: postventa_garantias_unidad
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.postventa_garantias_unidad (
  id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_propiedad      INTEGER     NOT NULL REFERENCES public.propiedades(id),
  id_entrega        BIGINT      REFERENCES public.entregas(id),
  id_categoria      BIGINT      NOT NULL
                      REFERENCES public.postventa_categorias_garantia(id),
  fecha_inicio      DATE        NOT NULL,
  fecha_vencimiento DATE        NOT NULL,
  estatus           TEXT        NOT NULL DEFAULT 'VIGENTE'
                      CHECK (estatus IN ('VIGENTE','POR_VENCER','VENCIDA')),
  activo            BOOLEAN     NOT NULL DEFAULT true,
  fecha_creacion    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER postventa_garantias_unidad_updated_at
  BEFORE UPDATE ON public.postventa_garantias_unidad
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- Solo una garantía activa por (propiedad, categoría)
CREATE UNIQUE INDEX postventa_garantias_propiedad_categoria_uidx
  ON public.postventa_garantias_unidad(id_propiedad, id_categoria)
  WHERE activo = true;


-- ════════════════════════════════════════════════════════════════════════════
--  TABLA 4: postventa_tickets
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.postventa_tickets (
  id    BIGINT GENERATED ALWAYS AS IDENTITY (START WITH 2031) PRIMARY KEY,

  id_propiedad                      INTEGER     NOT NULL REFERENCES public.propiedades(id),
  id_proyecto                       INTEGER     REFERENCES public.proyectos(id),
  id_cuenta_cobranza                BIGINT      REFERENCES public.cuentas_cobranza(id),
  id_entrega                        BIGINT      REFERENCES public.entregas(id),

  id_postventa_categoria_garantia   BIGINT      NOT NULL
                                      REFERENCES public.postventa_categorias_garantia(id),
  subcategoria                      TEXT        NOT NULL,
  descripcion                       TEXT        NOT NULL,

  canal_recepcion                   TEXT        NOT NULL DEFAULT 'INTERNO'
                                      CHECK (canal_recepcion IN (
                                        'PORTAL_CLIENTE',
                                        'WHATSAPP',
                                        'TELEFONO',
                                        'INTERNO',
                                        'OBSERVACION_ENTREGA'
                                      )),

  prioridad                         TEXT        NOT NULL DEFAULT 'MEDIA'
                                      CHECK (prioridad IN ('CRITICA','ALTA','MEDIA','BAJA')),

  estatus                           TEXT        NOT NULL DEFAULT 'NUEVO'
                                      CHECK (estatus IN (
                                        'NUEVO',
                                        'ASIGNADO',
                                        'EN_DIAGNOSTICO',
                                        'EN_REPARACION',
                                        'PENDIENTE_CLIENTE',
                                        'PENDIENTE_PROVEEDOR',
                                        'RESUELTO',
                                        'CERRADO',
                                        'REABIERTO'
                                      )),

  sla_horas                         INTEGER,
  fecha_limite_sla                  TIMESTAMPTZ,
  sla_cumplido                      BOOLEAN,

  diagnostico                       TEXT,
  causa_probable                    TEXT,
  solucion_propuesta                TEXT,

  descripcion_reparacion            TEXT,
  piezas_reemplazadas               TEXT,
  comentario_tecnico                TEXT,

  fecha_visita                      TIMESTAMPTZ,
  fecha_reparacion                  DATE,
  fecha_confirmacion_cliente        TIMESTAMPTZ,

  calificacion_cliente              INTEGER CHECK (calificacion_cliente BETWEEN 1 AND 5),
  comentario_cliente                TEXT,

  id_ticket_entrega                 BIGINT,

  activo                            BOOLEAN     NOT NULL DEFAULT true,
  fecha_creacion                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER postventa_tickets_updated_at
  BEFORE UPDATE ON public.postventa_tickets
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

CREATE INDEX postventa_tickets_propiedad_idx
  ON public.postventa_tickets(id_propiedad);

CREATE INDEX postventa_tickets_estatus_idx
  ON public.postventa_tickets(estatus)
  WHERE activo = true;

CREATE INDEX postventa_tickets_prioridad_idx
  ON public.postventa_tickets(prioridad)
  WHERE activo = true;

CREATE INDEX postventa_tickets_sla_idx
  ON public.postventa_tickets(fecha_limite_sla)
  WHERE sla_cumplido IS NOT TRUE AND activo = true;


-- ════════════════════════════════════════════════════════════════════════════
--  TABLA 5: postventa_evidencias
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.postventa_evidencias (
  id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_postventa_ticket BIGINT  NOT NULL
                        REFERENCES public.postventa_tickets(id) ON DELETE CASCADE,
  tipo_evidencia      TEXT    NOT NULL
                        CHECK (tipo_evidencia IN ('INICIAL','REPARACION')),
  tipo_archivo        TEXT    NOT NULL DEFAULT 'FOTO'
                        CHECK (tipo_archivo IN ('FOTO','VIDEO','DOCUMENTO')),
  url                 TEXT    NOT NULL,
  nombre              TEXT,
  descripcion         TEXT,
  subido_por          TEXT,
  activo              BOOLEAN     NOT NULL DEFAULT true,
  fecha_creacion      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER postventa_evidencias_updated_at
  BEFORE UPDATE ON public.postventa_evidencias
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

CREATE INDEX postventa_evidencias_ticket_idx
  ON public.postventa_evidencias(id_postventa_ticket)
  WHERE activo = true;



-- ════════════════════════════════════════════════════════════════════════════
--  TABLA 6: postventa_log_actividades  (INSERT-only — audit trail)
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.postventa_log_actividades (
  id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_postventa_ticket BIGINT  NOT NULL
                        REFERENCES public.postventa_tickets(id) ON DELETE CASCADE,
  tipo_evento         TEXT    NOT NULL
                        CHECK (tipo_evento IN (
                          'CREACION',
                          'ASIGNACION',
                          'CAMBIO_ESTATUS',
                          'EVIDENCIA_INICIAL',
                          'EVIDENCIA_REPARACION',
                          'DIAGNOSTICO',
                          'VISITA',
                          'REPARACION',
                          'CONFIRMACION_CLIENTE',
                          'RECHAZO_CLIENTE',
                          'CIERRE',
                          'REAPERTURA',
                          'ESCALAMIENTO',
                          'NOTA',
                          'SLA_VENCIDO'
                        )),
  descripcion         TEXT    NOT NULL,
  creado_por          TEXT,
  metadata            JSONB,
  activo              BOOLEAN     NOT NULL DEFAULT true,
  fecha_creacion      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER postventa_log_actividades_updated_at
  BEFORE UPDATE ON public.postventa_log_actividades
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

CREATE INDEX postventa_log_actividades_ticket_idx
  ON public.postventa_log_actividades(id_postventa_ticket);


-- ════════════════════════════════════════════════════════════════════════════
--  TABLA 7: postventa_comentarios
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.postventa_comentarios (
  id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_postventa_ticket BIGINT  NOT NULL
                        REFERENCES public.postventa_tickets(id) ON DELETE CASCADE,
  comentario          TEXT    NOT NULL,
  tipo                TEXT    NOT NULL DEFAULT 'INTERNO'
                        CHECK (tipo IN ('INTERNO','CLIENTE','PROVEEDOR')),
  creado_por          TEXT,
  activo              BOOLEAN     NOT NULL DEFAULT true,
  fecha_creacion      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER postventa_comentarios_updated_at
  BEFORE UPDATE ON public.postventa_comentarios
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

CREATE INDEX postventa_comentarios_ticket_idx
  ON public.postventa_comentarios(id_postventa_ticket)
  WHERE activo = true;


-- ════════════════════════════════════════════════════════════════════════════
--  RLS — Row Level Security
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.postventa_categorias_garantia  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.postventa_categorias_personal   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.postventa_garantias_unidad      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.postventa_tickets               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.postventa_evidencias            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.postventa_log_actividades       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.postventa_comentarios           ENABLE ROW LEVEL SECURITY;

-- postventa_categorias_garantia
CREATE POLICY "postventa_categorias_garantia_select"
  ON public.postventa_categorias_garantia FOR SELECT USING (true);
CREATE POLICY "postventa_categorias_garantia_insert"
  ON public.postventa_categorias_garantia FOR INSERT WITH CHECK (true);
CREATE POLICY "postventa_categorias_garantia_update"
  ON public.postventa_categorias_garantia FOR UPDATE USING (true);

-- postventa_categorias_personal
CREATE POLICY "postventa_categorias_personal_select"
  ON public.postventa_categorias_personal FOR SELECT USING (true);
CREATE POLICY "postventa_categorias_personal_insert"
  ON public.postventa_categorias_personal FOR INSERT WITH CHECK (true);
CREATE POLICY "postventa_categorias_personal_update"
  ON public.postventa_categorias_personal FOR UPDATE USING (true);

-- postventa_garantias_unidad
CREATE POLICY "postventa_garantias_unidad_select"
  ON public.postventa_garantias_unidad FOR SELECT USING (true);
CREATE POLICY "postventa_garantias_unidad_insert"
  ON public.postventa_garantias_unidad FOR INSERT WITH CHECK (true);
CREATE POLICY "postventa_garantias_unidad_update"
  ON public.postventa_garantias_unidad FOR UPDATE USING (true);

-- postventa_tickets
CREATE POLICY "postventa_tickets_select"
  ON public.postventa_tickets FOR SELECT USING (true);
CREATE POLICY "postventa_tickets_insert"
  ON public.postventa_tickets FOR INSERT WITH CHECK (true);
CREATE POLICY "postventa_tickets_update"
  ON public.postventa_tickets FOR UPDATE USING (true);

-- postventa_evidencias
CREATE POLICY "postventa_evidencias_select"
  ON public.postventa_evidencias FOR SELECT USING (true);
CREATE POLICY "postventa_evidencias_insert"
  ON public.postventa_evidencias FOR INSERT WITH CHECK (true);
CREATE POLICY "postventa_evidencias_update"
  ON public.postventa_evidencias FOR UPDATE USING (true);

-- postventa_log_actividades (INSERT-only: sin política UPDATE)
CREATE POLICY "postventa_log_actividades_select"
  ON public.postventa_log_actividades FOR SELECT USING (true);
CREATE POLICY "postventa_log_actividades_insert"
  ON public.postventa_log_actividades FOR INSERT WITH CHECK (true);

-- postventa_comentarios
CREATE POLICY "postventa_comentarios_select"
  ON public.postventa_comentarios FOR SELECT USING (true);
CREATE POLICY "postventa_comentarios_insert"
  ON public.postventa_comentarios FOR INSERT WITH CHECK (true);
CREATE POLICY "postventa_comentarios_update"
  ON public.postventa_comentarios FOR UPDATE USING (true);
