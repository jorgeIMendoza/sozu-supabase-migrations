-- =============================================================================
-- personas_update — aplicar la regla base (rama de permiso en submenú activo)
--
-- Hoy la policy admite dueño, dueño-del-lead o puede_impersonar. Los 5 roles con
-- crear/actualizar en /admin/compradores que NO pueden impersonar pasan el guard
-- de sync_conyuge_compradores pero el UPDATE de personas se deniega, y sin error
-- visible: un update sin .select() devuelve 2xx con 0 filas, así que el front
-- mostraba el toast verde sin haber escrito nada. Usuarios afectados en prod:
--   jorge.admin.proy@yopmail.com  rol 2, id_persona NULL, 0 leads → no editaba nada
--   abel.salazar@sozu.com         rol 2, id_persona 2212, 8 leads → solo esos 8
--   emily.vazquez@daiku.com.mx    rol 9, id_persona 2345, 0 leads → nada
--   luis.rivas@sozu.com           rol 10, id_persona NULL, 0 leads → nada
--
-- Es la primera aplicación real de la regla base del 06 (opción A del documento
-- 07), así que depende de 20260730020000_rls_estandar_base_tanda0.sql.
--
-- Verificado read-only contra prod el 2026-07-29:
--   · personas_update vigente: id = current_persona_id() OR
--     current_puede_impersonar() OR EXISTS(entidades_relacionadas con
--     id_persona_duena_lead = current_persona_id()). USING = WITH CHECK.
--   · Es la ÚNICA policy de UPDATE sobre personas. Las otras: personas_select
--     (USING true para anon y authenticated), personas_insert
--     (WITH CHECK auth.uid() IS NOT NULL) y dos de georgia_* de solo lectura.
--   · Roles con 'actualizar' en /admin/compradores (submenú 15, activo, menú 4
--     activo): 1, 2, 7, 9, 10, 11, 12, 16, 30. Los que no pueden impersonar:
--     2 (2 usuarios), 9 (1), 10 (1), 11 (0), 16 (0).
--
-- Corrección respecto al documento:
--   La rama (b) es row-independent: current_puede_tabla('personas','actualizar')
--   vale para TODA la tabla, no por fila. El catálogo del 06 declaraba también
--   'personas' × /admin/prospectos × actualizar, y ese submenú da 'actualizar' al
--   rol 3 Agente Inmobiliario: 321 usuarios activos, sin impersonar. Eso habría
--   convertido a cada agente externo en editor de todo el padrón — compradores
--   ajenos, staff y dueños — en lugar de solo sus leads, que es exactamente lo
--   que hoy contiene la rama id_persona_duena_lead. La opción B del documento
--   tenía el mismo problema, con las rutas embebidas.
--   Por eso esa fila se excluyó del seed (ver 20260730020000) y la rama (b) aquí
--   queda acotada a los 9 roles con escritura en /admin/compradores. El bloque
--   self-verifying de abajo lo vigila: aborta si algún rol con más de 50 usuarios
--   activos y sin puede_impersonar entra por la rama (b).
--
-- No se amplía nada más: las dos ramas de dueño se conservan (portal cliente y
-- agentes con sus leads siguen igual), INSERT no se toca y DELETE no existe — la
-- baja de personas es activo = false.
-- =============================================================================

-- Pre-condiciones: sin el helper y sin catálogo, la policy nueva sería idéntica a
-- la vieja y los 4 usuarios seguirían bloqueados.
DO $$
DECLARE
  v_n integer;
BEGIN
  IF to_regprocedure('public.current_puede_tabla(text, text)') IS NULL THEN
    RAISE EXCEPTION 'Falta current_puede_tabla: aplicar primero la tanda 0 (20260730020000)';
  END IF;

  IF to_regprocedure('public.current_persona_id()') IS NULL
     OR to_regprocedure('public.current_puede_impersonar()') IS NULL THEN
    RAISE EXCEPTION 'Faltan current_persona_id / current_puede_impersonar';
  END IF;

  SELECT count(*) INTO v_n
  FROM public.rls_tablas_submenus
  WHERE tabla = 'personas' AND permiso_id = 3 AND activo = true;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'El catálogo no declara ningún submenú para personas × actualizar: la rama (b) nunca daría true';
  END IF;
END
$$;

DROP POLICY IF EXISTS personas_update ON public.personas;

CREATE POLICY personas_update ON public.personas
  FOR UPDATE TO authenticated
  USING (
    -- (a) dueño: el portal cliente edita su propia persona.
    id = public.current_persona_id()
    -- (b) permiso 'actualizar' en algún submenú activo declarado para personas.
    OR public.current_puede_tabla('personas', 'actualizar')
    -- (c) bypass administrativo.
    OR public.current_puede_impersonar()
    -- (a') dueño del lead. Va al final: es la única rama que se evalúa por fila,
    -- las tres anteriores cortocircuitan primero.
    OR EXISTS (
      SELECT 1 FROM public.entidades_relacionadas er
      WHERE er.id_persona = personas.id
        AND er.activo = true
        AND er.id_persona_duena_lead = public.current_persona_id()
    )
  )
  WITH CHECK (
    -- Idéntico al USING: sin esto se podría mover la fila fuera del alcance
    -- permitido en el mismo UPDATE.
    id = public.current_persona_id()
    OR public.current_puede_tabla('personas', 'actualizar')
    OR public.current_puede_impersonar()
    OR EXISTS (
      SELECT 1 FROM public.entidades_relacionadas er
      WHERE er.id_persona = personas.id
        AND er.activo = true
        AND er.id_persona_duena_lead = public.current_persona_id()
    )
  );

COMMENT ON POLICY personas_update ON public.personas IS
  'Regla base: dueño ∪ permiso actualizar en submenú activo (rls_tablas_submenus) ∪ '
  'impersonar ∪ dueño del lead. La rama de permiso es row-independent: el catálogo '
  'decide qué roles editan TODO el padrón, así que no declarar ahí submenús de acceso '
  'masivo (p.ej. /admin/prospectos, con 321 agentes externos).';

-- -----------------------------------------------------------------------------
-- Self-verifying: aborta el CI si la policy quedó incompleta o si la rama (b)
-- abrió el padrón a un rol de acceso masivo.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_n     integer;
  v_qual  text;
  v_check text;
  v_rol   record;
BEGIN
  SELECT count(*) INTO v_n
  FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'personas' AND cmd = 'UPDATE';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'Se esperaba 1 policy de UPDATE en personas, hay %', v_n;
  END IF;

  SELECT coalesce(qual, ''), coalesce(with_check, '')
  INTO v_qual, v_check
  FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'personas' AND policyname = 'personas_update';

  IF position('current_puede_tabla' IN v_qual) = 0
     OR position('current_puede_tabla' IN v_check) = 0 THEN
    RAISE EXCEPTION 'La rama de permiso no quedó en USING y WITH CHECK: los 4 usuarios seguirían bloqueados';
  END IF;

  -- Las ramas que ya existían no se pueden perder.
  IF position('current_persona_id' IN v_qual) = 0 THEN
    RAISE EXCEPTION 'Se perdió la rama de dueño: el portal cliente dejaría de editar su propia persona';
  END IF;
  IF position('current_puede_impersonar' IN v_qual) = 0 THEN
    RAISE EXCEPTION 'Se perdió la rama de impersonar';
  END IF;
  IF position('id_persona_duena_lead' IN v_qual) = 0 THEN
    RAISE EXCEPTION 'Se perdió la rama de dueño del lead: los agentes dejarían de editar sus leads';
  END IF;
  IF v_check <> v_qual THEN
    RAISE WARNING 'WITH CHECK y USING no son idénticos: revisar que sea intencional';
  END IF;

  -- Guardrail del alcance: ningún rol de acceso masivo sin impersonar debe ganar
  -- UPDATE sobre todo el padrón por la rama (b).
  FOR v_rol IN
    SELECT DISTINCT r.id, r.nombre,
           (SELECT count(*) FROM public.usuarios u
             WHERE u.rol_id = r.id AND u.activo AND u.auth_user_id IS NOT NULL) AS usuarios
    FROM public.rls_tablas_submenus rts
    JOIN public.submenus s ON s.id = rts.submenu_id AND s.activo = true
    JOIN public.menus m    ON m.id = s.menu_id AND m.activo = true
    JOIN public.submenus_permisos sp
      ON sp.submenu_id = s.id AND sp.permiso_id = rts.permiso_id AND sp.activo = true
    JOIN public.roles r ON r.id = sp.rol_id
    WHERE rts.tabla = 'personas' AND rts.permiso_id = 3 AND rts.activo = true
      AND r.puede_impersonar = false
  LOOP
    IF v_rol.usuarios > 50 THEN
      RAISE EXCEPTION
        'El rol % (%) tiene % usuarios activos y ganaría UPDATE sobre TODO el padrón por la rama (b). Revisar el catálogo rls_tablas_submenus para personas.',
        v_rol.id, v_rol.nombre, v_rol.usuarios;
    END IF;
    RAISE NOTICE 'Rama (b) de personas: rol % (%) con % usuarios activos', v_rol.id, v_rol.nombre, v_rol.usuarios;
  END LOOP;
END
$$;
