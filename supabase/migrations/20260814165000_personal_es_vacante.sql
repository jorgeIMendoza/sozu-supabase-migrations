-- Vacantes en Roles y Sueldos
-- Fecha: 2026-08-14
-- Origen: Ejecuciones/ejecusiones.md
--
-- Timestamp con hora real (165000) y no redonda, para no repetir la colision de prefijos
-- del 2026-08-12: los 14 digitos son la PK de supabase_migrations.schema_migrations, asi
-- que dos archivos del mismo dia con hora redonda tumban el deploy del segundo.
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- Una vacante es una posicion presupuestada que todavia no tiene a nadie: ya tiene rol,
-- proyectos, costo y —si su rol comisiona— participacion en la estructura de comisiones.
-- Lo unico que le falta es la persona. Esta migracion la hace administrable como tal y
-- permite medir su efecto sobre el costo fijo de SOZU.
--
-- ─── El hallazgo ──────────────────────────────────────────────────────────────
-- Las vacantes YA EXISTEN, pero disfrazadas de personas. Verificado read-only contra
-- produccion el 2026-08-14:
--
--   id | nombre                          | rol                                  | costo
--   ---+---------------------------------+--------------------------------------+--------
--   11 | Vacante Venta Inbound Monocolo   | Asesor de Ventas Inbound Embajadores | 20000
--   12 | Vacante Venta Outbound Monocolo  | Asesor de Ventas Outbound            | 20000
--   13 | Vacante Evangelizador Promotor   | Evangelizador y Promotor             | 20000
--
-- Suman 60,000 de los 328,784.23 del costo fijo de SOZU (13 personas activas de tipo
-- empleado_sozu): el 18.2% del costo fijo corresponde hoy a plazas que nadie ocupa, y nada
-- en el sistema lo distingue. Cada una tiene ademas 1 proyecto vinculado y 6 reglas de
-- comision, asi que ya pesan tanto en el costo por proyecto como en el motor de comisiones.
--
-- ─── Decisiones ───────────────────────────────────────────────────────────────
-- · Una COLUMNA y no una tabla nueva. Una vacante tiene exactamente los mismos atributos
--   que una persona: rol principal y adicionales, proyectos con su % de asignacion, los
--   tres componentes del costo, perfil y participacion en comisiones. Separarla obligaria a
--   que cada consumidor —costo por proyecto, organigrama, comisionistas del motor,
--   escenarios— leyera dos fuentes y las uniera. Vacante no es otra entidad: es el ESTADO
--   de una plaza, y lo que falta es la persona. Con la bandera, todo lo construido sigue
--   funcionando sin cambios.
-- · Cubrir una vacante NO crea una plaza nueva: se apaga la bandera y se captura el nombre.
--   La plaza conserva su id, su rol, sus proyectos y su historia de costo.
-- · La baja de una vacante es la baja logica que ya existe (activo = false + fecha_baja +
--   motivo_baja): cancelar una plaza presupuestada y darla de baja son la misma operacion y
--   conviene que compartan el historico.
-- · El correo yopmail.com de las tres filas se conserva: no estorba y borrarlo perderia el
--   dato de contacto que alguien capturo a proposito.
--
-- Idempotente: ADD COLUMN / CREATE INDEX IF NOT EXISTS y el UPDATE solo toca lo que aun no
-- esta marcado. Sin BEGIN/COMMIT (el CI envuelve cada archivo).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. La bandera
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.personal_organizacional
  ADD COLUMN IF NOT EXISTS es_vacante boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.personal_organizacional.es_vacante IS
  'true = plaza presupuestada sin ocupante. Tiene rol, proyectos y costo, y participa en '
  'la estructura de comisiones; solo le falta la persona. Al cubrirse se pone en false y se '
  'captura el nombre: la plaza conserva su id, su rol, sus proyectos y su historia de costo.';

-- Parcial: solo interesa el subconjunto minoritario, y se consulta junto con `activo`.
CREATE INDEX IF NOT EXISTS personal_organizacional_es_vacante_idx
  ON public.personal_organizacional (es_vacante) WHERE es_vacante;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Marcado de las vacantes existentes
--
--    El documento marca por id (11, 12, 13) y no por `nombre ILIKE '%vacante%'`, con buena
--    razon: maniana alguien puede apellidarse asi o llamar "Vacante temporal" a una persona
--    real, y una migracion que adivina por texto acabaria marcando a quien no debe.
--
--    PERO esos ids son los de PRODUCCION, y esta migracion corre tambien en dev/Preview,
--    donde `personal_organizacional` tiene otro contenido. Ya paso en esta misma serie: los
--    ids de `submenus` del Anexo 3 (276 y 368) resultaron ser filas completamente distintas
--    en produccion. Un UPDATE por id a secas marcaria como vacante a tres personas reales
--    en el otro entorno, en silencio.
--
--    Por eso el id sigue siendo la llave —se respeta la decision del documento— y el nombre
--    se usa solo como CINTURON DE SEGURIDAD: si la fila con ese id no es una vacante, no se
--    toca. En produccion marca exactamente las tres; en cualquier otro entorno, solo marca
--    las que de verdad lo sean.
-- ═══════════════════════════════════════════════════════════════════════════════
UPDATE public.personal_organizacional
SET es_vacante = true
WHERE id IN (11, 12, 13)
  AND nombre ILIKE 'Vacante%'
  AND NOT es_vacante;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. Reporte del resultado
--    Avisa (no aborta) si el conteo no es el esperado: el numero correcto depende del
--    entorno, asi que tumbar el CI de dev por eso seria un falso positivo.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $reporte$
DECLARE
  v_vacantes bigint;
  v_costo_v  numeric;
  v_costo_o  numeric;
BEGIN
  SELECT count(*) FILTER (WHERE es_vacante),
         COALESCE(sum(costo_total) FILTER (WHERE es_vacante), 0),
         COALESCE(sum(costo_total) FILTER (WHERE NOT es_vacante), 0)
  INTO v_vacantes, v_costo_v, v_costo_o
  FROM public.personal_organizacional
  WHERE activo AND tipo_personal = 'empleado_sozu';

  RAISE NOTICE
    'Costo fijo de SOZU: % en plazas ocupadas + % en % vacante(s) vigente(s).',
    v_costo_o, v_costo_v, v_vacantes;

  IF v_vacantes <> 3 THEN
    RAISE WARNING
      'Se esperaban 3 vacantes (ids 11, 12 y 13, los de produccion) y hay %. Si este es otro entorno es normal: el marcado solo toca filas cuyo nombre empieza con "Vacante". Revisar y marcar a mano las que correspondan.',
      v_vacantes;
  END IF;
END
$reporte$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT column_name, data_type, is_nullable, column_default
--   FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='personal_organizacional'
--     AND column_name='es_vacante';
--
--   SELECT indexname, indexdef FROM pg_indexes
--   WHERE schemaname='public' AND tablename='personal_organizacional'
--     AND indexname='personal_organizacional_es_vacante_idx';
--
-- Las tres vacantes quedaron marcadas:
--   SELECT id, nombre, es_vacante, costo_total
--   FROM public.personal_organizacional WHERE es_vacante ORDER BY id;
--   -- esperado en produccion: ids 11, 12 y 13, 20000.00 cada una
--
-- Efecto sobre el costo fijo: ocupado vs vacante
--   SELECT
--     count(*) FILTER (WHERE NOT es_vacante)         AS personas,
--     sum(costo_total) FILTER (WHERE NOT es_vacante) AS costo_ocupado,
--     count(*) FILTER (WHERE es_vacante)             AS vacantes,
--     sum(costo_total) FILTER (WHERE es_vacante)     AS costo_vacantes,
--     sum(costo_total)                               AS costo_total
--   FROM public.personal_organizacional
--   WHERE activo AND tipo_personal = 'empleado_sozu';
--   -- esperado en produccion: 10 personas / 268,784.23 ocupado,
--   --                          3 vacantes / 60,000.00, total 328,784.23
--
-- ─── Lo que la base NO hace ───────────────────────────────────────────────────
-- · Una vacante SIGUE SUMANDO al costo fijo y sigue apareciendo como comisionista: es
--   deliberado —es justo lo que se quiere medir— pero significa que separar "costo de
--   plazas ocupadas" de "costo de vacantes" es responsabilidad de cada consulta del front.
--   Ninguna vista ni constraint lo impone.
-- · Cubrir una vacante es solo apagar la bandera y capturar el nombre; nada obliga a que el
--   nombre cambie al hacerlo, asi que una plaza puede quedar como "Vacante ..." con
--   es_vacante = false si el front no exige el nombre nuevo.
-- · Al dar de baja una vacante, sus vinculaciones en personal_proyectos NO se desactivan
--   solas — igual que con cualquier persona. El front debe cerrarlas (ver el caso 3 del UAT
--   del documento).
--
-- ─── Front dependiente de este DDL (repo sozu-admin) ──────────────────────────
-- Antes de ejecutarlo el modulo funciona igual que hoy: el hook detecta que la columna no
-- existe (42703 / PGRST204), relee sin ella y trata a todas las filas como personas —el
-- comportamiento actual—, mostrando el aviso del DDL pendiente en la seccion de Vacantes.
-- Ningun costo cambia y nadie pierde su rol.
