-- 20260804070000_cuentas_sozu_empresa_stp.sql
--
-- `cuentas_sozu.empresa_stp`: mapea las empresas de `pagos_stp_raw` a la cuenta de
-- cobro donde se concentran, para que el batch deduzca desde la CLABE STP del pago en
-- qué estado de cuenta buscarlo, sin tabla de reglas y sin hardcode en Python.
--
-- POR QUÉ `text[]` Y NO UNA COLUMNA ESCALAR CON ÍNDICE ÚNICO (corrección al spec)
--   La especificación pedía `empresa_stp text` + índice único parcial, es decir una
--   empresa por cuenta y una cuenta por empresa. La relación real es N:M, confirmado
--   por Eduardo el 2026-08-04 sobre la regla de cobro vigente:
--     · Bottura → Real Estate; bodegas y estacionamiento → Real Estate
--     · Daiku → Tallwood; condensadoras → Tallwood
--     · Paquete de muebles → Komakai … y Komakai son DOS cuentas (Santander id 2 y
--       Banorte id 5): "los pagos pueden reflejarse en ambas". Una empresa → 2 cuentas.
--     · Tallwood (id 3) concentra a la vez `TALLWOOD` (condensadoras de Bottura) y
--       `VIVE_DAIKU` (unidades de Daiku). Una cuenta → 2 empresas.
--   Con la columna escalar, `DAIKU` no se puede representar (el índice único deja meterla
--   en una sola de las dos Komakai) y `VIVE_DAIKU` obligaría a un segundo cambio de forma.
--   El arreglo cubre los dos sentidos sin tabla nueva, que es lo que pedía el spec.
--
-- CÓMO SE CONSULTA (lado micro, consulta directa; no hace falta RPC)
--   `cuentas_sozu` tiene 5 filas: el micro las trae completas en una llamada
--   (`select=id,alias,empresa_stp,bancos(nombre)`) y arma el mapa empresa → [cuenta] en
--   memoria. Por eso NO se crea índice sobre `empresa_stp`: a este volumen un GIN nunca
--   se usaría (y `empresa = ANY(col)` ni siquiera puede usarlo; requeriría `col @> ...`).
--   Tampoco se crea el índice de `pagos_stp_raw (cuenta_beneficiario)` que pedía el spec:
--   ya existe `idx_pagos_stp_raw_clabe_fecha (cuenta_beneficiario, fecha_creacion DESC)`
--   desde 20260803170000, y su primera columna cubre la búsqueda por igualdad.
--
-- DOS COSAS QUE EL MICRO DEBE RESOLVER (no son DDL, quedan documentadas aquí)
--   1. Empresa con más de una cuenta (`DAIKU` → 2 y 5): el ruteo no puede elegir una.
--      Debe caer al grupo genérico del proyecto, que es el comportamiento de hoy.
--   2. CLABEs ambiguas: el spec verificó 0 el 2026-07-27; al 2026-08-04 hay 5
--      (`A1_HABITACIONAL`/`REAL_E_VENTURES` 121 pagos, `HEVI_HOLDING`/`REAL_E_VENTURES` 35,
--      `HEVI_HOLDING`/`JMDQ` 30, `A1_HABITACIONAL`/`MUTUO_VIVE` 7,
--      `A1_HABITACIONAL`/`HEVI_HOLDING` 4), y tocan 2 pendientes de batch. El `LIMIT 1`
--      sobre `pagos_stp_raw` elegiría empresa al azar: el desempate debe ser determinista
--      (empresa más frecuente para esa CLABE) o caer al grupo genérico.
--
-- PENDIENTES DE DATO (no bloquean, se resuelven con un UPDATE de una línea)
--   · `HEVI_HOLDING` (Margot) no tiene fila en `cuentas_sozu`: falta numero_cuenta, clabe
--     e id_banco, así que no se inventa aquí. Además Margot no tiene ningún estado de
--     cuenta subido y sigue en BLOCKED_PROJECTS.
--   · `A1_HABITACIONAL`, `LATTE`, `MONOCOLO`, `MUTUO_VIVE`, `MUTUO_CREA` sin cuenta
--     asignada: no aparecen en los pendientes de Bottura/Daiku.
--   · Bottura todavía no tiene estados de cuenta de `tallwood` (sí de real_estate 54,
--     jmdq 40, komakai Banorte 24, komakai Santander 12). Mientras no se suban, los ~36
--     pendientes de condensadora se rutean a una cuenta sin estados de ese proyecto: el
--     micro debe tratar "cuenta sin estados del proyecto" como grupo genérico, no como
--     cero resultados.
--
-- Riesgo de datos: bajo. Columna nueva anulable + UPDATE de 5 filas de catálogo. Ninguna
-- función ni política depende de la columna todavía; sin poblar, el micro se comporta
-- como hoy. Idempotente y self-verifying. Sin BEGIN/COMMIT (el CI envuelve en transacción).
--
-- Rollback:
--   ALTER TABLE public.cuentas_sozu DROP CONSTRAINT IF EXISTS cuentas_sozu_empresa_stp_valida;
--   ALTER TABLE public.cuentas_sozu DROP COLUMN IF EXISTS empresa_stp;

-- 1) Anchor: el catálogo debe ser el que se mapeó (id → alias → numero_cuenta).
DO $guard$
DECLARE
  r         RECORD;
  v_alias   TEXT;
  v_cuenta  TEXT;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      (1, 'real_estate', '65-50809196-3'),
      (2, 'komakai',     '65-51111875-1'),
      (3, 'tallwood',    '65-50878620-1'),
      (4, 'jmdq',        '0108670641'),
      (5, 'komakai',     '1171530538')
    ) AS t(id, alias, numero_cuenta)
  LOOP
    SELECT cs.alias, cs.numero_cuenta
      INTO v_alias, v_cuenta
      FROM public.cuentas_sozu cs
     WHERE cs.id = r.id;

    IF v_alias IS NULL THEN
      RAISE EXCEPTION 'cuentas_sozu id % no existe; el mapeo de empresas ya no aplica', r.id;
    END IF;

    IF v_alias <> r.alias OR v_cuenta <> r.numero_cuenta THEN
      RAISE EXCEPTION
        'drift en cuentas_sozu id %: vivo (%, %) <> esperado (%, %). Revalidar el mapeo empresa→cuenta antes de aplicar.',
        r.id, v_alias, v_cuenta, r.alias, r.numero_cuenta;
    END IF;
  END LOOP;
END
$guard$;

-- 2) Columna.
ALTER TABLE public.cuentas_sozu
  ADD COLUMN IF NOT EXISTS empresa_stp text[];

COMMENT ON COLUMN public.cuentas_sozu.empresa_stp IS
  'Valores de pagos_stp_raw.empresa que se concentran en esta cuenta. Permite deducir desde la CLABE STP del pago a que estado de cuenta pertenece, sin tabla de reglas. Es N:M: una cuenta puede concentrar varias empresas (tallwood = TALLWOOD + VIVE_DAIKU) y una empresa puede caer en varias cuentas (DAIKU en las dos Komakai), en cuyo caso el ruteo no es unico y el batch usa el grupo genérico del proyecto.';

-- 3) Sin arreglos vacíos ni elementos NULL (un '{}' o '{NULL}' rompería el mapeo en silencio).
DO $ck$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.cuentas_sozu'::regclass
       AND conname  = 'cuentas_sozu_empresa_stp_valida'
  ) THEN
    ALTER TABLE public.cuentas_sozu
      ADD CONSTRAINT cuentas_sozu_empresa_stp_valida
      CHECK (
        empresa_stp IS NULL
        OR (cardinality(empresa_stp) > 0
            AND array_position(empresa_stp, NULL::text) IS NULL)
      );
  END IF;
END
$ck$;

-- 4) Backfill del catálogo (regla de cobro vigente confirmada por Eduardo 2026-08-04).
--    Idempotente: solo escribe si el valor difiere.
UPDATE public.cuentas_sozu SET empresa_stp = ARRAY['REAL_E_VENTURES']
 WHERE id = 1 AND empresa_stp IS DISTINCT FROM ARRAY['REAL_E_VENTURES'];          -- real_estate (Santander): Bottura, bodegas, estacionamiento

UPDATE public.cuentas_sozu SET empresa_stp = ARRAY['DAIKU']
 WHERE id = 2 AND empresa_stp IS DISTINCT FROM ARRAY['DAIKU'];                     -- komakai (Santander): paquete de muebles

UPDATE public.cuentas_sozu SET empresa_stp = ARRAY['TALLWOOD','VIVE_DAIKU']
 WHERE id = 3 AND empresa_stp IS DISTINCT FROM ARRAY['TALLWOOD','VIVE_DAIKU'];     -- tallwood (Santander): condensadoras de Bottura + unidades de Daiku

UPDATE public.cuentas_sozu SET empresa_stp = ARRAY['JMDQ']
 WHERE id = 4 AND empresa_stp IS DISTINCT FROM ARRAY['JMDQ'];                      -- jmdq (BBVA): unidades de Bottura cobradas por JMDQ

UPDATE public.cuentas_sozu SET empresa_stp = ARRAY['DAIKU']
 WHERE id = 5 AND empresa_stp IS DISTINCT FROM ARRAY['DAIKU'];                     -- komakai (Banorte): paquete de muebles, la otra Komakai

-- 5) Verificación post-aplicación.
DO $verify$
DECLARE
  v_mal      TEXT;
  v_inexist  TEXT;
BEGIN
  -- 5.1 El mapeo quedó exactamente como se pidió.
  SELECT string_agg(format('id %s: %s', e.id, COALESCE(cs.empresa_stp::text, 'NULL')), '; ')
    INTO v_mal
    FROM (VALUES
      (1, ARRAY['REAL_E_VENTURES']),
      (2, ARRAY['DAIKU']),
      (3, ARRAY['TALLWOOD','VIVE_DAIKU']),
      (4, ARRAY['JMDQ']),
      (5, ARRAY['DAIKU'])
    ) AS e(id, esperado)
    JOIN public.cuentas_sozu cs ON cs.id = e.id
   WHERE cs.empresa_stp IS DISTINCT FROM e.esperado;

  IF v_mal IS NOT NULL THEN
    RAISE EXCEPTION 'el backfill de empresa_stp no quedó como se esperaba: %', v_mal;
  END IF;

  -- 5.2 Ninguna empresa mapeada es un valor inventado: todas existen en pagos_stp_raw.
  SELECT string_agg(DISTINCT emp, ', ')
    INTO v_inexist
    FROM public.cuentas_sozu cs, unnest(cs.empresa_stp) AS emp
   WHERE NOT EXISTS (
     SELECT 1 FROM public.pagos_stp_raw r WHERE r.empresa = emp
   );

  IF v_inexist IS NOT NULL THEN
    RAISE EXCEPTION 'empresa_stp con valores que no existen en pagos_stp_raw.empresa: %', v_inexist;
  END IF;

  -- 5.3 Informativo: empresas con pagos pero sin cuenta asignada (Margot y compañía).
  RAISE NOTICE 'empresas sin cuenta asignada: %', (
    SELECT COALESCE(string_agg(r.empresa, ', ' ORDER BY r.empresa), 'ninguna')
      FROM (SELECT DISTINCT empresa FROM public.pagos_stp_raw WHERE empresa IS NOT NULL) r
     WHERE NOT EXISTS (
       SELECT 1 FROM public.cuentas_sozu cs WHERE cs.empresa_stp @> ARRAY[r.empresa]
     )
  );
END
$verify$;
