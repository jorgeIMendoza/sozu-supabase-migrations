-- =============================================================================
-- delegaciones_acceso: atributos, guardas, helpers y RPC del acceso delegado
-- =============================================================================
-- El dueño de una compra autoriza a personas físicas de su confianza (hijo, cónyuge,
-- abogado, contador) a entrar al portal y ver lo de sus propiedades SIN volverlas
-- compradoras, copropietarias ni dueñas de nada, y puede revocar cuando quiera.
--
-- El vínculo persona↔persona lo da 20260820150000 (`personas_relacionadas` +
-- ADMINISTRADOR_CUENTA). Aquí van los atributos del permiso (satélite 1:1), las guardas
-- de integridad, los helpers que consumirán las policies de RLS, y las RPC que son la
-- única puerta de escritura.
--
-- REQUIERE 20260820150000_personas_relacionadas_vinculo_activo aplicado (§0 lo verifica).
--
-- ─── Verificado read-only el 2026-08-20 (prod tzmhgfjmddkfyffkkmto y dev) ─────
-- · `delegaciones_acceso` y las 6 funciones: 0 en dev y 0 en prod. Nada que reemplazar,
--   así que ningún overload de firma vieja que estorbe.
-- · `propiedades.id` es bigint; `ofertas.id_propiedad` y `cuentas_cobranza.id_propiedad`
--   son integer. Inconsistencia preexistente: aquí se declara bigint (para que la FK sea
--   válida) y se castea al comparar.
-- · `cuentas_cobranza.id` es bigint y `compradores.id_cuenta_cobranza` integer: se castea
--   el integer HACIA bigint, no al revés (ver §2c).
-- · `usuarios.activo` es nullable → COALESCE(u.activo,false), no `u.activo`.
-- · `usuarios` tiene la policy "Users can view own record" USING (auth_user_id=auth.uid()),
--   y `personas_relacionadas` deja ver al titular y al delegado por current_persona_id():
--   por eso el EXISTS inline de la policy de §5 resuelve sin SECURITY DEFINER.
-- · `current_puede_impersonar()` y `set_fecha_actualizacion()` existen y se reutilizan.
-- · DEFAULT PRIVILEGES de `public` dan `anon=arwdDxtm` en toda tabla nueva y `anon=X` en
--   toda función nueva: por eso los REVOKE explícitos de §5 no son decorativos.
--
-- ─── Reglas de negocio que fija esta migración ───────────────────────────────
-- 1. El titular sigue siendo el único dueño: no se toca `compradores` ni `ofertas`.
-- 2. El delegado ve lo mismo que el dueño, pero no es dueño. Nominativo y revocable.
-- 3. La responsabilidad es del titular: queda quién otorgó, cuándo, alcance y evidencia.
-- 4. No se hereda ni se propaga: un delegado no puede nombrar a otro (§2b).
-- 5. Alcance 'total' (todo el titular) o 'propiedad' (una unidad suya).
-- 6. La lectura nunca se recorta; lo acotable es la escritura (`puede_escribir`).
-- 7. Nunca se borra: revocar = activo=false en el vínculo + sello en el satélite.
--
-- ─── Pendiente conocido, importa para operar ─────────────────────────────────
-- No hay trazabilidad de QUIÉN actuó: si el delegado sube un documento, `documentos`
-- guarda el id_persona del titular, así que la evidencia diría que lo subió el dueño.
-- Por eso `puede_escribir` nace en `false` — tanto el DEFAULT de la columna como el del
-- parámetro de la RPC — y la escritura se pide explícita. El documento fuente proponía
-- `true`; se cambió a propósito: mientras no exista la bitácora, el default seguro es el
-- que no deja actuar en nombre de otro sin dejar rastro.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §0. Guarda de prerrequisito
-- -----------------------------------------------------------------------------
DO $guard$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.tipos_relacion WHERE clave = 'ADMINISTRADOR_CUENTA') THEN
    RAISE EXCEPTION
      'Falta la clave ADMINISTRADOR_CUENTA: aplicar primero 20260820150000_personas_relacionadas_vinculo_activo';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_class WHERE relname = 'uq_personas_relacionadas_activa' AND relkind = 'i'
  ) THEN
    RAISE EXCEPTION
      'Falta uq_personas_relacionadas_activa: sin el UNIQUE parcial, reotorgar truena con 23505';
  END IF;
END
$guard$;

-- -----------------------------------------------------------------------------
-- §1. Satélite 1:1 del vínculo de delegación
-- -----------------------------------------------------------------------------
-- Satélite y no columnas en personas_relacionadas: estos ~14 atributos no aplican a
-- REPRESENTANTE_LEGAL ni a ACCIONISTA (serían NULL en el 100% de las filas de KYC, que es
-- lo que esa tabla va a tener en volumen), e `id_propiedad` mete una TERCERA entidad a un
-- vínculo persona↔persona.
CREATE TABLE IF NOT EXISTS public.delegaciones_acceso (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

  -- 1:1 con el vínculo. ON DELETE CASCADE: si el vínculo desaparece, sus atributos no
  -- tienen dueño. (El flujo normal NO borra: revoca.)
  id_persona_relacionada    bigint NOT NULL UNIQUE
                              REFERENCES public.personas_relacionadas(id) ON DELETE CASCADE,

  alcance                   text    NOT NULL DEFAULT 'total'
                                    CHECK (alcance IN ('total','propiedad')),
  id_propiedad              bigint  REFERENCES public.propiedades(id),

  -- La lectura es total por definición (regla 6). Lo acotable es escribir, y nace
  -- CERRADA: ver §Pendiente conocido del encabezado.
  puede_escribir            boolean NOT NULL DEFAULT false,

  fecha_inicio              timestamptz NOT NULL DEFAULT now(),
  vigencia_hasta            timestamptz,

  -- Quién y cómo lo otorgó + traslado de responsabilidad al titular (regla 3).
  origen                    text    NOT NULL CHECK (origen IN ('titular','admin_sozu')),
  otorgado_por              uuid    NOT NULL,            -- auth.users.id
  responsabilidad_aceptada  boolean NOT NULL DEFAULT false,
  responsabilidad_fecha     timestamptz,
  responsabilidad_version   text,
  evidencia_url             text,

  -- Revocación (nunca se borra la fila).
  revocado_por              uuid,
  fecha_revocacion          timestamptz,
  motivo_revocacion         text,

  notas                     text,
  fecha_creacion            timestamptz NOT NULL DEFAULT now(),
  fecha_actualizacion       timestamptz NOT NULL DEFAULT now(),

  -- alcance y propiedad van siempre de la mano, en los dos sentidos.
  CONSTRAINT da_alcance_propiedad_chk
    CHECK ((alcance = 'propiedad') = (id_propiedad IS NOT NULL)),
  -- Si lo otorgó el titular, aceptar la responsabilidad es obligatorio.
  CONSTRAINT da_responsabilidad_titular_chk
    CHECK (origen <> 'titular' OR responsabilidad_aceptada),
  -- Aceptarla exige sellar cuándo y con qué versión de términos.
  CONSTRAINT da_responsabilidad_sello_chk
    CHECK (NOT responsabilidad_aceptada
           OR (responsabilidad_fecha IS NOT NULL AND responsabilidad_version IS NOT NULL)),
  CONSTRAINT da_vigencia_chk
    CHECK (vigencia_hasta IS NULL OR vigencia_hasta > fecha_inicio),
  -- Si SOZU lo captura, debe quedar el respaldo (correo/oficio) o al menos una nota.
  CONSTRAINT da_evidencia_admin_chk
    CHECK (origen <> 'admin_sozu' OR evidencia_url IS NOT NULL OR notas IS NOT NULL)
);

COMMENT ON TABLE public.delegaciones_acceso IS
  'Atributos del permiso de un vínculo personas_relacionadas de tipo ADMINISTRADOR_CUENTA. '
  'El titular (id_persona del vínculo) autoriza al delegado (id_persona_relacion) a ver y '
  'operar lo de sus propiedades SIN volverlo comprador ni copropietario. Revocable; nunca '
  'se borra. Nombre genérico a propósito: no está amarrada al portal del cliente.';
COMMENT ON COLUMN public.delegaciones_acceso.puede_escribir IS
  'false = solo consulta, y es el DEFAULT. La LECTURA nunca se recorta: el delegado ve lo '
  'mismo que el dueño. Nace cerrada porque `documentos` no guarda quién actuó: lo que el '
  'delegado escriba queda a nombre del titular.';
COMMENT ON COLUMN public.delegaciones_acceso.otorgado_por IS
  'auth.users.id de quien otorgó. UUID y no correo: el correo cambia (EF update-user-email).';
COMMENT ON COLUMN public.delegaciones_acceso.id_propiedad IS
  'bigint porque propiedades.id es bigint. Al comparar contra ofertas.id_propiedad o '
  'cuentas_cobranza.id_propiedad (integer) hay que castear.';
COMMENT ON COLUMN public.delegaciones_acceso.fecha_revocacion IS
  'Sello de la revocación. Los helpers exigen que sea NULL además de que el vínculo esté '
  'activo: dos candados, porque quien apague solo uno de los dos no debe dar acceso.';

CREATE INDEX IF NOT EXISTS idx_delegaciones_acceso_propiedad
  ON public.delegaciones_acceso (id_propiedad) WHERE id_propiedad IS NOT NULL;

DROP TRIGGER IF EXISTS trg_delegaciones_acceso_fecha ON public.delegaciones_acceso;
CREATE TRIGGER trg_delegaciones_acceso_fecha
  BEFORE UPDATE ON public.delegaciones_acceso
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

-- -----------------------------------------------------------------------------
-- §2. Guardas de integridad del satélite
-- -----------------------------------------------------------------------------
-- En trigger y no solo en la RPC: cubre también los INSERT de service_role (backend, n8n,
-- scripts) que no pasan por ella.
CREATE OR REPLACE FUNCTION public.fn_delegaciones_acceso_valida()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_titular  integer;
  v_delegado integer;
  v_clave    text;
BEGIN
  SELECT pr.id_persona, pr.id_persona_relacion, tr.clave
    INTO v_titular, v_delegado, v_clave
  FROM public.personas_relacionadas pr
  JOIN public.tipos_relacion tr ON tr.id = pr.id_tipo_relacion
  WHERE pr.id = NEW.id_persona_relacionada;

  IF v_titular IS NULL THEN
    RAISE EXCEPTION 'El vinculo % no existe', NEW.id_persona_relacionada USING ERRCODE = '23503';
  END IF;

  -- (a) El satélite solo aplica al rol de acceso delegado.
  IF v_clave IS DISTINCT FROM 'ADMINISTRADOR_CUENTA' THEN
    RAISE EXCEPTION
      'delegaciones_acceso solo aplica a vinculos ADMINISTRADOR_CUENTA (el % es %)',
      NEW.id_persona_relacionada, COALESCE(v_clave,'sin clave')
      USING ERRCODE = '23514';
  END IF;

  -- (b) Sin cadenas (regla 4): quien ya es delegado vigente de alguien no otorga.
  --     Se evalúa sobre el otorgante, resuelto por su auth_user_id.
  IF NEW.origen = 'titular' AND EXISTS (
    SELECT 1
    FROM public.usuarios u
    JOIN public.personas_relacionadas pr ON pr.id_persona_relacion = u.id_persona AND pr.activo
    JOIN public.tipos_relacion tr        ON tr.id = pr.id_tipo_relacion
    JOIN public.delegaciones_acceso d    ON d.id_persona_relacionada = pr.id
    WHERE u.auth_user_id = NEW.otorgado_por
      AND tr.clave = 'ADMINISTRADOR_CUENTA'
      AND d.fecha_revocacion IS NULL
      AND (d.vigencia_hasta IS NULL OR d.vigencia_hasta > now())
  ) THEN
    RAISE EXCEPTION 'Un administrador de cuenta no puede otorgar accesos a terceros'
      USING ERRCODE = '23514';
  END IF;

  -- (c) Alcance por propiedad: la propiedad debe ser del TITULAR.
  --     Titular por lead (ofertas.id_persona_lead) o por comprador.
  --     `cuentas_cobranza.id` es bigint y `compradores.id_cuenta_cobranza` integer: se
  --     castea el integer hacia bigint, nunca al revés (cc.id::integer reventaría con
  --     22003 el día que la secuencia pase de 2^31).
  --     Si id_propiedad viene NULL se deja pasar a proposito: lo rechaza
  --     da_alcance_propiedad_chk, cuyo mensaje dice la verdad. El BEFORE trigger corre
  --     antes que los CHECK, asi que sin este NOT NULL el error seria 'La propiedad
  --     <NULL> no es del titular', que manda a buscar el problema al lado equivocado.
  IF NEW.alcance = 'propiedad' AND NEW.id_propiedad IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.cuentas_cobranza cc
    LEFT JOIN public.ofertas o     ON o.id = cc.id_oferta
    LEFT JOIN public.compradores c ON c.id_cuenta_cobranza::bigint = cc.id AND c.activo
    WHERE cc.activo
      AND COALESCE(cc.id_propiedad, o.id_propiedad) = NEW.id_propiedad::integer
      AND (o.id_persona_lead = v_titular OR c.id_persona = v_titular)
  ) THEN
    RAISE EXCEPTION 'La propiedad % no es del titular %', NEW.id_propiedad, v_titular
      USING ERRCODE = '23514';
  END IF;

  -- (d) Revocar exige sello de fecha.
  IF NEW.fecha_revocacion IS NULL AND NEW.revocado_por IS NOT NULL THEN
    NEW.fecha_revocacion := now();
  END IF;

  RETURN NEW;
END;
$$;

-- Nace con EXECUTE para PUBLIC y anon (DEFAULT PRIVILEGES del proyecto): se revoca.
REVOKE ALL ON FUNCTION public.fn_delegaciones_acceso_valida() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_delegaciones_acceso_valida ON public.delegaciones_acceso;
CREATE TRIGGER trg_delegaciones_acceso_valida
  BEFORE INSERT OR UPDATE ON public.delegaciones_acceso
  FOR EACH ROW EXECUTE FUNCTION public.fn_delegaciones_acceso_valida();

-- -----------------------------------------------------------------------------
-- §3. Helpers de resolución
-- -----------------------------------------------------------------------------
-- Los consumen las edge functions y, más adelante, las policies de las tandas 1-4 de
-- seguridad-rls/01. Se entregan YA aunque ninguna policy los use todavía: cuando esas
-- tandas cierren la cláusula de dueño, sin el término de "administrado" los delegados se
-- quedan ciegos de golpe.
CREATE OR REPLACE FUNCTION public.current_personas_administradas()
RETURNS TABLE (
  id_persona_titular integer,
  nombre_titular     text,
  alcance            text,
  id_propiedad       bigint,
  puede_escribir     boolean,
  vigencia_hasta     timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT pr.id_persona,
         p.nombre_legal,
         d.alcance,
         d.id_propiedad,
         d.puede_escribir,
         d.vigencia_hasta
  FROM public.usuarios u
  JOIN public.personas_relacionadas pr ON pr.id_persona_relacion = u.id_persona AND pr.activo
  JOIN public.tipos_relacion tr        ON tr.id = pr.id_tipo_relacion
  JOIN public.delegaciones_acceso d    ON d.id_persona_relacionada = pr.id
  JOIN public.personas p               ON p.id = pr.id_persona
  WHERE u.auth_user_id = auth.uid()
    AND COALESCE(u.activo, false)
    AND tr.clave = 'ADMINISTRADOR_CUENTA'
    AND d.fecha_revocacion IS NULL
    AND d.fecha_inicio <= now()
    AND (d.vigencia_hasta IS NULL OR d.vigencia_hasta > now());
$$;

COMMENT ON FUNCTION public.current_personas_administradas() IS
  'Titulares que la sesión actual administra por delegación vigente. Vacío para todos los '
  'demás. Exige vínculo activo Y satélite sin sello de revocación.';

-- ¿Puede la sesión actual ver los datos de esta persona?
-- Propia OR administrada OR staff con permiso de impersonar.
CREATE OR REPLACE FUNCTION public.current_puede_ver_persona(_id_persona integer)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT _id_persona IS NOT NULL AND (
       EXISTS (SELECT 1 FROM public.usuarios u
                WHERE u.auth_user_id = auth.uid() AND u.id_persona = _id_persona)
    OR EXISTS (SELECT 1 FROM public.current_personas_administradas() a
                WHERE a.id_persona_titular = _id_persona)
    OR public.current_puede_impersonar()
  );
$$;

COMMENT ON FUNCTION public.current_puede_ver_persona(integer) IS
  'Dueño de la fila UNION administrado por delegación vigente UNION staff que puede '
  'impersonar. Es la cláusula que deben usar las policies de las tandas 1-4 de '
  'seguridad-rls/01: sin el término de administrado, los delegados se quedan ciegos.';

-- -----------------------------------------------------------------------------
-- §4. RPC: única puerta de escritura
-- -----------------------------------------------------------------------------
-- Otorgar. La llama el TITULAR (origen 'titular') o staff (origen 'admin_sozu').
-- La auto-delegación (titular = delegado) la corta el CHECK
-- personas_relacionadas_no_autorreferencia con 23514.
CREATE OR REPLACE FUNCTION public.otorgar_administrador_cuenta(
  p_id_persona_titular  integer,
  p_id_persona_delegado integer,
  p_alcance             text        DEFAULT 'total',
  p_id_propiedad        bigint      DEFAULT NULL,
  p_puede_escribir      boolean     DEFAULT false,
  p_vigencia_hasta      timestamptz DEFAULT NULL,
  p_responsabilidad_version text    DEFAULT NULL,
  p_evidencia_url       text        DEFAULT NULL,
  p_notas               text        DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_es_titular boolean;
  v_es_staff   boolean := public.current_puede_impersonar();
  v_origen     text;
  v_tipo       integer;
  v_vinculo    bigint;
  v_deleg      bigint;
BEGIN
  IF p_id_persona_titular IS NULL OR p_id_persona_delegado IS NULL THEN
    RAISE EXCEPTION 'Titular y delegado son obligatorios' USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (SELECT 1 FROM public.usuarios u
                  WHERE u.auth_user_id = auth.uid() AND u.id_persona = p_id_persona_titular)
    INTO v_es_titular;

  IF NOT v_es_titular AND NOT v_es_staff THEN
    RAISE EXCEPTION 'Solo el titular o el staff autorizado pueden otorgar este acceso'
      USING ERRCODE = '42501';
  END IF;

  v_origen := CASE WHEN v_es_titular THEN 'titular' ELSE 'admin_sozu' END;

  -- El delegado debe existir como persona. Su usuario puede crearse después
  -- (EF create-client-user); sin usuario la delegación existe pero no da sesión.
  IF NOT EXISTS (SELECT 1 FROM public.personas WHERE id = p_id_persona_delegado) THEN
    RAISE EXCEPTION 'La persona delegada % no existe', p_id_persona_delegado USING ERRCODE = '23503';
  END IF;

  SELECT id INTO v_tipo FROM public.tipos_relacion WHERE clave = 'ADMINISTRADOR_CUENTA';
  IF v_tipo IS NULL THEN
    RAISE EXCEPTION 'Falta la clave ADMINISTRADOR_CUENTA en tipos_relacion' USING ERRCODE = 'P0002';
  END IF;

  -- El vínculo: si ya hay uno activo se reutiliza; el UNIQUE parcial garantiza que sea a
  -- lo más uno. Si el anterior fue revocado (activo=false), este SELECT no lo encuentra y
  -- se inserta un vínculo NUEVO: el histórico de la revocación se conserva intacto.
  SELECT id INTO v_vinculo
  FROM public.personas_relacionadas
  WHERE id_persona = p_id_persona_titular
    AND id_persona_relacion = p_id_persona_delegado
    AND id_tipo_relacion = v_tipo
    AND activo;

  IF v_vinculo IS NULL THEN
    INSERT INTO public.personas_relacionadas
      (id_persona, id_persona_relacion, id_tipo_relacion, activo)
    VALUES (p_id_persona_titular, p_id_persona_delegado, v_tipo, true)
    RETURNING id INTO v_vinculo;
  END IF;

  INSERT INTO public.delegaciones_acceso (
    id_persona_relacionada, alcance, id_propiedad, puede_escribir,
    vigencia_hasta, origen, otorgado_por,
    responsabilidad_aceptada, responsabilidad_fecha, responsabilidad_version,
    evidencia_url, notas
  ) VALUES (
    v_vinculo, p_alcance, p_id_propiedad, p_puede_escribir,
    p_vigencia_hasta, v_origen, auth.uid(),
    (v_origen = 'titular'),
    CASE WHEN v_origen = 'titular' THEN now() END,
    CASE WHEN v_origen = 'titular' THEN COALESCE(p_responsabilidad_version, 'v1') END,
    p_evidencia_url, p_notas
  )
  -- Solo se llega aquí cuando el vínculo activo YA traía satélite: es editar el alcance
  -- de una delegación viva, no resucitar una revocada.
  ON CONFLICT (id_persona_relacionada) DO UPDATE
    SET alcance = EXCLUDED.alcance,
        id_propiedad = EXCLUDED.id_propiedad,
        puede_escribir = EXCLUDED.puede_escribir,
        vigencia_hasta = EXCLUDED.vigencia_hasta,
        revocado_por = NULL, fecha_revocacion = NULL, motivo_revocacion = NULL,
        fecha_actualizacion = now()
  RETURNING id INTO v_deleg;

  RETURN v_deleg;
END;
$$;

-- Revocar. La llama el titular o staff. Nunca borra.
CREATE OR REPLACE FUNCTION public.revocar_administrador_cuenta(
  p_id_delegacion bigint,
  p_motivo        text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_titular integer;
  v_vinculo bigint;
BEGIN
  SELECT pr.id_persona, pr.id
    INTO v_titular, v_vinculo
  FROM public.delegaciones_acceso d
  JOIN public.personas_relacionadas pr ON pr.id = d.id_persona_relacionada
  WHERE d.id = p_id_delegacion;

  IF v_titular IS NULL THEN
    RAISE EXCEPTION 'La delegacion % no existe', p_id_delegacion USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.current_puede_impersonar()
     AND NOT EXISTS (SELECT 1 FROM public.usuarios u
                      WHERE u.auth_user_id = auth.uid() AND u.id_persona = v_titular) THEN
    RAISE EXCEPTION 'Solo el titular o el staff autorizado pueden revocar este acceso'
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.delegaciones_acceso
     SET revocado_por = auth.uid(),
         fecha_revocacion = now(),
         motivo_revocacion = p_motivo
   WHERE id = p_id_delegacion;

  -- El vínculo se apaga: es lo que hace que los helpers dejen de verlo.
  UPDATE public.personas_relacionadas SET activo = false WHERE id = v_vinculo;

  RETURN true;
END;
$$;

-- Lo que el delegado administra (para el selector de titular del portal).
CREATE OR REPLACE FUNCTION public.get_mis_administraciones()
RETURNS TABLE (
  id_persona_titular integer,
  nombre_titular     text,
  alcance            text,
  id_propiedad       bigint,
  puede_escribir     boolean,
  vigencia_hasta     timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT * FROM public.current_personas_administradas();
$$;

-- Lo que el TITULAR otorgó (para su pantalla de accesos). Incluye las revocadas: la
-- pantalla necesita mostrar el historial, y por eso NO filtra por pr.activo.
CREATE OR REPLACE FUNCTION public.get_mis_administradores_otorgados()
RETURNS TABLE (
  id_delegacion     bigint,
  id_persona        integer,
  nombre            text,
  email             text,
  tiene_usuario     boolean,
  alcance           text,
  id_propiedad      bigint,
  puede_escribir    boolean,
  fecha_inicio      timestamptz,
  vigencia_hasta    timestamptz,
  activo            boolean,
  fecha_revocacion  timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT d.id, p.id, p.nombre_legal, p.email,
         EXISTS (SELECT 1 FROM public.usuarios u
                  WHERE u.id_persona = p.id AND COALESCE(u.activo,false)),
         d.alcance, d.id_propiedad, d.puede_escribir,
         d.fecha_inicio, d.vigencia_hasta, pr.activo, d.fecha_revocacion
  FROM public.usuarios yo
  JOIN public.personas_relacionadas pr ON pr.id_persona = yo.id_persona
  JOIN public.tipos_relacion tr        ON tr.id = pr.id_tipo_relacion
  JOIN public.delegaciones_acceso d    ON d.id_persona_relacionada = pr.id
  JOIN public.personas p               ON p.id = pr.id_persona_relacion
  WHERE yo.auth_user_id = auth.uid()
    AND tr.clave = 'ADMINISTRADOR_CUENTA'
  ORDER BY pr.activo DESC, d.fecha_inicio DESC;
$$;

-- -----------------------------------------------------------------------------
-- §5. RLS del satélite + ACL
-- -----------------------------------------------------------------------------
-- Lectura: solo titular, delegado o staff. Escritura: solo vía RPC.
ALTER TABLE public.delegaciones_acceso ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS delegaciones_acceso_select ON public.delegaciones_acceso;
CREATE POLICY delegaciones_acceso_select
  ON public.delegaciones_acceso FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.personas_relacionadas pr
      JOIN public.usuarios u ON u.auth_user_id = auth.uid()
      WHERE pr.id = delegaciones_acceso.id_persona_relacionada
        AND (u.id_persona = pr.id_persona OR u.id_persona = pr.id_persona_relacion)
    )
    OR public.current_puede_impersonar()
  );

-- Sin policy de INSERT/UPDATE/DELETE: la escritura entra por las RPC SECURITY DEFINER,
-- que hacen bypass de RLS por diseño.

-- La tabla NACE con anon=arwdDxtm por los DEFAULT PRIVILEGES de este proyecto. RLS ya
-- dejaría a anon sin filas (las policies son TO authenticated), pero el grant se quita
-- igual: un día alguien agrega una policy TO public y el agujero aparece solo.
REVOKE ALL ON TABLE public.delegaciones_acceso FROM PUBLIC, anon;
GRANT SELECT ON public.delegaciones_acceso TO authenticated, service_role;

-- Las funciones nacen con EXECUTE para PUBLIC y anon: se revoca y se otorga explícito.
-- Sin el GRANT a authenticated, .rpc() responde 403.
REVOKE ALL ON FUNCTION public.otorgar_administrador_cuenta(integer,integer,text,bigint,boolean,timestamptz,text,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revocar_administrador_cuenta(bigint,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_mis_administraciones() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_mis_administradores_otorgados() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.current_personas_administradas() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.current_puede_ver_persona(integer) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.otorgar_administrador_cuenta(integer,integer,text,bigint,boolean,timestamptz,text,text,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.revocar_administrador_cuenta(bigint,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_mis_administraciones() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_mis_administradores_otorgados() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.current_personas_administradas() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.current_puede_ver_persona(integer) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- §6. Self-verifying: si algo no quedó, se aborta la migración
-- -----------------------------------------------------------------------------
DO $verifica$
DECLARE
  v_checks integer;
  v_trigs  integer;
BEGIN
  SELECT count(*) INTO v_checks FROM pg_constraint
   WHERE conrelid = 'public.delegaciones_acceso'::regclass AND contype = 'c';
  IF v_checks <> 7 THEN
    RAISE EXCEPTION 'delegaciones_acceso debe tener 7 CHECK, tiene %', v_checks;
  END IF;

  SELECT count(*) INTO v_trigs FROM pg_trigger
   WHERE tgrelid = 'public.delegaciones_acceso'::regclass AND NOT tgisinternal;
  IF v_trigs <> 2 THEN
    RAISE EXCEPTION 'faltan triggers en delegaciones_acceso (hay %)', v_trigs;
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.delegaciones_acceso'::regclass) THEN
    RAISE EXCEPTION 'delegaciones_acceso quedo sin RLS';
  END IF;

  IF has_table_privilege('anon','public.delegaciones_acceso','SELECT') THEN
    RAISE EXCEPTION 'anon conserva SELECT sobre delegaciones_acceso';
  END IF;

  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
       WHERE n.nspname='public' AND p.prosecdef AND p.proname IN
         ('fn_delegaciones_acceso_valida','current_personas_administradas',
          'current_puede_ver_persona','otorgar_administrador_cuenta',
          'revocar_administrador_cuenta','get_mis_administraciones',
          'get_mis_administradores_otorgados')) <> 7 THEN
    RAISE EXCEPTION 'faltan funciones SECURITY DEFINER de la delegacion';
  END IF;

  IF has_function_privilege('anon','public.current_puede_ver_persona(integer)','EXECUTE')
     OR has_function_privilege('anon',
          'public.otorgar_administrador_cuenta(integer,integer,text,bigint,boolean,timestamptz,text,text,text)',
          'EXECUTE') THEN
    RAISE EXCEPTION 'anon conserva EXECUTE en las funciones de la delegacion';
  END IF;

  IF NOT has_function_privilege('authenticated',
        'public.otorgar_administrador_cuenta(integer,integer,text,bigint,boolean,timestamptz,text,text,text)',
        'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated no puede ejecutar otorgar_administrador_cuenta: .rpc() daria 403';
  END IF;
END
$verifica$;

COMMIT;
