-- Portal Bancos — Solicitudes de credito (pre-calificacion) + SLA + tasas por banco
-- Persistencia del envio de credito hipotecario del Portal Cliente (Pago Final -> banco aliado).
-- No recaba perfil ni contacto del cliente: se resuelven desde la cuenta/persona en la BD.
--
-- Contexto:
--  - cuentas_cobranza.tipo_financiamiento ya existe (P05); no se toca aqui.
--  - creditos_hipotecarios = credito FORMAL post-aprobacion (no es el lead).
--  - bancos_convenio = bancos aliados de la modal; se le agregan SLA + tasas.
--
-- NOTA: el seed de tasas/SLA (dev) NO va en esta migracion; son datos que alimenta el
-- banco real y contaminarian prod. Se aplica suelto solo en dev.

-- =====================================================================
-- Paso 1 — SLA + tasas por banco en bancos_convenio
-- =====================================================================
-- dias_respuesta: SLA del banco. NULL o <1 = seleccion definitiva (cliente no cambia).
--                 >=1 = la solicitud expira tras N dias y el cliente puede cambiar.
-- tasa_min/tasa_max/cat_min/cat_max: rangos que alimenta el banco para la estimacion.
--                 Si tasa_min/tasa_max son NULL, el portal no muestra estimacion.

ALTER TABLE public.bancos_convenio
  ADD COLUMN IF NOT EXISTS dias_respuesta INTEGER,
  ADD COLUMN IF NOT EXISTS tasa_min NUMERIC(6,3),
  ADD COLUMN IF NOT EXISTS tasa_max NUMERIC(6,3),
  ADD COLUMN IF NOT EXISTS cat_min  NUMERIC(6,3),
  ADD COLUMN IF NOT EXISTS cat_max  NUMERIC(6,3);

COMMENT ON COLUMN public.bancos_convenio.dias_respuesta IS
  'SLA de respuesta del banco en dias. NULL o <1 = seleccion definitiva (el cliente no puede cambiar). >=1 = la solicitud expira tras N dias y el cliente puede cambiar.';
COMMENT ON COLUMN public.bancos_convenio.tasa_min IS
  'Tasa anual minima que ofrece el banco (%). Si tasa_min/tasa_max son NULL el portal no muestra estimacion.';

-- =====================================================================
-- Paso 2 — Tabla bancos_solicitudes (envio de credito)
-- =====================================================================
-- Historial 1:N por cuenta. Solo UNA solicitud vigente (no terminal) por cuenta a la vez.

CREATE TABLE IF NOT EXISTS public.bancos_solicitudes (
  id                       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

  -- Vinculos
  id_cuenta_cobranza       BIGINT  NOT NULL REFERENCES public.cuentas_cobranza(id),
  id_banco                 INTEGER NOT NULL REFERENCES public.bancos(id),
  id_agente                INTEGER REFERENCES public.bancos_agentes(id),          -- broker asignado por la mesa
  id_credito_hipotecario   BIGINT  REFERENCES public.creditos_hipotecarios(id),   -- se llena al formalizar

  -- Datos del credito elegidos por el cliente
  monto_financiar          NUMERIC(14,2) NOT NULL,
  plazo_anios              SMALLINT      NOT NULL,

  -- Estimacion mostrada (solo si el banco tiene tasas; NULL en caso contrario)
  mensualidad_estimada_min NUMERIC(14,2),
  mensualidad_estimada_max NUMERIC(14,2),
  tasa_estimada_min        NUMERIC(6,3),
  tasa_estimada_max        NUMERIC(6,3),
  cat_estimado_min         NUMERIC(6,3),
  cat_estimado_max         NUMERIC(6,3),

  -- Propuesta del banco / acuerdo mutuo (lo llena el portal del banco)
  monto_aprobado           NUMERIC(14,2),
  plazo_aprobado_anios     SMALLINT,
  tasa_aprobada            NUMERIC(6,3),
  cat_aprobado             NUMERIC(6,3),
  mensualidad_aprobada     NUMERIC(14,2),
  notas_banco              TEXT,
  fecha_respuesta_banco    TIMESTAMPTZ,   -- el banco emitio su propuesta
  acuerdo_aceptado_cliente BOOLEAN NOT NULL DEFAULT false,
  fecha_acuerdo            TIMESTAMPTZ,    -- el cliente acepto -> acuerdo mutuo

  -- Ciclo de vida (mesa hipotecaria)
  estatus                  TEXT NOT NULL DEFAULT 'nuevo'
                             CHECK (estatus IN (
                               'nuevo','asignado','contactado','en_evaluacion',
                               'pre_aprobado','oferta_vinculante','en_coordinacion',
                               'formalizado','rechazado','desistido','expirada')),
  motivo_cierre            TEXT,

  -- SLA / expiracion (el banco es dueno del cambio)
  dias_respuesta_snapshot  INTEGER,        -- copia de bancos_convenio.dias_respuesta al enviar
  fecha_expiracion         TIMESTAMPTZ,    -- fecha_envio + dias_respuesta_snapshot; NULL = no expira
  notificado_expiracion    BOOLEAN NOT NULL DEFAULT false,

  -- Consentimiento LFPDPPP (checkbox previo al envio)
  consentimiento_datos     BOOLEAN NOT NULL DEFAULT false,
  fecha_consentimiento     TIMESTAMPTZ,

  fecha_envio              TIMESTAMPTZ NOT NULL DEFAULT now(),
  activo                   BOOLEAN NOT NULL DEFAULT true,
  fecha_creacion           TIMESTAMPTZ NOT NULL DEFAULT now(),
  fecha_actualizacion      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_bancos_solicitudes_cuenta
  ON public.bancos_solicitudes (id_cuenta_cobranza);
CREATE INDEX IF NOT EXISTS idx_bancos_solicitudes_banco
  ON public.bancos_solicitudes (id_banco);
CREATE INDEX IF NOT EXISTS idx_bancos_solicitudes_estatus
  ON public.bancos_solicitudes (estatus) WHERE activo;
CREATE INDEX IF NOT EXISTS idx_bancos_solicitudes_expiracion
  ON public.bancos_solicitudes (fecha_expiracion)
  WHERE activo AND fecha_expiracion IS NOT NULL;

-- Una sola solicitud VIGENTE (no terminal) por cuenta a la vez
CREATE UNIQUE INDEX IF NOT EXISTS uq_bancos_solicitudes_vigente
  ON public.bancos_solicitudes (id_cuenta_cobranza)
  WHERE activo AND estatus NOT IN ('rechazado','desistido','expirada','formalizado');

-- =====================================================================
-- Paso 3 — Trigger fecha_actualizacion (convencion del repo)
-- =====================================================================

CREATE TRIGGER update_bancos_solicitudes_updated_at
  BEFORE UPDATE ON public.bancos_solicitudes
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- =====================================================================
-- Paso 4 — RLS por dueno
-- =====================================================================
-- El insert va directo con rol authenticated (PostgREST). Sin RLS cualquier usuario
-- autenticado leeria/escribiria solicitudes ajenas (PII).
-- Roles: 23=Cliente, 28=Banco.
--  - Staff interno (rol NO en 23,28) -> ve todo.
--  - Cliente (23) -> solo las solicitudes de sus propias cuentas.
--  - Banco (28) -> SIN acceso todavia (fail-closed): no existe usuarios.id_banco_asociado
--    ni el portal del banco. Al construirlo, agregar esa columna y descomentar la rama
--    del rol 28 para acotar a id_banco.
-- auth.uid() envuelto en (SELECT auth.uid()) -> initPlan, se cachea por query.
-- Cadena de dueno: usuarios.auth_user_id = auth.uid() -> id_persona ->
--                  ofertas.id_persona_lead -> cuentas_cobranza.id_oferta.

ALTER TABLE public.bancos_solicitudes ENABLE ROW LEVEL SECURITY;

CREATE POLICY bancos_solicitudes_rw ON public.bancos_solicitudes
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = (SELECT auth.uid())
        AND (
          u.rol_id NOT IN (23, 28)                         -- staff interno ve todo
          OR (                                             -- cliente: solo sus cuentas
            u.rol_id = 23
            AND u.id_persona IN (
              SELECT o.id_persona_lead
              FROM public.cuentas_cobranza cc
              JOIN public.ofertas o ON o.id = cc.id_oferta
              WHERE cc.id = bancos_solicitudes.id_cuenta_cobranza
            )
          )
          -- OR (u.rol_id = 28 AND bancos_solicitudes.id_banco = u.id_banco_asociado)  -- banco (pendiente)
        )
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = (SELECT auth.uid())
        AND (
          u.rol_id NOT IN (23, 28)
          OR (
            u.rol_id = 23
            AND u.id_persona IN (
              SELECT o.id_persona_lead
              FROM public.cuentas_cobranza cc
              JOIN public.ofertas o ON o.id = cc.id_oferta
              WHERE cc.id = bancos_solicitudes.id_cuenta_cobranza
            )
          )
          -- OR (u.rol_id = 28 AND bancos_solicitudes.id_banco = u.id_banco_asociado)
        )
    )
  );
