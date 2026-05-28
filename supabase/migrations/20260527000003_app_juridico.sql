-- =============================================================
-- Módulo App Jurídico — DDL completo
-- Fecha: 2026-05-27
-- Fuente: Ejecuciones/ejecutar.md
-- =============================================================


-- ============================================================
-- PASO 1 — Ampliar tabla demandas con campos jurídicos
-- ============================================================

ALTER TABLE public.demandas
  ADD COLUMN IF NOT EXISTS porcentaje_penalizacion  NUMERIC(5,2)  DEFAULT 0  CHECK (porcentaje_penalizacion >= 0 AND porcentaje_penalizacion <= 20),
  ADD COLUMN IF NOT EXISTS monto_reclamado          NUMERIC(14,2),
  ADD COLUMN IF NOT EXISTS monto_negociado          NUMERIC(14,2),
  ADD COLUMN IF NOT EXISTS resultado                TEXT,
  ADD COLUMN IF NOT EXISTS fecha_proxima_audiencia  DATE,
  ADD COLUMN IF NOT EXISTS fecha_limite_respuesta   DATE,
  ADD COLUMN IF NOT EXISTS resumen_juridico         TEXT,
  ADD COLUMN IF NOT EXISTS estrategia_legal         TEXT,
  ADD COLUMN IF NOT EXISTS proxima_accion           TEXT;

COMMENT ON COLUMN public.demandas.porcentaje_penalizacion IS 'Porcentaje de penalización aplicable (0–20%). Editado por el abogado con permiso.';
COMMENT ON COLUMN public.demandas.monto_reclamado         IS 'Monto total reclamado en la demanda (MXN).';
COMMENT ON COLUMN public.demandas.monto_negociado         IS 'Monto acordado en negociación pre-juicio o acuerdo (MXN).';
COMMENT ON COLUMN public.demandas.resultado               IS 'Descripción textual del resultado o acuerdo final del caso.';
COMMENT ON COLUMN public.demandas.fecha_proxima_audiencia IS 'Fecha de la próxima audiencia programada.';
COMMENT ON COLUMN public.demandas.fecha_limite_respuesta  IS 'Fecha límite para presentar respuesta o contestación.';
COMMENT ON COLUMN public.demandas.resumen_juridico        IS 'Resumen ejecutivo del caso redactado por el abogado.';
COMMENT ON COLUMN public.demandas.estrategia_legal        IS 'Estrategia legal propuesta por el abogado responsable.';
COMMENT ON COLUMN public.demandas.proxima_accion          IS 'Siguiente acción concreta que debe realizar el abogado.';


-- ============================================================
-- PASO 2 — Tabla perfiles_juridicos (catálogo de abogados)
-- ============================================================

CREATE TABLE IF NOT EXISTS public.perfiles_juridicos (
  id                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre_completo      TEXT        NOT NULL,
  email                TEXT        NOT NULL UNIQUE,
  telefono             TEXT,
  tipo_abogado         TEXT        NOT NULL DEFAULT 'EXTERNO'
                         CHECK (tipo_abogado IN ('INTERNO','EXTERNO','DESPACHO')),
  despacho             TEXT,
  cedula_profesional   TEXT,
  especialidad         TEXT,
  estatus              TEXT        NOT NULL DEFAULT 'ACTIVO'
                         CHECK (estatus IN ('ACTIVO','INACTIVO')),
  activo               BOOLEAN     NOT NULL DEFAULT TRUE,
  fecha_creacion       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  public.perfiles_juridicos                    IS 'Catálogo de abogados (internos, externos y despachos) que gestionan casos jurídicos. Análogo a la tabla notarios.';
COMMENT ON COLUMN public.perfiles_juridicos.tipo_abogado       IS 'INTERNO = empleado SOZU, EXTERNO = abogado independiente, DESPACHO = firma jurídica.';
COMMENT ON COLUMN public.perfiles_juridicos.cedula_profesional IS 'Cédula profesional del abogado (Dirección General de Profesiones).';
COMMENT ON COLUMN public.perfiles_juridicos.email              IS 'Email del abogado. Si tiene cuenta en usuarios, debe coincidir para derivar el perfil.';

CREATE INDEX IF NOT EXISTS idx_perfiles_juridicos_email
  ON public.perfiles_juridicos(email);

CREATE INDEX IF NOT EXISTS idx_perfiles_juridicos_estatus
  ON public.perfiles_juridicos(estatus)
  WHERE activo = TRUE;


-- ============================================================
-- PASO 3 — Tabla asignaciones_juridico (abogado ↔ demanda)
-- ============================================================

CREATE TABLE IF NOT EXISTS public.asignaciones_juridico (
  id                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_demanda           BIGINT      NOT NULL REFERENCES public.demandas(id)           ON DELETE CASCADE,
  id_perfil_juridico   BIGINT      NOT NULL REFERENCES public.perfiles_juridicos(id) ON DELETE CASCADE,
  es_responsable       BOOLEAN     NOT NULL DEFAULT TRUE,
  asignado_por         TEXT        NOT NULL,
  estatus              TEXT        NOT NULL DEFAULT 'ACTIVA'
                         CHECK (estatus IN ('ACTIVA','CERRADA','REASIGNADA')),
  notas                TEXT,
  activo               BOOLEAN     NOT NULL DEFAULT TRUE,
  fecha_asignacion     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (id_demanda, id_perfil_juridico)
);

COMMENT ON TABLE  public.asignaciones_juridico               IS 'Vincula demandas con abogados. Una demanda puede tener un responsable y varios colaboradores.';
COMMENT ON COLUMN public.asignaciones_juridico.es_responsable IS 'TRUE = abogado responsable principal, FALSE = colaborador.';

CREATE INDEX IF NOT EXISTS idx_asignaciones_juridico_demanda
  ON public.asignaciones_juridico(id_demanda);

CREATE INDEX IF NOT EXISTS idx_asignaciones_juridico_perfil_activa
  ON public.asignaciones_juridico(id_perfil_juridico, estatus)
  WHERE activo = TRUE;


-- ============================================================
-- PASO 4 — Tabla app_juridico_documentos
-- ============================================================

CREATE TABLE IF NOT EXISTS public.app_juridico_documentos (
  id                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_demanda           BIGINT      NOT NULL REFERENCES public.demandas(id) ON DELETE CASCADE,
  tipo_documento       TEXT        NOT NULL DEFAULT 'OTRO'
                         CHECK (tipo_documento IN (
                           'DEMANDA','CONTESTACION','NOTIFICACION','AUDIENCIA',
                           'ACUERDO','CONVENIO','SENTENCIA','PAGO_PENALIZACION',
                           'EVIDENCIA','OTRO'
                         )),
  nombre_archivo       TEXT        NOT NULL,
  url_archivo          TEXT        NOT NULL,
  descripcion          TEXT,
  es_vigente           BOOLEAN     NOT NULL DEFAULT TRUE,
  subido_por           TEXT        NOT NULL,
  activo               BOOLEAN     NOT NULL DEFAULT TRUE,
  fecha_creacion       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  public.app_juridico_documentos                IS 'Documentos legales del proceso judicial, versionados por tipo.';
COMMENT ON COLUMN public.app_juridico_documentos.es_vigente     IS 'Solo un documento por tipo puede ser vigente a la vez.';
COMMENT ON COLUMN public.app_juridico_documentos.tipo_documento IS 'Tipo de documento legal: demanda, contestación, acuerdo, sentencia, etc.';

CREATE INDEX IF NOT EXISTS idx_app_juridico_docs_demanda
  ON public.app_juridico_documentos(id_demanda)
  WHERE activo = TRUE;


-- ============================================================
-- PASO 5 — Tabla app_juridico_audiencias
-- ============================================================

CREATE TABLE IF NOT EXISTS public.app_juridico_audiencias (
  id                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_demanda           BIGINT      NOT NULL REFERENCES public.demandas(id) ON DELETE CASCADE,
  fecha                DATE        NOT NULL,
  hora_inicio          TIME,
  hora_fin             TIME,
  lugar                TEXT,
  descripcion          TEXT,
  resultado            TEXT,
  estatus              TEXT        NOT NULL DEFAULT 'PROGRAMADA'
                         CHECK (estatus IN ('PROGRAMADA','REALIZADA','POSPUESTA','CANCELADA')),
  registrado_por       TEXT        NOT NULL,
  activo               BOOLEAN     NOT NULL DEFAULT TRUE,
  fecha_creacion       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.app_juridico_audiencias IS 'Audiencias judiciales programadas o realizadas para cada demanda.';

CREATE INDEX IF NOT EXISTS idx_app_juridico_audiencias_demanda
  ON public.app_juridico_audiencias(id_demanda, fecha)
  WHERE activo = TRUE;


-- ============================================================
-- PASO 6 — Tabla app_juridico_acuerdos
-- ============================================================

CREATE TABLE IF NOT EXISTS public.app_juridico_acuerdos (
  id                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_demanda           BIGINT      NOT NULL REFERENCES public.demandas(id) ON DELETE CASCADE,
  tipo_acuerdo         TEXT        NOT NULL DEFAULT 'CONVENIO'
                         CHECK (tipo_acuerdo IN ('CONVENIO','SENTENCIA','DESISTIMIENTO','OTRO')),
  descripcion          TEXT        NOT NULL,
  monto_acordado       NUMERIC(14,2),
  fecha_acuerdo        DATE        NOT NULL,
  fecha_vencimiento    DATE,
  firmado_por_cliente  BOOLEAN     NOT NULL DEFAULT FALSE,
  firmado_por_sozu     BOOLEAN     NOT NULL DEFAULT FALSE,
  url_documento        TEXT,
  registrado_por       TEXT        NOT NULL,
  activo               BOOLEAN     NOT NULL DEFAULT TRUE,
  fecha_creacion       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_actualizacion  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.app_juridico_acuerdos IS 'Acuerdos, convenios y sentencias derivados del proceso judicial.';

CREATE INDEX IF NOT EXISTS idx_app_juridico_acuerdos_demanda
  ON public.app_juridico_acuerdos(id_demanda)
  WHERE activo = TRUE;


-- ============================================================
-- PASO 7 — Triggers updated_at para nuevas tablas
-- Requiere que la función set_fecha_actualizacion() ya exista.
-- ============================================================

CREATE TRIGGER trg_perfiles_juridicos_updated_at
  BEFORE UPDATE ON public.perfiles_juridicos
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

CREATE TRIGGER trg_asignaciones_juridico_updated_at
  BEFORE UPDATE ON public.asignaciones_juridico
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

CREATE TRIGGER trg_app_juridico_documentos_updated_at
  BEFORE UPDATE ON public.app_juridico_documentos
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

CREATE TRIGGER trg_app_juridico_audiencias_updated_at
  BEFORE UPDATE ON public.app_juridico_audiencias
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

CREATE TRIGGER trg_app_juridico_acuerdos_updated_at
  BEFORE UPDATE ON public.app_juridico_acuerdos
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();


-- ============================================================
-- PASO 8 — RLS (Row Level Security)
-- ============================================================

ALTER TABLE public.perfiles_juridicos        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.asignaciones_juridico     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_juridico_documentos   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_juridico_audiencias   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_juridico_acuerdos     ENABLE ROW LEVEL SECURITY;

CREATE POLICY "abogado_lee_sus_asignaciones"
  ON public.asignaciones_juridico FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid() AND u.rol_id <= 2 AND u.activo = TRUE
    )
    OR
    EXISTS (
      SELECT 1
      FROM public.perfiles_juridicos p
      JOIN public.usuarios u ON u.email = p.email
      WHERE u.auth_user_id = auth.uid()
        AND p.id = asignaciones_juridico.id_perfil_juridico
        AND u.activo = TRUE
    )
  );

CREATE POLICY "todos_leen_perfiles_juridicos_activos"
  ON public.perfiles_juridicos FOR SELECT
  TO authenticated
  USING (activo = TRUE);

CREATE POLICY "abogado_lee_sus_documentos"
  ON public.app_juridico_documentos FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.asignaciones_juridico a
      JOIN public.perfiles_juridicos p ON p.id = a.id_perfil_juridico
      JOIN public.usuarios u ON u.email = p.email
      WHERE u.auth_user_id = auth.uid()
        AND a.id_demanda = app_juridico_documentos.id_demanda
        AND a.estatus = 'ACTIVA'
        AND u.activo = TRUE
    )
    OR
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid() AND u.rol_id <= 2 AND u.activo = TRUE
    )
  );

CREATE POLICY "abogado_lee_sus_audiencias"
  ON public.app_juridico_audiencias FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.asignaciones_juridico a
      JOIN public.perfiles_juridicos p ON p.id = a.id_perfil_juridico
      JOIN public.usuarios u ON u.email = p.email
      WHERE u.auth_user_id = auth.uid()
        AND a.id_demanda = app_juridico_audiencias.id_demanda
        AND u.activo = TRUE
    )
    OR EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid() AND u.rol_id <= 2 AND u.activo = TRUE
    )
  );

CREATE POLICY "abogado_lee_sus_acuerdos"
  ON public.app_juridico_acuerdos FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.asignaciones_juridico a
      JOIN public.perfiles_juridicos p ON p.id = a.id_perfil_juridico
      JOIN public.usuarios u ON u.email = p.email
      WHERE u.auth_user_id = auth.uid()
        AND a.id_demanda = app_juridico_acuerdos.id_demanda
        AND u.activo = TRUE
    )
    OR EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid() AND u.rol_id <= 2 AND u.activo = TRUE
    )
  );


-- ============================================================
-- PASO 9 — Nuevo rol "Jurídico"
-- Ajusta los flags según los permisos que deba tener en la UI.
-- ============================================================

INSERT INTO public.roles
  (nombre, activo, ver_todos_prospectos_compradores, ver_todos_proyectos_propiedades,
   ver_filtros_avanzados_eliminados, ver_todos_duenos, es_rol_interno, configurar_citas)
VALUES
  ('Jurídico', TRUE, FALSE, FALSE, FALSE, FALSE, TRUE, FALSE);


-- ============================================================
-- PASO 10a — Agregar id_notario a usuarios (si no existe)
-- Columna añadida en prod por modulo_app_notaria; se garantiza
-- aquí con IF NOT EXISTS para que dev/localhost no falle.
-- ============================================================

ALTER TABLE public.usuarios
  ADD COLUMN IF NOT EXISTS id_notario INTEGER
    REFERENCES public.notarios(id)
    ON DELETE SET NULL;

COMMENT ON COLUMN public.usuarios.id_notario IS
  'FK hacia notarios. Vincula el usuario con su perfil de notario. NULL para todos los demás roles.';

CREATE INDEX IF NOT EXISTS idx_usuarios_id_notario
  ON public.usuarios(id_notario)
  WHERE id_notario IS NOT NULL;


-- ============================================================
-- PASO 10b — Actualizar get_current_user_profile
-- El perfil jurídico se deriva por email (sin FK en usuarios).
-- ver_todos_prospectos_compradores y ver_filtros_avanzados_eliminados
-- se leen de roles (fuente canónica en el baseline).
-- ============================================================

DROP FUNCTION IF EXISTS public.get_current_user_profile();

CREATE FUNCTION public.get_current_user_profile()
RETURNS TABLE(
  email                            TEXT,
  nombre                           TEXT,
  rol_id                           INTEGER,
  rol_nombre                       TEXT,
  debe_cambiar_password            BOOLEAN,
  id_persona                       INTEGER,
  activo                           BOOLEAN,
  ver_todos_prospectos_compradores BOOLEAN,
  ver_filtros_avanzados_eliminados BOOLEAN,
  id_notario                       INTEGER,
  notaria_nombre                   TEXT,
  id_perfil_juridico               BIGINT,
  perfil_juridico_nombre           TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    u.email::TEXT,
    u.nombre::TEXT,
    u.rol_id::INTEGER,
    r.nombre::TEXT                          AS rol_nombre,
    u.debe_cambiar_password::BOOLEAN,
    u.id_persona::INTEGER,
    u.activo::BOOLEAN,
    COALESCE(r.ver_todos_prospectos_compradores, false)::BOOLEAN,
    COALESCE(r.ver_filtros_avanzados_eliminados, true)::BOOLEAN,
    u.id_notario::INTEGER,
    n.notaria::TEXT                         AS notaria_nombre,
    j.id::BIGINT                            AS id_perfil_juridico,
    j.nombre_completo::TEXT                 AS perfil_juridico_nombre
  FROM public.usuarios u
  JOIN  public.roles    r ON r.id  = u.rol_id
  LEFT JOIN public.notarios n
         ON n.id     = u.id_notario
        AND n.activo = TRUE
  LEFT JOIN public.perfiles_juridicos j
         ON j.email  = u.email
        AND j.activo = TRUE
  WHERE u.email  = auth.email()
    AND u.activo = TRUE
  LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_current_user_profile() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_current_user_profile() TO anon;
GRANT EXECUTE ON FUNCTION public.get_current_user_profile() TO service_role;


-- ============================================================
-- PASO 12 — Vincular demandas con el abogado responsable
-- FK a perfiles_juridicos para shortcut de consulta directa.
-- ============================================================

ALTER TABLE public.demandas
  ADD COLUMN IF NOT EXISTS id_perfil_juridico BIGINT
    REFERENCES public.perfiles_juridicos(id)
    ON DELETE SET NULL;

COMMENT ON COLUMN public.demandas.id_perfil_juridico IS
  'FK hacia perfiles_juridicos. Abogado responsable de esta demanda.
   Se actualiza al asignar/reasignar desde el Dashboard de Demandas.';

CREATE INDEX IF NOT EXISTS idx_demandas_id_perfil_juridico
  ON public.demandas(id_perfil_juridico)
  WHERE id_perfil_juridico IS NOT NULL;

ALTER TABLE public.demandas
  ADD COLUMN IF NOT EXISTS monto_penalizacion NUMERIC(14,2) DEFAULT 0;

COMMENT ON COLUMN public.demandas.monto_penalizacion IS
  'Monto calculado de penalización en MXN: precio_final * (porcentaje_penalizacion / 100).
   Se actualiza desde el Dashboard de Demandas.';
