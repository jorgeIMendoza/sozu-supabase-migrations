-- Submenú "Historial de Comisiones" (Portal Operación Comercial e Incentivos)
-- Fecha: 2026-08-17
-- Origen: Ejecuciones/ejecusiones.md
--
-- Timestamp 200000 para quedar despues de 20260817000000, 20260817180000 y 20260817190000,
-- ya presentes con la fecha de hoy. Los 14 digitos son la PK de
-- supabase_migrations.schema_migrations: dos archivos con el mismo prefijo tumban el deploy
-- del segundo (paso el 2026-08-12).
--
-- Renombrado a 230000 el 2026-08-17: 200000 ya lo tenia
-- 20260817200000_fk_cobranza_sin_cascade.sql, que venia en dev y main desde antes y ya esta
-- aplicado en dev y prod. Este archivo era el segundo con ese prefijo y tumbo el deploy
-- exactamente como advierte el parrafo de arriba:
--   ERROR: duplicate key value violates unique constraint "schema_migrations_pkey"
--   Key (version)=(20260817200000) already exists.
-- El DDL hizo rollback completo (el submenu no llego a crearse en dev), asi que aplicar este
-- archivo con la version nueva lo crea limpio. Solo cambio el nombre del archivo; el SQL es
-- identico.
--
-- ─── Qué hace ─────────────────────────────────────────────────────────────────
-- Registra el submenu en `submenus` + `submenus_permisos` para que exista dentro del
-- control de acceso. Sin esas filas el submenu NO EXISTE para el sistema de permisos y no
-- aparece para ningun rol, aunque la ruta ya este en App.tsx.
--
-- La vista es de SOLO LECTURA: muestra las comisiones ya devengadas —externas e internas—
-- con su estatus, montos, porcentajes, beneficiarios y el analisis de pago por proyecto.
--
-- ─── Tres cambios sobre el DML del documento ──────────────────────────────────
--
-- 1) SE HACE IDEMPOTENTE. El documento inserta con `VALUES (...)` a secas, sin guarda. Como
--    migracion de CI eso no sirve: un reintento del deploy crearia un SEGUNDO submenu con
--    la misma ruta, que es exactamente lo que su propio UAT (caso 2) dice que no debe
--    pasar. Cada paso lleva ahora `NOT EXISTS`.
--
-- 2) SE ABANDONA EL CTE `RETURNING` a favor de resolver por `vista_front_end`. El CTE
--    encadenado del documento es correcto para una ejecucion manual —y su razon es buena:
--    `submenus.id` es GENERATED ALWAYS AS IDENTITY, asi que fijar el id da 428C9— pero
--    rompe la idempotencia: si el submenu YA existe, el INSERT no inserta, el CTE devuelve
--    cero filas y los permisos nunca se crean. El submenu quedaria dado de alta y a la vez
--    invisible, que es el peor de los dos mundos. Resolviendo por ruta, los tres pasos son
--    independientes y reaplicables. El id sigue sin fijarse nunca.
--
-- 3) EL MENU NO SE FIJA POR ID. El documento usa `menu_id = 35`. Ese es el id de
--    produccion, y esta migracion corre tambien en dev. Ya paso dos veces en esta serie:
--    los `submenus` 276/368 del Anexo 3 y los ids 11/12/13 de las vacantes resultaron ser
--    filas distintas en cada entorno. Aqui el menu se resuelve por la ruta de su submenu
--    vecino, `/admin/portal-estructura-comisiones/commissions`, que es estable entre
--    entornos: no depende de ids ni del nombre del menu. Eso ademas evita confundirlo con
--    "Operación Comercial e Incentivos" (orden 200), un menu de nombre parecido que existe
--    en el repo aparte del 35, "Portal Operación Comercial e Incentivos".
--
-- ─── Decisiones que se conservan del documento ────────────────────────────────
-- · Roles 1 (Super Administrador) y 30 (Admin Soporte), copiando la asignacion de sus
--   vecinos "Comisiones" y "Escenarios". La vista expone montos de comision de personas
--   identificables —quien cobro cuanto—, asi que ampliar el alcance es una decision de
--   negocio y se deja explicita en vez de abrirla por defecto.
-- · `orden = 235`: justo despues de "Comisiones" (230), porque el historial es la
--   contraparte de lo que ese menu configura y leerlos seguidos es el flujo natural. No se
--   usa 240 por si mas adelante se inserta algo intermedio.
-- · Permisos disponibles SOLO leer(1) y exportar(6). Los vecinos declaran 1,2,3,4,6, pero
--   esta vista no crea, no actualiza y no elimina: declarar esos permisos ofreceria
--   acciones que no existen y que alguien podria asignar creyendo que hacen algo.
--
-- ─── Estado verificado ────────────────────────────────────────────────────────
-- Contra produccion (con MCP, antes en esta misma sesion):
--   · menus.id = 35 es "Portal Operación Comercial e Incentivos", activo.
--   · submenu 280 = "Comisiones", /commissions, orden 230, activo.
--   · submenu 282 = "Escenarios",  /scenarios,   orden 310, activo.
--   · rol 30 = "Admin Soporte", activo.
-- Contra el repo (el MCP estaba caido al preparar este archivo):
--   · `submenus.id` es GENERATED ALWAYS AS IDENTITY (baseline linea 1393).
--   · La ruta historial-comisiones no aparece en ninguna migracion: es alta nueva.
--   · Ni `submenus_permisos` ni `submenus_permisos_disponibles` tienen UNIQUE sobre
--     (submenu_id, permiso_id), asi que la idempotencia va con NOT EXISTS y no con
--     ON CONFLICT: no hay indice que PostgreSQL pueda inferir.
-- Lo que NO se pudo reverificar hoy —que los vecinos tengan exactamente los roles 1 y 30—
-- lo cubre el guard de la seccion 0, que aborta si esos roles no existen.
--
-- ─── ⚠ Orden de despliegue ────────────────────────────────────────────────────
-- El submenu aparece en el sidebar en cuanto corre esta migracion, aunque la build del
-- front todavia no este desplegada. En ese hueco el usuario ve el submenu y al entrar no
-- carga nada. Conviene mergear esto DESPUES de desplegar el front con la ruta y la vista.
--
-- Sin BEGIN/COMMIT: el CI envuelve cada archivo, y un COMMIT explicito dejaria fuera el
-- registro en schema_migrations.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 0. Guard previo: el menú vecino, los permisos y los roles deben existir
-- ═══════════════════════════════════════════════════════════════════════════════
DO $guard$
DECLARE
  v_menu_id integer;
  v_vecinos bigint;
  v_faltan  text;
BEGIN
  SELECT count(*) INTO v_vecinos FROM public.submenus
  WHERE vista_front_end = '/admin/portal-estructura-comisiones/commissions';

  IF v_vecinos <> 1 THEN
    RAISE EXCEPTION
      'Se esperaba exactamente 1 submenu con la ruta /admin/portal-estructura-comisiones/commissions (de el se toma el menu contenedor) y hay %. Sin esa ancla no se puede colgar el historial del menu correcto.',
      v_vecinos;
  END IF;

  SELECT menu_id INTO v_menu_id FROM public.submenus
  WHERE vista_front_end = '/admin/portal-estructura-comisiones/commissions';

  IF v_menu_id <> 35 THEN
    RAISE NOTICE
      'El menu contenedor es el id % (en produccion es 35). Se usa el resuelto por ruta, que es el correcto para este entorno.',
      v_menu_id;
  END IF;

  SELECT string_agg(p.permiso_id::text, ', ' ORDER BY p.permiso_id)
  INTO v_faltan
  FROM (VALUES (1),(6)) AS p(permiso_id)
  WHERE NOT EXISTS (SELECT 1 FROM public.permisos x WHERE x.id = p.permiso_id);

  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'Faltan estos permiso_id en public.permisos: %. Se esperaba leer(1) y exportar(6).', v_faltan;
  END IF;

  SELECT string_agg(r.rol_id::text, ', ' ORDER BY r.rol_id)
  INTO v_faltan
  FROM (VALUES (1),(30)) AS r(rol_id)
  WHERE NOT EXISTS (SELECT 1 FROM public.roles x WHERE x.id = r.rol_id);

  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'Faltan estos rol_id en public.roles: %. Se esperaba 1 (Super Administrador) y 30 (Admin Soporte).', v_faltan;
  END IF;
END
$guard$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. El submenú
--    El menú se hereda del vecino "Comisiones". El id NUNCA se fija: la columna es
--    GENERATED ALWAYS AS IDENTITY y un id explícito daría SQLSTATE 428C9.
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT v.menu_id,
       'Historial de Comisiones',
       '/admin/portal-estructura-comisiones/historial-comisiones',
       235, true, false
FROM public.submenus v
WHERE v.vista_front_end = '/admin/portal-estructura-comisiones/commissions'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus s
    WHERE s.vista_front_end = '/admin/portal-estructura-comisiones/historial-comisiones'
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Permisos DISPONIBLES: solo leer y exportar
--    Es el catálogo que "Administrar Menús" puede ofrecer para esta vista.
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(6)) AS p(permiso_id)
WHERE s.vista_front_end = '/admin/portal-estructura-comisiones/historial-comisiones'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. Asignación efectiva: mismos roles que "Comisiones" y "Escenarios"
--    Un submenú solo es visible si existe al menos una fila aquí con permiso leer(1).
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, r.rol_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(6))  AS p(permiso_id)
CROSS JOIN (VALUES (1),(30)) AS r(rol_id)
WHERE s.vista_front_end = '/admin/portal-estructura-comisiones/historial-comisiones'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = r.rol_id
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. Guard de cierre: 1 submenú, 2 permisos disponibles, 4 asignaciones
--    Se aborta y no solo se avisa porque ninguno de los tres números depende del entorno:
--    los trae este mismo archivo.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $cierre$
DECLARE
  v_submenus bigint;
  v_disp     bigint;
  v_asign    bigint;
  v_id       integer;
  v_orden    integer;
BEGIN
  SELECT count(*) INTO v_submenus FROM public.submenus
  WHERE vista_front_end = '/admin/portal-estructura-comisiones/historial-comisiones';

  IF v_submenus <> 1 THEN
    RAISE EXCEPTION
      'Se esperaba exactamente 1 submenu con la ruta historial-comisiones y hay %. Con 0 no se dio de alta; con mas de 1 hay rutas duplicadas y el control de acceso se vuelve ambiguo.',
      v_submenus;
  END IF;

  SELECT s.id, s.orden INTO v_id, v_orden FROM public.submenus s
  WHERE s.vista_front_end = '/admin/portal-estructura-comisiones/historial-comisiones';

  SELECT count(*) INTO v_disp FROM public.submenus_permisos_disponibles
  WHERE submenu_id = v_id;

  SELECT count(*) INTO v_asign FROM public.submenus_permisos
  WHERE submenu_id = v_id;

  IF v_disp <> 2 THEN
    RAISE EXCEPTION 'Se esperaban 2 permisos disponibles (leer, exportar) y hay %.', v_disp;
  END IF;

  IF v_asign <> 4 THEN
    RAISE EXCEPTION 'Se esperaban 4 asignaciones (2 permisos x 2 roles) y hay %.', v_asign;
  END IF;

  RAISE NOTICE
    'Historial de Comisiones: submenu id %, orden %, % permisos disponibles, % asignaciones (roles 1 y 30).',
    v_id, v_orden, v_disp, v_asign;
END
$cierre$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT s.id, s.menu_id, m.nombre AS menu, s.nombre, s.vista_front_end, s.orden, s.activo
--   FROM public.submenus s JOIN public.menus m ON m.id = s.menu_id
--   WHERE s.vista_front_end = '/admin/portal-estructura-comisiones/historial-comisiones';
--   -- esperado: 1 fila, menu "Portal Operación Comercial e Incentivos", orden 235, activo
--
--   SELECT 'disponibles' AS tipo,
--          string_agg(d.permiso_id::text, ',' ORDER BY d.permiso_id) AS valor
--   FROM public.submenus_permisos_disponibles d
--   JOIN public.submenus s ON s.id = d.submenu_id
--   WHERE s.vista_front_end = '/admin/portal-estructura-comisiones/historial-comisiones'
--     AND d.activo
--   UNION ALL
--   SELECT 'roles asignados', string_agg(DISTINCT sp.rol_id::text, ',' ORDER BY sp.rol_id::text)
--   FROM public.submenus_permisos sp
--   JOIN public.submenus s ON s.id = sp.submenu_id
--   WHERE s.vista_front_end = '/admin/portal-estructura-comisiones/historial-comisiones'
--     AND sp.activo;
--   -- esperado: disponibles = 1,6 · roles asignados = 1,30
--
-- Queda junto a "Comisiones" en el orden del menu:
--   SELECT nombre, vista_front_end, orden FROM public.submenus
--   WHERE menu_id = (SELECT menu_id FROM public.submenus
--                    WHERE vista_front_end = '/admin/portal-estructura-comisiones/commissions')
--     AND orden BETWEEN 220 AND 320
--   ORDER BY orden;
--   -- esperado: Comisiones (230), Historial de Comisiones (235), ... Escenarios (310)
--
-- ─── Para ampliar a otro rol ───────────────────────────────────────────────────
-- Repetir el bloque 3 agregando el rol_id. Confirmar siempre el id con:
--   SELECT id, nombre FROM public.roles WHERE activo;
-- Recordar que la vista expone cuanto cobro cada persona: ampliar el alcance es una
-- decision de negocio, no un detalle de implementacion.
