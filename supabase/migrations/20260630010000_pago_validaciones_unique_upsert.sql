-- pago_validaciones: limpieza de duplicados + UNIQUE(id_pago) + estado nullable
--                     + save (INSERT->UPSERT) + RPC filtro estado IS NOT NULL.
-- Fecha: 2026-06-30
--
-- Permite resetear pagos con error/no_coincide poniendo estado=NULL para que el RPC
-- los reprocese, sin duplicados futuros. Orden EXACTO: dedup -> drop not null ->
-- unique -> upsert -> rpc. Idempotente (dedup re-corre sin efecto; DROP NOT NULL
-- idempotente; UNIQUE via guard pg_constraint; CREATE OR REPLACE).
-- Verificado en dev: estado NOT NULL; sin UNIQUE; 2 id_pago duplicados; ambas fn existen.

-- Paso 1 — Limpiar duplicados (conserva coincide > no_coincide > error; empate: más reciente)
DELETE FROM public.pago_validaciones
WHERE id IN (
    SELECT id FROM (
        SELECT id,
               ROW_NUMBER() OVER (
                   PARTITION BY id_pago
                   ORDER BY
                       CASE estado
                           WHEN 'coincide'    THEN 1
                           WHEN 'no_coincide' THEN 2
                           WHEN 'error'       THEN 3
                       END,
                       fecha_creacion DESC
               ) AS rn
        FROM public.pago_validaciones
    ) sub
    WHERE rn > 1
);

-- Paso 2 — estado nullable (el CHECK existente acepta NULL)
ALTER TABLE public.pago_validaciones
    ALTER COLUMN estado DROP NOT NULL;

-- Paso 3 — UNIQUE(id_pago). ADD CONSTRAINT no soporta IF NOT EXISTS -> guard.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'pago_validaciones_id_pago_key'
  ) THEN
    ALTER TABLE public.pago_validaciones
        ADD CONSTRAINT pago_validaciones_id_pago_key UNIQUE (id_pago);
  END IF;
END $$;

-- Paso 4 — save_pago_validation_results: INSERT -> UPSERT
CREATE OR REPLACE FUNCTION public.save_pago_validation_results(p_results jsonb)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
        )
        ON CONFLICT (id_pago) DO UPDATE SET
            monto_esperado = EXCLUDED.monto_esperado,
            monto_real     = EXCLUDED.monto_real,
            estado         = EXCLUDED.estado,
            motivo         = EXCLUDED.motivo,
            fuente_pdf     = EXCLUDED.fuente_pdf,
            fecha_creacion = now();
        v_inserted := v_inserted + 1;
    END LOOP;

    RETURN json_build_object('inserted', v_inserted);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.save_pago_validation_results(jsonb)
    TO service_role;

-- Paso 5 — get_payments_for_pago_validation: excluir solo los que ya tienen estado IS NOT NULL
CREATE OR REPLACE FUNCTION public.get_payments_for_pago_validation(
    p_proyecto           TEXT    DEFAULT NULL,
    p_limit              INTEGER DEFAULT 0,
    p_excluir_proyectos  TEXT[]  DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_rows  JSON;
    v_total INT;
BEGIN
    SELECT json_agg(sub), COUNT(*)
    INTO v_rows, v_total
    FROM (
        SELECT
            p.id            AS id_pago,
            mp.nombre       AS nombre_metodo,
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
              SELECT 1 FROM public.pago_validaciones pv
              WHERE pv.id_pago = p.id
                AND pv.estado IS NOT NULL
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
$function$;

GRANT EXECUTE ON FUNCTION public.get_payments_for_pago_validation(TEXT, INTEGER, TEXT[])
    TO service_role;
