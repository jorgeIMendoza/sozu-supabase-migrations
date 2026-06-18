-- Fix get_pending_contracts: filtro de proyecto (case-insensitive + ruta de joins).
-- Fecha: 2026-06-18
--
-- La versión previa (20260617070000) filtraba por d.id_proyecto con comparación
-- case-sensitive contra proyectos.nombre, lo que devolvía cero resultados cuando:
--   1) el casing no coincidía ('bottura' vs 'Bottura'), o
--   2) documentos.id_proyecto no estaba poblado.
--
-- Fix: derivar el proyecto por la ruta real (documentos → cuentas_cobranza → ofertas/
-- propiedad → edificios_modelos → edificios → proyectos) y comparar con LOWER(...).
-- También agrega cc.activo = TRUE. CREATE OR REPLACE idempotente.

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
        JOIN public.cuentas_cobranza cc   ON cc.id   = d.id_cuenta_cobranza
        LEFT JOIN public.ofertas     o    ON o.id    = cc.id_oferta
        JOIN public.propiedades      prop ON prop.id = COALESCE(cc.id_propiedad, o.id_propiedad)
        JOIN public.edificios_modelos em  ON em.id   = prop.id_edificio_modelo
        JOIN public.edificios        ed   ON ed.id   = em.id_edificio
        LEFT JOIN public.proyectos   pj   ON pj.id   = ed.id_proyecto
        WHERE d.id_tipo_documento IN (18, 42)
          AND d.activo  = TRUE
          AND cc.activo = TRUE
          AND d.url IS NOT NULL
          AND cc.precio_final IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM public.contrato_validaciones cv
              WHERE cv.id_documento = d.id
                AND cv.estado IN ('coincide', 'no_coincide')
                AND cv.fecha_creacion >= now() - interval '24 hours'
          )
          AND (p_proyecto IS NULL OR LOWER(pj.nombre) = LOWER(p_proyecto))
          AND (p_excluir_proyectos IS NULL OR LOWER(pj.nombre) != ALL(
              SELECT LOWER(x) FROM unnest(p_excluir_proyectos) x
          ))
        ORDER BY d.id
        LIMIT NULLIF(p_limit, 0)
    ) r;

    RETURN v_records;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_pending_contracts(text, int, text[]) TO service_role;

NOTIFY pgrst, 'reload schema';
