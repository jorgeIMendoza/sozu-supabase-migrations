-- Rol distinto por proyecto: override en la vinculación persona↔proyecto
-- Fecha: 2026-08-10
-- Origen: Ejecuciones/ejecusiones.md, Anexo 6
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- Una persona puede asumir roles diferentes según el proyecto. Hasta ahora tenía un solo
-- rol (`personal_organizacional.id_rol`) que aplicaba en todos los desarrollos que atiende.
--
-- Estaba previsto en el diagnóstico del DDL principal (20260809000000), que dejó dicho:
-- "Si más adelante se necesita un rol distinto por proyecto, el lugar natural es agregar
-- `id_rol` a `personal_proyectos` como override — no romper este modelo." Es exactamente
-- lo que se hace, sin tocar el modelo existente.
--
-- ─── Regla de resolución, única en todo el sistema ────────────────────────────
--   rol_efectivo(persona, proyecto)
--     = personal_proyectos.id_rol        -- override para ESE proyecto
--    ?? personal_organizacional.id_rol   -- rol base
--
-- ─── Decisiones ───────────────────────────────────────────────────────────────
-- · El override es NULLABLE, no un campo obligatorio. NULL significa "en este proyecto
--   asume su rol base", así el comportamiento actual se conserva bit a bit y solo se
--   captura el rol cuando de verdad difiere.
-- · `personal_organizacional.id_rol` se conserva como rol base, no se elimina. Sigue
--   siendo el rol en SOZU Central y el que aplica en cualquier proyecto sin override.
--   Quitarlo obligaría a capturar un rol por proyecto incluso para quien tiene el mismo
--   en todos.
-- · No se agrega unicidad nueva: `personal_proyectos` ya tiene
--   `personal_proyectos_persona_proyecto_uq (id_personal, id_proyecto) WHERE activo`
--   (verificado read-only), así que una persona no puede tener dos roles distintos en el
--   mismo proyecto.
-- · Sin FK `ON DELETE`: los roles no se borran físicamente (baja lógica con `activo`),
--   igual que en `personal_organizacional.id_rol`.
--
-- Idempotente: ADD COLUMN / CREATE INDEX IF NOT EXISTS. No modifica ningún dato — el
-- override nace vacío y todas las vinculaciones siguen resolviendo a su rol base.
-- Sin BEGIN/COMMIT (el CI envuelve cada archivo).
--
-- Requiere `personal_proyectos`, creada en 20260809000000.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. El override
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.personal_proyectos
  ADD COLUMN IF NOT EXISTS id_rol bigint
    REFERENCES public.roles_organizacionales (id);

COMMENT ON COLUMN public.personal_proyectos.id_rol IS
  'Rol que la persona asume EN ESTE PROYECTO. NULL = asume su rol base '
  '(personal_organizacional.id_rol). Permite que la misma persona tenga roles '
  'distintos segun el desarrollo.';

COMMENT ON COLUMN public.personal_organizacional.id_rol IS
  'Rol BASE de la persona: aplica en SOZU Central y en cualquier proyecto que no '
  'defina su propio rol en personal_proyectos.id_rol. NULL = alta sin rol vinculado.';

CREATE INDEX IF NOT EXISTS idx_personal_proyectos_id_rol
  ON public.personal_proyectos (id_rol);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Reporte: ninguna vinculación cambia de comportamiento
-- ═══════════════════════════════════════════════════════════════════════════════
DO $reporte$
DECLARE
  v_total    bigint;
  v_override bigint;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE id_rol IS NOT NULL)
  INTO v_total, v_override
  FROM public.personal_proyectos WHERE activo;

  RAISE NOTICE
    'personal_proyectos: % vinculacion(es) activa(s), % con rol propio (el resto hereda el rol base).',
    v_total, v_override;
END
$reporte$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT column_name, data_type, is_nullable FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='personal_proyectos'
--   ORDER BY ordinal_position;
--
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid='public.personal_proyectos'::regclass ORDER BY conname;
--   -- esperado: personal_proyectos_id_rol_fkey -> roles_organizacionales(id)
--
-- Ningún dato cambia — el override nace vacío:
--   SELECT count(*) AS total,
--          count(*) FILTER (WHERE id_rol IS NULL)     AS usan_rol_base,
--          count(*) FILTER (WHERE id_rol IS NOT NULL) AS con_rol_propio
--   FROM public.personal_proyectos WHERE activo;
--   -- esperado tras el ALTER: con_rol_propio = 0
--
-- La regla de resolución en SQL (rol efectivo por persona y proyecto):
--   SELECT p.nombre AS persona, pr.nombre AS proyecto,
--          COALESCE(ro.nombre, rb.nombre) AS rol_efectivo,
--          (pp.id_rol IS NOT NULL) AS es_override,
--          pp.asignacion_pct
--   FROM public.personal_proyectos pp
--   JOIN public.personal_organizacional p ON p.id = pp.id_personal
--   JOIN public.proyectos pr ON pr.id = pp.id_proyecto
--   LEFT JOIN public.roles_organizacionales ro ON ro.id = pp.id_rol
--   LEFT JOIN public.roles_organizacionales rb ON rb.id = p.id_rol
--   WHERE pp.activo AND p.activo
--   ORDER BY p.nombre, pr.nombre;
--
-- ─── El volumen de datos DIVERGE entre entornos ───────────────────────────────
-- El anexo audita Preview con 3 personas activas y 0 vinculaciones a proyecto. En
-- produccion, verificado read-only el 2026-08-10, ya hay 10 personas activas (las 10 con
-- rol base, ninguna apuntando a un rol inactivo) y 34 vinculaciones a proyecto. La
-- migracion sigue siendo un no-op sobre los datos en ambos entornos: las 34 filas quedan
-- con id_rol IS NULL y resuelven al rol base, exactamente como hoy.
--
-- ─── Lo que el front debe ajustar y NO se puede resolver en BD ────────────────
-- · Guard de baja de roles: dar de baja un rol se bloquea si hay personas activas
--   usandolo, y ese conteo debe mirar AHORA LAS DOS columnas — el rol base y los
--   overrides por proyecto. Si solo mira el rol base, un rol usado unicamente como
--   override podria darse de baja y dejar asignaciones apuntando a un rol inactivo (la FK
--   no valida `activo`, y no debe: la baja es logica). El conteo correcto:
--
--     SELECT
--       (SELECT count(*) FROM public.personal_organizacional
--         WHERE activo AND id_rol = $1)                        AS como_rol_base,
--       (SELECT count(*) FROM public.personal_proyectos pp
--         JOIN public.personal_organizacional p ON p.id = pp.id_personal
--         WHERE pp.activo AND p.activo AND pp.id_rol = $1)     AS como_override;
--
-- · Derivacion al simulador: `roleAssignments` agrupa por rol x proyecto y pasa a agrupar
--   por ROL EFECTIVO de cada vinculacion, con lo que una persona repartida entre dos
--   proyectos con roles distintos aporta su costo a dos roles distintos.
-- · Comisiones: la pantalla es por proyecto, asi que el rol del comisionista se resuelve
--   PARA EL PROYECTO SELECCIONADO. La misma persona puede comisionar como Asesor de
--   Ventas en Daiku y como Admin Comercial en Monocolo, y cada regla guarda el id_rol que
--   corresponde.
--
-- Archivos (repo sozu-admin): useDirectorioPuestos.ts (tipo AsignacionProyecto, guard de
-- baja de roles), useEstructuraRealSimulador.ts (rol efectivo en derivarEstructura y en
-- comisionistasDisponibles, que pasa a recibir el proyecto), DirectorioPuestosTab.tsx y
-- CommissionsTab.tsx. Mientras el DDL no se ejecute, la consulta del override falla y el
-- front cae al rol base: la pantalla sigue funcionando como hoy.
