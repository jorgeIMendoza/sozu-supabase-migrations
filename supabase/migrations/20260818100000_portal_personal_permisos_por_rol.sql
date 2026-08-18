-- Portal del Personal — permisos por rol y generar_oferta en Inventario
-- Fecha: 2026-08-18
-- Origen: Ejecuciones/ejecusiones.md
--
-- ─── Qué hace ─────────────────────────────────────────────────────────────────
-- Abre el Portal del Personal a los roles que deben usarlo. Los nueve submenus existen y
-- estan activos desde 20260817190000, pero `submenus_permisos` solo tiene filas para el
-- rol 1: cualquier otro rol entra al portal y ve el sidebar vacio.
--
-- Ademas, el submenu Inventario reutiliza las vistas del Portal Agente, que condicionan el
-- boton "Configurar Oferta" a los permisos generar_oferta (8) y generar_oferta_digital (9).
-- Esos dos no estan en el catalogo de disponibles de ese submenu, asi que hoy no se pueden
-- otorgar desde Roles y Permisos ni manualmente.
--
-- ═══════════════════════════════════════════════════════════════════════════════
-- EL CAMBIO IMPORTANTE SOBRE EL DML DEL DOCUMENTO: NADA SE RESUELVE POR submenu_id
-- ═══════════════════════════════════════════════════════════════════════════════
-- El documento usa los ids 386..394, que son los de PRODUCCION. Esos submenus los creo
-- 20260817190000 con GENERATED ALWAYS AS IDENTITY, asi que cada entorno les asigno ids
-- distintos segun el estado de su secuencia.
--
-- No es una hipotesis. Hay prueba directa de esta misma serie de migraciones:
--   · En produccion, segun la auditoria del documento, el submenu id 393 es
--     "Reglas del programa" del Portal del Personal.
--   · En dev, el deploy de 20260817223000 reporto por NOTICE que el submenu recien creado
--     "Historial de Comisiones" recibio el id 393.
-- El mismo id apunta a dos submenus distintos en cada entorno.
--
-- Un DML por id fijo no fallaria: submenus_permisos.submenu_id y .rol_id no tienen FK
-- declarada. Simplemente concederia permisos sobre los submenus equivocados, en silencio y
-- posiblemente de otros portales. Eso no es cosmetico: es dar acceso a roles sobre
-- pantallas que no deben ver.
--
-- Aqui todo se resuelve por vista_front_end, que es estable entre entornos porque la fija
-- el codigo del front y no una secuencia de la base.
--
-- ─── Qué permiso hace qué en este portal ──────────────────────────────────────
--   leer (1)        hace visible el submenu. Es el minimo indispensable.
--   crear (2)       "Nuevo contacto" en Mis referidos, "Crear negocio" en Negocios.
--   actualizar (3)  edicion de la ficha de contacto y del negocio.
--   eliminar (4)    borrar contactos y negocios. SE OTORGA APARTE (bloque 5, comentado):
--                   es destructivo y no todo el personal deberia tenerlo.
--   exportar (6)    descargas del listado.
--   generar_oferta (8) / generar_oferta_digital (9)
--                   solo Inventario: habilitan "Configurar Oferta" desde el detalle de una
--                   unidad.
--
-- Catalogo confirmado contra el repo: 1=leer, 2=crear, 3=actualizar, 4=eliminar,
-- 5=aprobar, 6=exportar, 8=generar_oferta, 9=generar_oferta_digital.
--
-- ─── Lo que esto NO hace ──────────────────────────────────────────────────────
-- NO amplia el alcance de datos. Mis referidos y Negocios ya estan acotados en codigo a lo
-- que la persona posee (crm_leads_atribucion.id_propietario). Dar leer a un rol no le abre
-- el pool completo del CRM.
--
-- ─── LA LISTA DE ROLES ES UNA DECISION DE NEGOCIO PENDIENTE ───────────────────
-- Se conserva la propuesta del documento: 2 Administrador de Proyecto, 30 Admin Soporte,
-- 42 Director Comercial Desarrollo; y el bloque 4 (generar oferta) se limita a 2 y 42 como
-- pedia. REVISAR antes de mergear: cada rol de esa lista pasa a ver los nueve submenus del
-- portal. El guard de la seccion 0 aborta si alguno no existe, para que un rol_id
-- equivocado no deje filas basura que ninguna FK frenaria.
--
-- Idempotente: NOT EXISTS en cada INSERT, re-ejecutable sin duplicar. No elimina nada.
-- Sin BEGIN/COMMIT: el CI envuelve cada archivo, y un COMMIT explicito dejaria fuera el
-- registro en schema_migrations.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 0. Guard previo: los 9 submenús, los permisos y los roles deben existir
-- ═══════════════════════════════════════════════════════════════════════════════
DO $guard$
DECLARE
  v_n      bigint;
  v_faltan text;
BEGIN
  SELECT count(*) INTO v_n
  FROM public.submenus
  WHERE vista_front_end IN (
    '/admin/portal-personal',
    '/admin/portal-personal/inventario',
    '/admin/portal-personal/simulador',
    '/admin/portal-personal/referidos',
    '/admin/portal-personal/negocios',
    '/admin/portal-personal/ganancias',
    '/admin/portal-personal/kit',
    '/admin/portal-personal/perfil',
    '/admin/portal-personal/reglas'
  );

  IF v_n <> 9 THEN
    RAISE EXCEPTION
      'Se esperaban los 9 submenus del Portal del Personal (resueltos por vista_front_end) y hay %. Aplicar primero 20260817190000_portal_personal_menu_submenus_permisos.sql.',
      v_n;
  END IF;

  SELECT string_agg(p.permiso_id::text, ', ' ORDER BY p.permiso_id)
  INTO v_faltan
  FROM (VALUES (1),(2),(3),(6),(8),(9)) AS p(permiso_id)
  WHERE NOT EXISTS (SELECT 1 FROM public.permisos x WHERE x.id = p.permiso_id);

  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION
      'Faltan estos permiso_id en public.permisos: %. Se esperaba 1=leer, 2=crear, 3=actualizar, 6=exportar, 8=generar_oferta, 9=generar_oferta_digital.',
      v_faltan;
  END IF;

  -- submenus_permisos.rol_id no tiene FK: un rol inexistente dejaria filas basura.
  SELECT string_agg(r.rol_id::text, ', ' ORDER BY r.rol_id)
  INTO v_faltan
  FROM (VALUES (2),(30),(42)) AS r(rol_id)
  WHERE NOT EXISTS (SELECT 1 FROM public.roles x WHERE x.id = r.rol_id);

  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION
      'Faltan estos rol_id en public.roles: %. Confirmar la lista con: SELECT id, nombre FROM public.roles WHERE activo;',
      v_faltan;
  END IF;
END
$guard$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Faltantes en el CATÁLOGO de disponibles del submenú Inventario
--    Sin esto, generar_oferta no se puede ni ofrecer en Roles y Permisos.
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (8),(9)) AS p(permiso_id)
WHERE s.vista_front_end = '/admin/portal-personal/inventario'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. LECTURA de todo el portal para los roles elegidos
--    ← Aquí se edita la lista de roles.
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, 1, r.rol_id, true
FROM public.submenus s
CROSS JOIN (VALUES
  (2),   -- Administrador de Proyecto
  (30),  -- Admin Soporte
  (42)   -- Director Comercial Desarrollo
) AS r(rol_id)
WHERE s.vista_front_end IN (
    '/admin/portal-personal',
    '/admin/portal-personal/inventario',
    '/admin/portal-personal/simulador',
    '/admin/portal-personal/referidos',
    '/admin/portal-personal/negocios',
    '/admin/portal-personal/ganancias',
    '/admin/portal-personal/kit',
    '/admin/portal-personal/perfil',
    '/admin/portal-personal/reglas'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = 1 AND sp.rol_id = r.rol_id
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. ALTA Y EDICIÓN en las vistas que capturan (Mis referidos y Negocios)
--    NO incluye eliminar (4): va aparte, en el bloque 5.
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, r.rol_id, true
FROM public.submenus s
CROSS JOIN (VALUES (2),(3),(6)) AS p(permiso_id)   -- crear, actualizar, exportar
CROSS JOIN (VALUES (2),(30),(42)) AS r(rol_id)
WHERE s.vista_front_end IN (
    '/admin/portal-personal/referidos',
    '/admin/portal-personal/negocios'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = r.rol_id
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. GENERAR OFERTA desde el Inventario del portal
--    Solo los roles que de verdad deban cotizar.
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, r.rol_id, true
FROM public.submenus s
CROSS JOIN (VALUES (8),(9)) AS p(permiso_id)
CROSS JOIN (VALUES (2),(42)) AS r(rol_id)
WHERE s.vista_front_end = '/admin/portal-personal/inventario'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = r.rol_id
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. ELIMINAR (destructivo). Bloque separado y COMENTADO a propósito.
--    Descomentar solo cuando se decida otorgarlo.
-- ═══════════════════════════════════════════════════════════════════════════════
-- INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
-- SELECT s.id, 4, r.rol_id, true
-- FROM public.submenus s
-- CROSS JOIN (VALUES (2)) AS r(rol_id)
-- WHERE s.vista_front_end IN (
--     '/admin/portal-personal/referidos',
--     '/admin/portal-personal/negocios'
--   )
--   AND NOT EXISTS (
--     SELECT 1 FROM public.submenus_permisos sp
--     WHERE sp.submenu_id = s.id AND sp.permiso_id = 4 AND sp.rol_id = r.rol_id
--   );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. Reporte de cierre
-- ═══════════════════════════════════════════════════════════════════════════════
DO $cierre$
DECLARE
  v_disp_inv bigint;
  v_lectura  bigint;
  v_roles    text;
BEGIN
  SELECT count(*) INTO v_disp_inv
  FROM public.submenus_permisos_disponibles d
  JOIN public.submenus s ON s.id = d.submenu_id
  WHERE s.vista_front_end = '/admin/portal-personal/inventario' AND d.activo;

  IF v_disp_inv < 7 THEN
    RAISE EXCEPTION
      'El catalogo de disponibles de Inventario deberia tener al menos 7 permisos (los 5 previos mas generar_oferta y generar_oferta_digital) y tiene %.',
      v_disp_inv;
  END IF;

  SELECT count(*) INTO v_lectura
  FROM public.submenus_permisos sp
  JOIN public.submenus s ON s.id = sp.submenu_id
  JOIN public.menus m ON m.id = s.menu_id
  WHERE m.nombre = 'Portal del Personal' AND sp.permiso_id = 1 AND sp.activo;

  SELECT string_agg(DISTINCT sp.rol_id::text, ', ' ORDER BY sp.rol_id::text)
  INTO v_roles
  FROM public.submenus_permisos sp
  JOIN public.submenus s ON s.id = sp.submenu_id
  JOIN public.menus m ON m.id = s.menu_id
  WHERE m.nombre = 'Portal del Personal' AND sp.activo;

  RAISE NOTICE
    'Portal del Personal: % permisos disponibles en Inventario, % filas de lectura, roles con acceso: %.',
    v_disp_inv, v_lectura, v_roles;
END
$cierre$;

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
-- Catalogo de disponibles de Inventario: deben aparecer 8 y 9.
--   SELECT d.permiso_id, p.nombre
--   FROM public.submenus_permisos_disponibles d
--   JOIN public.submenus s ON s.id = d.submenu_id
--   JOIN public.permisos p ON p.id = d.permiso_id
--   WHERE s.vista_front_end = '/admin/portal-personal/inventario' AND d.activo
--   ORDER BY d.permiso_id;
--
-- Matriz resultante: un renglon por submenu x rol.
--   SELECT s.nombre AS submenu, r.nombre AS rol,
--          string_agg(p.nombre, ', ' ORDER BY p.id) AS permisos
--   FROM public.submenus s
--   JOIN public.menus m ON m.id = s.menu_id
--   JOIN public.submenus_permisos sp ON sp.submenu_id = s.id AND sp.activo
--   JOIN public.permisos p ON p.id = sp.permiso_id
--   JOIN public.roles r ON r.id = sp.rol_id
--   WHERE m.nombre = 'Portal del Personal'
--   GROUP BY s.nombre, s.orden, r.nombre
--   ORDER BY s.orden, r.nombre;
--
-- Sin duplicados (los INSERT son idempotentes; queda como aserto):
--   SELECT sp.submenu_id, sp.permiso_id, sp.rol_id, count(*) AS veces
--   FROM public.submenus_permisos sp
--   JOIN public.submenus s ON s.id = sp.submenu_id
--   JOIN public.menus m ON m.id = s.menu_id
--   WHERE m.nombre = 'Portal del Personal'
--   GROUP BY 1,2,3 HAVING count(*) > 1;
--   -- esperado: 0 filas
--
-- ─── Rutas hijas que NO requieren submenú propio ──────────────────────────────
-- Heredan del padre por prefijo (isPathDisabled en useAllowedMenus):
--   /admin/portal-personal/inventario/unidades
--   /admin/portal-personal/inventario/proyecto/:id
--   /admin/portal-personal/referidos/:contactId
--   /admin/portal-personal/negocios/:dealId
