-- Validación de montos de contratos: tabla + RPCs.
-- Fecha: 2026-06-17
--
-- El endpoint POST /api/v1/contracts/validate extrae el monto total de contratos PDF
-- (visión) y lo compara contra cuentas_cobranza.precio_final. El frontend lee
-- contrato_validaciones (fuente de verdad de discrepancias). Acceso solo service_role
-- vía RPC SECURITY DEFINER.
--
-- Verificado en dev: documentos tiene id_cuenta_cobranza, id_proyecto, id_tipo_documento,
-- url; cuentas_cobranza.precio_final existe; la tabla no existía. Idempotente
-- (IF NOT EXISTS / CREATE OR REPLACE).

-- 1) Tabla de resultados
CREATE TABLE IF NOT EXISTS public.contrato_validaciones (
    id              bigserial    PRIMARY KEY,
    id_documento    bigint       NOT NULL REFERENCES public.documentos(id),
    monto_esperado  numeric(12,2),
    monto_real      numeric(12,2),
    estado          text         NOT NULL CHECK (estado IN ('coincide', 'no_coincide', 'error')),
    motivo          text,
    fecha_creacion  timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.contrato_validaciones IS
  'retention: durable | 3 years | resultados de validación de monto en contratos PDF, leído por frontend';

CREATE INDEX IF NOT EXISTS idx_contrato_validaciones_id_documento
    ON public.contrato_validaciones (id_documento);
CREATE INDEX IF NOT EXISTS idx_contrato_validaciones_estado
    ON public.contrato_validaciones (estado);

-- 2) Contratos pendientes de validar (tipos 18, 42; sin validación reciente <24h)
CREATE OR REPLACE FUNCTION public.get_pending_contracts(
    p_proyecto          text    DEFAULT NULL,
    p_limit             int     DEFAULT 0,
    p_excluir_proyectos text[]  DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_records json;
BEGIN
    SELECT json_build_object('records', COALESCE(json_agg(row_to_json(r)), '[]'::json))
    INTO v_records
    FROM (
        SELECT
            d.id                AS id_documento,
            d.url               AS url_contrato,
            cc.precio_final     AS monto_esperado
        FROM public.documentos d
        JOIN public.cuentas_cobranza cc ON cc.id = d.id_cuenta_cobranza
        WHERE d.id_tipo_documento IN (18, 42)
          AND d.url IS NOT NULL
          AND cc.precio_final IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM public.contrato_validaciones cv
              WHERE cv.id_documento = d.id
                AND cv.estado IN ('coincide', 'no_coincide')
                AND cv.fecha_creacion >= now() - interval '24 hours'
          )
          AND (p_proyecto IS NULL OR d.id_proyecto IN (
              SELECT id FROM public.proyectos WHERE nombre = p_proyecto
          ))
          AND (p_excluir_proyectos IS NULL OR d.id_proyecto NOT IN (
              SELECT id FROM public.proyectos WHERE nombre = ANY(p_excluir_proyectos)
          ))
        ORDER BY d.id
        LIMIT NULLIF(p_limit, 0)
    ) r;

    RETURN v_records;
END;
$$;

-- 3) Guardar resultados de validación
CREATE OR REPLACE FUNCTION public.save_contract_validation_results(
    p_results json
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_inserted int := 0;
    v_item     json;
BEGIN
    FOR v_item IN SELECT * FROM json_array_elements(p_results)
    LOOP
        INSERT INTO public.contrato_validaciones (
            id_documento, monto_esperado, monto_real, estado, motivo
        ) VALUES (
            (v_item->>'id_documento')::bigint,
            (v_item->>'monto_esperado')::numeric,
            NULLIF(v_item->>'monto_real', 'null')::numeric,
            v_item->>'estado',
            NULLIF(v_item->>'motivo', 'null')
        );
        v_inserted := v_inserted + 1;
    END LOOP;

    RETURN json_build_object('insertados', v_inserted);
END;
$$;

-- 4) Permisos
GRANT EXECUTE ON FUNCTION public.get_pending_contracts(text, int, text[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.save_contract_validation_results(json) TO service_role;

NOTIFY pgrst, 'reload schema';
