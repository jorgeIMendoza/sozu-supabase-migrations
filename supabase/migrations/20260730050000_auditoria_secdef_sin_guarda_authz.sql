-- Auditoría · Funciones SECURITY DEFINER sin guarda de autorización interna
-- Fecha: 2026-07-30 · CSV completo de lints (144 hallazgos)
--
-- POR QUÉ ESTA AUDITORÍA Y NO UN FIX MASIVO
--   El lint authenticated_security_definer_function_executable (103 hallazgos) se venía
--   descartando como "inherente al patrón RPC de Supabase": revocar EXECUTE a authenticated
--   dejaría la app sin backend. Eso sigue siendo cierto, pero esconde un riesgo real que el
--   lint no sabe expresar.
--
--   SECURITY DEFINER ejecuta como postgres, que tiene BYPASSRLS. Si la función no comprueba
--   por dentro quién la llama, el RLS de las tablas base no protege nada: cualquier usuario
--   con sesión válida obtiene los datos completos.
--
--   Medición read-only contra prod al escribir esto:
--     103 funciones SECURITY DEFINER ejecutables por authenticated
--      19 con guarda interna (user_has_permission / is_admin_user / RAISE 42501 / ...)
--      84 SIN NINGUNA GUARDA
--
--   Y del lado de quién puede llamarlas:
--     622 usuarios activos con rol `Cliente`, es_rol_interno = false — compradores, no
--     personal. Todos autenticados, todos capaces de invocar cualquiera de esas 84.
--
--   Entre las 84 sin guarda hay lectura de dinero y de padrón:
--     get_cuentas_cobranza_export (3 sobrecargas), get_pcobranza_relacion_pagos,
--     get_pcobranza_cuentas_cobranza, get_pcobranza_cuenta_detalle, get_expediente_cobranza,
--     get_kpis_alta_direccion, get_kpi_payment_report, get_totales_comisiones_sozu,
--     get_totales_comisionistas, get_pending_payments, get_payments_sin_evidencia,
--     get_usuarios_by_emails (enumeración de usuarios), scan_legacy_urls.
--
--   O sea: hoy, en producción, un comprador con su sesión del portal puede volcar el libro
--   de cobranza completo. No es teórico ni requiere explotar nada — es una llamada RPC.
--
-- POR QUÉ NO SE ARREGLA EN ESTA MIGRACIÓN
--   El arreglo es meter la guarda DENTRO de cada función, lo que obliga a CREATE OR REPLACE
--   de 84 cuerpos y, sobre todo, a decidir por función qué permiso exige. Hacerlo a ciegas
--   rompería la app en formas difíciles de diagnosticar. Además `authenticated` es un único
--   rol de Postgres compartido por todos los usuarios de la app: no se puede diferenciar a
--   nivel de GRANT, tiene que ser lógica interna.
--
--   Ojo con el atajo tentador: `user_has_internal_role()` a secas dejaría fuera al rol
--   `Directores` (es_rol_interno = false, 1 usuario activo), que sí necesita los KPIs de
--   alta dirección. La guarda correcta compone rol interno, permiso de submenu activo,
--   dueño del registro e impersonación — el modelo que ya está definido.
--
-- QUÉ HACE ESTA MIGRACIÓN
--   Inventaria y reporta. No modifica ninguna función. Deja la cuenta en el log del CI de
--   cada entorno para que el avance sea medible entre tandas y no se pierda de vista.
--
-- RESTO DEL CSV, sin acción:
--   · 28 anon_security_definer_function_executable → los 27 nombres distintos son
--     exactamente las exclusiones deliberadas: 10 flujos públicos con token y 17 helpers de
--     authz que las policies de RLS invocan. Quitarles anon rompe el sitio público o el RLS.
--   · 9 public_bucket_allows_listing → excluidos por indicación expresa.
--   · 1 extension_in_public (pg_net) → falso positivo: sus 15 objetos viven en el esquema
--     `net`, solo el extnamespace de metadatos dice public, y extrelocatable = false.
--   · 3 de configuración (OTP, leaked password protection, versión de Postgres) → dashboard.
--
-- Sin efectos secundarios: no modifica nada. Idempotente por construcción.
-- Sin BEGIN/COMMIT (el CI envuelve en transacción).

DO $$
DECLARE
  r           record;
  v_reporte   text := '';
  n_total     int  := 0;
  n_sin       int  := 0;
  n_muta      int  := 0;
  n_clientes  int  := 0;
BEGIN
  SELECT count(*) INTO n_clientes
  FROM public.usuarios u JOIN public.roles rr ON rr.id = u.rol_id
  WHERE u.activo AND NOT rr.es_rol_interno;

  FOR r IN
    SELECT p.oid::regprocedure::text AS firma,
           pg_get_functiondef(p.oid)  AS def
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
      AND p.prolang <> (SELECT oid FROM pg_language WHERE lanname = 'c')
    ORDER BY p.proname
  LOOP
    n_total := n_total + 1;

    IF r.def ~* 'user_has_permission|is_admin_user|is_super_admin|current_es_super_admin|user_has_internal_role|42501|insufficient_privilege' THEN
      CONTINUE;   -- tiene guarda
    END IF;

    n_sin := n_sin + 1;
    IF r.def ~* '(INSERT INTO|UPDATE |DELETE FROM)' THEN
      n_muta := n_muta + 1;
    END IF;

    -- Solo se listan las de mayor riesgo, para que el aviso sea legible.
    IF r.firma ~* 'cobranza|pcobranza|pago|kpi|comision|export|expediente|usuarios_by_emails|legacy' THEN
      v_reporte := v_reporte || format(E'\n  %s%s',
        CASE WHEN r.def ~* '(INSERT INTO|UPDATE |DELETE FROM)' THEN '[MUTA] ' ELSE '' END,
        r.firma);
    END IF;
  END LOOP;

  IF n_sin = 0 THEN
    RAISE NOTICE 'Auditoría SECURITY DEFINER OK: las % funciones tienen guarda interna', n_total;
    RETURN;
  END IF;

  RAISE WARNING E'% de % funciones SECURITY DEFINER ejecutables por authenticated NO tienen guarda de autorización interna (% de ellas mutan datos).\nEjecutan como postgres (BYPASSRLS), así que el RLS de las tablas base no las limita: cualquiera de los % usuarios activos con rol NO interno puede invocarlas.\n\nDe mayor riesgo (dinero, padrón, expedientes):%\n\nRemediación: guarda interna por función componiendo rol interno + permiso de submenu activo + dueño del registro + impersonación. Requiere decidir el permiso por función; no se puede hacer de forma mecánica.',
    n_sin, n_total, n_muta, n_clientes, v_reporte;
END $$;
