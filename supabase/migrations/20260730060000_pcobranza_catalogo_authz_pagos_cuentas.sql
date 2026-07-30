-- Seguridad · Catálogo de authz para `pagos` y `cuentas_cobranza`
-- Fecha: 2026-07-30
--
-- POR QUÉ
--   Las tres RPC del Portal Cobranza (cuentas de cobranza, relación de pagos y validación
--   de pagos) son SECURITY DEFINER: corren como postgres, que tiene BYPASSRLS, así que el
--   RLS de `pagos`/`cuentas_cobranza` no las limita. Hoy `authenticated` es un solo rol de
--   Postgres compartido por TODOS los usuarios de la app, de modo que cualquiera con sesión
--   —incluidos 622 usuarios con rol `Cliente`, 829 `Inmobiliaria` y 322 `Agente
--   Inmobiliario` activos, verificado read-only contra prod el 2026-07-30— puede invocarlas
--   y leer el libro de cobranza completo con CLABE, monto, nombre y correo de cada cliente.
--   Es el hallazgo que ya reportó 20260730050000_auditoria_secdef_sin_guarda_authz.
--
--   La remediación va DENTRO de cada función (migraciones 20260730062000/63000/64000). Esta
--   migración solo prepara el catálogo que esas guardas consultan, para que el permiso sea
--   dato editable y no lógica incrustada.
--
-- QUÉ HACE
--   Declara en `rls_tablas_submenus` (creada en 20260730020000_rls_estandar_base_tanda0)
--   qué submenús legitiman la LECTURA de `pagos` y `cuentas_cobranza`. Con eso,
--   `current_puede('<tabla>', 'leer')` —rama (b) de la regla base: permiso en submenú activo
--   de menú activo, más rama de impersonación— responde por las tres RPC.
--
--   Rutas declaradas (todas verificadas contra prod; el JOIN es por vista_front_end, así que
--   una ruta inexistente se omitiría en silencio: por eso el bloque self-verifying de abajo):
--
--     pagos              ← /admin/portal-cobranza/relacion-pagos      (submenú 93)
--                        ← /admin/portal-escrituracion/relacion-pagos (submenú 298)
--                        ← /admin/validacion-pagos                    (submenú 354)
--     cuentas_cobranza   ← /admin/portal-cobranza/cuentas-cobranza    (submenú 91)
--                        ← /admin/validacion-pagos                    (submenú 354)
--
--   `cuentas_cobranza` incluye /admin/validacion-pagos a propósito: ValidacionPagos.tsx
--   llama a get_pcobranza_cuentas_cobranza para el readiness de escrituración
--   (propiedad_id + liquidada), y el rol 10 «Administrador de data» tiene `leer` en
--   Validación pero no en Cuentas de Cobranza. Sin esta fila ese rol recibiría 403 en la
--   llamada secundaria.
--
-- QUÉ NO HACE
--   No toca ninguna policy. Las policies vigentes de `pagos` (`auth.uid() IS NOT NULL`) y de
--   `cuentas_cobranza` (passthrough + socio bancario) quedan igual: el comportamiento de la
--   app por acceso directo a tabla no cambia. Cerrar esas tablas con la plantilla estándar
--   es trabajo de la tanda 1.
--
-- Idempotente (ON CONFLICT DO NOTHING) y self-verifying.
-- Sin BEGIN/COMMIT (el CI envuelve en transacción).

INSERT INTO public.rls_tablas_submenus (tabla, submenu_id, permiso_id, activo)
SELECT v.tabla, s.id, p.id, true
FROM (VALUES
  ('pagos',            '/admin/portal-cobranza/relacion-pagos'),
  ('pagos',            '/admin/portal-escrituracion/relacion-pagos'),
  ('pagos',            '/admin/validacion-pagos'),
  ('cuentas_cobranza', '/admin/portal-cobranza/cuentas-cobranza'),
  ('cuentas_cobranza', '/admin/validacion-pagos')
) AS v(tabla, ruta)
JOIN public.submenus s ON s.vista_front_end = v.ruta AND s.activo = true
JOIN public.permisos p ON p.nombre = 'leer'
ON CONFLICT (tabla, submenu_id, permiso_id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Self-verifying: el catálogo tiene que dejar entrar a cobranza y dejar fuera a
-- los roles no internos. Si alguna ruta no existiera, la tabla quedaría con cero
-- filas y la guarda negaría a TODOS: eso aborta el CI aquí y no en producción.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_tabla text;
  v_n     integer;
  v_roles integer[];
BEGIN
  FOREACH v_tabla IN ARRAY ARRAY['pagos', 'cuentas_cobranza']
  LOOP
    SELECT count(*) INTO v_n
    FROM public.rls_tablas_submenus WHERE tabla = v_tabla AND activo = true;
    IF v_n = 0 THEN
      RAISE EXCEPTION 'El catálogo quedó sin filas para %: la guarda negaría a todos', v_tabla;
    END IF;

    SELECT array_agg(DISTINCT sp.rol_id ORDER BY sp.rol_id) INTO v_roles
    FROM public.rls_tablas_submenus rts
    JOIN public.submenus s          ON s.id  = rts.submenu_id AND s.activo = true
    JOIN public.menus m             ON m.id  = s.menu_id      AND m.activo = true
    JOIN public.submenus_permisos sp ON sp.submenu_id = s.id
                                    AND sp.permiso_id = rts.permiso_id
                                    AND sp.activo = true
    WHERE rts.tabla = v_tabla AND rts.activo = true;

    -- Administrador de cobranza (12) y Super Administrador (1) tienen que pasar.
    IF NOT (v_roles @> ARRAY[1, 12]) THEN
      RAISE EXCEPTION 'El catálogo de % deja fuera a Super Administrador o Administrador de cobranza: %',
        v_tabla, v_roles;
    END IF;

    -- Ningún rol NO interno puede quedar con lectura por esta vía.
    IF EXISTS (SELECT 1 FROM public.roles r
               WHERE r.id = ANY(v_roles) AND r.es_rol_interno = false) THEN
      RAISE EXCEPTION 'El catálogo de % otorga lectura a un rol no interno: %',
        v_tabla,
        (SELECT string_agg(r.nombre, ', ') FROM public.roles r
         WHERE r.id = ANY(v_roles) AND r.es_rol_interno = false);
    END IF;

    RAISE NOTICE 'Catálogo authz % OK: % submenús, roles con lectura %', v_tabla, v_n, v_roles;
  END LOOP;
END $$;
