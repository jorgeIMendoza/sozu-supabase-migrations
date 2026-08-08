-- Homologación CRM ↔ Portal Agente — 01: adoptar la FK de estado del lead
-- Fecha: 2026-08-07
--
-- La migración del CRM `20260804180000_crm_estatus_lead_fk` ya hizo lo pesado: creó
-- `crm_leads_atribucion.id_estatus_lead` (FK → `crm_estados_lead`), su índice y el trigger
-- bidireccional `trg_crm_sync_estatus_lead_id`, que mantiene alineados el texto legacy y el
-- id en la misma transacción. Este archivo NO propone nada nuevo: adopta lo que ya existe.
--
-- Hace tres cosas:
--   1. Verifica que la migración del CRM esté aplicada (aborta si no).
--   2. Red de seguridad: cualquier atribución activa sin `id_estatus_lead` queda resuelta.
--   3. Saca `entidades_relacionadas.id_estatus_persona` del flujo de leads y lo marca legacy.
--
-- Lo que deliberadamente NO hace:
--   * NO revoca UPDATE sobre `estatus_lead`. La migración del CRM es aditiva a propósito y
--     su front sigue escribiendo el texto; revocarlo rompería el CRM. El cutover es de ellos.
--   * NO pone FK ni CHECK sobre el texto: `crm_estados_lead` es administrable en runtime
--     (CRM > Configuración da de alta claves nuevas), y una restricción sobre el texto
--     reventaría con el primer estado nuevo mal normalizado.
--   * NO borra `entidades_relacionadas.id_estatus_persona`: `Prospectos.tsx`,
--     `InmobProspectos.tsx` y los KPIs de Alta Dirección todavía la leen. Migrar eso es
--     trabajo de front aparte.
--
-- ─── Verificado read-only contra prod (tzmhgfjmddkfyffkkmto, 2026-08-07) ──────
--   * `id_estatus_lead` presente con FK e índice; `trg_crm_sync_estatus_lead_id` y
--     `trg_crm_sync_etapa_ciclo_vida_id` existen.
--   * 2,304 atribuciones activas, **0 sin id_estatus_lead** y **0 desalineadas** contra el
--     texto. Tampoco hay inactivas sin estado. Las cifras del documento (2,295 / 736) son de
--     hace dos días; la base creció, la conclusión no cambia.
--   * Los 16 textos distintos de `estatus_lead` tienen los 16 su clave en `crm_estados_lead`:
--     ninguna fila depende del fallback a 'nuevo'.
--   * `id_estatus_persona`: 750 filas en tipo 7 (histórico, se conservan) y **69 fuera de
--     tipo 7** (67 del tipo 2, 1 del 15, 1 del 19), todas activas y todas con el mismo valor
--     heredado: id 3 = 'Nuevo'. `estatus_persona` está declarado para tipo 7, así que esas 69
--     muestran un estado que no les corresponde.
--   * Ninguna vista ni función de la base lee `id_estatus_persona`: solo el front. Limpiar
--     los tipos ≠ 7 no rompe nada del lado de la BD.
--
-- La normalización usada aquí —lower(regexp_replace(btrim(x),'\s+','_','g'))— es LA MISMA
-- que usa `crm_sync_estatus_lead_id()`, verificada leyendo su definición viva.
--
-- Idempotente: los UPDATE son convergentes (en la segunda corrida no matchean filas) y los
-- COMMENT se sobrescriben. Sin BEGIN/COMMIT (el CI envuelve cada migración en transacción).

-- ─────────────────────────────────────────────────────────────────────
-- 1. Guarda: la migración del CRM tiene que estar aplicada
-- ─────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'crm_leads_atribucion'
      AND column_name = 'id_estatus_lead'
  ) THEN
    RAISE EXCEPTION 'Falta crm_leads_atribucion.id_estatus_lead: aplicar antes la migración del CRM 20260804180000';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_crm_sync_estatus_lead_id') THEN
    RAISE EXCEPTION 'Falta el trigger de sincronía texto<->id del CRM (crm_sync_estatus_lead_id)';
  END IF;

  -- El fallback del paso 2 depende de esta clave.
  IF NOT EXISTS (SELECT 1 FROM public.crm_estados_lead WHERE clave = 'nuevo') THEN
    RAISE EXCEPTION 'crm_estados_lead no tiene la clave ''nuevo''; sin ella el fallback dejaría filas sin estado';
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────
-- 2. Red de seguridad + verificación de que no se desalinea nada
--    Hoy son 0 filas; esto cubre las creadas entre la migración del CRM y ésta.
--
--    Va todo en un bloque porque la comprobación correcta no es «hay desalineadas»
--    —eso puede venir de un rename de clave hecho en runtime, ajeno a esta migración—
--    sino «esta migración no CREÓ desalineadas». Por eso se mide antes y después.
-- ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_antes       bigint;
  v_despues     bigint;
  v_por_texto   bigint;
  v_fallback    bigint;
  v_sin_estado  bigint;
BEGIN
  SELECT count(*) INTO v_antes
  FROM public.crm_leads_atribucion a
  JOIN public.crm_estados_lead el ON el.id = a.id_estatus_lead
  WHERE a.activo
    AND el.clave IS DISTINCT FROM lower(regexp_replace(btrim(a.estatus_lead), '\s+', '_', 'g'));

  -- 2.a Resolver por el texto, que es lo que hace el trigger del CRM.
  UPDATE public.crm_leads_atribucion a
  SET id_estatus_lead = el.id
  FROM public.crm_estados_lead el
  WHERE a.activo
    AND a.id_estatus_lead IS NULL
    AND el.clave = lower(regexp_replace(btrim(a.estatus_lead), '\s+', '_', 'g'));
  GET DIAGNOSTICS v_por_texto = ROW_COUNT;

  -- 2.b Lo que el texto no resuelve cae a 'nuevo'.
  --     OJO: el trigger reescribe `estatus_lead` con la clave del id, así que el texto
  --     original de esas filas SE PIERDE. Es el precio de no dejar leads sin estado; por
  --     eso se avisa cuántas fueron. Hoy son 0.
  UPDATE public.crm_leads_atribucion
  SET id_estatus_lead = (SELECT id FROM public.crm_estados_lead WHERE clave = 'nuevo')
  WHERE activo AND id_estatus_lead IS NULL;
  GET DIAGNOSTICS v_fallback = ROW_COUNT;

  IF v_por_texto > 0 OR v_fallback > 0 THEN
    RAISE NOTICE 'Backfill de id_estatus_lead: % por texto, % al fallback ''nuevo'' (su texto original quedó reescrito).',
                 v_por_texto, v_fallback;
  END IF;

  SELECT count(*) INTO v_sin_estado
  FROM public.crm_leads_atribucion WHERE activo AND id_estatus_lead IS NULL;
  IF v_sin_estado > 0 THEN
    RAISE EXCEPTION 'Quedaron % atribuciones activas sin id_estatus_lead', v_sin_estado;
  END IF;

  SELECT count(*) INTO v_despues
  FROM public.crm_leads_atribucion a
  JOIN public.crm_estados_lead el ON el.id = a.id_estatus_lead
  WHERE a.activo
    AND el.clave IS DISTINCT FROM lower(regexp_replace(btrim(a.estatus_lead), '\s+', '_', 'g'));

  IF v_despues > v_antes THEN
    RAISE EXCEPTION 'Esta migración desalineó texto<->id: % filas antes, % después', v_antes, v_despues;
  END IF;

  IF v_despues > 0 THEN
    -- Preexistente y ajeno a este archivo (típicamente una clave renombrada en runtime, que
    -- el trigger no propaga a las filas viejas). Se avisa, no se aborta el deploy.
    RAISE NOTICE 'Hay % atribuciones activas cuyo texto no coincide con la clave de su id_estatus_lead (preexistente).', v_despues;
  END IF;
END $$;

COMMENT ON COLUMN public.crm_leads_atribucion.id_estatus_lead IS
  'Estado del lead. FUENTE ÚNICA para el Portal Agente y el CRM. Catálogo: crm_estados_lead. '
  'El texto estatus_lead es legacy sincronizado por trg_crm_sync_estatus_lead_id: escribir el '
  'id, nunca el texto.';

-- ─────────────────────────────────────────────────────────────────────
-- 3. Sacar estatus_persona del flujo de leads
--    `estatus_persona` está declarado para id_tipo_entidad = 7 (prospectos); en los otros
--    tipos el valor está heredado por copia y muestra un estado que no les corresponde.
--    Se limpian TODAS (activas e inactivas): el dato es incorrecto en ambos casos.
-- ─────────────────────────────────────────────────────────────────────
UPDATE public.entidades_relacionadas
SET id_estatus_persona = NULL
WHERE id_estatus_persona IS NOT NULL
  AND id_tipo_entidad <> 7;

COMMENT ON COLUMN public.entidades_relacionadas.id_estatus_persona IS
  'LEGACY (2026-08-07): el estado del lead vive en crm_leads_atribucion.id_estatus_lead. '
  'Solo aplica a id_tipo_entidad = 7 (prospectos) y solo lo leen Prospectos.tsx, '
  'InmobProspectos y los KPIs de dirección. No escribir desde flujos nuevos.';

-- ─────────────────────────────────────────────────────────────────────
-- 4. Self-verifying de lo que SÍ garantiza este archivo
-- ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_fuera_t7 bigint;
BEGIN
  SELECT count(*) INTO v_fuera_t7
  FROM public.entidades_relacionadas
  WHERE id_estatus_persona IS NOT NULL AND id_tipo_entidad <> 7;
  IF v_fuera_t7 > 0 THEN
    RAISE EXCEPTION 'Quedaron % entidades de tipo <> 7 con id_estatus_persona', v_fuera_t7;
  END IF;
END $$;

-- Rollback:
--   La FK, el índice y el trigger son de la migración del CRM (20260804180000): revertirlos
--   es de ese lado. De este archivo solo se revierten los COMMENT; la limpieza de los 69
--   id_estatus_persona corrige un dato incorrecto y no se deshace.
--
-- Validación posterior:
--   SELECT count(*) FILTER (WHERE id_estatus_lead IS NULL) sin_estado, count(*) activas
--   FROM public.crm_leads_atribucion WHERE activo;                    -- esperado: 0 · 2304
--   SELECT id_tipo_entidad, count(*) FROM public.entidades_relacionadas
--   WHERE id_estatus_persona IS NOT NULL GROUP BY 1;                  -- esperado: solo tipo 7
