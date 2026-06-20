-- Validación de fecha del contrato PDF en contrato_validaciones.
-- Fecha: 2026-06-19
--
-- Agrega fecha del contrato (vs cuentas_cobranza.fecha_compra para productos) a
-- contrato_validaciones y actualiza las 2 RPCs:
--   save_contract_validation_results: UPDATE-first (backfill de filas pre-migración
--     con fecha NULL) y luego INSERT.
--   get_pending_contracts: agrega id_cuenta_cobranza/proyecto/fecha_compra/es_producto
--     y reprocesa documentos validados >24h que aún tienen fecha_contrato_pdf NULL.
--
-- Extiende 20260617070000 (tabla + RPCs) y conserva el fix de ruta/case del filtro de
-- proyecto (20260618000000). Idempotente. Verificado en dev: tabla existe, columnas
-- nuevas no, cuentas_cobranza.fecha_compra existe.

-- ── Paso 1: columnas nuevas ──────────────────────────────────
ALTER TABLE public.contrato_validaciones
  ADD COLUMN IF NOT EXISTS fecha_contrato_pdf date,
  ADD COLUMN IF NOT EXISTS estado_fecha       text
    CHECK (estado_fecha IN ('coincide', 'no_coincide', 'error'));

-- ── Paso 2: save_contract_validation_results (UPDATE-first + INSERT) ──
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
    v_id_doc   bigint;
BEGIN
    FOR v_item IN SELECT * FROM json_array_elements(p_results)
    LOOP
        v_id_doc := (v_item->>'id_documento')::bigint;

        -- Backfill: actualiza la fila más reciente sin fecha para ese documento.
        UPDATE public.contrato_validaciones
        SET monto_real         = NULLIF(v_item->>'monto_real', 'null')::numeric,
            estado             = v_item->>'estado',
            motivo             = NULLIF(v_item->>'motivo', 'null'),
            fecha_contrato_pdf = NULLIF(v_item->>'fecha_contrato_pdf', 'null')::date,
            estado_fecha       = NULLIF(v_item->>'estado_fecha', 'null'),
            fecha_creacion     = now()
        WHERE id = (
            SELECT id FROM public.contrato_validaciones
            WHERE id_documento = v_id_doc
              AND fecha_contrato_pdf IS NULL
            ORDER BY fecha_creacion DESC
            LIMIT 1
        );

        IF NOT FOUND THEN
            INSERT INTO public.contrato_validaciones (
                id_documento, monto_esperado, monto_real, estado, motivo,
                fecha_contrato_pdf, estado_fecha
            ) VALUES (
                v_id_doc,
                (v_item->>'monto_esperado')::numeric,
                NULLIF(v_item->>'monto_real', 'null')::numeric,
                v_item->>'estado',
                NULLIF(v_item->>'motivo', 'null'),
                NULLIF(v_item->>'fecha_contrato_pdf', 'null')::date,
                NULLIF(v_item->>'estado_fecha', 'null')
            );
        END IF;

        v_inserted := v_inserted + 1;
    END LOOP;

    RETURN json_build_object('insertados', v_inserted);
END;
$$;

GRANT EXECUTE ON FUNCTION public.save_contract_validation_results(json) TO service_role;

-- ── Paso 3: get_pending_contracts (+campos, +reproceso de fecha pendiente) ──
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
            d.id                        AS id_documento,
            d.url                       AS url_contrato,
            cc.precio_final             AS monto_esperado,
            cc.id                       AS id_cuenta_cobranza,
            pj.nombre                   AS proyecto,
            cc.fecha_compra             AS fecha_compra,
            (cc.id_propiedad IS NULL)   AS es_producto
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
                -- Saltar si: fecha ya poblada (validación completa) o creada <24h.
                -- Reprocesar si: validado >24h Y fecha aún NULL (backfill).
                AND (cv.fecha_contrato_pdf IS NOT NULL OR cv.fecha_creacion >= now() - interval '24 hours')
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
