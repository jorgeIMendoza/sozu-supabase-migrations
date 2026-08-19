-- Proyectos industriales y terrenos
-- Fecha: 2026-08-19
-- Origen: Ejecuciones/ejecusiones.md
--
-- ─── Qué hace ─────────────────────────────────────────────────────────────────
-- Permite agrupar terrenos bajo un Proyecto Industrial, que es una entidad distinta del
-- `proyectos` actual: aquel modela desarrollos de vivienda y comercial (edificios, modelos,
-- unidades) y un parque industrial no tiene nada de eso — tiene lotes, superficie
-- urbanizable y etapas de urbanizacion.
--
--   proyectos_industriales                                tabla     el desarrollo
--   estatus_proyecto_industrial                           catalogo  etapa del parque
--   tipos_parque_industrial                               catalogo  parque, macrolote, ...
--   propiedades_atributos_terreno.id_proyecto_industrial  columna   vinculo del lote
--
-- ─── Decisiones que se conservan del documento ────────────────────────────────
-- · Tabla aparte y no un `id_tipo_uso` en `proyectos`: un parque no comparte casi nada con
--   un desarrollo de vivienda, y meterlo ahi obligaria a dejar en NULL la mitad de sus 38
--   columnas y a que todas las consultas existentes filtraran por tipo para no mezclarlos.
-- · El vinculo vive en `propiedades_atributos_terreno`, no en `propiedades`: solo aplica a
--   terrenos, y `propiedades` tiene ~53 mil filas. Si maniana una nave tambien debe colgar
--   de un parque, se promueve con un ALTER acotado.
-- · Catalogo de etapas propio: reusar `estatus_proyecto` obligaria a decir que un parque
--   industrial esta en "Sotanos".
-- · La columna nace NULL: un terreno puede ser un lote dentro de un parque o un predio
--   suelto, igual que un local puede no pertenecer a un desarrollo.
-- · No se crea otra tabla de atributos de terreno: `propiedades_atributos_terreno` ya
--   existe con sus 31 columnas y duplicarla dejaria dos fuentes para el mismo dato.
--
-- ─── Cuatro correcciones sobre el DDL del documento ───────────────────────────
--
-- 1) `direccion_id_pais` es char(2), NO character(3). El catalogo `paises.id` es char(2)
--    (baseline linea 1042). Con char(3) el valor viviria con un espacio de relleno y, aunque
--    bpchar compara ignorando espacios finales, el tipo declarado seria distinto al del
--    catalogo que dice reusar.
--
-- 2) SE DECLARAN LAS TRES FK DE UBICACION. El documento dice "reusa los catalogos de
--    pais/estado/municipio del sistema, para que un parque sea filtrable con los mismos
--    criterios que un desarrollo", pero deja las columnas sueltas: sin FK cualquiera puede
--    guardar un estado inexistente y el filtrado compartido deja de estar garantizado.
--    Se apuntan a los nombres reales, que no son los que sugiere el texto:
--      paises(id)         char(2)
--      estados_mx(id)     integer   <- no "estados"
--      municipios_mx(id)  integer   <- no "municipios"
--    Es lo mismo que hace `proyectos` (baseline lineas 2311-2319).
--
-- 3) REVOKE de `anon` en las tres tablas nuevas. Las default privileges de Supabase sobre
--    `public` le conceden todos los privilegios en cada tabla nueva. La policy de lectura es
--    `TO authenticated`, asi que hoy RLS lo frena, pero el GRANT quedaria como trampa para
--    la primera policy permisiva que llegue. Mismo criterio que 20260806100000 y las demas
--    de esta serie.
--
-- 4) Se reutiliza `public.set_fecha_actualizacion()` en vez de crear
--    `tg_proyectos_industriales_updated`. La funcion ya existe, hace exactamente lo mismo y
--    ademas trae `SET search_path` endurecido, que la del documento no lleva. Y se monta el
--    trigger tambien en los dos catalogos: tienen la columna `fecha_actualizacion` y sin
--    trigger nunca se refrescaria, que es el mismo defecto que arrastraba
--    `roles_organizacionales`.
--
-- ─── Aviso del documento que conviene no perder de vista ──────────────────────
-- `propiedades_atributos_terreno` tiene RLS con una sola policy, `super_admin_all`. Con el
-- alta de activos ya abierta a cualquier usuario (20260818143800), quien capture un terreno
-- NO podra volver a leer sus atributos: el insert funciona porque crear_activo_comercial es
-- SECURITY DEFINER, pero la lectura no. Este archivo NO cambia esa policy —afecta datos
-- existentes y es decision de negocio— y las tablas nuevas nacen con el criterio correcto:
-- lectura para toda sesion autenticada, escritura solo para Super Administrador.
--
-- Verificado contra el baseline y el repo: `propiedades_atributos_terreno` existe con PK
-- id_propiedad bigint (20260702000000, linea 376), `is_super_admin` existe, y los tres
-- catalogos de ubicacion tienen los tipos indicados arriba.
--
-- Idempotente: CREATE ... IF NOT EXISTS, DROP CONSTRAINT/POLICY/TRIGGER antes de crear, y
-- semillas guardadas por NOT EXISTS. Sin BEGIN/COMMIT (el CI envuelve cada archivo, y un
-- COMMIT explicito dejaria fuera el registro en schema_migrations).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 0. Guard previo
-- ═══════════════════════════════════════════════════════════════════════════════
DO $guard$
DECLARE
  v_faltan text;
BEGIN
  SELECT string_agg(t.nombre, ', ' ORDER BY t.nombre)
  INTO v_faltan
  FROM (VALUES
    ('propiedades_atributos_terreno'), ('paises'), ('estados_mx'), ('municipios_mx')
  ) AS t(nombre)
  WHERE to_regclass('public.' || t.nombre) IS NULL;

  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'Faltan estas tablas: %.', v_faltan;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'is_super_admin'
  ) THEN
    RAISE EXCEPTION 'No existe public.is_super_admin: las policies de escritura dependen de ella.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'set_fecha_actualizacion'
  ) THEN
    RAISE EXCEPTION 'No existe public.set_fecha_actualizacion: los triggers dependen de ella.';
  END IF;
END
$guard$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Catálogo: etapa del parque industrial
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.estatus_proyecto_industrial (
  id                  smallint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre              text      NOT NULL,
  orden               smallint  NOT NULL DEFAULT 100,
  activo              boolean   NOT NULL DEFAULT true,
  fecha_creacion      timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fecha_actualizacion timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_estatus_proy_ind_nombre
  ON public.estatus_proyecto_industrial (lower(nombre)) WHERE activo;

COMMENT ON TABLE public.estatus_proyecto_industrial IS
  'Etapas de un parque industrial. Separado de estatus_proyecto, que describe obra vertical '
  '(excavacion, muros, sotanos) y no aplica a la urbanizacion de un parque.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Catálogo: tipo de parque industrial
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.tipos_parque_industrial (
  id                  smallint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre              text      NOT NULL,
  activo              boolean   NOT NULL DEFAULT true,
  fecha_creacion      timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fecha_actualizacion timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_tipos_parque_ind_nombre
  ON public.tipos_parque_industrial (lower(nombre)) WHERE activo;

COMMENT ON TABLE public.tipos_parque_industrial IS
  'Naturaleza del desarrollo industrial: parque, macrolote, nave aislada, zona franca.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. Proyectos industriales
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.proyectos_industriales (
  id                        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

  -- Identificación
  nombre                    text NOT NULL,
  clave                     text,
  descripcion               text,
  id_tipo_parque            smallint REFERENCES public.tipos_parque_industrial (id),
  id_estatus                smallint REFERENCES public.estatus_proyecto_industrial (id),

  -- Ubicación. Mismos catálogos que `proyectos`, para que un parque sea filtrable con los
  -- mismos criterios que un desarrollo. char(2) en el país porque así es paises.id.
  direccion                 text,
  direccion_id_pais         char(2) REFERENCES public.paises (id),
  direccion_id_estado       integer REFERENCES public.estados_mx (id),
  direccion_id_municipio    integer REFERENCES public.municipios_mx (id),
  latitud                   numeric,
  longitud                  numeric,

  -- Dimensiones. En hectáreas, que es como se comercializa suelo industrial.
  superficie_total_ha       numeric,
  superficie_urbanizable_ha numeric,
  superficie_vendible_ha    numeric,
  numero_lotes              integer,

  -- Comercial
  precio_m2_actual          numeric,
  moneda                    text NOT NULL DEFAULT 'MXN',

  -- Infraestructura del PARQUE, no del lote: el lote tiene las suyas en
  -- propiedades_atributos_terreno.
  tiene_acceso_carretero    boolean NOT NULL DEFAULT false,
  tiene_espuela_ferroviaria boolean NOT NULL DEFAULT false,
  tiene_subestacion         boolean NOT NULL DEFAULT false,
  tiene_planta_tratamiento  boolean NOT NULL DEFAULT false,
  tiene_caseta_vigilancia   boolean NOT NULL DEFAULT false,
  kva_disponibles           numeric,

  -- Fechas
  fecha_inicio_urbanizacion date,
  fecha_entrega_estimada    date,

  -- Presentación
  url_logo                  text,
  url_imagen_portada        text,

  -- Control
  publicar                  boolean   NOT NULL DEFAULT false,
  activo                    boolean   NOT NULL DEFAULT true,
  fecha_creacion            timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fecha_actualizacion       timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT ck_proy_ind_superficies CHECK (
    (superficie_total_ha       IS NULL OR superficie_total_ha       >= 0) AND
    (superficie_urbanizable_ha IS NULL OR superficie_urbanizable_ha >= 0) AND
    (superficie_vendible_ha    IS NULL OR superficie_vendible_ha    >= 0)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_proyectos_industriales_nombre
  ON public.proyectos_industriales (lower(nombre)) WHERE activo;

CREATE UNIQUE INDEX IF NOT EXISTS uq_proyectos_industriales_clave
  ON public.proyectos_industriales (upper(clave)) WHERE clave IS NOT NULL AND activo;

CREATE INDEX IF NOT EXISTS ix_proyectos_industriales_estatus
  ON public.proyectos_industriales (id_estatus) WHERE activo;

COMMENT ON TABLE public.proyectos_industriales IS
  'Desarrollo industrial (parque, macrolote, nave aislada). Entidad separada de proyectos, '
  'que modela vivienda y comercial con edificios, modelos y unidades: un parque industrial '
  'no tiene ninguno de esos y si superficie urbanizable, lotes y etapas propias.';

COMMENT ON COLUMN public.proyectos_industriales.superficie_vendible_ha IS
  'Superficie comercializable. Menor que la urbanizable: descuenta vialidades, areas verdes '
  'y donaciones. La relacion entre las tres NO se impone con un CHECK: durante la captura '
  'parcial es normal tener solo una de ellas.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. Vínculo del terreno con su parque
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.propiedades_atributos_terreno
  ADD COLUMN IF NOT EXISTS id_proyecto_industrial integer;

ALTER TABLE public.propiedades_atributos_terreno
  DROP CONSTRAINT IF EXISTS fk_atributos_terreno_proyecto_industrial;
ALTER TABLE public.propiedades_atributos_terreno
  ADD CONSTRAINT fk_atributos_terreno_proyecto_industrial
  FOREIGN KEY (id_proyecto_industrial)
  REFERENCES public.proyectos_industriales (id)
  ON UPDATE CASCADE ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS ix_atributos_terreno_proyecto_industrial
  ON public.propiedades_atributos_terreno (id_proyecto_industrial)
  WHERE id_proyecto_industrial IS NOT NULL;

COMMENT ON COLUMN public.propiedades_atributos_terreno.id_proyecto_industrial IS
  'Parque industrial al que pertenece el lote. NULL = predio suelto, igual que un local '
  'puede no pertenecer a un desarrollo.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. Semillas de catálogo
--    Sin id explícito: las columnas son GENERATED ALWAYS.
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO public.estatus_proyecto_industrial (nombre, orden)
SELECT v.nombre, v.orden
FROM (VALUES
  ('En planeación',       10),
  ('Trámites y permisos', 20),
  ('En urbanización',     30),
  ('Urbanizado',          40),
  ('En comercialización', 50),
  ('Vendido',             60),
  ('Suspendido',          70)
) AS v(nombre, orden)
WHERE NOT EXISTS (
  SELECT 1 FROM public.estatus_proyecto_industrial e
  WHERE lower(e.nombre) = lower(v.nombre)
);

INSERT INTO public.tipos_parque_industrial (nombre)
SELECT v.nombre
FROM (VALUES
  ('Parque industrial'),
  ('Macrolote industrial'),
  ('Nave aislada'),
  ('Zona franca'),
  ('Recinto fiscalizado')
) AS v(nombre)
WHERE NOT EXISTS (
  SELECT 1 FROM public.tipos_parque_industrial t
  WHERE lower(t.nombre) = lower(v.nombre)
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. fecha_actualizacion automática
--    Se reutiliza el helper existente, que ya trae SET search_path endurecido. Se monta
--    también en los catálogos: tienen la columna y sin trigger nunca se refrescaría.
-- ═══════════════════════════════════════════════════════════════════════════════
DROP TRIGGER IF EXISTS trg_proyectos_industriales_updated ON public.proyectos_industriales;
CREATE TRIGGER trg_proyectos_industriales_updated
  BEFORE UPDATE ON public.proyectos_industriales
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

DROP TRIGGER IF EXISTS trg_estatus_proy_ind_updated ON public.estatus_proyecto_industrial;
CREATE TRIGGER trg_estatus_proy_ind_updated
  BEFORE UPDATE ON public.estatus_proyecto_industrial
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

DROP TRIGGER IF EXISTS trg_tipos_parque_ind_updated ON public.tipos_parque_industrial;
CREATE TRIGGER trg_tipos_parque_ind_updated
  BEFORE UPDATE ON public.tipos_parque_industrial
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 7. RLS y permisos
--    Leer lo puede cualquier sesión autenticada —si no, el selector de la pantalla saldría
--    vacío para quien captura—; escribir, solo Super Administrador. Las policies son
--    permisivas y se combinan con OR, así que el SELECT pasa por la de lectura y el
--    INSERT/UPDATE/DELETE solo por la de escritura.
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.proyectos_industriales      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.estatus_proyecto_industrial ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tipos_parque_industrial     ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS proy_ind_select      ON public.proyectos_industriales;
DROP POLICY IF EXISTS proy_ind_write       ON public.proyectos_industriales;
DROP POLICY IF EXISTS estatus_proy_ind_sel ON public.estatus_proyecto_industrial;
DROP POLICY IF EXISTS estatus_proy_ind_wr  ON public.estatus_proyecto_industrial;
DROP POLICY IF EXISTS tipos_parque_ind_sel ON public.tipos_parque_industrial;
DROP POLICY IF EXISTS tipos_parque_ind_wr  ON public.tipos_parque_industrial;

CREATE POLICY proy_ind_select ON public.proyectos_industriales
  FOR SELECT TO authenticated USING (true);
CREATE POLICY proy_ind_write ON public.proyectos_industriales
  FOR ALL TO authenticated
  USING (public.is_super_admin(auth.uid()))
  WITH CHECK (public.is_super_admin(auth.uid()));

CREATE POLICY estatus_proy_ind_sel ON public.estatus_proyecto_industrial
  FOR SELECT TO authenticated USING (true);
CREATE POLICY estatus_proy_ind_wr ON public.estatus_proyecto_industrial
  FOR ALL TO authenticated
  USING (public.is_super_admin(auth.uid()))
  WITH CHECK (public.is_super_admin(auth.uid()));

CREATE POLICY tipos_parque_ind_sel ON public.tipos_parque_industrial
  FOR SELECT TO authenticated USING (true);
CREATE POLICY tipos_parque_ind_wr ON public.tipos_parque_industrial
  FOR ALL TO authenticated
  USING (public.is_super_admin(auth.uid()))
  WITH CHECK (public.is_super_admin(auth.uid()));

REVOKE ALL PRIVILEGES ON TABLE public.proyectos_industriales      FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.estatus_proyecto_industrial FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.tipos_parque_industrial     FROM anon;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.proyectos_industriales,
     public.estatus_proyecto_industrial,
     public.tipos_parque_industrial
  TO authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 8. Guard de cierre
-- ═══════════════════════════════════════════════════════════════════════════════
DO $cierre$
DECLARE
  v_n        int;
  v_estatus  int;
  v_tipos    int;
BEGIN
  SELECT count(*) INTO v_n
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'propiedades_atributos_terreno'
    AND column_name = 'id_proyecto_industrial';

  IF v_n <> 1 THEN
    RAISE EXCEPTION 'No quedo creada propiedades_atributos_terreno.id_proyecto_industrial.';
  END IF;

  -- Las tres FK de ubicacion, que el documento no declaraba.
  SELECT count(*) INTO v_n
  FROM pg_constraint
  WHERE conrelid = 'public.proyectos_industriales'::regclass AND contype = 'f';

  IF v_n < 5 THEN
    RAISE EXCEPTION
      'proyectos_industriales deberia tener 5 FK (tipo, estatus, pais, estado, municipio) y tiene %.',
      v_n;
  END IF;

  SELECT count(*) INTO v_estatus FROM public.estatus_proyecto_industrial WHERE activo;
  SELECT count(*) INTO v_tipos   FROM public.tipos_parque_industrial     WHERE activo;

  IF v_estatus < 7 OR v_tipos < 5 THEN
    RAISE EXCEPTION
      'Las semillas no quedaron completas: % etapas y % tipos (se esperaban 7 y 5).',
      v_estatus, v_tipos;
  END IF;

  RAISE NOTICE
    'Proyectos industriales: tablas creadas, % etapas y % tipos sembrados, vinculo del lote listo.',
    v_estatus, v_tipos;
END
$cierre$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT c.relname, c.relrowsecurity AS rls,
--          (SELECT count(*) FROM pg_policies p WHERE p.tablename = c.relname) AS policies
--   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--   WHERE n.nspname = 'public'
--     AND c.relname IN ('proyectos_industriales','estatus_proyecto_industrial',
--                       'tipos_parque_industrial');
--   -- esperado: rls = true y 2 policies en cada una
--
-- Las cinco FK de proyectos_industriales, incluidas las tres de ubicacion:
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid = 'public.proyectos_industriales'::regclass AND contype = 'f'
--   ORDER BY conname;
--
-- `anon` sin GRANT en las tres:
--   SELECT table_name, grantee, privilege_type FROM information_schema.role_table_grants
--   WHERE table_schema = 'public' AND grantee = 'anon'
--     AND table_name IN ('proyectos_industriales','estatus_proyecto_industrial',
--                        'tipos_parque_industrial');
--   -- esperado: 0 filas
--
-- Semillas:
--   SELECT id, nombre, orden FROM public.estatus_proyecto_industrial ORDER BY orden;
--   SELECT id, nombre FROM public.tipos_parque_industrial ORDER BY id;
--
-- El vinculo nace vacio y ningun terreno se toca:
--   SELECT count(*) AS lotes_en_parque
--   FROM public.propiedades_atributos_terreno WHERE id_proyecto_industrial IS NOT NULL;
--   -- esperado: 0 justo despues de aplicar
--
-- ─── Pendiente que este archivo NO resuelve ───────────────────────────────────
-- `propiedades_atributos_terreno` sigue con su unica policy `super_admin_all`, asi que
-- quien capture un terreno no podra volver a leer sus atributos. El insert pasa porque
-- crear_activo_comercial es SECURITY DEFINER; la lectura, no. Es una decision de negocio y
-- toca datos existentes, asi que se deja fuera a proposito.
--
-- ─── Front ────────────────────────────────────────────────────────────────────
-- La pantalla de alta de terreno gana el selector de parque industrial, que escribe
-- propiedades_atributos_terreno.id_proyecto_industrial. La administracion de parques es una
-- pantalla nueva: solo Super Administrador puede crear y editar; el resto solo los ve en el
-- selector.
