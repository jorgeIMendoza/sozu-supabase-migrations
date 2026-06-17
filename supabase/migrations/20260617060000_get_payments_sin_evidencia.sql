-- RPC get_payments_sin_evidencia: pagos sin url_recibo NI url_cep (críticos, sin comprobante).
-- Fecha: 2026-06-17
--
-- Alimenta GET /api/v1/payments/report/sin-evidencia. Solo lectura. Acceso service_role
-- vía RPC SECURITY DEFINER.
--
-- Correcciones vs el spec (verificado en dev):
--   * pagos.id_metodo_pago NO existe → es id_metodos_pago (plural).
--   * pagos.id_proyecto NO existe → el proyecto se deriva por waterfall:
--       pagos → cuentas_cobranza → (id_propiedad directo o vía ofertas.id_propiedad)
--             → propiedades → edificios_modelos → edificios → proyectos.
--     LEFT JOIN en toda la cadena para NO perder pagos sin evidencia cuya cuenta no
--     tenga propiedad/proyecto derivable (proyecto = NULL); el reporte es de criticidad
--     y debe incluirlos todos.
-- Idempotente (CREATE OR REPLACE).

CREATE OR REPLACE FUNCTION public.get_payments_sin_evidencia(
    p_proyecto          text    DEFAULT NULL,
    p_metodo            text    DEFAULT NULL,
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
    SELECT json_build_object(
        'records', COALESCE(json_agg(row_to_json(r)), '[]'::json)
    )
    INTO v_records
    FROM (
        SELECT
            p.id                    AS id_pago,
            p.id_cuenta_cobranza,
            mp.nombre               AS nombre_metodo,
            p.monto,
            p.fecha_pago,
            p.url_recibo,
            p.url_cep,
            pr.nombre               AS proyecto
        FROM public.pagos p
        LEFT JOIN public.metodos_pago     mp   ON mp.id   = p.id_metodos_pago
        LEFT JOIN public.cuentas_cobranza cc   ON cc.id   = p.id_cuenta_cobranza
        LEFT JOIN public.ofertas          o    ON o.id    = cc.id_oferta
        LEFT JOIN public.propiedades      prop ON prop.id = COALESCE(cc.id_propiedad, o.id_propiedad)
        LEFT JOIN public.edificios_modelos em  ON em.id   = prop.id_edificio_modelo
        LEFT JOIN public.edificios        ed   ON ed.id   = em.id_edificio
        LEFT JOIN public.proyectos        pr   ON pr.id   = ed.id_proyecto
        WHERE p.url_cep    IS NULL
          AND p.url_recibo IS NULL
          AND (p_proyecto IS NULL OR pr.nombre = p_proyecto)
          AND (p_metodo   IS NULL OR mp.nombre = p_metodo)
          AND (p_excluir_proyectos IS NULL
               OR pr.nombre IS NULL
               OR pr.nombre <> ALL(p_excluir_proyectos))
        ORDER BY pr.nombre, p.fecha_pago DESC
        LIMIT NULLIF(p_limit, 0)
    ) r;

    RETURN v_records;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_payments_sin_evidencia(text, text, int, text[]) TO service_role;

NOTIFY pgrst, 'reload schema';
