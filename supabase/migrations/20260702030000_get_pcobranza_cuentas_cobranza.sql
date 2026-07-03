-- Portal Cobranza > menú Cuentas de Cobranza.
-- Crea get_pcobranza_cuentas_cobranza (convención get_p<portal>_<menu>), reemplazo
-- de get_bandeja_operativa + campos id_estatus_disponibilidad / estatus_propiedad
-- para el filtro Estatus propiedad.
-- La vieja get_bandeja_operativa se elimina aparte, tras desplegar el front
-- (ver Ejecuciones_manuales/portal-cobranza/cuentas-cobranza.md).

CREATE OR REPLACE FUNCTION public.get_pcobranza_cuentas_cobranza(
  p_proyecto_id integer DEFAULT NULL::integer,
  p_search text DEFAULT NULL::text,
  p_solo_vencidas boolean DEFAULT false
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  v_hoy date := current_date;
BEGIN
  SELECT COALESCE(jsonb_agg(row_to_json(r) ORDER BY
    CASE r.prioridad
      WHEN 'gray'     THEN 0
      WHEN 'blue'     THEN 1
      WHEN 'purple'   THEN 2
      WHEN 'red_dark' THEN 3
      WHEN 'red'      THEN 4
      WHEN 'yellow'   THEN 5
      ELSE 6
    END,
    r.dias_sin_pagar DESC NULLS LAST,
    r.monto_vencido DESC
  ), '[]'::jsonb)
  INTO result
  FROM (
    SELECT
      cc.id AS cuenta_id,
      cc.clabe_stp,
      cc.precio_final,
      cc.fecha_compra,
      p.nombre_legal  AS cliente_nombre,
      p.email         AS cliente_email,
      p.telefono      AS cliente_telefono,
      pr.nombre       AS proyecto,
      pr.id           AS proyecto_id,
      ed.nombre       AS edificio,
      prop.numero_propiedad,
      mod.nombre      AS modelo,
      prop.id_estatus_disponibilidad AS id_estatus_disponibilidad,
      est.nombre      AS estatus_propiedad,
      CASE WHEN eff_o.id_producto IS NOT NULL THEN ps.nombre ELSE NULL END AS producto_nombre,

      CASE
        WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL THEN 'Mantenimiento'
        WHEN eff_o.id_producto IS NOT NULL THEN 'Producto'
        ELSE 'Propiedad'
      END AS tipo_cuenta,

      COALESCE(vc.parcialidades_vencidas, 0) AS parcialidades_vencidas,
      COALESCE(vc.monto_vencido,          0) AS monto_vencido,
      COALESCE(vc.saldo_pendiente,        0) AS saldo_pendiente,
      COALESCE(vc.invalidos,              0) AS invalidos,
      vc.proximo_vencimiento,
      vc.ultima_fecha_pago,

      CASE
        WHEN vc.ultima_fecha_pago IS NOT NULL THEN GREATEST(0, (v_hoy - vc.ultima_fecha_pago)::int)
        WHEN cc.fecha_compra IS NOT NULL       THEN GREATEST(0, (v_hoy - cc.fecha_compra)::int)
        ELSE 0
      END AS dias_sin_pagar,

      CASE
        WHEN COALESCE(vc.parcialidades_vencidas, 0) = 0 THEN 'green'
        ELSE
          CASE
            WHEN (CASE
                    WHEN vc.ultima_fecha_pago IS NOT NULL THEN (v_hoy - vc.ultima_fecha_pago)::int
                    WHEN cc.fecha_compra IS NOT NULL       THEN (v_hoy - cc.fecha_compra)::int
                    ELSE 0
                  END) >= 90 THEN 'purple'
            WHEN (CASE
                    WHEN vc.ultima_fecha_pago IS NOT NULL THEN (v_hoy - vc.ultima_fecha_pago)::int
                    WHEN cc.fecha_compra IS NOT NULL       THEN (v_hoy - cc.fecha_compra)::int
                    ELSE 0
                  END) >= 60 THEN 'red_dark'
            WHEN (CASE
                    WHEN vc.ultima_fecha_pago IS NOT NULL THEN (v_hoy - vc.ultima_fecha_pago)::int
                    WHEN cc.fecha_compra IS NOT NULL       THEN (v_hoy - cc.fecha_compra)::int
                    ELSE 0
                  END) >= 30 THEN 'red'
            ELSE 'yellow'
          END
      END AS prioridad

    FROM cuentas_cobranza cc

    LEFT JOIN cuentas_cobranza cc_padre
           ON cc_padre.id = cc.id_cuenta_cobranza_padre

    LEFT JOIN LATERAL (
      SELECT COALESCE(cc.id_oferta,     cc_padre.id_oferta)     AS id_oferta,
             COALESCE(cc.id_propiedad,  cc_padre.id_propiedad)  AS id_propiedad
    ) eff_cc ON true

    LEFT JOIN ofertas            eff_o ON eff_o.id  = eff_cc.id_oferta
    LEFT JOIN personas           p     ON p.id       = eff_o.id_persona_lead
    LEFT JOIN propiedades        prop  ON prop.id    = eff_cc.id_propiedad
    LEFT JOIN edificios_modelos  em    ON em.id      = prop.id_edificio_modelo
    LEFT JOIN edificios          ed    ON ed.id      = em.id_edificio
    LEFT JOIN modelos            mod   ON mod.id     = em.id_modelo
    LEFT JOIN estatus_disponibilidad est ON est.id  = prop.id_estatus_disponibilidad
    LEFT JOIN productos_servicios ps   ON ps.id      = eff_o.id_producto
    LEFT JOIN proyectos          pr    ON pr.id      = COALESCE(ed.id_proyecto, ps.id_proyecto)

    LEFT JOIN LATERAL (
      SELECT
        -- Confía en pago_completado (autoritativo via trigger). Sin recálculo de residual.
        COUNT(CASE
          WHEN ap.pago_completado = false
           AND ap.fecha_pago < v_hoy
          THEN 1
        END)::int AS parcialidades_vencidas,

        -- Monto vencido / saldo: sumas de display (no validación)
        COALESCE(SUM(CASE
          WHEN ap.pago_completado = false AND ap.fecha_pago < v_hoy
          THEN GREATEST(ap.monto - COALESCE(apl.aplicado, 0), 0)
        END), 0) AS monto_vencido,

        COALESCE(SUM(CASE
          WHEN ap.pago_completado = false
          THEN GREATEST(ap.monto - COALESCE(apl.aplicado, 0), 0)
        END), 0) AS saldo_pendiente,

        MIN(CASE
          WHEN ap.pago_completado = false AND ap.fecha_pago >= v_hoy
          THEN ap.fecha_pago
        END) AS proximo_vencimiento,

        (
          SELECT MAX(pg.fecha_pago)
          FROM pagos pg
          WHERE pg.id_cuenta_cobranza = cc.id AND pg.activo = true
        ) AS ultima_fecha_pago,

        (
          SELECT COUNT(*)::int FROM (
            SELECT 1
            FROM acuerdos_pago      ap2
            JOIN aplicaciones_pago  apl2
              ON apl2.id_acuerdo_pago = ap2.id
             AND apl2.activo = true
             AND apl2.id_pago IS NOT NULL
            LEFT JOIN LATERAL (
              SELECT pv.estado
              FROM pago_validaciones pv
              WHERE pv.id_pago = apl2.id_pago
              ORDER BY pv.fecha_creacion DESC
              LIMIT 1
            ) latest_v ON true
            WHERE ap2.id_cuenta_cobranza = cc.id
              AND latest_v.estado IS DISTINCT FROM 'coincide'

            UNION ALL

            SELECT 1
            FROM acuerdos_pago ap3
            WHERE ap3.id_cuenta_cobranza = cc.id
              AND ap3.activo = true
              AND eff_o.id_producto IS NOT NULL
              AND NOT EXISTS (
                SELECT 1 FROM aplicaciones_pago apl3
                WHERE apl3.id_acuerdo_pago = ap3.id
                  AND apl3.activo = true
                  AND apl3.id_pago IS NOT NULL
              )
          ) inv
        ) AS invalidos

      FROM acuerdos_pago ap
      LEFT JOIN LATERAL (
        SELECT COALESCE(SUM(a.monto), 0) AS aplicado
        FROM aplicaciones_pago a
        WHERE a.id_acuerdo_pago = ap.id
          AND a.activo    = true
          AND a.es_multa  = false
      ) apl ON true
      WHERE ap.id_cuenta_cobranza = cc.id
        AND ap.activo = true
    ) vc ON true

    WHERE cc.activo = true
      AND (p_proyecto_id IS NULL OR pr.id = p_proyecto_id)
      AND (prop.id_estatus_disponibilidad IS NULL
           OR prop.id_estatus_disponibilidad NOT IN (8, 9))
      AND (
        p_search IS NULL OR p_search = '' OR
        cc.clabe_stp         ILIKE '%' || p_search || '%' OR
        p.nombre_legal       ILIKE '%' || p_search || '%' OR
        p.email              ILIKE '%' || p_search || '%' OR
        prop.numero_propiedad ILIKE '%' || p_search || '%' OR
        ps.nombre            ILIKE '%' || p_search || '%' OR
        ed.nombre            ILIKE '%' || p_search || '%' OR
        pr.nombre            ILIKE '%' || p_search || '%'
      )
      AND (
        p_solo_vencidas = false OR
        COALESCE(vc.parcialidades_vencidas, 0) > 0
      )
  ) r;

  RETURN result;
END;
$function$;

-- Grants (replican los de la función original)
GRANT EXECUTE ON FUNCTION public.get_pcobranza_cuentas_cobranza(integer, text, boolean)
  TO anon, authenticated, service_role;
