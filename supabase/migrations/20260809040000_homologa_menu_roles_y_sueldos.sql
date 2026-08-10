-- Homologación de "Puestos y Sueldos" en "Roles y Sueldos"
-- Fecha: 2026-08-09
-- Origen: Ejecuciones/ejecusiones.md, Anexo 3
--
-- ─── Qué cambia ───────────────────────────────────────────────────────────────
-- Había dos submenús del menú 35 (Portal Operación Comercial e Incentivos) capturando lo
-- mismo con fuentes distintas:
--
--   Directorio de Personal  /portal-estructura-comisiones/directorio  -> BD real
--   Puestos y Sueldos       /portal-estructura-comisiones/structure   -> localStorage
--
-- Sobrevive el Directorio, renombrado "Roles y Sueldos"; el duplicado se apaga por baja
-- lógica (no se borra: conserva sus permisos por si hay que revertir). La ruta /structure
-- sigue existiendo en el front como redirect a /directorio — eso va en el repo sozu-admin.
--
-- ─── Por qué se direcciona por RUTA y no por id ───────────────────────────────
-- El anexo indica `submenus.id = 368` (Directorio) y `id = 276` (Puestos y Sueldos). Esos
-- son los ids de Preview. En producción las secuencias divergieron y esos ids son OTRAS
-- filas — verificado read-only el 2026-08-09:
--
--   id  | Preview (segun el anexo)  | Produccion (real)
--   ----+---------------------------+-----------------------------------------------
--   276 | Puestos y Sueldos         | Canales de Venta   (/channels, menu 35, activo)
--   368 | Directorio de Personal    | Analisis de Cobranza (/portal-socio-bancario/...,
--       |                           | menu 37, inactivo)
--
--   Los ids correctos en produccion son 279 (/structure) y 363 (/directorio).
--
-- Un UPDATE por id habría sido un no-op silencioso en producción (los guards por
-- vista_front_end del anexo lo habrían salvado de dañar la fila equivocada, pero el menú
-- habría quedado duplicado en prod sin que nadie se enterara). `vista_front_end` sí es
-- estable entre entornos, así que es la llave que se usa aquí.
--
-- Idempotente: cada UPDATE lleva en el WHERE el estado que quiere cambiar, así que
-- reaplicar no hace nada. En dev/Preview el DML ya se ejecutó a mano el 2026-08-09 y esta
-- migración simplemente lo reconcilia: ambos UPDATE afectarán 0 filas ahí.
-- Sin BEGIN/COMMIT (el CI envuelve cada archivo).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Guard self-verifying: no apagar nada si el superviviente no está donde debe
-- ═══════════════════════════════════════════════════════════════════════════════
DO $guard$
DECLARE
  v_dir_n bigint;
  v_str_n bigint;
BEGIN
  SELECT count(*) INTO v_dir_n FROM public.submenus
  WHERE vista_front_end = '/admin/portal-estructura-comisiones/directorio';

  SELECT count(*) INTO v_str_n FROM public.submenus
  WHERE vista_front_end = '/admin/portal-estructura-comisiones/structure';

  -- Si el Directorio no existe o está duplicado, apagar /structure dejaría el portal sin
  -- ninguna pantalla de estructura. Se aborta antes de tocar nada.
  IF v_dir_n <> 1 THEN
    RAISE EXCEPTION
      'Se esperaba exactamente 1 submenu con vista_front_end = /admin/portal-estructura-comisiones/directorio y hay %. Se aborta sin apagar Puestos y Sueldos.',
      v_dir_n;
  END IF;

  IF v_str_n > 1 THEN
    RAISE EXCEPTION
      'Hay % submenus con vista_front_end = /admin/portal-estructura-comisiones/structure. Resolver el duplicado antes de reintentar.',
      v_str_n;
  END IF;

  IF v_str_n = 0 THEN
    RAISE NOTICE 'No existe el submenu /structure en este entorno: solo se aplica el renombre.';
  END IF;
END
$guard$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. El menú superviviente cambia de nombre
-- ═══════════════════════════════════════════════════════════════════════════════
UPDATE public.submenus
SET nombre = 'Roles y Sueldos'
WHERE vista_front_end = '/admin/portal-estructura-comisiones/directorio'
  AND nombre IS DISTINCT FROM 'Roles y Sueldos';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. El duplicado se apaga (baja lógica: conserva sus permisos por si hay que revertir)
-- ═══════════════════════════════════════════════════════════════════════════════
UPDATE public.submenus
SET activo = false
WHERE vista_front_end = '/admin/portal-estructura-comisiones/structure'
  AND activo;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. Aviso: roles que se quedan sin pantalla de estructura
--    NO se copian permisos automaticamente. Las dos pantallas no son equivalentes en
--    lo que exponen: /structure mostraba agregados del simulador, mientras que
--    /directorio (ahora "Roles y Sueldos") muestra el sueldo y el costo de CADA persona.
--    Conceder ese acceso es una decision de autorizacion, no un efecto colateral de
--    renombrar un menu. Se reporta y se deja la decision al administrador.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $aviso$
DECLARE
  v_roles text;
BEGIN
  SELECT string_agg(format('%s (rol_id %s)', COALESCE(r.nombre, '?'), sp.rol_id), ', '
                    ORDER BY sp.rol_id)
  INTO v_roles
  FROM (
    SELECT DISTINCT sp.rol_id
    FROM public.submenus_permisos sp
    JOIN public.submenus s ON s.id = sp.submenu_id
    WHERE s.vista_front_end = '/admin/portal-estructura-comisiones/structure'
      AND sp.activo
      AND NOT EXISTS (
        SELECT 1
        FROM public.submenus_permisos sp2
        JOIN public.submenus s2 ON s2.id = sp2.submenu_id
        WHERE s2.vista_front_end = '/admin/portal-estructura-comisiones/directorio'
          AND sp2.activo
          AND sp2.rol_id = sp.rol_id
      )
  ) sp
  LEFT JOIN public.roles r ON r.id = sp.rol_id;

  IF v_roles IS NOT NULL THEN
    RAISE WARNING
      'Estos roles tenian acceso a Puestos y Sueldos y NO lo tienen en Roles y Sueldos, por lo que se quedan sin pantalla de estructura: %. Otorgar el permiso desde la administracion de submenus si corresponde.',
      v_roles;
  ELSE
    RAISE NOTICE 'Ningun rol pierde acceso: todos los que tenian /structure tienen /directorio.';
  END IF;
END
$aviso$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT id, nombre, vista_front_end, orden, activo FROM public.submenus
--   WHERE vista_front_end IN ('/admin/portal-estructura-comisiones/structure',
--                             '/admin/portal-estructura-comisiones/directorio');
--   -- esperado: /directorio -> 'Roles y Sueldos', activo = true
--   --           /structure  -> 'Puestos y Sueldos', activo = false
--
-- El sidebar del portal ya no muestra el duplicado:
--   SELECT s.orden, s.nombre, s.vista_front_end
--   FROM public.submenus s JOIN public.menus m ON m.id = s.menu_id
--   WHERE s.menu_id = 35 AND s.activo AND m.activo ORDER BY s.orden;
--
-- Los permisos del submenu superviviente siguen intactos:
--   SELECT sp.rol_id, count(*) FILTER (WHERE sp.activo) AS permisos
--   FROM public.submenus_permisos sp JOIN public.submenus s ON s.id = sp.submenu_id
--   WHERE s.vista_front_end = '/admin/portal-estructura-comisiones/directorio'
--   GROUP BY 1 ORDER BY 1;
--
-- ─── Estado por entorno (verificado read-only el 2026-08-09) ──────────────────
-- · dev/Preview: el DML ya se aplicó a mano. Ambos UPDATE afectan 0 filas.
-- · Producción: /directorio = id 363 (orden 225) con permisos para rol 1 (Super
--   Administrador) y rol 2 (Administrador de Proyecto); /structure = id 279 (orden 220)
--   con permisos para rol 1, rol 2 y rol 30 (Admin Soporte).
--   -> Al apagar /structure, el rol 30 "Admin Soporte" se queda SIN pantalla de
--      estructura en producción. La sección 4 lo reporta con RAISE WARNING y NO le
--      concede el permiso: "Roles y Sueldos" expone el sueldo y el costo de cada persona,
--      que es más de lo que ese rol veía. Decidir aparte si debe tenerlo.
--
-- El orden no se toca: el superviviente conserva 225, igual que en Preview, para que dev
-- y prod queden idénticos.
