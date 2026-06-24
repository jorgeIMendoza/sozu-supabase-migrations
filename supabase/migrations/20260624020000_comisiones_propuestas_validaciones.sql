-- Estructura de Comisiones: propuestas + validaciones por proyecto + submenu.
-- Fecha: 2026-06-24
--
-- Comparte el Motor de Comisiones entre el Portal Estructura de Comisiones (propone) y
-- el Portal Alta Dirección (valida por proyecto+escenario), con historial.
--   comisiones_propuestas: propuesta vigente por (proyecto, escenario) + snapshot del motor.
--   comisiones_validaciones: historial append-only de validaciones/rechazos.
-- + submenu "Estructura de Comisiones" en Portal Alta Dirección (permisos leer+aprobar
--   a Super Admin).
--
-- Idempotente: CREATE TABLE/INDEX IF NOT EXISTS; submenu/permisos con WHERE NOT EXISTS.
-- Verificado en dev: tablas/submenu no existen; menu "Portal Alta Dirección" (id 21) y
-- permisos 1,5 existen.

-- ── 1. Tablas ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.comisiones_propuestas (
  id                   SERIAL PRIMARY KEY,
  id_proyecto          INTEGER NOT NULL REFERENCES public.proyectos(id),
  escenario_id         TEXT NOT NULL,
  escenario_nombre     TEXT,
  modo                 TEXT,
  snapshot             JSONB NOT NULL,
  estado               TEXT NOT NULL DEFAULT 'propuesta'
                         CHECK (estado IN ('propuesta','validada','rechazada')),
  propuesta_por        TEXT,
  fecha_propuesta      TIMESTAMPTZ NOT NULL DEFAULT now(),
  fecha_actualizacion  TIMESTAMPTZ NOT NULL DEFAULT now(),
  activo               BOOLEAN NOT NULL DEFAULT true,
  UNIQUE (id_proyecto, escenario_id)
);

CREATE TABLE IF NOT EXISTS public.comisiones_validaciones (
  id                   SERIAL PRIMARY KEY,
  id_proyecto          INTEGER NOT NULL REFERENCES public.proyectos(id),
  escenario_id         TEXT NOT NULL,
  escenario_nombre     TEXT,
  modo                 TEXT,
  snapshot             JSONB,
  estado               TEXT NOT NULL CHECK (estado IN ('validada','rechazada')),
  notas                TEXT,
  validado_por         TEXT,
  fecha_validacion     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_comisiones_propuestas_proyecto   ON public.comisiones_propuestas(id_proyecto);
CREATE INDEX IF NOT EXISTS idx_comisiones_validaciones_proyecto ON public.comisiones_validaciones(id_proyecto, escenario_id);

-- ── 2. Submenu "Estructura de Comisiones" (Portal Alta Dirección) + permisos ──
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo)
SELECT (SELECT id FROM public.menus WHERE nombre = 'Portal Alta Dirección' AND activo = true LIMIT 1),
       'Estructura de Comisiones', '/admin/portal-alta-direccion/estructura-comisiones', 150, true
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus WHERE vista_front_end = '/admin/portal-alta-direccion/estructura-comisiones'
);

-- Permisos disponibles: leer(1) + aprobar(5)
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(5)) AS p(permiso_id)
WHERE s.vista_front_end = '/admin/portal-alta-direccion/estructura-comisiones'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- Asignación a Super Admin (rol 1)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, 1, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(5)) AS p(permiso_id)
WHERE s.vista_front_end = '/admin/portal-alta-direccion/estructura-comisiones'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = 1
  );
