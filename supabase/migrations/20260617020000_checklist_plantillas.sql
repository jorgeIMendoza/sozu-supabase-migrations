-- Sistema de Plantillas de Checklist — Portal Escrituración / Entregas.
-- Fecha: 2026-06-17
--
-- Crea la capa de plantilla reutilizable para el checklist de entrega (hoy hardcodeada
-- en CHECKLIST_PLANTILLA de EntregaDetalle.tsx):
--   checklist_plantillas / checklist_plantilla_categorias / checklist_plantilla_items
-- + columnas de trazabilidad nullable en las tablas de entrega + seed de la plantilla
-- global PRE_ENTREGA (12 categorías / 75 ítems).
--
-- Al crear una entrega se copia la plantilla activa como snapshot; configurar la
-- plantilla NO modifica entregas ya creadas (regla funcional).
--
-- Corrección vs el spec: id_proyecto/id_modelo se declaran INTEGER (no BIGINT) para que
-- la FK calce con proyectos.id/modelos.id (ambos integer en el baseline). Las columnas
-- de trazabilidad sí son bigint (entregas_checklist_*.id y checklist_plantilla_*.id son bigint).
--
-- Idempotente: CREATE TABLE/INDEX IF NOT EXISTS, ADD COLUMN IF NOT EXISTS, DO-blocks con
-- guardas para constraints/triggers, y guard IF EXISTS en el seed.

BEGIN;

-- PASO 0: función de fecha_actualizacion (ya existe en dev; CREATE OR REPLACE seguro)
CREATE OR REPLACE FUNCTION public.fn_set_fecha_actualizacion()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.fecha_actualizacion = now();
  RETURN NEW;
END;
$$;

-- PASO 1: checklist_plantillas
CREATE TABLE IF NOT EXISTS public.checklist_plantillas (
  id                  BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre              VARCHAR(200)  NOT NULL,
  tipo_checklist      VARCHAR(50)   NOT NULL DEFAULT 'PRE_ENTREGA',
  descripcion         TEXT,
  id_proyecto         INTEGER       REFERENCES public.proyectos(id),
  id_modelo           INTEGER       REFERENCES public.modelos(id),
  activo              BOOLEAN       NOT NULL DEFAULT true,
  fecha_creacion      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  fecha_actualizacion TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.checklist_plantillas IS
  'Plantillas reutilizables de checklist. Define categorías e ítems por tipo de '
  'entrega, opcionalmente por proyecto/modelo. Al crear una entrega se copia el snapshot.';
COMMENT ON COLUMN public.checklist_plantillas.id_proyecto IS 'NULL = global (todos los proyectos).';
COMMENT ON COLUMN public.checklist_plantillas.id_modelo IS 'NULL = todos los modelos del proyecto.';

-- PASO 2: checklist_plantilla_categorias
CREATE TABLE IF NOT EXISTS public.checklist_plantilla_categorias (
  id                  BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_plantilla        BIGINT        NOT NULL REFERENCES public.checklist_plantillas(id),
  nombre              VARCHAR(200)  NOT NULL,
  descripcion         TEXT,
  orden               INTEGER       NOT NULL DEFAULT 0,
  activo              BOOLEAN       NOT NULL DEFAULT true,
  fecha_creacion      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  fecha_actualizacion TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.checklist_plantilla_categorias IS
  'Categorías de una plantilla. Soft-delete con activo=false.';
COMMENT ON COLUMN public.checklist_plantilla_categorias.orden IS
  'Orden de presentación (1-based). La secuencia técnica no es alfabética; ordenar por orden ASC.';

CREATE INDEX IF NOT EXISTS idx_chk_pla_cat_plantilla
  ON public.checklist_plantilla_categorias(id_plantilla);
CREATE INDEX IF NOT EXISTS idx_chk_pla_cat_activo
  ON public.checklist_plantilla_categorias(id_plantilla, activo, orden);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_chk_pla_cat_plantilla_nombre') THEN
    ALTER TABLE public.checklist_plantilla_categorias
      ADD CONSTRAINT uq_chk_pla_cat_plantilla_nombre UNIQUE (id_plantilla, nombre);
  END IF;
END $$;

-- PASO 3: checklist_plantilla_items
CREATE TABLE IF NOT EXISTS public.checklist_plantilla_items (
  id                     BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_plantilla_categoria BIGINT        NOT NULL REFERENCES public.checklist_plantilla_categorias(id),
  nombre                 VARCHAR(300)  NOT NULL,
  descripcion            TEXT,
  orden                  INTEGER       NOT NULL DEFAULT 0,
  activo                 BOOLEAN       NOT NULL DEFAULT true,
  fecha_creacion         TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  fecha_actualizacion    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.checklist_plantilla_items IS
  'Conceptos dentro de una categoría de plantilla. Soft-delete con activo=false.';
COMMENT ON COLUMN public.checklist_plantilla_items.orden IS
  'Orden de presentación del ítem (1-based). Ordenar por orden ASC.';

CREATE INDEX IF NOT EXISTS idx_chk_pla_items_categoria
  ON public.checklist_plantilla_items(id_plantilla_categoria);
CREATE INDEX IF NOT EXISTS idx_chk_pla_items_activo
  ON public.checklist_plantilla_items(id_plantilla_categoria, activo, orden);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_chk_pla_items_cat_nombre') THEN
    ALTER TABLE public.checklist_plantilla_items
      ADD CONSTRAINT uq_chk_pla_items_cat_nombre UNIQUE (id_plantilla_categoria, nombre);
  END IF;
END $$;

-- PASO 4: triggers fecha_actualizacion (idempotentes)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_chk_plantillas_fecha_act') THEN
    CREATE TRIGGER trg_chk_plantillas_fecha_act
      BEFORE UPDATE ON public.checklist_plantillas
      FOR EACH ROW EXECUTE FUNCTION public.fn_set_fecha_actualizacion();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_chk_pla_cat_fecha_act') THEN
    CREATE TRIGGER trg_chk_pla_cat_fecha_act
      BEFORE UPDATE ON public.checklist_plantilla_categorias
      FOR EACH ROW EXECUTE FUNCTION public.fn_set_fecha_actualizacion();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_chk_pla_items_fecha_act') THEN
    CREATE TRIGGER trg_chk_pla_items_fecha_act
      BEFORE UPDATE ON public.checklist_plantilla_items
      FOR EACH ROW EXECUTE FUNCTION public.fn_set_fecha_actualizacion();
  END IF;
END $$;

-- PASO 5: trazabilidad en tablas de entrega (nullable; bigint calza con *.id bigint)
ALTER TABLE public.entregas_checklist_categorias
  ADD COLUMN IF NOT EXISTS id_plantilla_categoria BIGINT
    REFERENCES public.checklist_plantilla_categorias(id);
ALTER TABLE public.entregas_checklist_items
  ADD COLUMN IF NOT EXISTS id_plantilla_item BIGINT
    REFERENCES public.checklist_plantilla_items(id);

COMMENT ON COLUMN public.entregas_checklist_categorias.id_plantilla_categoria IS
  'Categoría de plantilla de la que se generó esta fila. NULL en entregas previas al sistema de plantillas.';
COMMENT ON COLUMN public.entregas_checklist_items.id_plantilla_item IS
  'Ítem de plantilla del que se generó esta fila. NULL en entregas previas al sistema de plantillas.';

-- PASO 6: seed plantilla global PRE_ENTREGA (12 categorías / 75 ítems). Guard idempotente.
DO $$
DECLARE
  v_plantilla_id BIGINT;
  v_cat_id       BIGINT;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.checklist_plantillas
    WHERE tipo_checklist = 'PRE_ENTREGA' AND id_proyecto IS NULL AND id_modelo IS NULL
  ) THEN
    RAISE NOTICE 'Plantilla PRE_ENTREGA global ya existe. Seed omitido.';
    RETURN;
  END IF;

  INSERT INTO public.checklist_plantillas (nombre, tipo_checklist, descripcion)
  VALUES ('Checklist estándar PRE_ENTREGA', 'PRE_ENTREGA',
    'Plantilla global de pre-entrega técnica. Migrada desde CHECKLIST_PLANTILLA '
    '(EntregaDetalle.tsx). Aplica a todos los proyectos y modelos por defecto.')
  RETURNING id INTO v_plantilla_id;

  INSERT INTO public.checklist_plantilla_categorias (id_plantilla, nombre, orden)
  VALUES (v_plantilla_id, 'Acabados', 1) RETURNING id INTO v_cat_id;
  INSERT INTO public.checklist_plantilla_items (id_plantilla_categoria, nombre, orden) VALUES
    (v_cat_id, 'Muros',1),(v_cat_id, 'Plafones',2),(v_cat_id, 'Pintura',3),(v_cat_id, 'Pisos',4),
    (v_cat_id, 'Zoclos',5),(v_cat_id, 'Puertas',6),(v_cat_id, 'Cerraduras',7),(v_cat_id, 'Herrajes',8),
    (v_cat_id, 'Cancelería',9),(v_cat_id, 'Vidrios',10),(v_cat_id, 'Ventanas',11);

  INSERT INTO public.checklist_plantilla_categorias (id_plantilla, nombre, orden)
  VALUES (v_plantilla_id, 'Instalación eléctrica', 2) RETURNING id INTO v_cat_id;
  INSERT INTO public.checklist_plantilla_items (id_plantilla_categoria, nombre, orden) VALUES
    (v_cat_id, 'Contactos',1),(v_cat_id, 'Apagadores',2),(v_cat_id, 'Centro de carga',3),
    (v_cat_id, 'Luminarias',4),(v_cat_id, 'Preparaciones',5),(v_cat_id, 'Tierra física',6);

  INSERT INTO public.checklist_plantilla_categorias (id_plantilla, nombre, orden)
  VALUES (v_plantilla_id, 'Instalación hidráulica', 3) RETURNING id INTO v_cat_id;
  INSERT INTO public.checklist_plantilla_items (id_plantilla_categoria, nombre, orden) VALUES
    (v_cat_id, 'Presión de agua',1),(v_cat_id, 'Llaves',2),(v_cat_id, 'Lavabos',3),
    (v_cat_id, 'Regaderas',4),(v_cat_id, 'Tarjas',5),(v_cat_id, 'Conexiones',6),(v_cat_id, 'Fugas',7);

  INSERT INTO public.checklist_plantilla_categorias (id_plantilla, nombre, orden)
  VALUES (v_plantilla_id, 'Instalación sanitaria', 4) RETURNING id INTO v_cat_id;
  INSERT INTO public.checklist_plantilla_items (id_plantilla_categoria, nombre, orden) VALUES
    (v_cat_id, 'WC',1),(v_cat_id, 'Coladeras',2),(v_cat_id, 'Drenajes',3),
    (v_cat_id, 'Prueba de descarga',4),(v_cat_id, 'Olores',5),(v_cat_id, 'Sellos',6);

  INSERT INTO public.checklist_plantilla_categorias (id_plantilla, nombre, orden)
  VALUES (v_plantilla_id, 'Aire acondicionado / HVAC', 5) RETURNING id INTO v_cat_id;
  INSERT INTO public.checklist_plantilla_items (id_plantilla_categoria, nombre, orden) VALUES
    (v_cat_id, 'Preparaciones',1),(v_cat_id, 'Minisplits (si aplica)',2),(v_cat_id, 'Drenes',3),
    (v_cat_id, 'Alimentación eléctrica',4),(v_cat_id, 'Prueba de funcionamiento (si aplica)',5);

  INSERT INTO public.checklist_plantilla_categorias (id_plantilla, nombre, orden)
  VALUES (v_plantilla_id, 'Carpintería', 6) RETURNING id INTO v_cat_id;
  INSERT INTO public.checklist_plantilla_items (id_plantilla_categoria, nombre, orden) VALUES
    (v_cat_id, 'Clósets',1),(v_cat_id, 'Puertas interiores',2),(v_cat_id, 'Muebles de baño',3),
    (v_cat_id, 'Cocina (si aplica)',4),(v_cat_id, 'Ajustes',5),(v_cat_id, 'Bisagras',6),(v_cat_id, 'Jaladeras',7);

  INSERT INTO public.checklist_plantilla_categorias (id_plantilla, nombre, orden)
  VALUES (v_plantilla_id, 'Electrodomésticos / equipamiento', 7) RETURNING id INTO v_cat_id;
  INSERT INTO public.checklist_plantilla_items (id_plantilla_categoria, nombre, orden) VALUES
    (v_cat_id, 'Parrilla',1),(v_cat_id, 'Campana',2),(v_cat_id, 'Horno',3),
    (v_cat_id, 'Refrigerador (si aplica)',4),(v_cat_id, 'Lavasecadora (si aplica)',5),(v_cat_id, 'Manuales y garantías',6);

  INSERT INTO public.checklist_plantilla_categorias (id_plantilla, nombre, orden)
  VALUES (v_plantilla_id, 'Calentador / boiler', 8) RETURNING id INTO v_cat_id;
  INSERT INTO public.checklist_plantilla_items (id_plantilla_categoria, nombre, orden) VALUES
    (v_cat_id, 'Instalación',1),(v_cat_id, 'Encendido',2),(v_cat_id, 'Ventilación',3),
    (v_cat_id, 'Conexiones',4),(v_cat_id, 'Prueba de agua caliente',5);

  INSERT INTO public.checklist_plantilla_categorias (id_plantilla, nombre, orden)
  VALUES (v_plantilla_id, 'Fachada / exteriores', 9) RETURNING id INTO v_cat_id;
  INSERT INTO public.checklist_plantilla_items (id_plantilla_categoria, nombre, orden) VALUES
    (v_cat_id, 'Balcón',1),(v_cat_id, 'Barandales',2),(v_cat_id, 'Cancelería exterior',3),
    (v_cat_id, 'Impermeabilización visible',4),(v_cat_id, 'Drenes pluviales',5);

  INSERT INTO public.checklist_plantilla_categorias (id_plantilla, nombre, orden)
  VALUES (v_plantilla_id, 'Limpieza fina', 10) RETURNING id INTO v_cat_id;
  INSERT INTO public.checklist_plantilla_items (id_plantilla_categoria, nombre, orden) VALUES
    (v_cat_id, 'Vidrios',1),(v_cat_id, 'Pisos',2),(v_cat_id, 'Baños',3),
    (v_cat_id, 'Cocina',4),(v_cat_id, 'Retiro de residuos',5),(v_cat_id, 'Detalles finales',6);

  INSERT INTO public.checklist_plantilla_categorias (id_plantilla, nombre, orden)
  VALUES (v_plantilla_id, 'Seguridad y acceso', 11) RETURNING id INTO v_cat_id;
  INSERT INTO public.checklist_plantilla_items (id_plantilla_categoria, nombre, orden) VALUES
    (v_cat_id, 'Cerradura principal',1),(v_cat_id, 'Tarjetas / llaves',2),(v_cat_id, 'Interfon',3),
    (v_cat_id, 'Accesos',4),(v_cat_id, 'Cajón de estacionamiento',5),(v_cat_id, 'Bodega (si aplica)',6);

  INSERT INTO public.checklist_plantilla_categorias (id_plantilla, nombre, orden)
  VALUES (v_plantilla_id, 'Paquete de Muebles', 12) RETURNING id INTO v_cat_id;
  INSERT INTO public.checklist_plantilla_items (id_plantilla_categoria, nombre, orden) VALUES
    (v_cat_id, 'Sala',1),(v_cat_id, 'Comedor',2),(v_cat_id, 'Recámaras',3),
    (v_cat_id, 'Cocina integral (si aplica)',4),(v_cat_id, 'General / otros',5);

  RAISE NOTICE 'Seed completado. id_plantilla = %. 12 categorías / 75 ítems.', v_plantilla_id;
END $$;

COMMIT;
