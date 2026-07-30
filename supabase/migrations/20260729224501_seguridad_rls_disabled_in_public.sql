-- Seguridad · Lints rls_disabled_in_public (112) + policy_exists_rls_disabled (7)
-- Fecha: 2026-07-29 · CSV "errores riesgo 2", nivel ERROR
--
-- PROBLEMA
--   97 tablas de `public` (en el CSV eran 112; 15 eran `borrar_*` ya eliminadas) tienen RLS
--   APAGADO. PostgREST las expone y anon tiene SELECT, INSERT, UPDATE y DELETE sobre las 97
--   —verificado read-only contra prod—, así que con la clave anon publicada en el front
--   cualquiera puede leerlas y reescribirlas hoy. Sin RLS las políticas ni se consultan.
--
--   Es más grave que los lints de riesgo 1: ahí el problema era un predicado permisivo,
--   aquí directamente no hay control. Lo peor del conjunto:
--     · Dinero: pagos (22 571), aplicaciones_pago (33 934), acuerdos_pago (26 506),
--       pago_validaciones, estados_cuenta, facturas_mantenimientos, cuentas_sozu,
--       tabla_datos_cep, cep_audit_log.
--     · Autorización: submenus_permisos (5 908), submenus, menus, menus_roles, roles,
--       permisos, roles_organizacionales, proyectos_acceso. Es decir, anon podía
--       otorgarse permisos reescribiendo el propio catálogo que los define.
--     · PII/legal: notarios, beneficiarios, residentes, legal_flow_*.
--
--   Las 7 de policy_exists_rls_disabled son las que 20260729204503 dejó con políticas
--   correctas pero RLS apagado: las políticas existen y no hacen nada. Aquí solo hace falta
--   encender RLS para que la corrección anterior surta efecto.
--
-- CORRECCIÓN, en dos clases
--
--   CATÁLOGO — datos de referencia sin PII ni dinero. Se preserva la lectura tal como está
--     hoy (incluida anon, por si algún consumidor no inventariado la usa) y se cierra la
--     escritura a authenticated:
--       <tabla>_rls_lectura   FOR SELECT USING (true)
--       <tabla>_rls_escritura FOR ALL TO authenticated con (SELECT auth.uid()) IS NOT NULL
--     El lint excluye a propósito SELECT con USING (true): es lectura pública deliberada.
--
--   RESTRINGIDA — dinero, autorización, PII, legal, staging y respaldos. Se cierra lectura
--     y escritura a authenticated:
--       <tabla>_rls_auth      FOR ALL TO authenticated con (SELECT auth.uid()) IS NOT NULL
--
--   service_role no se afecta en ningún caso (rolbypassrls = true), así que edge functions,
--   crons y n8n siguen igual. authenticated conserva el acceso que tiene hoy.
--
-- POR QUÉ NO ROMPE EL SITIO PÚBLICO
--   Las páginas de src/pages/public solo leen ofertas, personas, usuarios y documentos, y
--   esas cuatro ya tienen RLS. Los landings externos consumen landing_*_rpc, que son
--   SECURITY DEFINER y saltan RLS. Verificado tabla por tabla.
--
-- FUERA DE ALCANCE, POR INDICACIÓN EXPRESA
--   · public.pagos_stp_raw — NO se toca. Queda con RLS apagado y su lint abierto.
--   · Buckets de storage — no se tocan en esta migración.
--
-- ALCANCE DECLARADO: esto cierra la escritura anon y enciende RLS, pero NO añade
--   autorización por fila. Cualquier usuario autenticado sigue pudiendo escribir cualquier
--   fila de estas tablas. Endurecerlo requiere decisión por tabla (dueño, permiso de
--   submenu, impersonación) y va en la fase que ya conversamos.
--
-- Idempotente (guardado por existencia de la política y por relrowsecurity) y
-- self-verifying: aborta si al final queda alguna tabla de public sin RLS fuera de la
-- exclusión declarada.
-- Sin BEGIN/COMMIT (el CI envuelve en transacción).

DROP TABLE IF EXISTS _rls_plan;
CREATE TEMP TABLE _rls_plan (tabla text PRIMARY KEY, clase text NOT NULL);

-- ── CATÁLOGO: lectura pública preservada, escritura solo authenticated ───────────────
INSERT INTO _rls_plan (tabla, clase) VALUES
  ('actividades','catalogo'),
  ('amenidades','catalogo'),
  ('amenidades_proyectos','catalogo'),
  ('bancos_convenio','catalogo'),
  ('caracteristicas','catalogo'),
  ('categorias_multimedia_proyecto','catalogo'),
  ('categorias_producto','catalogo'),
  ('categorias_tipo_documento','catalogo'),
  ('checklist_plantilla_categorias','catalogo'),
  ('checklist_plantilla_items','catalogo'),
  ('checklist_plantillas','catalogo'),
  ('conceptos_pago','catalogo'),
  ('espacios_reservables_edificio','catalogo'),
  ('esquemas_pago','catalogo'),
  ('estados_civil','catalogo'),
  ('estados_mx','catalogo'),
  ('estatus_checklist','catalogo'),
  ('estatus_disponibilidad','catalogo'),
  ('estatus_reserva','catalogo'),
  ('estatus_verificacion','catalogo'),
  ('metodos_pago','catalogo'),
  ('modelos_caracteristicas','catalogo'),
  ('multimedias_modelo','catalogo'),
  ('municipios_mx','catalogo'),
  ('paises','catalogo'),
  ('parentescos','catalogo'),
  ('postventa_subcategorias','catalogo'),
  ('regimen','catalogo'),
  ('tipos_cancelacion','catalogo'),
  ('tipos_cep','catalogo'),
  ('tipos_documento','catalogo'),
  ('tipos_espacio_reservables','catalogo'),
  ('tipos_estacionamiento','catalogo'),
  ('tipos_multa','catalogo'),
  ('tipos_pago','catalogo'),
  ('tipos_propiedad','catalogo'),
  ('tipos_relacion','catalogo'),
  ('tipos_transaccion','catalogo'),
  ('tipos_uso','catalogo'),
  ('unidades_sat','catalogo'),
  ('uso_cfdi','catalogo'),
  ('vistas','catalogo');

-- ── RESTRINGIDA: dinero, autorización, PII, legal, staging y respaldos ───────────────
INSERT INTO _rls_plan (tabla, clase) VALUES
  ('_bak_personas_ocupacion_20260722','restringida'),
  ('acuerdos_pago','restringida'),
  ('adminte_pago','restringida'),
  ('aplicaciones_pago','restringida'),
  ('bancos_agentes','restringida'),
  ('beneficiarios','restringida'),
  ('bodegas_stagin','restringida'),
  ('borra_extraccion_ceps_solo','restringida'),
  ('cep_audit_log','restringida'),
  ('comentarios_verificacion_documento','restringida'),
  ('comisiones_canales','restringida'),
  ('comisiones_propuestas','restringida'),
  ('comisiones_reglas','restringida'),
  ('comisiones_validaciones','restringida'),
  ('contrato_validaciones','restringida'),
  ('cuentas_sozu','restringida'),
  ('entregas_checklist_log','restringida'),
  ('estacionamientos_stagin','restringida'),
  ('estados_cuenta','restringida'),
  ('facturas_mantenimientos','restringida'),
  ('legal_flow_bitacora','restringida'),
  ('legal_flow_etapas','restringida'),
  ('legal_flow_expedientes','restringida'),
  ('legal_flow_historico','restringida'),
  ('menus','restringida'),
  ('menus_roles','restringida'),
  ('multas','restringida'),
  ('notarios','restringida'),
  ('pago_validaciones','restringida'),
  ('pagos','restringida'),
  ('permisos','restringida'),
  ('propiedades_stagin','restringida'),
  ('proyectos_acceso','restringida'),
  ('puestos_organizacionales','restringida'),
  ('reservas','restringida'),
  ('residentes','restringida'),
  ('resultado_historico','restringida'),
  ('roles','restringida'),
  ('roles_organizacionales','restringida'),
  ('submenus','restringida'),
  ('submenus_permisos','restringida'),
  ('tabla_datos_cep','restringida'),
  ('v_esquema_id','restringida'),
  ('v_id_producto','restringida'),
  ('v_id_propiedad','restringida'),
  ('v_id_tipo_pago','restringida'),
  ('v_pago_tipo','restringida');

-- ── SOLO ENCENDER RLS: ya tienen políticas correctas de 20260729204503 ───────────────
INSERT INTO _rls_plan (tabla, clase) VALUES
  ('avisos_legales','solo_rls'),
  ('bancos','solo_rls'),
  ('estatus_persona','solo_rls'),
  ('estatus_proyecto','solo_rls'),
  ('multimedias_propiedad','solo_rls'),
  ('propiedades_caracteristicas','solo_rls'),
  ('tipos_entidad','solo_rls');

-- ════════════════════════════════════════════════════════════════════════════════════
-- Aplicación
-- ════════════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  r          record;
  n_rls      int := 0;
  n_pol      int := 0;
  n_ausente  int := 0;
BEGIN
  FOR r IN SELECT p.tabla, p.clase FROM _rls_plan p ORDER BY p.clase, p.tabla LOOP

    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = r.tabla AND c.relkind IN ('r','p')
    ) THEN
      n_ausente := n_ausente + 1;
      RAISE NOTICE 'drift: no existe public.% — se omite', r.tabla;
      CONTINUE;
    END IF;

    -- Políticas primero, RLS después: así no hay ni un instante con RLS activo y sin
    -- política, que denegaría todo.
    IF r.clase = 'catalogo' THEN
      IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                     AND tablename = r.tabla AND policyname = r.tabla || '_rls_lectura') THEN
        EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT USING (true)',
                       r.tabla || '_rls_lectura', r.tabla);
        n_pol := n_pol + 1;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                     AND tablename = r.tabla AND policyname = r.tabla || '_rls_escritura') THEN
        EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO authenticated '
                       || 'USING ((SELECT auth.uid()) IS NOT NULL) '
                       || 'WITH CHECK ((SELECT auth.uid()) IS NOT NULL)',
                       r.tabla || '_rls_escritura', r.tabla);
        n_pol := n_pol + 1;
      END IF;

    ELSIF r.clase = 'restringida' THEN
      IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                     AND tablename = r.tabla AND policyname = r.tabla || '_rls_auth') THEN
        EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO authenticated '
                       || 'USING ((SELECT auth.uid()) IS NOT NULL) '
                       || 'WITH CHECK ((SELECT auth.uid()) IS NOT NULL)',
                       r.tabla || '_rls_auth', r.tabla);
        n_pol := n_pol + 1;
      END IF;
    END IF;
    -- clase 'solo_rls': las políticas ya existen y son correctas.

    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname='public' AND c.relname = r.tabla AND c.relrowsecurity
    ) THEN
      EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.tabla);
      n_rls := n_rls + 1;
    END IF;

  END LOOP;

  RAISE NOTICE 'RLS activado en % tablas, % políticas creadas, % ausentes por drift',
    n_rls, n_pol, n_ausente;
END $$;

-- ════════════════════════════════════════════════════════════════════════════════════
-- Verificación
-- ════════════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_sin_rls    text;
  v_sin_policy text;
BEGIN
  -- 1. Ninguna tabla del plan puede quedar sin RLS.
  SELECT string_agg(p.tabla, ', ' ORDER BY p.tabla) INTO v_sin_rls
  FROM _rls_plan p
  JOIN pg_class c ON c.relname = p.tabla
  JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
  WHERE c.relkind IN ('r','p') AND NOT c.relrowsecurity;

  IF v_sin_rls IS NOT NULL THEN
    RAISE EXCEPTION 'Tablas del plan que siguen sin RLS: %', v_sin_rls;
  END IF;

  -- 2. RLS encendido sin ninguna política deniega todo: sería romper la app.
  SELECT string_agg(p.tabla, ', ' ORDER BY p.tabla) INTO v_sin_policy
  FROM _rls_plan p
  JOIN pg_class c ON c.relname = p.tabla
  JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
  WHERE c.relkind IN ('r','p')
    AND NOT EXISTS (SELECT 1 FROM pg_policy pol WHERE pol.polrelid = c.oid);

  IF v_sin_policy IS NOT NULL THEN
    RAISE EXCEPTION 'Tablas con RLS activo y SIN políticas (denegarían todo): %', v_sin_policy;
  END IF;

  -- 3. Cobertura: qué queda sin RLS en public fuera de la exclusión declarada.
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO v_sin_rls
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND NOT c.relrowsecurity
    AND c.relname <> 'pagos_stp_raw';   -- exclusión expresa

  IF v_sin_rls IS NOT NULL THEN
    RAISE WARNING 'Quedan tablas de public sin RLS fuera del plan (revisar si son nuevas): %',
      v_sin_rls;
  END IF;

  RAISE NOTICE 'Verificación OK: RLS activo y con políticas en todas las tablas del plan';
  RAISE NOTICE 'Excluida por indicación expresa: public.pagos_stp_raw (sigue sin RLS)';
END $$;

DROP TABLE IF EXISTS _rls_plan;

-- ════════════════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ════════════════════════════════════════════════════════════════════════════════════
-- Este cambio es REVERSIBLE SIN PÉRDIDA DE DATOS: solo toca metadatos (flag de RLS y
-- políticas), no hace INSERT/UPDATE/DELETE/DROP de datos. Y el CI envuelve el archivo en
-- una transacción, así que si falla a la mitad no queda nada aplicado.
--
-- REVERSA MÍNIMA — para un incidente puntual, sin revertir todo. Devuelve una tabla al
-- comportamiento previo al instante; las políticas quedan inertes y ni hace falta borrarlas:
--
--   ALTER TABLE public.<tabla> DISABLE ROW LEVEL SECURITY;
--
-- REVERSA COMPLETA — copiar a supabase/migrations/ con timestamp NUEVO y desplegar por CI.
-- Una migración aplicada no se "desaplica" editando su archivo: hay que avanzar con otra.
-- Elimina solo las políticas creadas aquí; conserva las de las 7 tablas de 20260729204503,
-- que son anteriores y con RLS apagado quedan inertes (el estado previo exacto).
--
--   DO $rb$
--   DECLARE r record; n_rls int := 0; n_pol int := 0;
--   BEGIN
--     FOR r IN
--       SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--       WHERE n.nspname='public' AND c.relkind IN ('r','p') AND c.relrowsecurity
--         AND (EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid
--                      AND p.polname IN (c.relname||'_rls_lectura', c.relname||'_rls_escritura',
--                                        c.relname||'_rls_auth'))
--              OR c.relname IN ('avisos_legales','bancos','estatus_persona','estatus_proyecto',
--                               'multimedias_propiedad','propiedades_caracteristicas','tipos_entidad'))
--     LOOP
--       EXECUTE format('ALTER TABLE public.%I DISABLE ROW LEVEL SECURITY', r.relname);
--       n_rls := n_rls + 1;
--     END LOOP;
--
--     FOR r IN
--       SELECT c.relname, p.polname FROM pg_policy p
--       JOIN pg_class c ON c.oid = p.polrelid
--       JOIN pg_namespace n ON n.oid = c.relnamespace
--       WHERE n.nspname='public'
--         AND p.polname IN (c.relname||'_rls_lectura', c.relname||'_rls_escritura',
--                           c.relname||'_rls_auth')
--     LOOP
--       EXECUTE format('DROP POLICY %I ON public.%I', r.polname, r.relname);
--       n_pol := n_pol + 1;
--     END LOOP;
--
--     RAISE NOTICE 'rollback: RLS apagado en %, % políticas eliminadas', n_rls, n_pol;
--   END $rb$;
