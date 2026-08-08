-- Agente dependiente: información fiscal, cuenta bancaria y CSF en solo lectura
-- Fecha: 2026-08-08
--
-- El agente ligado a una inmobiliaria no captura ni corrige su información fiscal, su cuenta
-- bancaria ni su Constancia de Situación Fiscal: eso lo hace su inmobiliaria. En el portal esas
-- secciones SIGUEN VISIBLES —para que confirme que sus datos están bien— pero sin acciones de
-- edición. Esto cierra la regla en la base: leer sí, escribir no.
--
--   objeto                          dependiente   su inmobiliaria   admin (puede_impersonar)
--   cuentas_bancarias propias       leer          leer + escribir   todo
--   documentos tipo 6 (CSF)         leer          leer + escribir   todo
--   columnas fiscales de personas   leer          leer + escribir   todo
--   datos personales, INE, dirección  leer + escribir en los tres casos
--
-- Discriminador (el mismo que usa el front): entidades_relacionadas tipo 19 activo con
-- `id_persona_duena_lead` no nulo.
--
-- ─── Verificado read-only contra prod (tzmhgfjmddkfyffkkmto, 2026-08-08) ──────
--   * **237 agentes dependientes** (el documento traía 231, del 6-ago): 10 con cuenta bancaria
--     activa, 10 con CSF activa y 17 con `personas.rfc`. Ninguna fila se toca aquí.
--   * Los helpers existen y son SECURITY DEFINER: `current_persona_id`, `current_puede_impersonar`,
--     `current_puede_tabla`.
--   * Las policies vigentes son las que describe el documento: `cuentas_bancarias_all` deja la
--     tabla solo al dueño de la fila o a quien impersona —así que la inmobiliaria HOY ni
--     siquiera puede LEER las cuentas de sus agentes—, `personas_update` ya contempla a la
--     inmobiliaria dueña, y las de `documentos` solo filtran socio bancario.
--   * `tipos_documento` 6 = «Constancia de situación fiscal».
--   * `rls_tablas_submenus` no tiene NINGUNA fila para `documentos`, así que
--     `current_puede_tabla('documentos', …)` siempre responde false. Queda como está: el escape
--     real son los roles que pueden impersonar.
--   * `personas` ya tiene 3 triggers; ninguno colisiona con el que se agrega.
--
-- ─── Tres correcciones respecto al documento ─────────────────────────────────
-- 1. FALTABA CERRAR EL DELETE DE `documentos`. La policy «Usuarios autenticados pueden eliminar
--    documentos» es `current_socio_bancario_id() IS NULL`: cualquier autenticado no-socio puede
--    BORRAR la fila. Con solo INSERT y UPDATE cerrados, el dependiente no puede subir ni editar
--    su CSF pero sí borrarla, que es justo la escritura que se quiere impedir. Se agrega la
--    restrictiva de DELETE.
-- 2. EL AVISO SOBRE EL ROL 30 ES INCORRECTO. El documento advierte que si quien valida CSF usa
--    «Admin Soporte» (30) hay que dar de alta el mapeo en `rls_tablas_submenus`. En prod
--    `puede_impersonar` es true en SIETE roles: 1 Super Administrador, 2 Administrador de
--    Proyecto, 7 Administrador de finanzas/legal, 12 Administrador de cobranza, **30 Admin
--    Soporte**, 31 Supervisor agentes externos y **34 Admin de clientes**. El 30 ya pasa por el
--    escape de impersonación, así que el bloque opcional no hace falta para ese rol.
-- 3. EL TRIGGER COMPARA PRIMERO Y PREGUNTA DESPUÉS. El documento llamaba a tres funciones
--    SECURITY DEFINER en CADA update de `personas` antes de mirar si algo fiscal cambió. La
--    inmensa mayoría de los updates son de teléfono o dirección: se comparan las 9 columnas
--    primero —comparación pura, sin consultas— y solo si alguna cambió se evalúa el permiso.
--
-- Las policies nuevas son RESTRICTIVE: se suman con AND a las permisivas existentes en vez de
-- reescribirlas, y se revierten con un DROP POLICY. Ninguna toca SELECT: la lectura queda
-- intacta a propósito.
--
-- Idempotente (CREATE OR REPLACE, DROP POLICY/TRIGGER IF EXISTS + CREATE).
-- Sin BEGIN/COMMIT: el CI ya envuelve cada migración en transacción.

-- ─────────────────────────────────────────────────────────────────────
-- 1. Helpers
--    SECURITY DEFINER porque `entidades_relacionadas` tiene RLS: como INVOKER devolverían
--    false para quien no ve su propia fila y el candado quedaría abierto.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.es_agente_dependiente(_id_persona integer)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.entidades_relacionadas er
    WHERE er.id_persona = _id_persona
      AND er.id_tipo_entidad = 19            -- 'Agente'
      AND er.activo = true
      AND er.id_persona_duena_lead IS NOT NULL
  );
$$;

COMMENT ON FUNCTION public.es_agente_dependiente(integer) IS
  'TRUE si la persona es un agente ligado a una inmobiliaria (entidades_relacionadas tipo 19 '
  'activo con id_persona_duena_lead). Ese agente consulta su información fiscal, bancaria y su '
  'CSF, pero no las escribe: las administra su inmobiliaria. NULL -> FALSE (los documentos sin '
  'persona no se ven afectados).';

CREATE OR REPLACE FUNCTION public.current_agente_dependiente()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public.es_agente_dependiente(public.current_persona_id());
$$;

COMMENT ON FUNCTION public.current_agente_dependiente() IS
  'es_agente_dependiente() aplicado a la persona de la sesión actual.';

CREATE OR REPLACE FUNCTION public.current_es_inmobiliaria_de(_id_persona integer)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.entidades_relacionadas er
    WHERE er.id_persona = _id_persona
      AND er.activo = true
      AND er.id_persona_duena_lead = public.current_persona_id()
  );
$$;

COMMENT ON FUNCTION public.current_es_inmobiliaria_de(integer) IS
  'TRUE si quien tiene la sesión es la inmobiliaria dueña de esa persona '
  '(entidades_relacionadas.id_persona_duena_lead). Mismo criterio que ya usa personas_update.';

REVOKE ALL ON FUNCTION public.es_agente_dependiente(integer)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.current_agente_dependiente()        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.current_es_inmobiliaria_de(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.es_agente_dependiente(integer)      TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_agente_dependiente()        TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_es_inmobiliaria_de(integer) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- 2. cuentas_bancarias: el dependiente las ve, no las escribe
--    SELECT queda intacto (cuentas_bancarias_all): el agente sigue viendo banco, titular y
--    últimos dígitos en su perfil.
-- ─────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS cuentas_bancarias_no_dependiente_ins ON public.cuentas_bancarias;
DROP POLICY IF EXISTS cuentas_bancarias_no_dependiente_upd ON public.cuentas_bancarias;
DROP POLICY IF EXISTS cuentas_bancarias_no_dependiente_del ON public.cuentas_bancarias;

CREATE POLICY cuentas_bancarias_no_dependiente_ins
ON public.cuentas_bancarias AS RESTRICTIVE FOR INSERT TO authenticated
WITH CHECK (
  NOT public.es_agente_dependiente(id_persona)
  OR public.current_es_inmobiliaria_de(id_persona)
  OR public.current_puede_impersonar()
);

CREATE POLICY cuentas_bancarias_no_dependiente_upd
ON public.cuentas_bancarias AS RESTRICTIVE FOR UPDATE TO authenticated
USING (
  NOT public.es_agente_dependiente(id_persona)
  OR public.current_es_inmobiliaria_de(id_persona)
  OR public.current_puede_impersonar()
)
WITH CHECK (
  NOT public.es_agente_dependiente(id_persona)
  OR public.current_es_inmobiliaria_de(id_persona)
  OR public.current_puede_impersonar()
);

CREATE POLICY cuentas_bancarias_no_dependiente_del
ON public.cuentas_bancarias AS RESTRICTIVE FOR DELETE TO authenticated
USING (
  NOT public.es_agente_dependiente(id_persona)
  OR public.current_es_inmobiliaria_de(id_persona)
  OR public.current_puede_impersonar()
);

COMMENT ON POLICY cuentas_bancarias_no_dependiente_ins ON public.cuentas_bancarias IS
  'El agente ligado a una inmobiliaria consulta su cuenta de dispersión pero no la registra ni '
  'la modifica: su inmobiliaria cobra y define cómo le paga.';

-- Permisiva: la inmobiliaria dueña administra las cuentas de sus agentes. Es FOR ALL, así que
-- también le da la LECTURA que hoy no tiene y sin la cual la columna «Cuenta bancaria» de
-- MisAgentes.tsx mostraría «Sin cuenta» para todos.
DROP POLICY IF EXISTS cuentas_bancarias_inmobiliaria ON public.cuentas_bancarias;

CREATE POLICY cuentas_bancarias_inmobiliaria
ON public.cuentas_bancarias FOR ALL TO authenticated
USING (public.current_es_inmobiliaria_de(id_persona))
WITH CHECK (public.current_es_inmobiliaria_de(id_persona));

COMMENT ON POLICY cuentas_bancarias_inmobiliaria ON public.cuentas_bancarias IS
  'Contraparte de cuentas_bancarias_no_dependiente_*: si la inmobiliaria es la responsable de '
  'capturar, necesita el permiso que cuentas_bancarias_all no le da.';

-- ─────────────────────────────────────────────────────────────────────
-- 3. documentos: la CSF (tipo 6) del dependiente es de consulta
--    SELECT intacto: el agente abre y descarga su constancia.
--    Se cierran INSERT, UPDATE y DELETE (ver «Corrección 1»).
-- ─────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS documentos_csf_no_dependiente_ins ON public.documentos;
DROP POLICY IF EXISTS documentos_csf_no_dependiente_upd ON public.documentos;
DROP POLICY IF EXISTS documentos_csf_no_dependiente_del ON public.documentos;

CREATE POLICY documentos_csf_no_dependiente_ins
ON public.documentos AS RESTRICTIVE FOR INSERT TO authenticated
WITH CHECK (
  id_tipo_documento <> 6
  OR public.current_puede_impersonar()
  OR public.current_puede_tabla('documentos'::text, 'crear'::text)
  OR public.current_es_inmobiliaria_de(id_persona)
  OR (
    NOT public.current_agente_dependiente()          -- quién escribe
    AND NOT public.es_agente_dependiente(id_persona) -- sobre quién escribe
  )
);

CREATE POLICY documentos_csf_no_dependiente_upd
ON public.documentos AS RESTRICTIVE FOR UPDATE TO authenticated
USING (
  id_tipo_documento <> 6
  OR public.current_puede_impersonar()
  OR public.current_puede_tabla('documentos'::text, 'actualizar'::text)
  OR public.current_es_inmobiliaria_de(id_persona)
  OR (
    NOT public.current_agente_dependiente()
    AND NOT public.es_agente_dependiente(id_persona)
  )
)
WITH CHECK (
  id_tipo_documento <> 6
  OR public.current_puede_impersonar()
  OR public.current_puede_tabla('documentos'::text, 'actualizar'::text)
  OR public.current_es_inmobiliaria_de(id_persona)
  OR (
    NOT public.current_agente_dependiente()
    AND NOT public.es_agente_dependiente(id_persona)
  )
);

CREATE POLICY documentos_csf_no_dependiente_del
ON public.documentos AS RESTRICTIVE FOR DELETE TO authenticated
USING (
  id_tipo_documento <> 6
  OR public.current_puede_impersonar()
  OR public.current_puede_tabla('documentos'::text, 'actualizar'::text)
  OR public.current_es_inmobiliaria_de(id_persona)
  OR (
    NOT public.current_agente_dependiente()
    AND NOT public.es_agente_dependiente(id_persona)
  )
);

COMMENT ON POLICY documentos_csf_no_dependiente_ins ON public.documentos IS
  'Un agente dependiente no sube Constancias de Situación Fiscal (tipo 6), ni suyas ni ajenas, '
  'y nadie le da de alta una salvo su inmobiliaria, verificación o un admin.';
COMMENT ON POLICY documentos_csf_no_dependiente_del ON public.documentos IS
  'Cierra el hueco de la policy abierta de DELETE: sin esto el dependiente no podía editar su '
  'CSF pero sí borrarla.';

-- ─────────────────────────────────────────────────────────────────────
-- 4. personas: columnas fiscales de solo lectura para el dependiente
--    RLS no alcanza: la policy es por FILA y el dependiente sí debe poder editar teléfono,
--    dirección y su INE. Hace falta granularidad por COLUMNA.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_bloquear_fiscal_agente_dependiente()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  -- Primero lo barato: si no cambió ninguna columna fiscal no hay nada que decidir, y ese es
  -- el caso de casi todos los updates (teléfono, dirección, INE). Ver «Corrección 3».
  IF NEW.rfc                             IS NOT DISTINCT FROM OLD.rfc
     AND NEW.regimen                     IS NOT DISTINCT FROM OLD.regimen
     AND NEW.uso_cfdi                    IS NOT DISTINCT FROM OLD.uso_cfdi
     AND NEW.direccion_fiscal_calle      IS NOT DISTINCT FROM OLD.direccion_fiscal_calle
     AND NEW.direccion_fiscal_colonia    IS NOT DISTINCT FROM OLD.direccion_fiscal_colonia
     AND NEW.direccion_fiscal_codigo_postal IS NOT DISTINCT FROM OLD.direccion_fiscal_codigo_postal
     AND NEW.direccion_fiscal_id_pais       IS NOT DISTINCT FROM OLD.direccion_fiscal_id_pais
     AND NEW.direccion_fiscal_id_estado     IS NOT DISTINCT FROM OLD.direccion_fiscal_id_estado
     AND NEW.direccion_fiscal_id_municipio  IS NOT DISTINCT FROM OLD.direccion_fiscal_id_municipio
  THEN
    RETURN NEW;
  END IF;

  -- Procesos sin sesión (service_role, Edge Functions, migraciones, backend Python): ahí no
  -- está el vector de usurpación y bloquearlos rompería cargas legítimas.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- Administración con permiso explícito, o la inmobiliaria dueña del agente.
  IF public.current_puede_impersonar()
     OR public.current_puede_tabla('personas'::text, 'actualizar'::text)
     OR public.current_es_inmobiliaria_de(NEW.id) THEN
    RETURN NEW;
  END IF;

  IF NOT public.es_agente_dependiente(NEW.id) THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION
    'Los datos fiscales de un agente ligado a una inmobiliaria los administra la inmobiliaria (persona %)', NEW.id
    USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER IF EXISTS trg_bloquear_fiscal_agente_dependiente ON public.personas;

CREATE TRIGGER trg_bloquear_fiscal_agente_dependiente
BEFORE UPDATE ON public.personas
FOR EACH ROW
EXECUTE FUNCTION public.trg_bloquear_fiscal_agente_dependiente();

-- ─────────────────────────────────────────────────────────────────────
-- 5. Self-verifying
-- ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_pol int;
BEGIN
  IF to_regprocedure('public.es_agente_dependiente(integer)') IS NULL
     OR to_regprocedure('public.current_agente_dependiente()') IS NULL
     OR to_regprocedure('public.current_es_inmobiliaria_de(integer)') IS NULL THEN
    RAISE EXCEPTION 'Faltan los helpers de agente dependiente';
  END IF;

  SELECT count(*) INTO v_pol
  FROM pg_policies
  WHERE schemaname = 'public'
    AND policyname IN ('cuentas_bancarias_no_dependiente_ins','cuentas_bancarias_no_dependiente_upd',
                       'cuentas_bancarias_no_dependiente_del','cuentas_bancarias_inmobiliaria',
                       'documentos_csf_no_dependiente_ins','documentos_csf_no_dependiente_upd',
                       'documentos_csf_no_dependiente_del');
  IF v_pol <> 7 THEN
    RAISE EXCEPTION 'Se esperaban 7 policies nuevas, hay %', v_pol;
  END IF;

  -- Ninguna de las nuevas puede tocar SELECT: la lectura es el punto del requerimiento.
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND policyname LIKE '%no_dependiente%'
      AND cmd IN ('SELECT','ALL')
  ) THEN
    RAISE EXCEPTION 'Alguna policy restrictiva alcanza al SELECT: el dependiente debe poder LEER sus datos';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_bloquear_fiscal_agente_dependiente') THEN
    RAISE EXCEPTION 'Falta el trigger que protege las columnas fiscales de personas';
  END IF;
END $$;

-- Bloque OPCIONAL, no incluido: dar de alta `documentos` en `rls_tablas_submenus` para que
-- `current_puede_tabla('documentos', …)` responda true a un rol sin `puede_impersonar`. Hoy no
-- hace falta: los siete roles que impersonan (1, 2, 7, 12, 30, 31, 34) ya pasan por el escape.
--   INSERT INTO public.rls_tablas_submenus (tabla, submenu_id, permiso_id, activo)
--   VALUES ('documentos', <SUBMENU_ID>, 2, true), ('documentos', <SUBMENU_ID>, 3, true);
--
-- Rollback:
--   DROP TRIGGER IF EXISTS trg_bloquear_fiscal_agente_dependiente ON public.personas;
--   DROP FUNCTION IF EXISTS public.trg_bloquear_fiscal_agente_dependiente();
--   DROP POLICY IF EXISTS documentos_csf_no_dependiente_del ON public.documentos;
--   DROP POLICY IF EXISTS documentos_csf_no_dependiente_upd ON public.documentos;
--   DROP POLICY IF EXISTS documentos_csf_no_dependiente_ins ON public.documentos;
--   DROP POLICY IF EXISTS cuentas_bancarias_inmobiliaria ON public.cuentas_bancarias;
--   DROP POLICY IF EXISTS cuentas_bancarias_no_dependiente_del ON public.cuentas_bancarias;
--   DROP POLICY IF EXISTS cuentas_bancarias_no_dependiente_upd ON public.cuentas_bancarias;
--   DROP POLICY IF EXISTS cuentas_bancarias_no_dependiente_ins ON public.cuentas_bancarias;
--   DROP FUNCTION IF EXISTS public.current_es_inmobiliaria_de(integer);
--   DROP FUNCTION IF EXISTS public.current_agente_dependiente();
--   DROP FUNCTION IF EXISTS public.es_agente_dependiente(integer);
--   Ninguna fila de datos se toca: no hay nada que restaurar.
