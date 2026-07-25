-- get_payments_for_cep_cleanup (consolidate) + get_payments_for_pago_validation (validate)
-- Fecha: 2026-07-25 · Solicita: Eduardo
--
-- Tres cambios + cierre de fuga de seguridad. Ninguna tabla se modifica (sin DDL de esquema,
-- sin cambio de datos, sin cambio de firma).
--
-- 1) Cadena de proyecto: INNER JOIN de una sola ruta (cc.id_propiedad) → LEFT JOIN + COALESCE de
--    4 rutas a propiedades. Antes, si cuentas_cobranza.id_propiedad IS NULL el pago desaparecía del
--    resultado (3066 pagos activos hoy). Rutas: cc.id_propiedad, cc.id_oferta→ofertas.id_propiedad,
--    cc.id_cuenta_cobranza_padre→padre.id_propiedad, padre.id_oferta→ofertas.id_propiedad.
--    COALESCE de las 4 resuelve 100%; los LEFT JOIN se conservan para que un futuro huérfano entre
--    con proyecto NULL en vez de caer del pipeline en silencio. Verificado en prod (read-only):
--    22511 pagos, 0 sin proyecto (antes 3066), daiku 350→397, sin multiplicación de filas.
-- 2) cep_cleanup: p_metodos DEFAULT ARRAY['STP','STP-manual'] → DEFAULT NULL (NULL = todos los
--    métodos). El default anterior excluía Transferencia/Efectivo/Cheque. validate ya era DEFAULT NULL.
-- 3) id_cuenta_cobranza en el output de ambas (columna del Excel; permite eliminar la 2ª query del micro).
--
-- SEGURIDAD: ambas son SECURITY DEFINER y tenían EXECUTE para anon → exponían monto/url_cep/
--    clave_rastreo/id_cuenta_cobranza (datos financieros) a la anon key, bypasseando RLS. Se cierra
--    con REVOKE FROM anon. service_role (micro) y authenticated (panel) conservan EXECUTE → sin impacto.
--
-- Idempotente: CREATE OR REPLACE + REVOKE (no-op si no hay grant). Sin BEGIN/COMMIT (CI/CD envuelve en tx).

-- ── A. get_payments_for_cep_cleanup ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_payments_for_cep_cleanup(
    p_proyecto           text    DEFAULT NULL,
    p_metodos            text[]  DEFAULT NULL,   -- NULL = todos los métodos
    p_limit              integer DEFAULT 0,
    p_excluir_proyectos  text[]  DEFAULT NULL
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
            p.id                  AS id_pago,
            p.id_cuenta_cobranza,
            mp.nombre             AS nombre_metodo,
            p.monto,
            p.fecha_pago,
            p.url_cep,
            p.url_recibo,
            p.clave_rastreo,
            LOWER(e.nombre)       AS proyecto     -- NULL solo si ninguna ruta resuelve
        FROM public.pagos p
        JOIN      public.metodos_pago      mp ON mp.id = p.id_metodos_pago
        LEFT JOIN public.cuentas_cobranza  cc ON cc.id = p.id_cuenta_cobranza
        LEFT JOIN public.ofertas           o  ON o.id  = cc.id_oferta
        LEFT JOIN public.cuentas_cobranza  cp ON cp.id = cc.id_cuenta_cobranza_padre
        LEFT JOIN public.ofertas           op ON op.id = cp.id_oferta
        LEFT JOIN public.propiedades       pr ON pr.id = COALESCE(
                                                     cc.id_propiedad,
                                                     o.id_propiedad,
                                                     cp.id_propiedad,
                                                     op.id_propiedad
                                                 )
        LEFT JOIN public.edificios_modelos em ON em.id = pr.id_edificio_modelo
        LEFT JOIN public.edificios         e  ON e.id  = em.id_edificio
        WHERE p.activo = true
          AND (p_metodos IS NULL OR mp.nombre = ANY(p_metodos))
          AND (p_proyecto IS NULL OR LOWER(e.nombre) = LOWER(p_proyecto))
          AND (
              p_excluir_proyectos IS NULL
              OR e.nombre IS NULL
              OR LOWER(e.nombre) != ALL(SELECT LOWER(x) FROM unnest(p_excluir_proyectos) AS x)
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

-- ── B. get_payments_for_pago_validation ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_payments_for_pago_validation(
    p_proyecto           text    DEFAULT NULL,
    p_limit              integer DEFAULT 0,
    p_excluir_proyectos  text[]  DEFAULT NULL,
    p_metodos            text[]  DEFAULT NULL,
    p_estado_previo      text    DEFAULT NULL
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
            p.id                  AS id_pago,
            p.id_cuenta_cobranza,
            mp.nombre             AS nombre_metodo,
            p.monto,
            p.fecha_pago,
            p.url_cep,
            p.url_recibo,
            LOWER(e.nombre)       AS proyecto
        FROM public.pagos p
        JOIN      public.metodos_pago      mp ON mp.id = p.id_metodos_pago
        LEFT JOIN public.cuentas_cobranza  cc ON cc.id = p.id_cuenta_cobranza
        LEFT JOIN public.ofertas           o  ON o.id  = cc.id_oferta
        LEFT JOIN public.cuentas_cobranza  cp ON cp.id = cc.id_cuenta_cobranza_padre
        LEFT JOIN public.ofertas           op ON op.id = cp.id_oferta
        LEFT JOIN public.propiedades       pr ON pr.id = COALESCE(
                                                     cc.id_propiedad,
                                                     o.id_propiedad,
                                                     cp.id_propiedad,
                                                     op.id_propiedad
                                                 )
        LEFT JOIN public.edificios_modelos em ON em.id = pr.id_edificio_modelo
        LEFT JOIN public.edificios         e  ON e.id  = em.id_edificio
        WHERE p.activo = true
          AND (p.url_cep IS NOT NULL OR p.url_recibo IS NOT NULL)
          AND (p_metodos IS NULL OR mp.nombre = ANY(p_metodos))
          AND (
              -- Sin filtro de estado previo: solo los no validados
              (p_estado_previo IS NULL AND NOT EXISTS (
                  SELECT 1 FROM public.pago_validaciones pv
                  WHERE pv.id_pago = p.id AND pv.estado IS NOT NULL
              ))
              -- Con filtro: la última validación debe tener ese estado
              OR (p_estado_previo IS NOT NULL AND EXISTS (
                  SELECT 1 FROM public.pago_validaciones pv
                  WHERE pv.id_pago = p.id
                    AND pv.estado = p_estado_previo
                    AND pv.fecha_creacion = (
                        SELECT MAX(pv2.fecha_creacion)
                        FROM public.pago_validaciones pv2
                        WHERE pv2.id_pago = p.id
                    )
              ))
          )
          AND (p_proyecto IS NULL OR LOWER(e.nombre) = LOWER(p_proyecto))
          AND (
              p_excluir_proyectos IS NULL
              OR e.nombre IS NULL
              OR LOWER(e.nombre) != ALL(SELECT LOWER(x) FROM unnest(p_excluir_proyectos) AS x)
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

-- ── C. Cierre de fuga: revocar anon (SECURITY DEFINER expone datos financieros) ──
-- service_role (micro) y authenticated (panel) conservan EXECUTE existente.
REVOKE ALL ON FUNCTION public.get_payments_for_cep_cleanup(text, text[], integer, text[]) FROM anon;
REVOKE ALL ON FUNCTION public.get_payments_for_pago_validation(text, integer, text[], text[], text) FROM anon;
