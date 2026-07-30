-- Portal Cobranza · get_pcobranza_validacion_pagos (RPC nueva)
-- Fecha: 2026-07-30
-- Spec: sozu-admin/Ejecuciones_manuales/portal-cobranza/20260729_rpc_validacion_pagos.md
--
-- QUÉ RESUELVE
--   Validación de Pagos cargaba todos los pagos con `count:'exact'` + N peticiones `.range()`
--   EN PARALELO ordenadas por `fecha_pago`. Dos fallas silenciosas:
--     · `fecha_pago` no es única (hasta 95 pagos comparten fecha), así que las filas empatadas
--       en la frontera de cada página se duplicaban o se perdían;
--     · si el `count` fallaba, `numChunks` caía a 1 y la pantalla mostraba 1,000 pagos de
--       22,544 sin ningún error visible.
--   Además rearmaba el contexto con ~10 consultas encadenadas y reglas propias, distintas a
--   las de Cuentas de Cobranza y Relación de Pagos (clasificaba el tipo por el NOMBRE del
--   producto y resolvía la propiedad en otro orden).
--
--   Esta RPC entrega el mismo renglón que RP, paginado por KEYSET sobre `pago_id` (llave
--   única): sin duplicados, sin huecos y sin depender de ningún count. Se llama en bucle;
--   la primera página sin `p_after_id` y cada vuelta con el `pago_id` más chico de la
--   anterior, hasta que devuelve `[]`.
--
-- CAMBIO DE COMPORTAMIENTO CONOCIDO
--   El cliente pasa a ser `ofertas.id_persona_lead` (el mismo que ya usan CC y RP). Antes
--   esta pantalla mostraba al comprador con mayor `porcentaje_copropiedad`. En copropiedades
--   donde el lead no es el mayoritario el nombre puede cambiar; a cambio, las tres pantallas
--   nombran igual al mismo cliente.
--
-- CORRECCIONES SOBRE LA SPEC (verificadas read-only contra prod el 2026-07-30)
--   a) GUARDA DE AUTORIZACIÓN INTERNA. Es SECURITY DEFINER: corre como postgres (BYPASSRLS).
--      Sin guarda, cualquier `authenticated` —622 usuarios `Cliente`, 829 `Inmobiliaria`,
--      322 `Agente Inmobiliario` activos— puede volcar los 22,544 pagos con CLABE, monto,
--      nombre y correo. Se usa la regla base de 20260730020000 con el catálogo de
--      20260730060000: current_puede('pagos','leer').
--   b) REVOKE a anon. `pg_default_acl` de Supabase otorga EXECUTE a `anon` en toda función
--      nueva de public; sin el REVOKE esta RPC nacería invocable sin sesión, revirtiendo
--      20260729204501_seguridad_revoke_anon_funciones_secdef.
--   c) No se crean los índices que pedía la spec: `pagos_pkey` ya sirve el keyset (de 22,578
--      pagos solo 34 están inactivos) y `uq_apppago_pago_acuerdo` ya resuelve el LATERAL de
--      aplicaciones por `id_pago`. Detalle en 20260730061000.
--
-- NOTA SOBRE `es_multa`
--   `monto_aplicado` suma TODAS las aplicaciones activas del pago, multas incluidas, igual
--   que Relación de Pagos. CC excluye `es_multa = true` de su `total_aplicado`. Divergencia
--   conocida, pendiente de decisión (contrato canónico).
--
-- El readiness de escrituración de la pantalla NO se calcula aquí: sale de
-- get_pcobranza_cuentas_cobranza (`propiedad_id` + `liquidada`), para que el "liquidada" de
-- Validación sea el mismo número que ve cobranza.
--
-- Idempotente (CREATE OR REPLACE; la función no existe en prod al escribir esto) y
-- self-verifying. Sin BEGIN/COMMIT (el CI envuelve en transacción).

CREATE OR REPLACE FUNCTION public.get_pcobranza_validacion_pagos(
  p_after_id bigint  DEFAULT NULL,
  p_limit    integer DEFAULT 1000
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════════
  -- AUTORIZACIÓN — regla base 2026-07-29 (ver 20260730020000 y 20260730060000).
  -- ═══════════════════════════════════════════════════════════════════════════
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;
    IF NOT public.current_puede('pagos', 'leer') THEN
      RAISE EXCEPTION 'Rol sin permiso de lectura sobre pagos.' USING ERRCODE = '42501';
    END IF;
  END IF;

  WITH page AS (
    SELECT
      p.id AS pago_id,
      p.id_cuenta_cobranza AS cuenta_id,
      p.monto, p.fecha_pago, p.id_metodos_pago, mp.nombre AS metodo_pago,
      p.clave_rastreo, p.url_cep, p.url_recibo, p.descripcion,
      COALESCE(p.validacion_documental_efectivo, false) AS validacion_documental_efectivo,
      pv.estado        AS estado_validacion,
      pv.motivo        AS validacion_motivo,
      pv.monto_esperado,
      pv.monto_real,
      proy.nombre      AS proyecto,
      proy.id          AS proyecto_id,
      prop.numero_propiedad,
      prop.id          AS propiedad_id,
      prop.id_estatus_disponibilidad,
      CASE WHEN cc.activo = false AND cc.id_tipo_cancelacion IS NOT NULL THEN 'Cancelada'
           WHEN cc.activo = false                                        THEN 'Inactiva'
           ELSE est.nombre END AS estatus_propiedad,
      per.nombre_legal AS cliente_nombre,
      per.email        AS cliente_email,
      ps.nombre        AS producto_nombre,
      -- ── Bloque canónico (90_contrato_canonico_pagos.md §2) ──────────────────
      CASE
        WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL THEN 'Mantenimiento'
        WHEN o.id_producto IS NOT NULL THEN 'Producto'
        ELSE 'Propiedad'
      END AS tipo_cuenta,
      CASE
        WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL THEN 'Mantenimiento'
        WHEN o.id_producto IS NULL      THEN 'Propiedad'
        WHEN ps.id_categoria = 1        THEN 'Estacionamiento'
        WHEN ps.id_categoria = 2        THEN 'Bodega'
        WHEN ps.id_categoria IN (3, 4)  THEN 'Producto'
        ELSE 'Adicional'
      END AS tipo_categoria,
      CASE
        WHEN cc.id_cuenta_cobranza_padre IS NOT NULL AND cc.id_oferta IS NULL
          THEN 'CM-'  || lpad(cc.id::text, 6, '0')
        WHEN o.id_producto IS NOT NULL
          THEN 'CCP-' || lpad(cc.id::text, 6, '0')
        ELSE 'CC-'    || lpad(cc.id::text, 6, '0')
      END AS cuenta_folio,
      -- ────────────────────────────────────────────────────────────────────────
      COALESCE(apl.aplicado, 0) AS monto_aplicado,
      CASE
        WHEN COALESCE(apl.n, 0) = 0                      THEN 'sin_aplicar'
        WHEN COALESCE(apl.aplicado, 0) >= p.monto - 0.01 THEN 'pagado'
        ELSE 'parcial'
      END AS estado_pago
    FROM pagos p
    LEFT JOIN metodos_pago          mp   ON mp.id   = p.id_metodos_pago
    -- ── Bloque canónico: herencia de cuenta padre (§1) ────────────────────────
    LEFT JOIN cuentas_cobranza      cc   ON cc.id   = p.id_cuenta_cobranza
    LEFT JOIN cuentas_cobranza      ccp  ON ccp.id  = cc.id_cuenta_cobranza_padre
    LEFT JOIN ofertas               o    ON o.id    = COALESCE(cc.id_oferta, ccp.id_oferta)
    LEFT JOIN propiedades           prop ON prop.id = COALESCE(cc.id_propiedad, ccp.id_propiedad, o.id_propiedad)
    LEFT JOIN edificios_modelos     em   ON em.id   = prop.id_edificio_modelo
    LEFT JOIN edificios             ed   ON ed.id   = em.id_edificio
    LEFT JOIN estatus_disponibilidad est ON est.id  = prop.id_estatus_disponibilidad
    LEFT JOIN productos_servicios   ps   ON ps.id   = o.id_producto
    LEFT JOIN personas              per  ON per.id  = o.id_persona_lead
    LEFT JOIN proyectos             proy ON proy.id = COALESCE(ed.id_proyecto, ps.id_proyecto)
    -- ──────────────────────────────────────────────────────────────────────────
    LEFT JOIN pago_validaciones     pv   ON pv.id_pago = p.id   -- UNIQUE (id_pago)
    LEFT JOIN LATERAL (
      SELECT COALESCE(SUM(a.monto), 0) AS aplicado, COUNT(*) AS n
      FROM aplicaciones_pago a
      WHERE a.id_pago = p.id AND a.activo = true
    ) apl ON true
    -- Universo (§3): idéntico al de RP
    WHERE p.activo = true
      AND (p_after_id IS NULL OR p.id < p_after_id)
    ORDER BY p.id DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 1000), 1), 5000)
  )
  SELECT jsonb_build_object(
    'pagos', COALESCE((SELECT jsonb_agg(to_jsonb(page) ORDER BY pago_id DESC) FROM page), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_pcobranza_validacion_pagos(bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pcobranza_validacion_pagos(bigint, integer)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Self-verifying
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_oid oid;
  v_n   integer;
  v_src text;
BEGIN
  SELECT count(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_pcobranza_validacion_pagos';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'Quedaron % sobrecargas de get_pcobranza_validacion_pagos', v_n;
  END IF;

  v_oid := to_regprocedure('public.get_pcobranza_validacion_pagos(bigint, integer)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'No quedó la firma (bigint, integer)';
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = v_oid;
  IF v_src NOT LIKE '%current_puede(''pagos'', ''leer'')%' OR v_src NOT LIKE '%42501%' THEN
    RAISE EXCEPTION 'La función quedó sin guarda de autorización interna';
  END IF;
  IF (SELECT provolatile FROM pg_proc WHERE oid = v_oid) <> 's' THEN
    RAISE EXCEPTION 'La función no quedó STABLE';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
    RAISE EXCEPTION 'La función no quedó SECURITY DEFINER';
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'anon quedó con EXECUTE sobre get_pcobranza_validacion_pagos';
  END IF;
  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated/service_role se quedaron sin EXECUTE';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rls_tablas_submenus WHERE tabla = 'pagos' AND activo = true) THEN
    RAISE EXCEPTION 'Falta el catálogo authz de pagos (20260730060000)';
  END IF;

  RAISE NOTICE 'get_pcobranza_validacion_pagos OK: guarda 42501, sin anon';
END $$;
