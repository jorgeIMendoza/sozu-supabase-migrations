-- =============================================================================
-- sync_conyuge_compradores — RE-EMISIÓN para paridad con dev
--
-- Contenido idéntico a 20260729000000_sync_conyuge_compradores_guard_grant.sql,
-- que YA está aplicada en prod (fila 20260729000000, cuerpo vivo md5
-- 5ffdc8f0d5758a233bce6a4b144e40f9) pero NUNCA corrió en dev: allá la versión
-- 20260729000000 está ocupada por seguridad_revoke_anon_funciones_secdef (que en
-- dev aparece duplicada en 20260729000000 y 20260729204501, residuo de un
-- renumerado previo). supabase db push decide por número de versión, así que en
-- dev el archivo original nunca se aplicará, ni con --include-all.
--
-- Por qué una re-emisión y NO renombrar el archivo original: prod tiene la fila
-- 20260729000000 apuntando a ese archivo. Renombrarlo dejaría en prod una versión
-- remota sin archivo local, que es justo lo que detiene a supabase db push (de ahí
-- la lista de `migration repair --status reverted` en deploy-prod.yml). Con la
-- re-emisión, dev la aplica por primera vez y prod la vuelve a aplicar sin efecto:
-- el CREATE OR REPLACE deja el mismo cuerpo (md5 sin cambios), el REVOKE/GRANT es
-- idempotente y el self-verify pasa. No se toca schema_migrations a mano.
--
-- Única diferencia respecto al archivo original: la aserción de "9 roles con
-- escritura en /admin/compradores" pasa de EXCEPTION a WARNING, porque es una
-- expectativa del entorno (los catálogos de dev y prod difieren) y no una
-- invariante de correctitud: el guard resuelve los permisos en tiempo de
-- ejecución con user_has_permission, así que funciona con cualquier conteo.
--
-- Bug original: "Editar Comprador" (/admin/compradores) devuelve 403. El UPDATE
-- de personas se comitea, la llamada posterior a sync_conyuge_compradores falla
-- con 42501 (permission denied for function) y la mutación se marca como
-- fallida: guardado a medias con toast rojo. No es RLS, es ACL de función: la
-- función quedó en 'postgres | service_role' tras una pasada de REVOKE ALL.
--
-- Verificado read-only contra prod el 2026-07-29:
--   · ACL vivo: postgres=X/postgres | service_role=X/postgres (sin authenticated).
--   · Cuerpo vivo md5 ca0847b047ad3632209cb7dac2d581e6. La lógica de reparto
--     50/50 de esta migración es idéntica al cuerpo desplegado; lo único que se
--     agrega es el guard.
--   · Ninguna otra función ni trigger de la base llama a sync_conyuge_compradores.
--   · current_puede_impersonar() y current_persona_id() resuelven por auth.uid().
--
-- Corrección respecto al documento de la solicitud:
--   a) El guard propuesto era `current_puede_impersonar() OR dueño del lead`.
--      Eso deja fuera a 5 roles que HOY tienen permiso 'actualizar'/'crear' sobre
--      el submenú 15 (/admin/compradores) y NO tienen puede_impersonar:
--        2  Administrador de Proyecto   (2 usuarios activos)
--        9  Agente Interno              (1)
--        10 Administrador de data       (1)
--        11 Documentador Escrituras     (0)
--        16 Gestion Mantenimiento       (0)
--      Para ellos el 403 de ACL se habría convertido en un 42501 desde dentro de
--      la función: el mismo bug con otro origen. El guard usa la matriz de
--      permisos de la app (user_has_permission, ya GRANT-eada a authenticated),
--      que cubre a los 9 roles con permiso de escritura y sigue excluyendo al
--      rol 23 Cliente.
--   b) El guard solo se aplica a sesiones de la API (anon/authenticated). Con
--      service_role, cron o psql, auth.uid() es NULL y los tres helpers darían
--      false: el guard del documento habría roto cualquier llamada de backend.
--   c) Se conserva la rama de dueño del lead (entidades_relacionadas
--      .id_persona_duena_lead), igual que la policy personas_update, por si la
--      pantalla se abre a agentes externos más adelante.
--
-- NO se toca execute_safe_query: otorgarle EXECUTE a authenticated equivale a
-- SELECT arbitrario sobre todo el esquema saltándose RLS (SECURITY DEFINER con
-- EXECUTE format y lista negra por regex). El REVOKE fue correcto; el camino es
-- el refactor a RPCs específicas.
-- NO se toca actualizar_estatus_reservas: diferido por decisión del 2026-07-29
-- (reservas tiene 0 filas en prod, la función es no-op).
-- =============================================================================

-- Pre-condiciones: si falta un helper, abortar antes de dejar un guard que
-- rechace a todo el mundo.
DO $$
BEGIN
  IF to_regprocedure('public.user_has_permission(text, text)') IS NULL
     OR to_regprocedure('public.current_puede_impersonar()') IS NULL
     OR to_regprocedure('public.current_persona_id()') IS NULL THEN
    RAISE EXCEPTION 'Faltan helpers de autorización (user_has_permission / current_puede_impersonar / current_persona_id)';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.submenus
    WHERE vista_front_end = '/admin/compradores' AND activo = true
  ) THEN
    RAISE EXCEPTION 'El submenú /admin/compradores no está activo: el guard dejaría fuera a todos';
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.sync_conyuge_compradores(p_id_persona integer)
 RETURNS TABLE(mensaje text, cuentas_procesadas integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_id_conyuge INTEGER;
    v_cuenta_record RECORD;
    v_nuevo_porcentaje NUMERIC;
    v_existe_conyuge BOOLEAN;
    v_existe_persona_original BOOLEAN;
    v_contador INTEGER := 0;
    v_sesion_api BOOLEAN;
BEGIN
    -- ====================================================================
    -- GUARD (nuevo). La función es SECURITY DEFINER y escribe porcentajes de
    -- copropiedad, así que no basta con abrir EXECUTE a authenticated: el rol
    -- 23 (Cliente) también es authenticated.
    --
    -- Solo se exige autorización cuando la llamada viene de la API REST
    -- (PostgREST hace SET LOCAL ROLE anon/authenticated). Con service_role,
    -- pg_cron o psql, auth.uid() es NULL y los helpers darían false.
    -- ====================================================================
    v_sesion_api := COALESCE(current_setting('role', true), '') IN ('anon', 'authenticated')
                    OR auth.uid() IS NOT NULL;

    IF v_sesion_api AND NOT (
        -- Matriz de permisos de la app: los 9 roles con escritura en el
        -- submenú /admin/compradores. Excluye Cliente, Vendedor y Solo Lectura.
        public.user_has_permission('/admin/compradores', 'actualizar')
        OR public.user_has_permission('/admin/compradores', 'crear')
        -- Bypass administrativo, igual que la policy personas_update.
        OR public.current_puede_impersonar()
        -- Dueño del lead (para cuando la pantalla se abra a agentes externos).
        OR EXISTS (
            SELECT 1 FROM public.entidades_relacionadas er
            WHERE er.id_persona = p_id_persona
              AND er.activo = true
              AND er.id_persona_duena_lead = public.current_persona_id()
        )
    ) THEN
        RAISE EXCEPTION 'No autorizado para sincronizar cónyuge de la persona %', p_id_persona
            USING ERRCODE = '42501';
    END IF;

    -- Obtener id_conyuge de la persona
    SELECT id_conyuge INTO v_id_conyuge
    FROM personas
    WHERE id = p_id_persona
      AND activo = true;

    -- Si no tiene cónyuge, retornar mensaje
    IF v_id_conyuge IS NULL THEN
        RETURN QUERY SELECT
            'La persona no tiene cónyuge asignado'::TEXT,
            0::INTEGER;
        RETURN;
    END IF;

    -- Verificar que el cónyuge existe y está activo
    IF NOT EXISTS(
        SELECT 1 FROM personas
        WHERE id = v_id_conyuge
        AND activo = true
    ) THEN
        RETURN QUERY SELECT
            'El cónyuge no existe o no está activo'::TEXT,
            0::INTEGER;
        RETURN;
    END IF;

    -- ====================================================================
    -- LOOP 1: Procesar cuentas donde la PERSONA ORIGINAL es compradora
    -- ====================================================================
    FOR v_cuenta_record IN
        SELECT
            c.id_cuenta_cobranza,
            c.porcentaje_copropiedad
        FROM compradores c
        JOIN cuentas_cobranza cc ON c.id_cuenta_cobranza = cc.id
        JOIN ofertas o ON cc.id_oferta = o.id
        WHERE c.id_persona = p_id_persona
          AND c.activo = true
          AND cc.activo = true
          AND o.id_producto IS NULL  -- Solo propiedades
    LOOP
        -- Verificar si el cónyuge ya existe en esta cuenta
        SELECT EXISTS(
            SELECT 1
            FROM compradores
            WHERE id_persona = v_id_conyuge
              AND id_cuenta_cobranza = v_cuenta_record.id_cuenta_cobranza
              AND activo = true
        ) INTO v_existe_conyuge;

        IF NOT v_existe_conyuge THEN
            -- Dividir el porcentaje actual
            v_nuevo_porcentaje := v_cuenta_record.porcentaje_copropiedad / 2;

            -- Actualizar el porcentaje de la persona original
            UPDATE compradores
            SET porcentaje_copropiedad = v_nuevo_porcentaje,
                fecha_actualizacion = CURRENT_TIMESTAMP
            WHERE id_persona = p_id_persona
              AND id_cuenta_cobranza = v_cuenta_record.id_cuenta_cobranza
              AND activo = true;

            -- Insertar el cónyuge con el otro 50%
            INSERT INTO compradores (
                id_cuenta_cobranza,
                id_persona,
                porcentaje_copropiedad,
                activo,
                fecha_creacion,
                fecha_actualizacion
            ) VALUES (
                v_cuenta_record.id_cuenta_cobranza,
                v_id_conyuge,
                v_nuevo_porcentaje,
                true,
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP
            );

            v_contador := v_contador + 1;
        END IF;
    END LOOP;

    -- ====================================================================
    -- LOOP 2: Procesar cuentas donde el CÓNYUGE es comprador
    -- ====================================================================
    FOR v_cuenta_record IN
        SELECT
            c.id_cuenta_cobranza,
            c.porcentaje_copropiedad
        FROM compradores c
        JOIN cuentas_cobranza cc ON c.id_cuenta_cobranza = cc.id
        JOIN ofertas o ON cc.id_oferta = o.id
        WHERE c.id_persona = v_id_conyuge
          AND c.activo = true
          AND cc.activo = true
          AND o.id_producto IS NULL  -- Solo propiedades
    LOOP
        -- Verificar si la persona original ya existe en esta cuenta del cónyuge
        SELECT EXISTS(
            SELECT 1
            FROM compradores
            WHERE id_persona = p_id_persona
              AND id_cuenta_cobranza = v_cuenta_record.id_cuenta_cobranza
              AND activo = true
        ) INTO v_existe_persona_original;

        IF NOT v_existe_persona_original THEN
            -- Dividir el porcentaje del cónyuge
            v_nuevo_porcentaje := v_cuenta_record.porcentaje_copropiedad / 2;

            -- Actualizar el porcentaje del cónyuge
            UPDATE compradores
            SET porcentaje_copropiedad = v_nuevo_porcentaje,
                fecha_actualizacion = CURRENT_TIMESTAMP
            WHERE id_persona = v_id_conyuge
              AND id_cuenta_cobranza = v_cuenta_record.id_cuenta_cobranza
              AND activo = true;

            -- Insertar la persona original con el otro 50%
            INSERT INTO compradores (
                id_cuenta_cobranza,
                id_persona,
                porcentaje_copropiedad,
                activo,
                fecha_creacion,
                fecha_actualizacion
            ) VALUES (
                v_cuenta_record.id_cuenta_cobranza,
                p_id_persona,
                v_nuevo_porcentaje,
                true,
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP
            );

            v_contador := v_contador + 1;
        END IF;
    END LOOP;

    -- Retornar resultado
    RETURN QUERY SELECT
        format('Sincronización completada. %s cuentas procesadas.', v_contador)::TEXT,
        v_contador::INTEGER;
END;
$function$;

COMMENT ON FUNCTION public.sync_conyuge_compradores(integer) IS
  'Reparte porcentaje_copropiedad 50/50 entre persona y cónyuge en las cuentas de '
  'propiedad (ofertas.id_producto IS NULL). SECURITY DEFINER con guard: desde la API '
  'exige permiso actualizar/crear sobre /admin/compradores, puede_impersonar, o ser '
  'dueño del lead. Llamada desde src/pages/admin/Compradores.tsx (crear/editar).';

REVOKE ALL ON FUNCTION public.sync_conyuge_compradores(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sync_conyuge_compradores(integer) TO authenticated;
-- anon NO. service_role y postgres ya lo tienen.

-- -----------------------------------------------------------------------------
-- Self-verifying: aborta el CI si el guard, los grants o la firma no quedaron
-- como se espera.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_n   integer;
  v_def text;
BEGIN
  -- Una sola firma (CREATE OR REPLACE no reemplaza otra distinta: la agrega y
  -- PostgREST deja de resolver la llamada).
  SELECT count(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'sync_conyuge_compradores';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'Se esperaba 1 firma de sync_conyuge_compradores, hay %', v_n;
  END IF;

  v_def := pg_get_functiondef('public.sync_conyuge_compradores(integer)'::regprocedure);

  IF position('user_has_permission' in v_def) = 0
     OR position('42501' in v_def) = 0 THEN
    RAISE EXCEPTION 'El guard de autorización no quedó en el cuerpo desplegado';
  END IF;

  -- La lógica de negocio sigue intacta: los dos loops y el filtro de propiedades.
  IF position('o.id_producto IS NULL' in v_def) = 0 THEN
    RAISE EXCEPTION 'Se perdió el filtro de cuentas de propiedad';
  END IF;

  -- Grants: authenticated sí, anon no.
  IF NOT has_function_privilege('authenticated', 'public.sync_conyuge_compradores(integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated sigue sin EXECUTE: el 403 no se arregla';
  END IF;
  IF has_function_privilege('anon', 'public.sync_conyuge_compradores(integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon quedó con EXECUTE sobre sync_conyuge_compradores';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.sync_conyuge_compradores(integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role perdió EXECUTE';
  END IF;

  -- Regresión de seguridad: execute_safe_query sigue cerrada.
  IF has_function_privilege('authenticated', 'public.execute_safe_query(text, integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.execute_safe_query(text, integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'execute_safe_query quedó abierta a anon/authenticated';
  END IF;

  -- Cuántos roles pasan el guard por la rama de user_has_permission. En prod son
  -- 9; en dev los catálogos difieren, así que aquí es WARNING y no EXCEPTION: el
  -- guard resuelve los permisos en tiempo de ejecución y funciona con cualquier
  -- conteo. Cero sí importa: significaría que ningún rol podría guardar.
  SELECT count(DISTINCT sp.rol_id) INTO v_n
  FROM public.submenus s
  JOIN public.submenus_permisos sp ON sp.submenu_id = s.id AND sp.activo = true
  JOIN public.permisos perm ON perm.id = sp.permiso_id
  WHERE s.vista_front_end = '/admin/compradores'
    AND s.activo = true
    AND perm.nombre IN ('actualizar', 'crear');

  IF v_n = 0 THEN
    RAISE EXCEPTION 'Ningún rol tiene crear/actualizar en /admin/compradores: el guard bloquearía a todos';
  ELSIF v_n < 9 THEN
    RAISE WARNING 'Solo % roles con escritura en /admin/compradores (en prod son 9): revisar el catálogo de este entorno', v_n;
  END IF;
END
$$;
