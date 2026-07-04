-- Portal Cobranza > menú Dashboard.
-- Actualiza get_pcobranza_dashboard: pipeline.listas_escrituracion ahora exige,
-- además de que el ÚNICO pendiente sea el contra entrega (concepto 3), que TODOS
-- los pagos de venta previos estén validados 'coincide' en pago_validaciones
-- (un pago sin validar o que no coincide => aún se revisa, no cuenta como lista).
-- Resto del cuerpo igual que 20260703020000 (universo SOZU, conceptos venta 1-6,
-- _pg por aplicaciones_pago, serie 5 años, clientes_criticos 3+ parcialidades).
-- CREATE OR REPLACE en sitio, misma firma (4 args). Sin BEGIN/COMMIT (CI/CD tx).
-- La vieja get_dashboard_cobranza_kpis (3 overloads) se elimina aparte, tras
-- desplegar el front nuevo (ver Ejecuciones_manuales/portal-cobranza/dashboard.md).

CREATE OR REPLACE FUNCTION public.get_pcobranza_dashboard(
  p_proyecto_id integer DEFAULT NULL::integer,
  p_fecha_inicio date DEFAULT NULL::date,
  p_fecha_fin date DEFAULT NULL::date,
  p_entidad_ids integer[] DEFAULT NULL::integer[]
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  v_mes_inicio date;
  v_mes_fin date;
  v_hoy date;
  v_cobrado_mes numeric;
  v_programado_mes numeric;
BEGIN
  v_hoy := current_date;
  v_mes_inicio := COALESCE(p_fecha_inicio, date_trunc('month', v_hoy)::date);
  v_mes_fin := COALESCE(p_fecha_fin, (date_trunc('month', v_hoy) + interval '1 month' - interval '1 day')::date);

  -- ════ Universo del portal: SOLO proyectos SOZU (entidad relacionada tipo 5) ════
  -- El dashboard de cobranza trabaja únicamente sobre unidades de proyectos
  -- administrados por SOZU (Margot, Bottura, Monócolo, Daiku…).
  CREATE TEMP TABLE _sozu ON COMMIT DROP AS
  SELECT DISTINCT id_proyecto
  FROM entidades_relacionadas
  WHERE id_tipo_entidad = 5 AND activo = true AND id_proyecto IS NOT NULL;

  -- ════ Acuerdos materializados: join chain + aplicaciones_pago UNA sola vez ════
  -- Solo cuentas de UNIDAD: el depto (sin producto) + Bodega(cat 2) y
  -- Estacionamiento(cat 1), que comparten id_propiedad con el depto. Se excluyen
  -- condensadoras(4), paquetes/persianas(3) y servicios (cat NULL). La propiedad
  -- efectiva se resuelve por la cuenta o, si es cuenta hija, por su padre.
  CREATE TEMP TABLE _ap ON COMMIT DROP AS
  SELECT ap.id,
         ap.id_cuenta_cobranza,
         ap.monto,
         ap.fecha_pago,
         ap.pago_completado,
         ap.id_concepto,
         ed.id_proyecto,
         GREATEST(ap.monto - COALESCE(apl.pagado, 0), 0) AS pend
  FROM acuerdos_pago ap
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza AND cc.activo = true
  LEFT JOIN cuentas_cobranza ccp ON ccp.id = cc.id_cuenta_cobranza_padre
  LEFT JOIN ofertas o ON o.id = cc.id_oferta
  LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
  LEFT JOIN propiedades prop ON prop.id = COALESCE(cc.id_propiedad, ccp.id_propiedad)
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  LEFT JOIN (
    SELECT id_acuerdo_pago, SUM(monto) AS pagado
    FROM aplicaciones_pago
    WHERE activo = true AND es_multa = false
    GROUP BY id_acuerdo_pago
  ) apl ON apl.id_acuerdo_pago = ap.id
  WHERE ap.activo = true
    -- Solo conceptos del flujo de venta (abonos al precio): Apartado(1),
    -- Enganche(2), Contra entrega(3), Pago especial(4), Parcialidad(5),
    -- Cesión de derechos(6). Igual que "Durante obra + Entrega" del detalle de
    -- cuenta. Fuera: mantenimiento(11), penalización, multa, reserva, etc.
    AND ap.id_concepto IN (1, 2, 3, 4, 5, 6)
    AND ed.id_proyecto IN (SELECT id_proyecto FROM _sozu)
    AND (o.id_producto IS NULL OR ps.id_categoria IN (1, 2))
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  CREATE INDEX ON _ap (id_proyecto);

  -- ════ Cobrado materializado: por aplicaciones_pago (NO por pagos) ════
  -- "Cobrado" = dinero aplicado a acuerdos de UNIDAD, excluyendo mantenimiento
  -- (concepto 11) y multas. Se usa aplicaciones_pago (no pagos.monto) para poder
  -- separar por concepto/cuenta y quedar consistente con la deuda (_ap.pend, que
  -- también se calcula contra aplicaciones). fecha_pago viene del pago aplicado.
  CREATE TEMP TABLE _pg ON COMMIT DROP AS
  SELECT apl.monto,
         pg.fecha_pago,
         ed.id_proyecto
  FROM aplicaciones_pago apl
  JOIN acuerdos_pago ap ON ap.id = apl.id_acuerdo_pago AND ap.activo = true
  JOIN pagos pg ON pg.id = apl.id_pago AND pg.activo = true
  JOIN cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza AND cc.activo = true
  LEFT JOIN cuentas_cobranza ccp ON ccp.id = cc.id_cuenta_cobranza_padre
  LEFT JOIN ofertas o ON o.id = cc.id_oferta
  LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
  LEFT JOIN propiedades prop ON prop.id = COALESCE(cc.id_propiedad, ccp.id_propiedad)
  LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
  LEFT JOIN edificios ed ON ed.id = em.id_edificio
  WHERE apl.activo = true AND apl.es_multa = false
    AND ap.id_concepto IN (1, 2, 3, 4, 5, 6)   -- solo flujo de venta (ver _ap)
    AND ed.id_proyecto IN (SELECT id_proyecto FROM _sozu)
    AND (o.id_producto IS NULL OR ps.id_categoria IN (1, 2))
    AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
    AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids));

  CREATE INDEX ON _pg (id_proyecto);

  -- ════ Para recovery_rate ════
  SELECT COALESCE(SUM(monto), 0) INTO v_cobrado_mes
  FROM _pg WHERE fecha_pago BETWEEN v_mes_inicio AND v_mes_fin;

  SELECT COALESCE(SUM(pend), 0) INTO v_programado_mes
  FROM _ap WHERE fecha_pago BETWEEN v_mes_inicio AND v_mes_fin;

  -- ════ Escalares ════
  result := jsonb_build_object(
    'cobrado_total',         (SELECT COALESCE(SUM(monto), 0) FROM _pg),
    'vencido_total',         (SELECT COALESCE(SUM(pend), 0) FROM _ap WHERE pago_completado = false AND fecha_pago < v_hoy),
    'vencido_total_sin_ce',  (SELECT COALESCE(SUM(pend), 0) FROM _ap WHERE pago_completado = false AND fecha_pago < v_hoy AND id_concepto <> 3),
    'pendiente_total',       (SELECT COALESCE(SUM(monto), 0) FROM _ap WHERE pago_completado = false AND fecha_pago >= v_hoy),
    'cobrado_mes',           v_cobrado_mes,
    'programado_mes',        v_programado_mes,
    'programado_mes_sin_ce', (SELECT COALESCE(SUM(pend), 0) FROM _ap WHERE fecha_pago BETWEEN v_mes_inicio AND v_mes_fin AND id_concepto <> 3),
    'por_cobrar_mes',        (SELECT COALESCE(SUM(pend), 0) FROM _ap WHERE pago_completado = false AND fecha_pago BETWEEN v_mes_inicio AND v_mes_fin),
    'por_cobrar_mes_sin_ce', (SELECT COALESCE(SUM(pend), 0) FROM _ap WHERE pago_completado = false AND fecha_pago BETWEEN v_mes_inicio AND v_mes_fin AND id_concepto <> 3),
    'recovery_rate', CASE WHEN v_programado_mes > 0 THEN ROUND((v_cobrado_mes / v_programado_mes * 100)::numeric, 1) ELSE 0 END
  );

  -- ════ Aging ════
  result := result || jsonb_build_object('aging', (
    SELECT COALESCE(jsonb_agg(row_to_json(a)), '[]'::jsonb)
    FROM (
      SELECT
        CASE
          WHEN v_hoy - fecha_pago BETWEEN 1 AND 30 THEN '1-30'
          WHEN v_hoy - fecha_pago BETWEEN 31 AND 60 THEN '31-60'
          WHEN v_hoy - fecha_pago BETWEEN 61 AND 90 THEN '61-90'
          ELSE '90+'
        END AS rango,
        SUM(pend) AS monto,
        SUM(CASE WHEN id_concepto <> 3 THEN pend ELSE 0 END) AS monto_sin_ce,
        COUNT(*) AS cantidad
      FROM _ap
      WHERE pago_completado = false AND fecha_pago < v_hoy
      GROUP BY 1 ORDER BY 1
    ) a
  ));

  -- ════ Morosidad (cuentas por # parcialidades vencidas) ════
  result := result || jsonb_build_object('morosidad', (
    SELECT COALESCE(jsonb_agg(row_to_json(m)), '[]'::jsonb)
    FROM (
      SELECT
        CASE WHEN cnt = 1 THEN '1_vencida' WHEN cnt = 2 THEN '2_vencidas' ELSE '3_plus' END AS grupo,
        COUNT(*)::integer AS cuentas
      FROM (
        SELECT id_cuenta_cobranza, LEAST(COUNT(*), 3) AS cnt
        FROM _ap
        WHERE pago_completado = false AND fecha_pago < v_hoy
        GROUP BY id_cuenta_cobranza
      ) sub
      GROUP BY 1 ORDER BY 1
    ) m
  ));

  -- ════ Por proyecto (solo proyectos con actividad en el scope) ════
  result := result || jsonb_build_object('por_proyecto', (
    SELECT COALESCE(jsonb_agg(row_to_json(pp)), '[]'::jsonb)
    FROM (
      SELECT pr.nombre AS proyecto, pr.id AS proyecto_id,
        COALESCE(c.cobrado, 0) AS cobrado,
        COALESCE(v.vencido, 0) AS vencido,
        COALESCE(pe.pendiente, 0) AS pendiente
      FROM proyectos pr
      JOIN (
        SELECT id_proyecto FROM _pg WHERE id_proyecto IS NOT NULL
        UNION
        SELECT id_proyecto FROM _ap WHERE id_proyecto IS NOT NULL
      ) scope ON scope.id_proyecto = pr.id
      LEFT JOIN (SELECT id_proyecto, SUM(monto) AS cobrado FROM _pg GROUP BY 1) c ON c.id_proyecto = pr.id
      LEFT JOIN (SELECT id_proyecto, SUM(pend) AS vencido FROM _ap WHERE pago_completado = false AND fecha_pago < v_hoy GROUP BY 1) v ON v.id_proyecto = pr.id
      LEFT JOIN (SELECT id_proyecto, SUM(monto) AS pendiente FROM _ap WHERE pago_completado = false AND fecha_pago >= v_hoy GROUP BY 1) pe ON pe.id_proyecto = pr.id
      WHERE pr.activo = true
        AND (p_proyecto_id IS NULL OR pr.id = p_proyecto_id)
      ORDER BY pr.nombre
    ) pp
  ));

  -- ════ Cobrado mensual (año actual + 4 previos = 5 años) ════
  result := result || jsonb_build_object('cobrado_mensual', (
    SELECT COALESCE(jsonb_agg(row_to_json(cm)), '[]'::jsonb)
    FROM (
      SELECT to_char(date_trunc('month', fecha_pago), 'YYYY-MM') AS mes, SUM(monto) AS cobrado
      FROM _pg
      WHERE fecha_pago >= make_date(EXTRACT(YEAR FROM v_hoy)::int - 4, 1, 1)
      GROUP BY 1 ORDER BY 1
    ) cm
  ));

  -- ════ Programado mensual (año actual + 4 previos = 5 años) ════
  result := result || jsonb_build_object('programado_mensual', (
    SELECT COALESCE(jsonb_agg(row_to_json(pm)), '[]'::jsonb)
    FROM (
      SELECT to_char(date_trunc('month', fecha_pago), 'YYYY-MM') AS mes,
        SUM(monto) AS programado,
        SUM(CASE WHEN id_concepto <> 3 THEN monto ELSE 0 END) AS programado_sin_ce
      FROM _ap
      WHERE fecha_pago >= make_date(EXTRACT(YEAR FROM v_hoy)::int - 4, 1, 1)
      GROUP BY 1 ORDER BY 1
    ) pm
  ));

  -- ════ Pipeline (ruta a escrituración) ════
  result := result || jsonb_build_object('pipeline', (
    WITH scope_props AS (
      SELECT prop.id, prop.id_estatus_disponibilidad AS est
      FROM propiedades prop
      JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      JOIN edificios ed ON ed.id = em.id_edificio
      JOIN _sozu sp ON sp.id_proyecto = ed.id_proyecto
      WHERE prop.activo = true
        AND prop.id_estatus_disponibilidad IN (5,7,8,9)
        AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
        AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
    ),
    cand AS (SELECT id FROM scope_props WHERE est = 5),
    -- Acuerdos con AL MENOS un pago cuya validación NO es exactamente 'coincide'
    -- (incluye pagos SIN validación = NULL, además de no_coincide/error).
    notcoin AS (
      SELECT DISTINCT apl.id_acuerdo_pago AS aid
      FROM aplicaciones_pago apl
      LEFT JOIN pago_validaciones pv ON pv.id_pago = apl.id_pago
      WHERE apl.activo = true AND (pv.estado IS DISTINCT FROM 'coincide')
    ),
    -- Estado por CUENTA de la unidad: depto (sin producto) + Bodega(cat 2) +
    -- Estacionamiento(cat 1), que comparten id_propiedad. Se ignoran
    -- condensadoras(4)/paquetes(3)/servicios ('otro'). Conceptos de venta:
    -- SOLO 1-6 (Apartado, Enganche, Contra entrega, Pago especial, Parcialidad,
    -- Cesión de derechos). Mantenimiento/multas/asignación/etc. NO son de la compra.
    --   prev_pend    = acuerdos previos (≠ contra entrega) sin liquidar.
    --   prev_notcoin = acuerdos previos con algún pago sin validar / ≠ 'coincide'.
    cta_unidad AS (
      SELECT p.id AS prop_id,
        CASE WHEN o.id_producto IS NULL THEN 'depto'
             WHEN ps.id_categoria = 1 THEN 'estac'
             WHEN ps.id_categoria = 2 THEN 'bodega'
             ELSE 'otro' END AS tipo,
        bool_or(ap.id_concepto = 3) AS tiene_contra,
        count(*) FILTER (WHERE ap.id_concepto <> 3 AND NOT ap.pago_completado) AS prev_pend,
        count(*) FILTER (WHERE ap.id_concepto <> 3 AND ap.id IN (SELECT aid FROM notcoin)) AS prev_notcoin
      FROM cand p
      JOIN cuentas_cobranza cc ON cc.id_propiedad = p.id AND cc.activo = true AND cc.id_tipo_cancelacion IS NULL
      JOIN ofertas o ON o.id = cc.id_oferta
      LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
      LEFT JOIN acuerdos_pago ap ON ap.id_cuenta_cobranza = cc.id AND ap.activo = true
                                 AND ap.id_concepto IN (1, 2, 3, 4, 5, 6)
      GROUP BY p.id, cc.id, o.id_producto, ps.id_categoria
    ),
    -- "Listas p/ escriturar": el DEPTO tiene contra entrega y sus pagos previos
    -- (todo lo que NO es concepto 3) están LIQUIDADOS y validados 'coincide'; y
    -- ninguna Bodega/Estacionamiento incumple esa misma regla. El contra entrega
    -- (concepto 3, el pago de escrituración) puede estar liquidado o no.
    listas AS (
      SELECT prop_id AS id
      FROM cta_unidad
      GROUP BY prop_id
      HAVING bool_or(tipo = 'depto' AND tiene_contra AND prev_pend = 0 AND prev_notcoin = 0)
         AND count(*) FILTER (WHERE tipo IN ('bodega','estac') AND (prev_pend > 0 OR prev_notcoin > 0)) = 0
    )
    SELECT jsonb_build_object(
      'vendidas',              (SELECT COUNT(*) FROM scope_props WHERE est = 5),
      'listas_escrituracion',  (SELECT COUNT(*) FROM listas),
      'en_escrituracion',      (SELECT COUNT(*) FROM scope_props WHERE est = 7),
      'entregadas',            (SELECT COUNT(*) FROM scope_props WHERE est = 8),
      'pagadas_completamente', (SELECT COUNT(*) FROM scope_props WHERE est = 9)
    )
  ));

  -- ════ CEPs sin extraer = pagos con url_cep IS NULL ════
  result := result || jsonb_build_object('ceps_sin_validar', (
    SELECT COUNT(*)
    FROM pagos p
    JOIN cuentas_cobranza cc ON cc.id = p.id_cuenta_cobranza
    LEFT JOIN cuentas_cobranza ccp ON ccp.id = cc.id_cuenta_cobranza_padre
    LEFT JOIN ofertas o ON o.id = cc.id_oferta
    LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
    LEFT JOIN propiedades prop ON prop.id = COALESCE(cc.id_propiedad, ccp.id_propiedad)
    LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
    LEFT JOIN edificios ed ON ed.id = em.id_edificio
    WHERE p.activo = true
      AND p.url_cep IS NULL
      AND ed.id_proyecto IN (SELECT id_proyecto FROM _sozu)
      AND (o.id_producto IS NULL OR ps.id_categoria IN (1, 2))
      AND (p_proyecto_id IS NULL OR ed.id_proyecto = p_proyecto_id)
      AND (p_entidad_ids IS NULL OR prop.id_entidad_relacionada_dueno = ANY(p_entidad_ids))
  ));

  -- ════ Clientes críticos (cuentas con 3+ parcialidades vencidas) ════
  result := result || jsonb_build_object('clientes_criticos', (
    WITH cc_eff AS (
      SELECT cc.id AS cuenta_id,
             COALESCE(cc.id_oferta, ccp.id_oferta) AS id_oferta,
             COALESCE(cc.id_propiedad, ccp.id_propiedad) AS id_propiedad
      FROM cuentas_cobranza cc
      LEFT JOIN cuentas_cobranza ccp ON ccp.id = cc.id_cuenta_cobranza_padre
      WHERE cc.activo = true
    ),
    rows AS (
      SELECT e.cuenta_id,
        per.nombre_legal AS cliente_nombre,
        pr.nombre AS proyecto,
        prop.numero_propiedad,
        CASE WHEN o.id_producto IS NOT NULL THEN ps.nombre ELSE NULL END AS producto_nombre,
        CASE WHEN o.id_producto IS NOT NULL THEN 'Producto' ELSE 'Propiedad' END AS tipo_cuenta,
        (SELECT COUNT(*) FROM acuerdos_pago ap
           WHERE ap.id_cuenta_cobranza = e.cuenta_id AND ap.activo = true
             AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
             AND ap.id_concepto IN (1, 2, 3, 4, 5, 6)) AS parcialidades_vencidas,
        (SELECT COALESCE(SUM(GREATEST(ap.monto - COALESCE((
              SELECT SUM(a.monto) FROM aplicaciones_pago a
              WHERE a.id_acuerdo_pago = ap.id AND a.activo = true AND a.es_multa = false), 0), 0)), 0)
           FROM acuerdos_pago ap
           WHERE ap.id_cuenta_cobranza = e.cuenta_id AND ap.activo = true
             AND ap.pago_completado = false AND ap.fecha_pago < v_hoy
             AND ap.id_concepto IN (1, 2, 3, 4, 5, 6)) AS monto_vencido,
        prop.id_estatus_disponibilidad AS est,
        prop.id_entidad_relacionada_dueno AS dueno,
        ed.id_proyecto AS proy_id,
        -- Solo unidad: depto (sin producto) o Bodega(2)/Estacionamiento(1).
        (o.id_producto IS NULL OR ps.id_categoria IN (1, 2)) AS es_unidad
      FROM cc_eff e
      LEFT JOIN ofertas o ON o.id = e.id_oferta
      LEFT JOIN personas per ON per.id = o.id_persona_lead
      LEFT JOIN productos_servicios ps ON ps.id = o.id_producto
      LEFT JOIN propiedades prop ON prop.id = e.id_propiedad
      LEFT JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      LEFT JOIN edificios ed ON ed.id = em.id_edificio
      LEFT JOIN proyectos pr ON pr.id = COALESCE(ed.id_proyecto, ps.id_proyecto)
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'cuenta_id', cuenta_id,
      'cliente_nombre', cliente_nombre,
      'proyecto', proyecto,
      'numero_propiedad', numero_propiedad,
      'producto_nombre', producto_nombre,
      'tipo_cuenta', tipo_cuenta,
      'parcialidades_vencidas', parcialidades_vencidas,
      'monto_vencido', monto_vencido
    ) ORDER BY monto_vencido DESC, parcialidades_vencidas DESC), '[]'::jsonb)
    FROM rows
    WHERE parcialidades_vencidas >= 3
      AND es_unidad
      AND proy_id IN (SELECT id_proyecto FROM _sozu)
      AND (est IS NULL OR est NOT IN (8,9))
      AND (p_proyecto_id IS NULL OR proy_id = p_proyecto_id)
      AND (p_entidad_ids IS NULL OR dueno = ANY(p_entidad_ids))
  ));

  -- ════ Dueños de proyectos SOZU (fuente del filtro) ════
  result := result || jsonb_build_object('duenos', (
    WITH sozu_proj AS (
      SELECT DISTINCT er.id_proyecto
      FROM entidades_relacionadas er
      JOIN edificios ed ON ed.id_proyecto = er.id_proyecto
      WHERE er.cuenta_madre_stp IS NOT NULL AND er.activo = true
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', d.nombre, 'entidad_ids', d.entidad_ids) ORDER BY d.nombre), '[]'::jsonb)
    FROM (
      SELECT COALESCE(per.nombre_comercial, per.nombre_legal, 'Entidad ' || er.id::text) AS nombre,
             array_agg(DISTINCT er.id ORDER BY er.id)::int[] AS entidad_ids
      FROM propiedades prop
      JOIN edificios_modelos em ON em.id = prop.id_edificio_modelo
      JOIN edificios ed ON ed.id = em.id_edificio
      JOIN sozu_proj sp ON sp.id_proyecto = ed.id_proyecto
      JOIN entidades_relacionadas er ON er.id = prop.id_entidad_relacionada_dueno
      LEFT JOIN personas per ON per.id = er.id_persona
      WHERE prop.activo = true
      GROUP BY 1
    ) d
  ));

  RETURN result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_pcobranza_dashboard(integer, date, date, integer[])
  TO anon, authenticated, service_role;
