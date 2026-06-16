-- Postventa: catálogo administrable de subcategorías por categoría de garantía.
-- Fecha: 2026-06-15
--
-- Tabla postventa_subcategorias + función/trigger de fecha_actualizacion + índices,
-- y seed de 46 subcategorías confirmadas (9 categorías, fuente: PostventaDashboard.tsx).
-- Idempotente: CREATE TABLE/INDEX IF NOT EXISTS, CREATE OR REPLACE FUNCTION,
-- DROP TRIGGER IF EXISTS, ON CONFLICT (id_categoria, nombre) DO NOTHING.
--
-- Excluido del spec:
--   * BLOQUE 3 (Fachada, id_categoria=10): propuestas sin respaldo de negocio,
--     marcadas "NO EJECUTAR" → no se incluyen.
--   * BLOQUE 4 (verificación): SELECTs de solo lectura, no son migración.
-- Verificado en dev: tabla no existía; categorías garantía 1-9 existen; ordenamiento
-- delegado a ORDER BY nombre (sin columna `orden`).

-- ── Función genérica de fecha_actualizacion ──────────────────
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

-- ── Tabla ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.postventa_subcategorias (
  id                  integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_categoria        integer      NOT NULL
                                     REFERENCES public.postventa_categorias_garantia(id)
                                     ON UPDATE CASCADE
                                     ON DELETE RESTRICT,
  nombre              varchar(255) NOT NULL,
  activo              boolean      NOT NULL DEFAULT true,
  fecha_creacion      timestamptz  NOT NULL DEFAULT now(),
  fecha_actualizacion timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT uq_subcat_categoria_nombre UNIQUE (id_categoria, nombre)
);

COMMENT ON TABLE  public.postventa_subcategorias              IS 'Catálogo administrable de subcategorías por categoría de garantía Postventa';
COMMENT ON COLUMN public.postventa_subcategorias.id_categoria IS 'FK a postventa_categorias_garantia';
COMMENT ON COLUMN public.postventa_subcategorias.nombre       IS 'Nombre visible en dropdown; ordenar siempre con ORDER BY nombre ASC';
COMMENT ON COLUMN public.postventa_subcategorias.activo       IS 'false = oculta en tickets nuevos; conservada en tickets históricos';
COMMENT ON COLUMN public.postventa_subcategorias.fecha_actualizacion IS 'Auto-actualizado por trg_pv_subcategorias_fecha_actualizacion';

-- ── Trigger fecha_actualizacion ──────────────────────────────
DROP TRIGGER IF EXISTS trg_pv_subcategorias_fecha_actualizacion ON public.postventa_subcategorias;
CREATE TRIGGER trg_pv_subcategorias_fecha_actualizacion
  BEFORE UPDATE ON public.postventa_subcategorias
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_set_fecha_actualizacion();

-- ── Índices ───────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_pv_subcats_categoria_activo
  ON public.postventa_subcategorias(id_categoria, nombre)
  WHERE activo = true;

CREATE INDEX IF NOT EXISTS idx_pv_subcats_categoria_all
  ON public.postventa_subcategorias(id_categoria, nombre);

-- ── Seed: 46 subcategorías confirmadas ───────────────────────
INSERT INTO public.postventa_subcategorias (id_categoria, nombre, activo) VALUES
  -- Eléctrica (1)
  (1, 'Apagador no funciona',  true),
  (1, 'Contacto no funciona',  true),
  (1, 'Corto eléctrico',       true),
  (1, 'Luminaria no funciona', true),
  (1, 'Tablero eléctrico',     true),
  -- Sanitaria (2)
  (2, 'Coladera tapada', true),
  (2, 'Drenaje lento',   true),
  (2, 'Fuga sanitaria',  true),
  (2, 'Mal olor',        true),
  (2, 'WC no descarga',  true),
  -- Hidráulica (3)
  (3, 'Baja presión',          true),
  (3, 'Fuga en lavabo',        true),
  (3, 'Fuga en tarja',         true),
  (3, 'Humedad',               true),
  (3, 'Llave no funciona',     true),
  (3, 'Mezcladora defectuosa', true),
  -- HVAC (4)
  (4, 'Control no funciona', true),
  (4, 'Fuga de condensado',  true),
  (4, 'No enciende',         true),
  (4, 'No enfría',           true),
  (4, 'Ruido',               true),
  -- Calentador / Boiler (5)
  (5, 'Baja presión',       true),
  (5, 'Error eléctrico',    true),
  (5, 'Falla intermitente', true),
  (5, 'Fuga',               true),
  (5, 'No calienta',        true),
  (5, 'No enciende',        true),
  (5, 'Olor a gas',         true),
  -- Acabados (6)
  (6, 'Grieta',   true),
  (6, 'Pintura',  true),
  (6, 'Plafón',   true),
  (6, 'Piso',     true),
  (6, 'Sellador', true),
  (6, 'Yeso',     true),
  -- Carpintería (7)
  (7, 'Bisagra dañada',     true),
  (7, 'Cajón no corre',     true),
  (7, 'Closet no cierra',   true),
  (7, 'Cubierta dañada',    true),
  (7, 'Mueble desalineado', true),
  (7, 'Puerta no cierra',   true),
  -- Paquete Muebles / DAIKU (8)
  (8, 'Daño en transporte',     true),
  (8, 'Defecto de fábrica',     true),
  (8, 'Instalación incompleta', true),
  -- Electrodomésticos (9)
  (9, 'Daño visible',              true),
  (9, 'No enciende',               true),
  (9, 'No funciona correctamente', true)
ON CONFLICT (id_categoria, nombre) DO NOTHING;
