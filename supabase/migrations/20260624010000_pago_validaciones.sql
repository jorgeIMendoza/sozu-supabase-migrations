-- Validación de montos de pagos: tabla pago_validaciones + RPCs.
-- Fecha: 2026-06-24
--
-- Valida que el monto del PDF de evidencia (url_cep / url_recibo) coincida con
-- pagos.monto. Análogo a contrato_validaciones pero para pagos. Acceso service_role
-- vía RPC SECURITY DEFINER.
--
-- Verificado en dev: tabla/funciones no existían; columnas de pagos y
-- cuentas_cobranza.id_propiedad existen. Idempotente (IF NOT EXISTS / CREATE OR REPLACE).

-- 1) Tabla
CREATE TABLE IF NOT EXISTS public.pago_validaciones (
    id            BIGSERIAL PRIMARY KEY,
    id_pago       BIGINT NOT NULL REFERENCES public.pagos(id),
    monto_esperado NUMERIC(12,2) NULL,
    monto_real    NUMERIC(12,2) NULL,
    estado        TEXT NOT NULL CHECK (estado = ANY(ARRAY['coincide','no_coincide','error'])),
    motivo        TEXT NULL,
    fuente_pdf    TEXT NULL,
    fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.pago_validaciones IS
    'retention: durable | indefinite | resultado de validación de monto en evidencia de pago vs pagos.monto, leído por frontend';

CREATE INDEX IF NOT EXISTS idx_pago_validaciones_id_pago ON public.pago_validaciones (id_pago);
CREATE INDEX IF NOT EXISTS idx_pago_validaciones_estado  ON public.pago_validaciones (estado);
CREATE INDEX IF NOT EXISTS idx_pago_validaciones_fecha   ON public.pago_validaciones (fecha_creacion DESC);

-- 2) Pagos pendientes de validar (con evidencia, sin entrada en pago_validaciones)
CREATE OR REPLACE FUNCTION public.get_payments_for_pago_validation(
    p_proyecto         TEXT    DEFAULT NULL,
    p_limit            INT     DEFAULT 0,
    p_excluir_proyectos TEXT[] DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_rows  JSON;
    v_total INT;
BEGIN
    SELECT json_agg(sub), COUNT(*)
    INTO v_rows, v_total
    FROM (
        SELECT
            p.id          AS id_pago,
            mp.nombre     AS nombre_metodo,
            p.monto,
            p.fecha_pago,
            p.url_cep,
            p.url_recibo,
            LOWER(e.nombre) AS proyecto
        FROM public.pagos p
        JOIN public.cuentas_cobranza cc  ON cc.id = p.id_cuenta_cobranza
        JOIN public.propiedades       pr  ON pr.id = cc.id_propiedad
        JOIN public.edificios_modelos em  ON em.id = pr.id_edificio_modelo
        JOIN public.edificios         e   ON e.id  = em.id_edificio
        JOIN public.metodos_pago      mp  ON mp.id = p.id_metodos_pago
        WHERE p.activo = true
          AND (p.url_cep IS NOT NULL OR p.url_recibo IS NOT NULL)
          AND NOT EXISTS (
              SELECT 1 FROM public.pago_validaciones pv WHERE pv.id_pago = p.id
          )
          AND (p_proyecto IS NULL OR LOWER(e.nombre) = LOWER(p_proyecto))
          AND (
              p_excluir_proyectos IS NULL
              OR LOWER(e.nombre) != ALL(
                  SELECT LOWER(x) FROM unnest(p_excluir_proyectos) AS x
              )
          )
        ORDER BY p.fecha_pago DESC
        LIMIT CASE WHEN p_limit = 0 THEN NULL ELSE p_limit END
    ) sub;

    RETURN json_build_object(
        'records', COALESCE(v_rows, '[]'::JSON),
        'total',   COALESCE(v_total, 0)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_payments_for_pago_validation(TEXT, INT, TEXT[]) TO service_role;

-- 3) Guardar resultados (sin ON CONFLICT: histórico; el front muestra el más reciente)
CREATE OR REPLACE FUNCTION public.save_pago_validation_results(p_results JSONB)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_inserted INT := 0;
    v_item     JSONB;
BEGIN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_results)
    LOOP
        INSERT INTO public.pago_validaciones (
            id_pago, monto_esperado, monto_real, estado, motivo, fuente_pdf
        ) VALUES (
            (v_item->>'id_pago')::BIGINT,
            NULLIF(v_item->>'monto_esperado', 'null')::NUMERIC,
            NULLIF(v_item->>'monto_real',     'null')::NUMERIC,
            v_item->>'estado',
            NULLIF(v_item->>'motivo', ''),
            NULLIF(v_item->>'fuente_pdf', '')
        );
        v_inserted := v_inserted + 1;
    END LOOP;

    RETURN json_build_object('inserted', v_inserted);
END;
$$;

GRANT EXECUTE ON FUNCTION public.save_pago_validation_results(JSONB) TO service_role;

NOTIFY pgrst, 'reload schema';
