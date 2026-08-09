-- Administración de Roles — objetivo, descripción de labores y unicidad por nombre
-- Fecha: 2026-08-09
-- Origen: Ejecuciones/ejecusiones.md, Anexo 2
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- `roles_organizacionales` era un catálogo en el que solo se podía crear y desactivar.
-- Pasa a ser una administración completa: alta, baja y modificación, y cada rol documenta
-- para qué existe (un objetivo y una descripción de labores). El vínculo con la persona
-- ya existe (`personal_organizacional.id_rol`) y no cambia.
--
-- ─── Decisiones ───────────────────────────────────────────────────────────────
-- · `objetivo` y `descripcion_labores` son text NULL. Los roles existentes no los tienen
--   y obligarlos rompería la edición de cualquiera de ellos. La UI marca los roles sin
--   documentar para que se completen, en vez de bloquear.
-- · Unicidad por nombre PARCIAL y case-insensitive (`lower(btrim(nombre))` WHERE activo):
--   dos roles activos no pueden llamarse igual — hoy es posible crear dos "Asesor de
--   Ventas" y quedan indistinguibles en el selector de la persona — pero un nombre
--   liberado por una baja sí puede reutilizarse.
-- · Se reutiliza `public.set_fecha_actualizacion()`, el mismo helper que usan las tablas
--   de personal. La tabla tenía la columna `fecha_actualizacion` con DEFAULT now() pero
--   ningún trigger que la refrescara en UPDATE.
-- · La baja de un rol sigue siendo lógica (`activo = false`); el front impide dar de baja
--   un rol vinculado a personas activas. No se agrega FK ON DELETE porque el rol nunca se
--   borra físicamente.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS, DROP CONSTRAINT
-- IF EXISTS antes del ADD. Sin BEGIN/COMMIT (el CI envuelve cada archivo).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Documentación del rol
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.roles_organizacionales
  ADD COLUMN IF NOT EXISTS objetivo            text,
  ADD COLUMN IF NOT EXISTS descripcion_labores text;

COMMENT ON COLUMN public.roles_organizacionales.objetivo IS
  'Para que existe el rol: el resultado que debe producir en la organizacion.';
COMMENT ON COLUMN public.roles_organizacionales.descripcion_labores IS
  'Actividades concretas y responsabilidades del rol.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Guard self-verifying antes de la unicidad
--    Si algún entorno ya tuviera dos roles ACTIVOS con el mismo nombre, el CREATE UNIQUE
--    INDEX fallaría con un error críptico de duplicados. Se aborta antes, diciendo cuáles.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $guard$
DECLARE
  v_dups text;
BEGIN
  SELECT string_agg(format('%s (x%s)', k, n), ', ' ORDER BY k)
  INTO v_dups
  FROM (
    SELECT lower(btrim(nombre)) AS k, count(*) AS n
    FROM public.roles_organizacionales
    WHERE activo
    GROUP BY 1
    HAVING count(*) > 1
  ) d;

  IF v_dups IS NOT NULL THEN
    RAISE EXCEPTION
      'No se puede crear roles_organizacionales_nombre_uq: hay nombres duplicados entre roles activos -> %. Resolver (renombrar o dar de baja) antes de reintentar el deploy.',
      v_dups;
  END IF;
END
$guard$;

-- Dos roles ACTIVOS no pueden llamarse igual (sin distinguir mayusculas ni espacios).
-- Parcial: un nombre liberado por una baja puede volver a usarse.
CREATE UNIQUE INDEX IF NOT EXISTS roles_organizacionales_nombre_uq
  ON public.roles_organizacionales (lower(btrim(nombre)))
  WHERE activo;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. El nombre no puede quedar vacío
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.roles_organizacionales
  DROP CONSTRAINT IF EXISTS roles_organizacionales_nombre_chk;
ALTER TABLE public.roles_organizacionales
  ADD CONSTRAINT roles_organizacionales_nombre_chk CHECK (btrim(nombre) <> '');

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. fecha_actualizacion viva
-- ═══════════════════════════════════════════════════════════════════════════════
DROP TRIGGER IF EXISTS trg_roles_organizacionales_upd ON public.roles_organizacionales;
CREATE TRIGGER trg_roles_organizacionales_upd
  BEFORE UPDATE ON public.roles_organizacionales
  FOR EACH ROW EXECUTE FUNCTION public.set_fecha_actualizacion();

COMMENT ON TABLE public.roles_organizacionales IS
  'Catalogo administrable de roles de empresa del Directorio de Personal (Estructura de '
  'Comisiones). Alta, baja logica y modificacion, con objetivo y descripcion de labores. '
  'Independiente de roles/usuarios.rol_id (auth y permisos). Sin acceso para el rol anon '
  'desde 20260809010000.';

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT column_name, data_type, is_nullable FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='roles_organizacionales'
--   ORDER BY ordinal_position;
--
--   SELECT indexname, indexdef FROM pg_indexes
--   WHERE schemaname='public' AND tablename='roles_organizacionales';
--
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid='public.roles_organizacionales'::regclass ORDER BY conname;
--
--   SELECT t.tgname, p.proname FROM pg_trigger t
--   JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_proc p ON p.oid=t.tgfoid
--   WHERE NOT t.tgisinternal AND c.relname='roles_organizacionales';
--
-- Cuántos roles quedan sin documentar (la UI los marca):
--   SELECT count(*) FILTER (WHERE objetivo IS NULL OR btrim(objetivo)='')            AS sin_objetivo,
--          count(*) FILTER (WHERE descripcion_labores IS NULL
--                             OR btrim(descripcion_labores)='')                      AS sin_labores,
--          count(*)                                                                  AS total_activos
--   FROM public.roles_organizacionales WHERE activo;
--
-- OJO — el estado de los datos difiere por entorno (verificado read-only 2026-08-09):
--   · dev/Preview: 7 roles, los 7 ACTIVOS -> sin_objetivo = sin_labores = 7.
--   · Producción: los mismos 7 roles, pero los 7 con activo = false. El indice unico
--     parcial no aplica a ninguno y el selector de rol del Directorio saldra vacio hasta
--     que se reactiven. Es un tema de datos, no de esta migracion.
