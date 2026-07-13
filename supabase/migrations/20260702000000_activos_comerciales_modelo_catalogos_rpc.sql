-- Activos Comerciales — Modelo, catálogos, permisos y RPC
-- Fecha: 2026-07-02
--
-- Alcance:
--   1. Catálogos nuevos con semilla (17 tablas id/nombre|codigo).
--   2. Tabla 1:1 propiedades_activo_comercial + tablas hijas por tipo.
--   3. Tabla ofertas_renta.
--   4. RLS + GRANTs (lectura authenticated en catálogos; datos solo Super Admin).
--   5. RPC atómica crear_activo_comercial(jsonb).
--   6. Submenú Finanzas (menu_id=6) → Activos Comerciales (/admin/activos-comerciales), permisos rol 1.
--
-- Idempotente: CREATE TABLE IF NOT EXISTS, ON CONFLICT DO NOTHING, DROP ... IF EXISTS,
-- CREATE OR REPLACE, DELETE-then-INSERT del submenú.
--
-- Dependencias verificadas en dev 2026-07-02: is_super_admin(user_id uuid) existe,
-- menu id 6 = Finanzas, propiedades.id = bigint, tipos_propiedad comercial = 11/12/13/14.
--
-- NOTA: se removió BEGIN/COMMIT del script original — CI/CD envuelve cada migración en su
-- propia transacción. Tras aplicar: regenerar tipos de Supabase para exponer las tablas nuevas
-- y agregar la <Route path="activos-comerciales"> en App.tsx del front (sozu-admin).

-- ==============================================================
-- 1. CATÁLOGOS
-- ==============================================================

-- Utilidad: función trigger updated_at (si no existe una equivalente)
CREATE OR REPLACE FUNCTION public.tg_set_fecha_actualizacion()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.fecha_actualizacion := now();
  RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS public.estados_conservacion (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre                text NOT NULL UNIQUE,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.regimenes_propiedad (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo                text NOT NULL UNIQUE,
  nombre                text NOT NULL,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.usos_suelo (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo                text NOT NULL UNIQUE,
  nombre                text NOT NULL,
  grupo                 text NOT NULL,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.giros_comerciales (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre                text NOT NULL UNIQUE,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.clases_edificio (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo                text NOT NULL UNIQUE,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.estandares_medicion (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre                text NOT NULL UNIQUE,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.hvac_tipo (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo                text NOT NULL UNIQUE,
  nombre                text NOT NULL,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.estados_acabados (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo                text NOT NULL UNIQUE,
  nombre                text NOT NULL,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.estados_entrega_comercio (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo                text NOT NULL UNIQUE,
  nombre                text NOT NULL,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.tipos_comercio (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo                text NOT NULL UNIQUE,
  nombre                text NOT NULL,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.tipos_centro (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo                text NOT NULL UNIQUE,
  nombre                text NOT NULL,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.tipos_terreno (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo                text NOT NULL UNIQUE,
  nombre                text NOT NULL,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.tipos_contrato_renta (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo                text NOT NULL UNIQUE,
  nombre                text NOT NULL,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.indexaciones_renta (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo                text NOT NULL UNIQUE,
  nombre                text NOT NULL,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.tipos_garantia_renta (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo                text NOT NULL UNIQUE,
  nombre                text NOT NULL,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.estatus_renta (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo                text NOT NULL UNIQUE,
  nombre                text NOT NULL,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.amenidades_oficina (
  id                    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre                text NOT NULL UNIQUE,
  activo                boolean NOT NULL DEFAULT true,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

-- Semillas idempotentes
INSERT INTO public.estados_conservacion (nombre) VALUES
  ('Nuevo'),('Excelente'),('Bueno'),('Regular'),('A remodelar')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO public.regimenes_propiedad (codigo, nombre) VALUES
  ('P','Privada'),('D','Condominio'),('J','Ejidal'),('C','Comunal'),
  ('E','Estatal'),('F','Federal'),('M','Municipal'),('S','Concesionada')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.usos_suelo (codigo, nombre, grupo) VALUES
  ('H1-U','H1-U Habitacional','Habitacional'),
  ('H1-H','H1-H Habitacional','Habitacional'),
  ('H1-V','H1-V Habitacional','Habitacional'),
  ('H2-U','H2-U Habitacional','Habitacional'),
  ('H2-H','H2-H Habitacional','Habitacional'),
  ('H2-V','H2-V Habitacional','Habitacional'),
  ('H3-U','H3-U Habitacional','Habitacional'),
  ('H3-H','H3-H Habitacional','Habitacional'),
  ('H3-V','H3-V Habitacional','Habitacional'),
  ('H4-U','H4-U Habitacional','Habitacional'),
  ('H4-H','H4-H Habitacional','Habitacional'),
  ('H4-V','H4-V Habitacional','Habitacional'),
  ('H5-U','H5-U Habitacional','Habitacional'),
  ('H5-H','H5-H Habitacional','Habitacional'),
  ('H5-V','H5-V Habitacional','Habitacional'),
  ('MB','MB Mixto Barrial','Mixto'),
  ('MD','MD Mixto Distrital','Mixto'),
  ('MC','MC Mixto Central','Mixto'),
  ('MR','MR Mixto Regional','Mixto'),
  ('CV','CV Comercio Vecinal','Comercio'),
  ('CB','CB Comercio Barrial','Comercio'),
  ('CD','CD Comercio Distrital','Comercio'),
  ('CC','CC Comercio Central','Comercio'),
  ('CR','CR Comercio Regional','Comercio'),
  ('SV','SV Servicios Vecinal','Servicios'),
  ('SB','SB Servicios Barrial','Servicios'),
  ('SD','SD Servicios Distrital','Servicios'),
  ('SC','SC Servicios Central','Servicios'),
  ('SR','SR Servicios Regional','Servicios'),
  ('SI','SI Servicios Industriales','Servicios'),
  ('I1','I1 Industria Ligera','Industrial'),
  ('I2','I2 Industria Mediana','Industrial'),
  ('I3','I3 Industria Pesada','Industrial'),
  ('IJ','IJ Parque Industrial Jardín','Industrial'),
  ('TH1','TH1 Turístico','Turístico'),
  ('TH2','TH2 Turístico','Turístico'),
  ('TH3','TH3 Turístico','Turístico'),
  ('TH4','TH4 Turístico','Turístico')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.giros_comerciales (nombre) VALUES
  ('Restaurante / Cafetería'),('Boutique de ropa'),
  ('Banco / Servicios financieros'),('Farmacia'),('Gimnasio'),
  ('Consultorio médico'),('Tienda de conveniencia'),
  ('Salón de belleza'),('Telefonía'),('Mueblería'),('Otro')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO public.clases_edificio (codigo) VALUES
  ('A+'),('A'),('B'),('C')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.estandares_medicion (nombre) VALUES
  ('BOMA 2017'),('BOMA 2024'),('IPMS'),('No especificado')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO public.hvac_tipo (codigo, nombre) VALUES
  ('central','Central'),('mini_split','Mini split'),
  ('chiller','Chiller'),('ninguno','Ninguno')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.estados_acabados (codigo, nombre) VALUES
  ('obra_gris','Obra gris'),('acondicionada','Acondicionada'),
  ('amueblada','Amueblada')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.estados_entrega_comercio (codigo, nombre) VALUES
  ('obra_gris','Obra gris'),('shell','Shell'),
  ('acondicionado','Acondicionado')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.tipos_comercio (codigo, nombre) VALUES
  ('local_plaza','Local en plaza'),('pie_de_calle','Pie de calle'),
  ('strip_mall','Strip mall'),('local_ancla','Local ancla'),
  ('isla_kiosko','Isla / Kiosko'),('nave_comercial','Nave comercial')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.tipos_centro (codigo, nombre) VALUES
  ('vecinal','Vecinal'),('comunitario','Comunitario'),
  ('regional','Regional'),('super_regional','Super regional'),
  ('strip','Strip'),('power_center','Power center'),
  ('lifestyle','Lifestyle'),('outlet','Outlet'),
  ('no_aplica','No aplica')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.tipos_terreno (codigo, nombre) VALUES
  ('bruto','Bruto'),('macrolote','Macrolote'),
  ('lote_urbanizado','Lote urbanizado'),('residencial','Residencial'),
  ('comercial','Comercial'),('industrial','Industrial'),
  ('rustico','Rústico'),('ejidal_regularizado','Ejidal regularizado'),
  ('mixto','Mixto'),('condominio_horizontal','Condominio horizontal')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.tipos_contrato_renta (codigo, nombre) VALUES
  ('bruto','Bruto'),('neto','Neto'),
  ('doble_neto','Doble neto'),('triple_neto_NNN','Triple neto (NNN)')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.indexaciones_renta (codigo, nombre) VALUES
  ('INPC','INPC'),('porcentaje_fijo','% fijo anual'),
  ('tipo_cambio_USD','Tipo de cambio USD')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.tipos_garantia_renta (codigo, nombre) VALUES
  ('fiador','Fiador'),('poliza_juridica','Póliza jurídica'),
  ('deposito','Depósito'),('pagare','Pagaré'),
  ('garantia_corporativa','Garantía corporativa')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.estatus_renta (codigo, nombre) VALUES
  ('disponible','Disponible'),('apartado','Apartado'),
  ('rentado','Rentado'),('ocupado','Ocupado'),
  ('vacante','Vacante'),('no_disponible','No disponible')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.amenidades_oficina (nombre) VALUES
  ('Lobby'),('Terraza'),('Gimnasio'),('Valet'),('Restaurantes')
ON CONFLICT (nombre) DO NOTHING;

-- Triggers de updated_at para catálogos
DO $$
DECLARE t text;
BEGIN
  FOR t IN
    SELECT unnest(ARRAY[
      'estados_conservacion','regimenes_propiedad','usos_suelo','giros_comerciales',
      'clases_edificio','estandares_medicion','hvac_tipo','estados_acabados',
      'estados_entrega_comercio','tipos_comercio','tipos_centro','tipos_terreno',
      'tipos_contrato_renta','indexaciones_renta','tipos_garantia_renta',
      'estatus_renta','amenidades_oficina'
    ])
  LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_%1$s_updated ON public.%1$s;
       CREATE TRIGGER trg_%1$s_updated
       BEFORE UPDATE ON public.%1$s
       FOR EACH ROW EXECUTE FUNCTION public.tg_set_fecha_actualizacion();', t);
  END LOOP;
END $$;

-- ==============================================================
-- 2. TABLA 1:1 PROPIEDADES_ACTIVO_COMERCIAL
-- ==============================================================

CREATE TABLE IF NOT EXISTS public.propiedades_activo_comercial (
  id_propiedad              bigint PRIMARY KEY REFERENCES public.propiedades(id) ON DELETE CASCADE,
  codigo_interno            text,
  anio_construccion         int,
  id_estado_conservacion    smallint REFERENCES public.estados_conservacion(id),
  cuota_condominio_mensual  numeric(14,2),
  url_recorrido_virtual     text,
  ubicacion_direccion       text,
  ubicacion_ciudad          text,
  ubicacion_lat             numeric(10,7),
  ubicacion_lng             numeric(10,7),
  id_regimen_propiedad      smallint REFERENCES public.regimenes_propiedad(id),
  subtipo_condominio        text CHECK (subtipo_condominio IS NULL OR subtipo_condominio IN ('horizontal','vertical','mixto')),
  folio_real                text,
  clave_catastral           text,
  cuenta_predial            text,
  valor_catastral           numeric(16,2),
  predial_al_corriente      boolean NOT NULL DEFAULT false,
  origen_ejidal             boolean NOT NULL DEFAULT false,
  dominio_pleno             boolean NOT NULL DEFAULT true,
  libre_gravamen            boolean NOT NULL DEFAULT true,
  gravamen_descripcion      text,
  monto_predial_anual       numeric(14,2),
  fecha_creacion            timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion       timestamp NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_pac_updated ON public.propiedades_activo_comercial;
CREATE TRIGGER trg_pac_updated
BEFORE UPDATE ON public.propiedades_activo_comercial
FOR EACH ROW EXECUTE FUNCTION public.tg_set_fecha_actualizacion();

-- ==============================================================
-- 3. TABLAS HIJAS POR TIPO
-- ==============================================================

CREATE TABLE IF NOT EXISTS public.propiedades_atributos_terreno (
  id_propiedad          bigint PRIMARY KEY REFERENCES public.propiedades(id) ON DELETE CASCADE,
  id_tipo_terreno       smallint REFERENCES public.tipos_terreno(id),
  manzana               text,
  lote                  text,
  superficie_terreno    numeric(14,2),
  superficie_construida numeric(14,2),
  frente                numeric(10,2),
  fondo                 numeric(10,2),
  numero_frentes        smallint,
  topografia            text CHECK (topografia IN ('plano','pendiente','irregular')),
  forma                 text CHECK (forma IN ('regular','irregular')),
  id_uso_suelo          smallint REFERENCES public.usos_suelo(id),
  densidad              numeric(10,2),
  cos                   numeric(6,3),
  cus                   numeric(6,3),
  cas                   numeric(6,3),
  niveles_permitidos    smallint,
  restricciones         text,
  serv_agua                     boolean NOT NULL DEFAULT false,
  serv_drenaje                  boolean NOT NULL DEFAULT false,
  serv_electricidad             boolean NOT NULL DEFAULT false,
  serv_gas                      boolean NOT NULL DEFAULT false,
  serv_fibra                    boolean NOT NULL DEFAULT false,
  serv_alumbrado                boolean NOT NULL DEFAULT false,
  serv_calles_pavimentadas      boolean NOT NULL DEFAULT false,
  serv_banquetas                boolean NOT NULL DEFAULT false,
  serv_urbanizado               boolean NOT NULL DEFAULT false,
  serv_factibilidad_agua        boolean NOT NULL DEFAULT false,
  serv_factibilidad_cfe         boolean NOT NULL DEFAULT false,
  fecha_creacion        timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion   timestamp NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_pat_updated ON public.propiedades_atributos_terreno;
CREATE TRIGGER trg_pat_updated
BEFORE UPDATE ON public.propiedades_atributos_terreno
FOR EACH ROW EXECUTE FUNCTION public.tg_set_fecha_actualizacion();

CREATE TABLE IF NOT EXISTS public.propiedades_atributos_oficina (
  id_propiedad              bigint PRIMARY KEY REFERENCES public.propiedades(id) ON DELETE CASCADE,
  edificio                  text,
  piso                      text,
  numero_oficina            text,
  corredor                  text,
  area_rentable             numeric(14,2),
  area_util                 numeric(14,2),
  factor_eficiencia         numeric(6,3),
  id_estandar_medicion      smallint REFERENCES public.estandares_medicion(id),
  altura_libre              numeric(6,2),
  niveles                   smallint,
  divisible                 boolean NOT NULL DEFAULT false,
  minimo_rentable           numeric(14,2),
  id_estado_acabados        smallint REFERENCES public.estados_acabados(id),
  id_clase_edificio         smallint REFERENCES public.clases_edificio(id),
  id_hvac                   smallint REFERENCES public.hvac_tipo(id),
  elevadores                smallint,
  planta_luz                boolean NOT NULL DEFAULT false,
  seguridad_cctv            boolean NOT NULL DEFAULT false,
  control_acceso            boolean NOT NULL DEFAULT false,
  cajones_estacionamiento   smallint,
  ratio_estacionamiento     text,
  fibra                     boolean NOT NULL DEFAULT false,
  certificacion_leed        text CHECK (certificacion_leed IS NULL OR certificacion_leed IN ('Ninguna','Certificado','Plata','Oro','Platino')),
  fecha_creacion            timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion       timestamp NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_pao_updated ON public.propiedades_atributos_oficina;
CREATE TRIGGER trg_pao_updated
BEFORE UPDATE ON public.propiedades_atributos_oficina
FOR EACH ROW EXECUTE FUNCTION public.tg_set_fecha_actualizacion();

CREATE TABLE IF NOT EXISTS public.propiedades_atributos_comercio (
  id_propiedad              bigint PRIMARY KEY REFERENCES public.propiedades(id) ON DELETE CASCADE,
  id_tipo_comercio          smallint REFERENCES public.tipos_comercio(id),
  plaza                     text,
  numero_local              text,
  nivel                     text,
  gla                       numeric(14,2),
  area_privativa            numeric(14,2),
  mezzanine                 numeric(14,2),
  terraza                   numeric(14,2),
  frente_exhibicion         numeric(10,2),
  fondo                     numeric(10,2),
  altura_libre              numeric(6,2),
  esquina                   boolean NOT NULL DEFAULT false,
  id_estado_entrega         smallint REFERENCES public.estados_entrega_comercio(id),
  id_tipo_centro            smallint REFERENCES public.tipos_centro(id),
  visibilidad               text CHECK (visibilidad IS NULL OR visibilidad IN ('alta','media','baja')),
  aforo_vehicular           int,
  foot_traffic              int,
  cajones_estacionamiento   smallint,
  capacidad_carga_piso      numeric(10,2),
  andenes_carga             smallint,
  patio_maniobras           numeric(10,2),
  kva_energia               numeric(10,2),
  licencia_funcionamiento   boolean NOT NULL DEFAULT false,
  fecha_creacion            timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion       timestamp NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_pac2_updated ON public.propiedades_atributos_comercio;
CREATE TRIGGER trg_pac2_updated
BEFORE UPDATE ON public.propiedades_atributos_comercio
FOR EACH ROW EXECUTE FUNCTION public.tg_set_fecha_actualizacion();

CREATE TABLE IF NOT EXISTS public.propiedades_oficina_amenidades (
  id_propiedad          bigint NOT NULL REFERENCES public.propiedades(id) ON DELETE CASCADE,
  id_amenidad_oficina   smallint NOT NULL REFERENCES public.amenidades_oficina(id),
  PRIMARY KEY (id_propiedad, id_amenidad_oficina)
);

CREATE TABLE IF NOT EXISTS public.propiedades_comercio_tiendas_ancla (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_propiedad          bigint NOT NULL REFERENCES public.propiedades(id) ON DELETE CASCADE,
  nombre                text NOT NULL
);

-- ==============================================================
-- 4. OFERTAS DE RENTA
-- ==============================================================

CREATE TABLE IF NOT EXISTS public.ofertas_renta (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_propiedad              bigint NOT NULL REFERENCES public.propiedades(id) ON DELETE CASCADE,
  activa                    boolean NOT NULL DEFAULT true,
  renta_mensual             numeric(14,2) NOT NULL,
  precio_m2_mes             numeric(14,2),
  moneda                    text NOT NULL DEFAULT 'MXN' CHECK (moneda IN ('MXN','USD')),
  id_tipo_contrato          smallint REFERENCES public.tipos_contrato_renta(id),
  cam                       numeric(14,2),
  cam_es_porcentaje         boolean NOT NULL DEFAULT false,
  cuota_publicidad          numeric(14,2),
  plazo_forzoso_meses       smallint,
  deposito_meses            smallint,
  meses_gracia              smallint DEFAULT 0,
  escalacion_anual          numeric(6,3),
  id_indexacion             smallint REFERENCES public.indexaciones_renta(id),
  iva_aplica                boolean NOT NULL DEFAULT true,
  id_giro_permitido         smallint REFERENCES public.giros_comerciales(id),
  exclusividad              text,
  id_tipo_garantia          smallint REFERENCES public.tipos_garantia_renta(id),
  id_estatus_renta          smallint REFERENCES public.estatus_renta(id),
  comision_corretaje        numeric(10,4),
  comision_es_porcentaje    boolean NOT NULL DEFAULT true,
  disponible_desde          date,
  fecha_fin_contrato_actual date,
  inquilino_actual          text,
  porcentaje_ocupacion      numeric(5,2),
  fecha_creacion            timestamp NOT NULL DEFAULT now(),
  fecha_actualizacion       timestamp NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_ofertas_renta_updated ON public.ofertas_renta;
CREATE TRIGGER trg_ofertas_renta_updated
BEFORE UPDATE ON public.ofertas_renta
FOR EACH ROW EXECUTE FUNCTION public.tg_set_fecha_actualizacion();

CREATE INDEX IF NOT EXISTS idx_ofertas_renta_propiedad ON public.ofertas_renta(id_propiedad) WHERE activa;

-- ==============================================================
-- 5. GRANTS + RLS
-- ==============================================================

-- Catálogos: lectura para authenticated
DO $$
DECLARE t text;
BEGIN
  FOR t IN
    SELECT unnest(ARRAY[
      'estados_conservacion','regimenes_propiedad','usos_suelo','giros_comerciales',
      'clases_edificio','estandares_medicion','hvac_tipo','estados_acabados',
      'estados_entrega_comercio','tipos_comercio','tipos_centro','tipos_terreno',
      'tipos_contrato_renta','indexaciones_renta','tipos_garantia_renta',
      'estatus_renta','amenidades_oficina'
    ])
  LOOP
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated;', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role;', t);
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('DROP POLICY IF EXISTS "read_all_authenticated" ON public.%I;', t);
    EXECUTE format('CREATE POLICY "read_all_authenticated" ON public.%I FOR SELECT TO authenticated USING (true);', t);
    EXECUTE format('DROP POLICY IF EXISTS "write_super_admin" ON public.%I;', t);
    EXECUTE format('CREATE POLICY "write_super_admin" ON public.%I FOR ALL TO authenticated USING (public.is_super_admin(auth.uid())) WITH CHECK (public.is_super_admin(auth.uid()));', t);
  END LOOP;
END $$;

-- Tablas de datos: acceso completo solo Super Admin
DO $$
DECLARE t text;
BEGIN
  FOR t IN
    SELECT unnest(ARRAY[
      'propiedades_activo_comercial',
      'propiedades_atributos_terreno',
      'propiedades_atributos_oficina',
      'propiedades_atributos_comercio',
      'propiedades_oficina_amenidades',
      'propiedades_comercio_tiendas_ancla',
      'ofertas_renta'
    ])
  LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated;', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role;', t);
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('DROP POLICY IF EXISTS "super_admin_all" ON public.%I;', t);
    EXECUTE format('CREATE POLICY "super_admin_all" ON public.%I FOR ALL TO authenticated USING (public.is_super_admin(auth.uid())) WITH CHECK (public.is_super_admin(auth.uid()));', t);
  END LOOP;
END $$;

-- Grants sobre secuencias de identidad (<tabla>_id_seq)
DO $$
DECLARE s text;
BEGIN
  FOR s IN
    SELECT sequencename FROM pg_sequences
     WHERE schemaname='public'
       AND sequencename IN (
         'ofertas_renta_id_seq',
         'propiedades_comercio_tiendas_ancla_id_seq',
         'estados_conservacion_id_seq','regimenes_propiedad_id_seq','usos_suelo_id_seq',
         'giros_comerciales_id_seq','clases_edificio_id_seq','estandares_medicion_id_seq',
         'hvac_tipo_id_seq','estados_acabados_id_seq','estados_entrega_comercio_id_seq',
         'tipos_comercio_id_seq','tipos_centro_id_seq','tipos_terreno_id_seq',
         'tipos_contrato_renta_id_seq','indexaciones_renta_id_seq',
         'tipos_garantia_renta_id_seq','estatus_renta_id_seq','amenidades_oficina_id_seq'
       )
  LOOP
    EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE public.%I TO authenticated;', s);
  END LOOP;
END $$;

-- ==============================================================
-- 6. RPC ATÓMICA crear_activo_comercial
-- ==============================================================

CREATE OR REPLACE FUNCTION public.crear_activo_comercial(payload jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id_propiedad bigint;
  v_tipo         int;
  v_prop         jsonb := payload->'propiedad';
  v_pac          jsonb := payload->'activo_comercial';
  v_atts         jsonb := payload->'atributos';
  v_venta        jsonb := payload->'oferta_venta';
  v_renta        jsonb := payload->'oferta_renta';
BEGIN
  IF NOT public.is_super_admin(auth.uid()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_tipo := (v_prop->>'id_tipo_propiedad')::int;
  IF v_tipo IS NULL OR v_tipo <= 10 THEN
    RAISE EXCEPTION 'id_tipo_propiedad debe ser > 10 (comercial)';
  END IF;

  INSERT INTO public.propiedades (
    id_entidad_relacionada_dueno, id_vista, id_tipo_transaccion,
    id_edificio_modelo, id_tipo_propiedad, id_estatus_disponibilidad,
    numero_propiedad, numero_piso, m2_interiores, m2_exteriores,
    precio_lista, descripcion, url_imagen_portada,
    es_aprobado, activo
  ) VALUES (
    NULLIF(v_prop->>'id_entidad_relacionada_dueno','')::bigint,
    NULLIF(v_prop->>'id_vista','')::int,
    NULLIF(v_prop->>'id_tipo_transaccion','')::int,
    NULLIF(v_prop->>'id_edificio_modelo','')::int,
    v_tipo,
    COALESCE(NULLIF(v_prop->>'id_estatus_disponibilidad','')::int, 2),
    v_prop->>'numero_propiedad',
    v_prop->>'numero_piso',
    COALESCE(NULLIF(v_prop->>'m2_interiores','')::numeric, 0),
    COALESCE(NULLIF(v_prop->>'m2_exteriores','')::numeric, 0),
    COALESCE(NULLIF(v_prop->>'precio_lista','')::numeric, 0),
    v_prop->>'descripcion',
    v_prop->>'url_imagen_portada',
    COALESCE((v_prop->>'es_aprobado')::boolean, true),
    true
  )
  RETURNING id INTO v_id_propiedad;

  -- 1:1 activo_comercial
  IF v_pac IS NOT NULL THEN
    INSERT INTO public.propiedades_activo_comercial (
      id_propiedad, codigo_interno, anio_construccion, id_estado_conservacion,
      cuota_condominio_mensual, url_recorrido_virtual,
      ubicacion_direccion, ubicacion_ciudad, ubicacion_lat, ubicacion_lng,
      id_regimen_propiedad, subtipo_condominio, folio_real, clave_catastral,
      cuenta_predial, valor_catastral, predial_al_corriente, origen_ejidal,
      dominio_pleno, libre_gravamen, gravamen_descripcion, monto_predial_anual
    ) VALUES (
      v_id_propiedad,
      v_pac->>'codigo_interno',
      NULLIF(v_pac->>'anio_construccion','')::int,
      NULLIF(v_pac->>'id_estado_conservacion','')::smallint,
      NULLIF(v_pac->>'cuota_condominio_mensual','')::numeric,
      v_pac->>'url_recorrido_virtual',
      v_pac->>'ubicacion_direccion',
      v_pac->>'ubicacion_ciudad',
      NULLIF(v_pac->>'ubicacion_lat','')::numeric,
      NULLIF(v_pac->>'ubicacion_lng','')::numeric,
      NULLIF(v_pac->>'id_regimen_propiedad','')::smallint,
      v_pac->>'subtipo_condominio',
      v_pac->>'folio_real',
      v_pac->>'clave_catastral',
      v_pac->>'cuenta_predial',
      NULLIF(v_pac->>'valor_catastral','')::numeric,
      COALESCE((v_pac->>'predial_al_corriente')::boolean, false),
      COALESCE((v_pac->>'origen_ejidal')::boolean, false),
      COALESCE((v_pac->>'dominio_pleno')::boolean, true),
      COALESCE((v_pac->>'libre_gravamen')::boolean, true),
      v_pac->>'gravamen_descripcion',
      NULLIF(v_pac->>'monto_predial_anual','')::numeric
    );
  END IF;

  -- Atributos por tipo
  IF v_atts IS NOT NULL THEN
    IF v_tipo = 14 THEN
      INSERT INTO public.propiedades_atributos_terreno (
        id_propiedad, id_tipo_terreno, manzana, lote,
        superficie_terreno, superficie_construida, frente, fondo, numero_frentes,
        topografia, forma, id_uso_suelo, densidad, cos, cus, cas,
        niveles_permitidos, restricciones,
        serv_agua, serv_drenaje, serv_electricidad, serv_gas, serv_fibra,
        serv_alumbrado, serv_calles_pavimentadas, serv_banquetas,
        serv_urbanizado, serv_factibilidad_agua, serv_factibilidad_cfe
      ) VALUES (
        v_id_propiedad,
        NULLIF(v_atts->>'id_tipo_terreno','')::smallint,
        v_atts->>'manzana', v_atts->>'lote',
        NULLIF(v_atts->>'superficie_terreno','')::numeric,
        NULLIF(v_atts->>'superficie_construida','')::numeric,
        NULLIF(v_atts->>'frente','')::numeric,
        NULLIF(v_atts->>'fondo','')::numeric,
        NULLIF(v_atts->>'numero_frentes','')::smallint,
        v_atts->>'topografia', v_atts->>'forma',
        NULLIF(v_atts->>'id_uso_suelo','')::smallint,
        NULLIF(v_atts->>'densidad','')::numeric,
        NULLIF(v_atts->>'cos','')::numeric,
        NULLIF(v_atts->>'cus','')::numeric,
        NULLIF(v_atts->>'cas','')::numeric,
        NULLIF(v_atts->>'niveles_permitidos','')::smallint,
        v_atts->>'restricciones',
        COALESCE((v_atts->>'serv_agua')::boolean,false),
        COALESCE((v_atts->>'serv_drenaje')::boolean,false),
        COALESCE((v_atts->>'serv_electricidad')::boolean,false),
        COALESCE((v_atts->>'serv_gas')::boolean,false),
        COALESCE((v_atts->>'serv_fibra')::boolean,false),
        COALESCE((v_atts->>'serv_alumbrado')::boolean,false),
        COALESCE((v_atts->>'serv_calles_pavimentadas')::boolean,false),
        COALESCE((v_atts->>'serv_banquetas')::boolean,false),
        COALESCE((v_atts->>'serv_urbanizado')::boolean,false),
        COALESCE((v_atts->>'serv_factibilidad_agua')::boolean,false),
        COALESCE((v_atts->>'serv_factibilidad_cfe')::boolean,false)
      );
    ELSIF v_tipo = 12 THEN
      INSERT INTO public.propiedades_atributos_oficina (
        id_propiedad, edificio, piso, numero_oficina, corredor,
        area_rentable, area_util, factor_eficiencia, id_estandar_medicion,
        altura_libre, niveles, divisible, minimo_rentable,
        id_estado_acabados, id_clase_edificio, id_hvac,
        elevadores, planta_luz, seguridad_cctv, control_acceso,
        cajones_estacionamiento, ratio_estacionamiento, fibra, certificacion_leed
      ) VALUES (
        v_id_propiedad,
        v_atts->>'edificio', v_atts->>'piso',
        v_atts->>'numero_oficina', v_atts->>'corredor',
        NULLIF(v_atts->>'area_rentable','')::numeric,
        NULLIF(v_atts->>'area_util','')::numeric,
        NULLIF(v_atts->>'factor_eficiencia','')::numeric,
        NULLIF(v_atts->>'id_estandar_medicion','')::smallint,
        NULLIF(v_atts->>'altura_libre','')::numeric,
        NULLIF(v_atts->>'niveles','')::smallint,
        COALESCE((v_atts->>'divisible')::boolean,false),
        NULLIF(v_atts->>'minimo_rentable','')::numeric,
        NULLIF(v_atts->>'id_estado_acabados','')::smallint,
        NULLIF(v_atts->>'id_clase_edificio','')::smallint,
        NULLIF(v_atts->>'id_hvac','')::smallint,
        NULLIF(v_atts->>'elevadores','')::smallint,
        COALESCE((v_atts->>'planta_luz')::boolean,false),
        COALESCE((v_atts->>'seguridad_cctv')::boolean,false),
        COALESCE((v_atts->>'control_acceso')::boolean,false),
        NULLIF(v_atts->>'cajones_estacionamiento','')::smallint,
        v_atts->>'ratio_estacionamiento',
        COALESCE((v_atts->>'fibra')::boolean,false),
        v_atts->>'certificacion_leed'
      );
    ELSIF v_tipo IN (11, 13) THEN
      INSERT INTO public.propiedades_atributos_comercio (
        id_propiedad, id_tipo_comercio, plaza, numero_local, nivel,
        gla, area_privativa, mezzanine, terraza,
        frente_exhibicion, fondo, altura_libre, esquina,
        id_estado_entrega, id_tipo_centro, visibilidad,
        aforo_vehicular, foot_traffic, cajones_estacionamiento,
        capacidad_carga_piso, andenes_carga, patio_maniobras,
        kva_energia, licencia_funcionamiento
      ) VALUES (
        v_id_propiedad,
        NULLIF(v_atts->>'id_tipo_comercio','')::smallint,
        v_atts->>'plaza', v_atts->>'numero_local', v_atts->>'nivel',
        NULLIF(v_atts->>'gla','')::numeric,
        NULLIF(v_atts->>'area_privativa','')::numeric,
        NULLIF(v_atts->>'mezzanine','')::numeric,
        NULLIF(v_atts->>'terraza','')::numeric,
        NULLIF(v_atts->>'frente_exhibicion','')::numeric,
        NULLIF(v_atts->>'fondo','')::numeric,
        NULLIF(v_atts->>'altura_libre','')::numeric,
        COALESCE((v_atts->>'esquina')::boolean,false),
        NULLIF(v_atts->>'id_estado_entrega','')::smallint,
        NULLIF(v_atts->>'id_tipo_centro','')::smallint,
        v_atts->>'visibilidad',
        NULLIF(v_atts->>'aforo_vehicular','')::int,
        NULLIF(v_atts->>'foot_traffic','')::int,
        NULLIF(v_atts->>'cajones_estacionamiento','')::smallint,
        NULLIF(v_atts->>'capacidad_carga_piso','')::numeric,
        NULLIF(v_atts->>'andenes_carga','')::smallint,
        NULLIF(v_atts->>'patio_maniobras','')::numeric,
        NULLIF(v_atts->>'kva_energia','')::numeric,
        COALESCE((v_atts->>'licencia_funcionamiento')::boolean,false)
      );
    END IF;
  END IF;

  -- Oferta renta (opcional)
  IF v_renta IS NOT NULL AND (v_renta->>'renta_mensual') IS NOT NULL THEN
    INSERT INTO public.ofertas_renta (
      id_propiedad, activa, renta_mensual, precio_m2_mes, moneda,
      id_tipo_contrato, cam, cam_es_porcentaje, cuota_publicidad,
      plazo_forzoso_meses, deposito_meses, meses_gracia, escalacion_anual,
      id_indexacion, iva_aplica, id_giro_permitido, exclusividad,
      id_tipo_garantia, id_estatus_renta, comision_corretaje, comision_es_porcentaje,
      disponible_desde, fecha_fin_contrato_actual, inquilino_actual, porcentaje_ocupacion
    ) VALUES (
      v_id_propiedad,
      COALESCE((v_renta->>'activa')::boolean, true),
      (v_renta->>'renta_mensual')::numeric,
      NULLIF(v_renta->>'precio_m2_mes','')::numeric,
      COALESCE(v_renta->>'moneda','MXN'),
      NULLIF(v_renta->>'id_tipo_contrato','')::smallint,
      NULLIF(v_renta->>'cam','')::numeric,
      COALESCE((v_renta->>'cam_es_porcentaje')::boolean,false),
      NULLIF(v_renta->>'cuota_publicidad','')::numeric,
      NULLIF(v_renta->>'plazo_forzoso_meses','')::smallint,
      NULLIF(v_renta->>'deposito_meses','')::smallint,
      COALESCE(NULLIF(v_renta->>'meses_gracia','')::smallint, 0),
      NULLIF(v_renta->>'escalacion_anual','')::numeric,
      NULLIF(v_renta->>'id_indexacion','')::smallint,
      COALESCE((v_renta->>'iva_aplica')::boolean,true),
      NULLIF(v_renta->>'id_giro_permitido','')::smallint,
      v_renta->>'exclusividad',
      NULLIF(v_renta->>'id_tipo_garantia','')::smallint,
      NULLIF(v_renta->>'id_estatus_renta','')::smallint,
      NULLIF(v_renta->>'comision_corretaje','')::numeric,
      COALESCE((v_renta->>'comision_es_porcentaje')::boolean,true),
      NULLIF(v_renta->>'disponible_desde','')::date,
      NULLIF(v_renta->>'fecha_fin_contrato_actual','')::date,
      v_renta->>'inquilino_actual',
      NULLIF(v_renta->>'porcentaje_ocupacion','')::numeric
    );
  END IF;

  RETURN v_id_propiedad;
END;
$$;

GRANT EXECUTE ON FUNCTION public.crear_activo_comercial(jsonb) TO authenticated;

-- ==============================================================
-- 7. SUBMENÚ Y PERMISOS
-- ==============================================================

-- Elimina alta previa (idempotente)
DELETE FROM public.submenus_permisos
 WHERE submenu_id IN (
   SELECT id FROM public.submenus
    WHERE vista_front_end = '/admin/activos-comerciales'
 );
DELETE FROM public.submenus_permisos_disponibles
 WHERE submenu_id IN (
   SELECT id FROM public.submenus
    WHERE vista_front_end = '/admin/activos-comerciales'
 );
DELETE FROM public.submenus
 WHERE vista_front_end = '/admin/activos-comerciales';

WITH nuevo AS (
  INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
  VALUES (6, 'Activos Comerciales', '/admin/activos-comerciales', 10, true, false)
  RETURNING id
),
disp AS (
  INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
  SELECT n.id, p.permiso_id, true
  FROM nuevo n
  CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
  RETURNING submenu_id
)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT n.id, p.permiso_id, r.rol_id, true
FROM nuevo n
CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
CROSS JOIN (VALUES (1)) AS r(rol_id);
