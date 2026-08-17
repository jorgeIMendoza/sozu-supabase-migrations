-- Portal del Personal — menú, submenús y permisos
-- Fecha: 2026-08-17
-- Origen: Ejecuciones/ejecusiones.md
--
-- Timestamp 190000 para quedar despues de 20260817000000_menu_precios_roles_permisos.sql y
-- 20260817180000_facturas_mantenimientos_homologar_prod.sql, ya presentes con fecha de hoy.
-- Los 14 digitos son la PK de supabase_migrations.schema_migrations: dos archivos del mismo
-- dia con la misma hora tumban el deploy del segundo (paso el 2026-08-12).
--
-- ─── Qué hace ─────────────────────────────────────────────────────────────────
-- Da de alta el menu `Portal del Personal` con sus 9 submenus y otorga todos los permisos
-- al rol Super Administrador (rol_id = 1), para que el portal aparezca en el sidebar y su
-- navegacion quede gobernada por el sistema de roles/permisos ya existente. El front no
-- fija ningun menu: `usePortalPersonalNav` lee menus/submenus y filtra con `useAllowedMenus`.
--
-- ─── Estado verificado contra el esquema del repo ─────────────────────────────
-- · `menus.id` y `submenus.id` son GENERATED ALWAYS AS IDENTITY -> nunca se fijan a mano.
-- · `submenus.solo_usuarioa` existe con ese nombre exacto (baseline_schema, linea 1401).
--   Parece un typo pero no lo es: asi se llama la columna.
-- · `menus_roles` tiene PK compuesta (rol_id, menu_id) y no columna id.
-- · Ni `submenus_permisos` ni `submenus_permisos_disponibles` tienen UNIQUE sobre
--   (submenu_id, permiso_id), asi que la idempotencia va con NOT EXISTS y no con
--   ON CONFLICT — no hay indice que PostgreSQL pueda inferir.
-- · Catalogo de permisos usado: leer(1), crear(2), actualizar(3), eliminar(4), exportar(6).
--   Es el patron dominante del repo (14 migraciones lo usan) y el 5 se salta a proposito.
-- · `menus.orden = 270` esta libre: los menus existentes usan 29, 30, 200, 210, 250, 260 y
--   300, asi que el portal cae entre "Portal CRM Sozu"/"Portal Tickets" (260) y "Portal
--   Estructura de Comisiones" (300).
--
-- NOTA: el MCP de Supabase estaba desconectado al preparar esta migracion, asi que el
-- esquema se verifico contra el baseline y las migraciones del repo, no contra la BD viva.
-- Para compensarlo, los bloques de guarda de las secciones 0 y 6 validan en tiempo de
-- ejecucion lo que no se pudo comprobar antes: si el catalogo de permisos o el rol no
-- estuvieran como se asume, la migracion aborta en vez de dejar el portal a medias.
--
-- Idempotente (NOT EXISTS en cada paso), re-ejecutable sin duplicar filas. No elimina nada.
-- Sin BEGIN/COMMIT: el CI envuelve cada archivo en su propia transaccion, y un COMMIT
-- explicito dejaria fuera el registro en schema_migrations.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 0. Guard previo: el catálogo de permisos y el rol deben existir
--    Sin esto, un catálogo distinto dejaría submenús visibles sin permisos o filas
--    apuntando a permisos inexistentes, y el portal quedaría a medias en silencio.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $guard$
DECLARE
  v_faltan text;
BEGIN
  SELECT string_agg(p.permiso_id::text, ', ' ORDER BY p.permiso_id)
  INTO v_faltan
  FROM (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
  WHERE NOT EXISTS (SELECT 1 FROM public.permisos x WHERE x.id = p.permiso_id);

  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION
      'Faltan estos permiso_id en public.permisos: %. Se esperaba leer(1), crear(2), actualizar(3), eliminar(4), exportar(6).',
      v_faltan;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.roles WHERE id = 1) THEN
    RAISE EXCEPTION 'No existe el rol_id = 1 (Super Administrador): no hay a quien asignar los permisos.';
  END IF;
END
$guard$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Menú padre
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO public.menus (nombre, orden, activo)
SELECT 'Portal del Personal', 270, true
WHERE NOT EXISTS (SELECT 1 FROM public.menus WHERE nombre = 'Portal del Personal');

-- Si ya existia apagado, se reactiva.
UPDATE public.menus SET activo = true
WHERE nombre = 'Portal del Personal' AND activo IS DISTINCT FROM true;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Los 9 submenús
--    El NOT EXISTS mira `vista_front_end` en TODA la tabla, no solo dentro de este menú:
--    una misma ruta no debe existir dos veces ni siquiera colgada de otro menú.
-- ═══════════════════════════════════════════════════════════════════════════════
WITH m AS (
  SELECT id FROM public.menus WHERE nombre = 'Portal del Personal'
), v(nombre, ruta, orden) AS (
  VALUES
    ('Inicio',              '/admin/portal-personal',             10),
    ('Inventario',          '/admin/portal-personal/inventario',  20),
    ('Simulador',           '/admin/portal-personal/simulador',   30),
    ('Mis referidos',       '/admin/portal-personal/referidos',   40),
    ('Negocios',            '/admin/portal-personal/negocios',    50),
    ('Mis ganancias',       '/admin/portal-personal/ganancias',   60),
    ('Kit de promoción',    '/admin/portal-personal/kit',         70),
    ('Mi perfil',           '/admin/portal-personal/perfil',      80),
    ('Reglas del programa', '/admin/portal-personal/reglas',      90)
)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT m.id, v.nombre, v.ruta, v.orden, true, false
FROM m CROSS JOIN v
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus s WHERE s.vista_front_end = v.ruta
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. Permisos DISPONIBLES por submenú
--    Es el catálogo que "Administrar Menús" puede ofrecer para cada vista.
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
JOIN public.menus mm ON mm.id = s.menu_id
CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
WHERE mm.nombre = 'Portal del Personal'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. Asignación efectiva al Super Administrador (rol_id = 1)
--    Un submenú solo es visible si existe al menos una fila aquí con permiso leer(1).
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, 1, true
FROM public.submenus s
JOIN public.menus mm ON mm.id = s.menu_id
CROSS JOIN (VALUES (1),(2),(3),(4),(6)) AS p(permiso_id)
WHERE mm.nombre = 'Portal del Personal'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = 1
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. Relación menú ↔ rol (para que el menú aparezca en el sidebar)
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO public.menus_roles (menu_id, rol_id, activo)
SELECT mm.id, 1, true
FROM public.menus mm
WHERE mm.nombre = 'Portal del Personal'
  AND NOT EXISTS (
    SELECT 1 FROM public.menus_roles mr WHERE mr.menu_id = mm.id AND mr.rol_id = 1
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. Guard de cierre: el portal quedó completo o la migración aborta
--    9 submenús × 5 permisos = 45 filas en submenus_permisos para el rol 1.
--    Aquí sí se aborta (y no solo se avisa) porque el contero no depende del entorno:
--    las 9 rutas las trae este mismo archivo.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $cierre$
DECLARE
  v_menu_id   integer;
  v_submenus  bigint;
  v_disp      bigint;
  v_permisos  bigint;
  v_sidebar   bigint;
BEGIN
  SELECT id INTO v_menu_id FROM public.menus WHERE nombre = 'Portal del Personal';

  IF v_menu_id IS NULL THEN
    RAISE EXCEPTION 'No quedo creado el menu "Portal del Personal".';
  END IF;

  SELECT count(*) INTO v_submenus
  FROM public.submenus WHERE menu_id = v_menu_id AND activo;

  SELECT count(*) INTO v_disp
  FROM public.submenus_permisos_disponibles d
  JOIN public.submenus s ON s.id = d.submenu_id
  WHERE s.menu_id = v_menu_id;

  SELECT count(*) INTO v_permisos
  FROM public.submenus_permisos sp
  JOIN public.submenus s ON s.id = sp.submenu_id
  WHERE s.menu_id = v_menu_id AND sp.rol_id = 1;

  SELECT count(*) INTO v_sidebar
  FROM public.menus_roles WHERE menu_id = v_menu_id AND rol_id = 1;

  IF v_submenus <> 9 THEN
    RAISE EXCEPTION
      'Se esperaban 9 submenus activos bajo "Portal del Personal" y hay %. Probable causa: alguna de las 9 rutas /admin/portal-personal/* ya existia colgada de OTRO menu, y el NOT EXISTS por vista_front_end la salto. Revisar antes de reintentar.',
      v_submenus;
  END IF;

  IF v_permisos <> 45 THEN
    RAISE EXCEPTION
      'Se esperaban 45 filas en submenus_permisos para rol_id = 1 (9 submenus x 5 permisos) y hay %.',
      v_permisos;
  END IF;

  IF v_sidebar <> 1 THEN
    RAISE EXCEPTION 'El menu no quedo ligado al rol 1 en menus_roles: el sidebar no lo mostraria.';
  END IF;

  RAISE NOTICE
    'Portal del Personal (menu id %): % submenus, % permisos disponibles, % permisos asignados al rol 1, ligado al sidebar.',
    v_menu_id, v_submenus, v_disp, v_permisos;
END
$cierre$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT mm.nombre AS menu, s.nombre AS submenu, s.vista_front_end, s.orden, s.activo
--   FROM public.submenus s
--   JOIN public.menus mm ON mm.id = s.menu_id
--   WHERE mm.nombre = 'Portal del Personal'
--   ORDER BY s.orden;
--   -- esperado: 9 filas, todas activas
--
--   SELECT s.nombre, p.nombre AS permiso, sp.rol_id
--   FROM public.submenus_permisos sp
--   JOIN public.submenus s ON s.id = sp.submenu_id
--   JOIN public.menus mm ON mm.id = s.menu_id
--   JOIN public.permisos p ON p.id = sp.permiso_id
--   WHERE mm.nombre = 'Portal del Personal'
--   ORDER BY s.orden, p.id;
--   -- esperado: 45 filas
--
-- Candidatos del selector "Ver como" (no requiere DDL, solo se comprueba):
--   SELECT p.nombre, p.email_usuario, u.rol_id, r.nombre AS rol_sistema
--   FROM public.personal_organizacional p
--   JOIN public.usuarios u ON lower(u.email) = lower(p.email_usuario)
--   LEFT JOIN public.roles r ON r.id = u.rol_id
--   WHERE p.activo AND p.email_usuario IS NOT NULL
--   ORDER BY p.nombre;
--   -- esperado: ~13 personas
--
-- ─── Un efecto colateral del diseño de rutas, para tenerlo presente ───────────
-- El submenu "Inicio" usa `/admin/portal-personal`, que es PREFIJO de las otras ocho
-- rutas. `useAllowedMenus` resuelve el apagado por prefijo con frontera "/" (ver
-- 20260817000000_menu_precios_roles_permisos.sql), asi que apagar o quitarle el permiso a
-- "Inicio" apaga TODO el portal, no solo su pantalla de bienvenida. No se cambia la ruta
-- porque `/admin/portal-personal` ya existe como <Route> en src/App.tsx; queda anotado
-- para que nadie lo descubra apagando "Inicio" desde Administrar Menus.
--
-- ─── Para habilitar otro rol ──────────────────────────────────────────────────
-- Repetir los bloques 4 y 5 cambiando el 1 por el rol_id y ajustando los permiso_id.
-- Confirmar siempre el id con: SELECT id, nombre FROM public.roles WHERE activo;
