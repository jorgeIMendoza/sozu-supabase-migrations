-- Estandariza `fecha_actualizacion` en las tablas del CRM que no la tenían.
-- Todas ya cuentan con `activo` y `fecha_creacion`; les faltaba `fecha_actualizacion`
-- (columna "de ley"). Se agrega la columna + un trigger BEFORE UPDATE que la mantiene
-- al día, usando una función compartida (mismo comportamiento que crm_tareas / crm_negocios /
-- crm_leads_atribucion, que ya la tenían).
--
-- Idempotente y self-guarded:
--   - `ADD COLUMN IF NOT EXISTS` no rompe si ya existe.
--   - `to_regclass(...) IS NOT NULL` salta tablas que no existan en el ambiente.
--   - `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER` re-crea sin duplicar.
-- Seguro para prod (tablas ya vivas): `DEFAULT NOW()` rellena las filas existentes.

-- Función compartida que mantiene fecha_actualizacion.
CREATE OR REPLACE FUNCTION public.crm_set_fecha_actualizacion()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.fecha_actualizacion = NOW();
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    t TEXT;
    tablas TEXT[] := ARRAY[
        'crm_notas',
        'crm_notas_comentarios',
        'crm_pipelines',
        'crm_pipeline_etapas',
        'crm_negocios_contactos',
        'crm_notas_adjuntos',
        'crm_categorias',
        'entidades_relacionadas_categorias'
    ];
BEGIN
    FOREACH t IN ARRAY tablas LOOP
        IF to_regclass('public.' || t) IS NOT NULL THEN
            EXECUTE format(
                'ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT NOW()', t);
            EXECUTE format(
                'DROP TRIGGER IF EXISTS trg_%I_fecha_actualizacion ON public.%I', t, t);
            EXECUTE format(
                'CREATE TRIGGER trg_%I_fecha_actualizacion BEFORE UPDATE ON public.%I '
                'FOR EACH ROW EXECUTE FUNCTION public.crm_set_fecha_actualizacion()', t, t);
        END IF;
    END LOOP;
END $$;
