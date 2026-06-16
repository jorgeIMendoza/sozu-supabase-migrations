-- Catálogo tipos_embajador + migración de embajadores_config.tipo → id_tipo_embajador.
-- Fecha: 2026-06-15
--
-- Mueve los tipos de embajador (antes hardcodeados en el frontend) a un catálogo
-- y reemplaza embajadores_config.tipo (texto libre) por la FK integer
-- id_tipo_embajador → tipos_embajador(id).
--
-- Endurecido vs el spec:
--   * CREATE TABLE IF NOT EXISTS + seed con WHERE NOT EXISTS (re-ejecutable).
--   * La transformación de columna va dentro de un DO guardado por "existe la
--     columna text `tipo`" → no re-ejecuta el DROP si ya se aplicó.
--   * El CASE de mapeo lleva ELSE → 'Otro': cualquier valor de texto no listado
--     (posible en prod) cae en 'Otro' en vez de quedar NULL y abortar el NOT NULL.
--   * RLS con DROP POLICY IF EXISTS + CREATE.

-- ── 1. Catálogo de tipos ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.tipos_embajador (
    id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    etiqueta         text    NOT NULL,
    activo           boolean DEFAULT true NOT NULL,
    orden            integer DEFAULT 0 NOT NULL,
    fecha_creacion      timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    fecha_actualizacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);

-- Datos iniciales (idempotente por etiqueta)
INSERT INTO public.tipos_embajador (etiqueta, orden)
SELECT v.etiqueta, v.orden
FROM (VALUES
    ('Cliente',           1),
    ('Socio',             2),
    ('Aliado',            3),
    ('Referidor externo', 4),
    ('Colaborador',       5),
    ('Otro',              6)
) AS v(etiqueta, orden)
WHERE NOT EXISTS (
    SELECT 1 FROM public.tipos_embajador e WHERE e.etiqueta = v.etiqueta
);

-- ── 2. embajadores_config.tipo (text) → id_tipo_embajador (integer FK) ──
-- Sólo corre si la columna text `tipo` aún existe (no re-ejecuta si ya migró).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='embajadores_config'
      AND column_name='tipo' AND data_type='text'
  ) THEN
    -- Columna FK nullable temporal
    ALTER TABLE public.embajadores_config ADD COLUMN id_tipo_embajador integer;

    -- Poblar desde el texto existente (ELSE 'Otro' como catch-all)
    UPDATE public.embajadores_config
    SET id_tipo_embajador = CASE tipo
        WHEN 'cliente'           THEN (SELECT id FROM public.tipos_embajador WHERE etiqueta = 'Cliente')
        WHEN 'socio'             THEN (SELECT id FROM public.tipos_embajador WHERE etiqueta = 'Socio')
        WHEN 'aliado'            THEN (SELECT id FROM public.tipos_embajador WHERE etiqueta = 'Aliado')
        WHEN 'referidor_externo' THEN (SELECT id FROM public.tipos_embajador WHERE etiqueta = 'Referidor externo')
        WHEN 'colaborador'       THEN (SELECT id FROM public.tipos_embajador WHERE etiqueta = 'Colaborador')
        WHEN 'otro'              THEN (SELECT id FROM public.tipos_embajador WHERE etiqueta = 'Otro')
        ELSE (SELECT id FROM public.tipos_embajador WHERE etiqueta = 'Otro')
    END;

    ALTER TABLE public.embajadores_config ALTER COLUMN id_tipo_embajador SET NOT NULL;
    ALTER TABLE public.embajadores_config DROP COLUMN tipo;
    ALTER TABLE public.embajadores_config
      ADD CONSTRAINT fk_embajadores_config_id_tipo_embajador
      FOREIGN KEY (id_tipo_embajador) REFERENCES public.tipos_embajador (id);
  END IF;
END $$;

-- ── 3. RLS ───────────────────────────────────────────────────
ALTER TABLE public.tipos_embajador ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Lectura para usuarios autenticados" ON public.tipos_embajador;
CREATE POLICY "Lectura para usuarios autenticados"
    ON public.tipos_embajador
    FOR SELECT
    TO authenticated
    USING (true);
