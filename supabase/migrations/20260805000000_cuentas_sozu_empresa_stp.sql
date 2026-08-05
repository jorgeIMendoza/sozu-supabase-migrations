-- 20260805000000_cuentas_sozu_empresa_stp.sql
--
-- `cuentas_sozu.empresa_stp`: mapea las empresas de `pagos_stp_raw` a la cuenta de
-- cobro donde se concentran, para que el batch deduzca desde la CLABE STP del pago en
-- qué estado de cuenta buscarlo, sin tabla de reglas y sin hardcode en Python.
--
-- REINTENTO DE 20260804070000 (falló en deploy-dev)
--   La versión anterior anclaba y backfilleaba por `cuentas_sozu.id` con los ids de
--   prod (1..5) y abortaba si no existían:
--     ERROR: cuentas_sozu id 1 no existe; el mapeo de empresas ya no aplica (SQLSTATE P0001)
--   El catálogo no está sincronizado entre entornos: dev tiene las mismas 5 cuentas con
--   ids 6..10 y el alias `real_state` en vez de `real_estate`. Lo que sí coincide en los
--   dos es `numero_cuenta` (y la CLABE), así que el mapeo va por `numero_cuenta` y una
--   cuenta ausente es un NOTICE, no un error: ningún assert depende de datos que puedan
--   diferir entre dev y prod. Timestamp reemitido porque dev ya aplicó 20260804170000 y
--   20260804180000, y este archivo entraría fuera de orden.
--
-- POR QUÉ `text[]` Y NO UNA COLUMNA ESCALAR CON ÍNDICE ÚNICO (corrección al spec)
--   La especificación pedía `empresa_stp text` + índice único parcial, es decir una
--   empresa por cuenta y una cuenta por empresa. La relación real es N:M, confirmado
--   por Eduardo el 2026-08-04 sobre la regla de cobro vigente:
--     · Bottura → Real Estate; bodegas y estacionamiento → Real Estate
--     · Daiku → Tallwood; condensadoras → Tallwood
--     · Paquete de muebles → Komakai … y Komakai son DOS cuentas (Santander
--       65-51111875-1 y Banorte 1171530538): "los pagos pueden reflejarse en ambas".
--       Una empresa → 2 cuentas.
--     · Tallwood (65-50878620-1) concentra a la vez `TALLWOOD` (condensadoras de
--       Bottura) y `VIVE_DAIKU` (unidades de Daiku). Una cuenta → 2 empresas.
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
--   1. Empresa con más de una cuenta (`DAIKU` → las dos Komakai): el ruteo no puede
--      elegir una. Debe caer al grupo genérico del proyecto, que es el comportamiento
--      de hoy.
--   2. CLABEs ambiguas: el spec verificó 0 el 2026-07-27; al 2026-08-04 hay 5 en prod
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

-- 1) Columna.
ALTER TABLE public.cuentas_sozu
  ADD COLUMN IF NOT EXISTS empresa_stp text[];

COMMENT ON COLUMN public.cuentas_sozu.empresa_stp IS
  'Valores de pagos_stp_raw.empresa que se concentran en esta cuenta. Permite deducir desde la CLABE STP del pago a que estado de cuenta pertenece, sin tabla de reglas. Es N:M: una cuenta puede concentrar varias empresas (tallwood = TALLWOOD + VIVE_DAIKU) y una empresa puede caer en varias cuentas (DAIKU en las dos Komakai), en cuyo caso el ruteo no es unico y el batch usa el grupo genérico del proyecto.';

-- 2) Sin arreglos vacíos ni elementos NULL (un '{}' o '{NULL}' rompería el mapeo en silencio).
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

-- 3) Backfill del catálogo (regla de cobro vigente confirmada por Eduardo 2026-08-04).
--    La llave es `numero_cuenta`, que sí es igual en dev y prod; el `id` y el `alias` no
--    lo son. Idempotente: solo escribe si el valor difiere. Cuenta ausente = NOTICE.
DO $backfill$
DECLARE
  r        RECORD;
  v_filas  INT;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      -- numero_cuenta,     empresas,                              para qué cobra
      ('65-50809196-3', ARRAY['REAL_E_VENTURES'],            'real_estate (Santander): Bottura, bodegas, estacionamiento'),
      ('65-51111875-1', ARRAY['DAIKU'],                      'komakai (Santander): paquete de muebles'),
      ('65-50878620-1', ARRAY['TALLWOOD','VIVE_DAIKU'],      'tallwood (Santander): condensadoras de Bottura + unidades de Daiku'),
      ('0108670641',    ARRAY['JMDQ'],                       'jmdq (BBVA): unidades de Bottura cobradas por JMDQ'),
      ('1171530538',    ARRAY['DAIKU'],                       'komakai (Banorte): paquete de muebles, la otra Komakai')
    ) AS t(numero_cuenta, empresas, para_que)
  LOOP
    SELECT COUNT(*) INTO v_filas
      FROM public.cuentas_sozu cs
     WHERE cs.numero_cuenta = r.numero_cuenta;

    IF v_filas = 0 THEN
      RAISE NOTICE 'cuentas_sozu sin la cuenta % (%): no se mapea en este entorno',
        r.numero_cuenta, r.para_que;
      CONTINUE;
    END IF;

    IF v_filas > 1 THEN
      RAISE EXCEPTION
        'cuentas_sozu tiene % filas con numero_cuenta %: el mapeo empresa→cuenta sería ambiguo',
        v_filas, r.numero_cuenta;
    END IF;

    UPDATE public.cuentas_sozu cs
       SET empresa_stp = r.empresas
     WHERE cs.numero_cuenta = r.numero_cuenta
       AND cs.empresa_stp IS DISTINCT FROM r.empresas;
  END LOOP;
END
$backfill$;

-- 4) Verificación post-aplicación. Solo sobre lo que este entorno sí tiene: nada de
--    asserts contra datos de catálogo que difieren entre dev y prod.
DO $verify$
DECLARE
  v_mal        TEXT;
  v_mapeadas   INT;
  v_sin_cuenta TEXT;
BEGIN
  -- 4.1 Toda cuenta presente quedó con el arreglo que le toca.
  SELECT string_agg(format('%s: %s (esperado %s)',
                           e.numero_cuenta,
                           COALESCE(cs.empresa_stp::text, 'NULL'),
                           e.empresas::text), '; ')
    INTO v_mal
    FROM (VALUES
      ('65-50809196-3', ARRAY['REAL_E_VENTURES']),
      ('65-51111875-1', ARRAY['DAIKU']),
      ('65-50878620-1', ARRAY['TALLWOOD','VIVE_DAIKU']),
      ('0108670641',    ARRAY['JMDQ']),
      ('1171530538',    ARRAY['DAIKU'])
    ) AS e(numero_cuenta, empresas)
    JOIN public.cuentas_sozu cs ON cs.numero_cuenta = e.numero_cuenta
   WHERE cs.empresa_stp IS DISTINCT FROM e.empresas;

  IF v_mal IS NOT NULL THEN
    RAISE EXCEPTION 'el backfill de empresa_stp no quedó como se esperaba: %', v_mal;
  END IF;

  SELECT COUNT(*) INTO v_mapeadas
    FROM public.cuentas_sozu WHERE empresa_stp IS NOT NULL;
  RAISE NOTICE 'cuentas con empresa_stp mapeada: %', v_mapeadas;

  -- 4.2 Informativo: empresas con pagos pero sin cuenta asignada (Margot y compañía).
  SELECT COALESCE(string_agg(r.empresa, ', ' ORDER BY r.empresa), 'ninguna')
    INTO v_sin_cuenta
    FROM (SELECT DISTINCT empresa FROM public.pagos_stp_raw WHERE empresa IS NOT NULL) r
   WHERE NOT EXISTS (
     SELECT 1 FROM public.cuentas_sozu cs WHERE cs.empresa_stp @> ARRAY[r.empresa]
   );
  RAISE NOTICE 'empresas sin cuenta asignada: %', v_sin_cuenta;
END
$verify$;
