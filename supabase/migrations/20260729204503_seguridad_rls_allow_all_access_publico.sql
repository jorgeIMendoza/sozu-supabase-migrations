-- Seguridad · Políticas "Allow all access to …" con FOR ALL / rol PUBLIC
-- Fecha: 2026-07-28
--
-- ORIGEN: hallazgo propio al validar el CSV de lints en prod. Estas 7 tablas NO aparecen en
--   `errores riesgo 1.csv`, pero son la variante más grave del mismo defecto
--   (rls_policy_always_true): una sola política FOR ALL, rol PUBLIC, USING (true) y
--   WITH CHECK (true). Como anon tiene INSERT/UPDATE/DELETE otorgado sobre ellas, cualquiera
--   con la clave anon publicada puede reescribir o vaciar catálogos vivos: `bancos`,
--   `tipos_entidad`, `estatus_persona`, `estatus_proyecto`, `avisos_legales`,
--   `multimedias_propiedad`, `propiedades_caracteristicas`.
--
-- CORRECCIÓN: se parte cada política en dos, preservando la lectura pública actual —
--   los landings externos leen catálogos con la clave anon y no quiero romperlos:
--     · `<tabla>_select_publico`  → FOR SELECT, sin restricción (el lint excluye SELECT
--                                   con USING (true) a propósito; es lectura pública
--                                   deliberada).
--     · `<tabla>_escritura_auth`  → FOR ALL TO authenticated con
--                                   (SELECT auth.uid()) IS NOT NULL.
--   Ambas son permissive, así que la lectura sigue abierta y la escritura queda cerrada a
--   anon. service_role no se afecta (rolbypassrls = true).
--
-- Estas 7 tablas son catálogo: si en algún momento se decide que ni la lectura debe ser
--   pública, basta cambiar `_select_publico` a `TO authenticated`. Fuera de alcance aquí.
--
-- Idempotente (DROP POLICY IF EXISTS + CREATE POLICY guardado) y self-verifying.
-- Sin BEGIN/COMMIT (el CI envuelve en transacción).

DO $$
DECLARE
  r        record;
  n_fix    int := 0;
  n_skip   int := 0;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('avisos_legales'),
      ('bancos'),
      ('estatus_persona'),
      ('estatus_proyecto'),
      ('multimedias_propiedad'),
      ('propiedades_caracteristicas'),
      ('tipos_entidad')
    ) AS t(tabla)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'public' AND tablename = r.tabla
        AND policyname = 'Allow all access to ' || r.tabla
    ) THEN
      n_skip := n_skip + 1;
      RAISE NOTICE 'drift: no existe "Allow all access to %" — se omite', r.tabla;
      CONTINUE;
    END IF;

    EXECUTE format('DROP POLICY %I ON public.%I', 'Allow all access to ' || r.tabla, r.tabla);

    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT USING (true)',
      r.tabla || '_select_publico', r.tabla);

    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL TO authenticated '
      || 'USING ((SELECT auth.uid()) IS NOT NULL) WITH CHECK ((SELECT auth.uid()) IS NOT NULL)',
      r.tabla || '_escritura_auth', r.tabla);

    n_fix := n_fix + 1;
  END LOOP;

  RAISE NOTICE 'tablas de catálogo corregidas=%, omitidas por drift=%', n_fix, n_skip;
END $$;

-- Verificación: sin escritura anon con predicado true en estas tablas.
DO $$
DECLARE
  v_restantes text;
BEGIN
  SELECT string_agg(format('%s.%s', tablename, policyname), ', ' ORDER BY tablename)
    INTO v_restantes
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename IN ('avisos_legales','bancos','estatus_persona','estatus_proyecto',
                      'multimedias_propiedad','propiedades_caracteristicas','tipos_entidad')
    AND cmd <> 'SELECT'
    AND (qual = 'true' OR with_check = 'true');

  IF v_restantes IS NOT NULL THEN
    RAISE EXCEPTION 'Siguen políticas de escritura con predicado true: %', v_restantes;
  END IF;

  RAISE NOTICE 'Verificación OK: catálogos con lectura pública y escritura solo authenticated';
END $$;
