-- Módulo de Entregas de Departamentos
-- Tablas: entregas, checklist_categorias, checklist_items,
--         evidencia, observaciones, firmas
-- Reutiliza set_fecha_actualizacion() creada en 20260519000001.

-- ── 2. Tabla principal de entregas ───────────────────────────────────────────
CREATE TABLE public.entregas (
  id                   BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_propiedad         INTEGER      NOT NULL REFERENCES public.propiedades(id),
  id_cuenta_cobranza   BIGINT                REFERENCES public.cuentas_cobranza(id),
  id_proyecto          INTEGER               REFERENCES public.proyectos(id),
  estatus              TEXT         NOT NULL DEFAULT 'PROGRAMADA'
                         CHECK (estatus IN (
                           'PROGRAMADA','EN_PROCESO',
                           'ENTREGADA','CON_OBSERVACIONES','REPROGRAMADA'
                         )),
  fecha_programada     DATE,
  fecha_entrega        DATE,
  entregado_por        TEXT,
  punto_reunion        TEXT,
  telefono_contacto    TEXT,
  muebles_daiku_estatus TEXT        NOT NULL DEFAULT 'NO_APLICA'
                         CHECK (muebles_daiku_estatus IN (
                           'NO_APLICA','PENDIENTE','EN_INSTALACION','COMPLETADO'
                         )),
  activo               BOOLEAN      NOT NULL DEFAULT true,
  fecha_creacion       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  fecha_actualizacion  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Una sola entrega activa por propiedad
CREATE UNIQUE INDEX entregas_propiedad_uidx
  ON public.entregas(id_propiedad) WHERE activo = true;

CREATE INDEX idx_entregas_cuenta   ON public.entregas(id_cuenta_cobranza);
CREATE INDEX idx_entregas_proyecto ON public.entregas(id_proyecto);
CREATE INDEX idx_entregas_estatus  ON public.entregas(estatus);

-- ── 3. Checklist: categorías ──────────────────────────────────────────────────
CREATE TABLE public.entregas_checklist_categorias (
  id              BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_entrega      BIGINT      NOT NULL REFERENCES public.entregas(id) ON DELETE CASCADE,
  nombre          TEXT        NOT NULL,
  responsable     TEXT,
  cargo           TEXT,
  total_items     INTEGER     NOT NULL DEFAULT 0,
  items_completos INTEGER     NOT NULL DEFAULT 0,
  estatus         TEXT        NOT NULL DEFAULT 'PENDIENTE'
                    CHECK (estatus IN ('PENDIENTE','CON_OBSERVACION','COMPLETADO')),
  fecha_vobo      TIMESTAMPTZ,
  activo          BOOLEAN     NOT NULL DEFAULT true,
  fecha_creacion  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_entregas_cat_entrega ON public.entregas_checklist_categorias(id_entrega);

-- ── 4. Checklist: ítems ───────────────────────────────────────────────────────
CREATE TABLE public.entregas_checklist_items (
  id             BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_categoria   BIGINT      NOT NULL REFERENCES public.entregas_checklist_categorias(id) ON DELETE CASCADE,
  nombre         TEXT        NOT NULL,
  estatus        TEXT        NOT NULL DEFAULT 'PENDIENTE'
                   CHECK (estatus IN ('PENDIENTE','COMPLETADO','CON_OBSERVACION','NO_APLICA')),
  observacion    TEXT,
  activo         BOOLEAN     NOT NULL DEFAULT true,
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_entregas_items_cat ON public.entregas_checklist_items(id_categoria);

-- ── 5. Evidencias (fotos, videos, documentos) ────────────────────────────────
CREATE TABLE public.entregas_evidencia (
  id             BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_entrega     BIGINT      NOT NULL REFERENCES public.entregas(id) ON DELETE CASCADE,
  id_categoria   BIGINT               REFERENCES public.entregas_checklist_categorias(id),
  tipo           TEXT        NOT NULL CHECK (tipo IN ('FOTO','VIDEO','DOCUMENTO')),
  url            TEXT        NOT NULL,
  nombre         TEXT,
  subido_por     TEXT,
  activo         BOOLEAN     NOT NULL DEFAULT true,
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_entregas_evid_entrega  ON public.entregas_evidencia(id_entrega);
CREATE INDEX idx_entregas_evid_categoria ON public.entregas_evidencia(id_categoria);

-- ── 6. Observaciones / deficiencias ──────────────────────────────────────────
CREATE TABLE public.entregas_observaciones (
  id                   BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_entrega           BIGINT      NOT NULL REFERENCES public.entregas(id) ON DELETE CASCADE,
  descripcion          TEXT        NOT NULL,
  prioridad            TEXT        NOT NULL DEFAULT 'MEDIA'
                         CHECK (prioridad IN ('CRITICA','ALTA','MEDIA','BAJA')),
  estatus              TEXT        NOT NULL DEFAULT 'ABIERTA'
                         CHECK (estatus IN ('ABIERTA','EN_ATENCION','RESUELTA','CERRADA')),
  id_ticket_postventa  INTEGER,
  activo               BOOLEAN     NOT NULL DEFAULT true,
  fecha_creacion       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_entregas_obs_entrega  ON public.entregas_observaciones(id_entrega);
CREATE INDEX idx_entregas_obs_prioridad ON public.entregas_observaciones(prioridad);

-- ── 7. Firmas digitales del acta ──────────────────────────────────────────────
CREATE TABLE public.entregas_firmas (
  id              BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_entrega      BIGINT      NOT NULL REFERENCES public.entregas(id) ON DELETE CASCADE,
  tipo_firmante   TEXT        NOT NULL
                    CHECK (tipo_firmante IN ('CLIENTE','RESPONSABLE','TESTIGO')),
  nombre_firmante TEXT,
  firma_data_url  TEXT,
  ip_dispositivo  TEXT,
  user_agent      TEXT,
  activo          BOOLEAN     NOT NULL DEFAULT true,
  fecha_creacion  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_entregas_firmas_entrega ON public.entregas_firmas(id_entrega);

-- ── 8. Triggers fecha_actualizacion ──────────────────────────────────────────
CREATE TRIGGER entregas_updated_at
  BEFORE UPDATE ON public.entregas
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

CREATE TRIGGER entregas_obs_updated_at
  BEFORE UPDATE ON public.entregas_observaciones
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- ── 9. RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE public.entregas                      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.entregas_checklist_categorias ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.entregas_checklist_items      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.entregas_evidencia            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.entregas_observaciones        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.entregas_firmas               ENABLE ROW LEVEL SECURITY;

CREATE POLICY "entregas_select"      ON public.entregas                      FOR SELECT USING (true);
CREATE POLICY "entregas_insert"      ON public.entregas                      FOR INSERT WITH CHECK (true);
CREATE POLICY "entregas_update"      ON public.entregas                      FOR UPDATE USING (true);

CREATE POLICY "ent_cat_select"       ON public.entregas_checklist_categorias FOR SELECT USING (true);
CREATE POLICY "ent_cat_insert"       ON public.entregas_checklist_categorias FOR INSERT WITH CHECK (true);
CREATE POLICY "ent_cat_update"       ON public.entregas_checklist_categorias FOR UPDATE USING (true);

CREATE POLICY "ent_items_select"     ON public.entregas_checklist_items      FOR SELECT USING (true);
CREATE POLICY "ent_items_insert"     ON public.entregas_checklist_items      FOR INSERT WITH CHECK (true);
CREATE POLICY "ent_items_update"     ON public.entregas_checklist_items      FOR UPDATE USING (true);

CREATE POLICY "ent_evid_select"      ON public.entregas_evidencia            FOR SELECT USING (true);
CREATE POLICY "ent_evid_insert"      ON public.entregas_evidencia            FOR INSERT WITH CHECK (true);
CREATE POLICY "ent_evid_update"      ON public.entregas_evidencia            FOR UPDATE USING (true);

CREATE POLICY "ent_obs_select"       ON public.entregas_observaciones        FOR SELECT USING (true);
CREATE POLICY "ent_obs_insert"       ON public.entregas_observaciones        FOR INSERT WITH CHECK (true);
CREATE POLICY "ent_obs_update"       ON public.entregas_observaciones        FOR UPDATE USING (true);

CREATE POLICY "ent_firmas_select"    ON public.entregas_firmas               FOR SELECT USING (true);
CREATE POLICY "ent_firmas_insert"    ON public.entregas_firmas               FOR INSERT WITH CHECK (true);
CREATE POLICY "ent_firmas_update"    ON public.entregas_firmas               FOR UPDATE USING (true);
