-- 20260817220000_permisos_personas_ligadas_juridico.sql
-- Propósito: dar `crear` y `actualizar` sobre el submenú de expedientes de jurídico a los
-- roles que administran expedientes, para que puedan ligar representante legal y accionistas
-- de una persona moral desde la tarjeta "Personas ligadas".
--
-- CÓMO SE ABRE ESA TARJETA
--
-- En sozu-admin, DocumentosObligatorios.tsx la monta con:
--
--   const puedeLigarPersonas = gestionarPersonasLigadas && (canCreate || canUpdate);
--
-- donde canCreate/canUpdate salen de usePagePermissions(rutaPermisos), y legal-flow/
-- ExpedienteDocumentos.tsx pasa rutaPermisos="/admin/legal-flow/escrituracion/expedientes",
-- que compara EXACTO contra submenus.vista_front_end. Ese submenú solo ofrece hoy `leer` y
-- `exportar`, así que la tarjeta no aparece para nadie salvo el Super Administrador (a quien
-- el front le da todo). Cobranza no necesita nada: su submenú
-- /admin/portal-cobranza/cuentas-cobranza ya tiene crear, actualizar y eliminar.
--
-- Socio bancario y notaría quedan fuera aunque se les diera el permiso: ambos montan el
-- componente con gestionarPersonasLigadas={false}, porque consultan el expediente, no lo
-- administran.
--
-- POR QUÉ EL GATE ES EL PERMISO DE SUBMENÚ Y NO LA RLS
--
-- La policy de escritura de personas_relacionadas es user_has_internal_role(auth.uid()), y
-- ese helper mira roles.es_rol_interno, que está en true en 37 de los 40 roles activos
-- (verificado en prod el 2026-08-17) — Agente Inmobiliario, Inmobiliaria, Embajador, Notario
-- y Banco incluidos. O sea que a nivel DB casi cualquier usuario autenticado puede escribir
-- esa tabla; el gate real lo pone el front. Por eso el permiso se otorga solo a los roles que
-- administran expedientes, y por eso esta migración NO amplía la superficie de escritura de
-- la base: solo enciende la UI para tres roles.
--
-- ROLES
--
--   7  Administrador de finanzas/legal
--   18 Admin Legal
--   12 Administrador de cobranza
--
-- El 1 (Super Administrador) no necesita fila. El 30 (Admin Soporte) se deja fuera a
-- propósito: que consulte el expediente, no que edite el accionariado.
--
-- ALCANCE DEL PERMISO
--
-- Se verificó que ningún otro componente consume los permisos de esa ruta: el único
-- consumidor de "/admin/legal-flow/escrituracion/expedientes" en sozu-admin es
-- ExpedienteDocumentos.tsx. Dar crear/actualizar ahí no enciende ninguna otra acción.
--
-- ANCLAJE
--
-- Los ids de submenú hoy coinciden entre dev y prod (248), pero se resuelve por
-- vista_front_end de todas formas, y los permisos por nombre, porque los catálogos han
-- divergido antes. Los ids de rol sí se usan directo, con un guard que exige que el nombre
-- del rol sea el esperado en el entorno donde corre.
--
-- Estado antes del cambio (idéntico en dev y prod, 2026-08-17): el submenú ofrece leer y
-- exportar; roles 1, 7, 12 y 18 tienen leer + exportar, el 30 solo leer.
--
-- Rollback al final del archivo.

BEGIN;

-- 1. Precondiciones. Si algo no cuadra, aborta el deploy en lugar de insertar cero filas y
--    dejar el CI en verde con el permiso sin otorgar.
DO $$
DECLARE
  v_submenu   int;
  v_permisos  int;
  v_roles_mal text;
BEGIN
  SELECT id INTO v_submenu
  FROM public.submenus
  WHERE vista_front_end = '/admin/legal-flow/escrituracion/expedientes'
    AND activo = true;

  IF v_submenu IS NULL THEN
    RAISE EXCEPTION
      'No hay submenú activo con vista_front_end = /admin/legal-flow/escrituracion/expedientes.';
  END IF;

  SELECT count(*) INTO v_permisos
  FROM public.permisos
  WHERE nombre IN ('crear', 'actualizar') AND activo = true;

  IF v_permisos <> 2 THEN
    RAISE EXCEPTION
      'Se esperaban los permisos activos crear y actualizar; se encontraron %.', v_permisos;
  END IF;

  -- Los ids de rol deben significar lo mismo en este entorno.
  SELECT string_agg(esperado.rol_id || ' debería ser ' || esperado.nombre ||
                    ' y es ' || coalesce(r.nombre, '(inexistente)'), '; ')
    INTO v_roles_mal
  FROM (VALUES (7,  'Administrador de finanzas/legal'),
               (18, 'Admin Legal'),
               (12, 'Administrador de cobranza')) AS esperado(rol_id, nombre)
  LEFT JOIN public.roles r ON r.id = esperado.rol_id
  WHERE r.nombre IS DISTINCT FROM esperado.nombre;

  IF v_roles_mal IS NOT NULL THEN
    RAISE EXCEPTION 'Los ids de rol no coinciden con los esperados: %.', v_roles_mal;
  END IF;
END $$;

-- 2. El submenú tiene que OFRECER el permiso antes de que se pueda asignar a un rol.
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.id, true
FROM public.submenus s
CROSS JOIN public.permisos p
WHERE s.vista_front_end = '/admin/legal-flow/escrituracion/expedientes'
  AND s.activo = true
  AND p.nombre IN ('crear', 'actualizar')
ON CONFLICT (submenu_id, permiso_id)
DO UPDATE SET activo = true, fecha_actualizacion = now();

-- 3. La asignación por rol. ON CONFLICT reactiva la fila si alguien la dejó apagada, para
--    que re-aplicar la migración deje siempre el mismo estado.
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.id, r.rol_id, true
FROM public.submenus s
CROSS JOIN public.permisos p
CROSS JOIN (VALUES (7), (18), (12)) AS r(rol_id)
WHERE s.vista_front_end = '/admin/legal-flow/escrituracion/expedientes'
  AND s.activo = true
  AND p.nombre IN ('crear', 'actualizar')
ON CONFLICT (submenu_id, permiso_id, rol_id)
DO UPDATE SET activo = true, fecha_actualizacion = CURRENT_TIMESTAMP;

-- 4. Self-verifying: 2 permisos disponibles y 6 asignaciones activas (3 roles x 2 permisos).
DO $$
DECLARE
  v_disp int;
  v_asig int;
BEGIN
  SELECT count(*) INTO v_disp
  FROM public.submenus_permisos_disponibles d
  JOIN public.submenus s ON s.id = d.submenu_id
  JOIN public.permisos p ON p.id = d.permiso_id
  WHERE s.vista_front_end = '/admin/legal-flow/escrituracion/expedientes'
    AND p.nombre IN ('crear', 'actualizar')
    AND d.activo = true;

  SELECT count(*) INTO v_asig
  FROM public.submenus_permisos sp
  JOIN public.submenus s ON s.id = sp.submenu_id
  JOIN public.permisos p ON p.id = sp.permiso_id
  WHERE s.vista_front_end = '/admin/legal-flow/escrituracion/expedientes'
    AND p.nombre IN ('crear', 'actualizar')
    AND sp.rol_id IN (7, 18, 12)
    AND sp.activo = true;

  IF v_disp <> 2 OR v_asig <> 6 THEN
    RAISE EXCEPTION
      'Estado inesperado: % permiso(s) disponible(s) (esperado 2) y % asignación(es) activa(s) (esperado 6).',
      v_disp, v_asig;
  END IF;

  RAISE NOTICE
    'Expedientes jurídico: crear y actualizar habilitados para los roles 7, 18 y 12.';
END $$;

COMMIT;

-- ROLLBACK (quita solo lo que agregó esta migración; leer y exportar no se tocan):
--
--   DELETE FROM public.submenus_permisos sp
--   USING public.submenus s, public.permisos p
--   WHERE sp.submenu_id = s.id AND sp.permiso_id = p.id
--     AND s.vista_front_end = '/admin/legal-flow/escrituracion/expedientes'
--     AND p.nombre IN ('crear','actualizar')
--     AND sp.rol_id IN (7, 18, 12);
--
--   DELETE FROM public.submenus_permisos_disponibles d
--   USING public.submenus s, public.permisos p
--   WHERE d.submenu_id = s.id AND d.permiso_id = p.id
--     AND s.vista_front_end = '/admin/legal-flow/escrituracion/expedientes'
--     AND p.nombre IN ('crear','actualizar');
--
-- VALIDACIÓN:
--
--   SELECT s.vista_front_end, sp.rol_id, r.nombre AS rol, pe.nombre AS permiso, sp.activo
--   FROM public.submenus s
--   JOIN public.submenus_permisos sp ON sp.submenu_id = s.id
--   JOIN public.permisos pe ON pe.id = sp.permiso_id
--   JOIN public.roles r ON r.id = sp.rol_id
--   WHERE s.vista_front_end = '/admin/legal-flow/escrituracion/expedientes'
--   ORDER BY sp.rol_id, pe.nombre;
