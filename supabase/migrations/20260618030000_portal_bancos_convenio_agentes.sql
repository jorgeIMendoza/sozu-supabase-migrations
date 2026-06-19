-- Portal Bancos: tablas bancos_convenio y bancos_agentes + seed + submenu Bancos.
-- Fecha: 2026-06-18
--
-- Reemplaza el mock del Portal Bancos:
--   bancos_convenio: bancos del catálogo real `bancos` con convenio SOZU + marca/producto.
--   bancos_agentes:  ejecutivos de contacto por banco (sin login; alta/baja/modificar).
-- + seed de los 3 convenios actuales (BBVA, Santander, Banorte) + registro formal del
--   submenu "Bancos" (menu 32) con permisos Super Admin.
--
-- Idempotente: CREATE TABLE/INDEX IF NOT EXISTS, ON CONFLICT en el seed, WHERE NOT EXISTS
-- en menús/permisos. Verificado en dev: tablas no existían; bancos (id,nombre,activo)
-- existe; menu 32 = "Portal Bancos"; submenu Equipo (id 243) existe; BBVA/Santander/
-- Banorte coinciden (ids 1,2,3).

-- ── 1. Tablas ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.bancos_convenio (
  id                   SERIAL PRIMARY KEY,
  id_banco             INTEGER NOT NULL UNIQUE REFERENCES public.bancos(id),
  color_marca          TEXT,
  producto_nombre      TEXT,
  tasa_desde           NUMERIC(5,2),
  orden                INTEGER NOT NULL DEFAULT 100,
  activo               BOOLEAN NOT NULL DEFAULT true,
  fecha_creacion       TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fecha_actualizacion  TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS public.bancos_agentes (
  id                   SERIAL PRIMARY KEY,
  id_banco             INTEGER NOT NULL REFERENCES public.bancos(id),
  nombre               TEXT NOT NULL,
  email                TEXT,
  telefono             TEXT,
  rol                  TEXT NOT NULL DEFAULT 'agente' CHECK (rol IN ('agente','admin')),
  activo               BOOLEAN NOT NULL DEFAULT true,
  fecha_creacion       TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fecha_actualizacion  TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_bancos_agentes_banco ON public.bancos_agentes(id_banco);

-- ── 2. Seed de convenios (match por prefijo en el catálogo real `bancos`) ──
-- bancos_agentes se deja SIN seed: los ejecutivos del mock eran ficticios.
INSERT INTO public.bancos_convenio (id_banco, color_marca, producto_nombre, tasa_desde, orden)
SELECT b.id, x.color, x.prod, x.tasa, x.orden
FROM (VALUES
  ('BBVA%',      '#004481', 'Hipoteca Fija',   9.15, 10),
  ('Santander%', '#EC0000', 'Hipoteca Plus',   8.85, 20),
  ('Banorte%',   '#EB0029', 'Hipoteca Fuerte', 9.15, 30)
) AS x(pat, color, prod, tasa, orden)
CROSS JOIN LATERAL (
  SELECT id FROM public.bancos
  WHERE nombre ILIKE x.pat AND activo = true
  ORDER BY id LIMIT 1
) AS b
ON CONFLICT (id_banco) DO NOTHING;

-- ── 3. Submenu "Bancos" (menu 32) + permisos Super Admin (rol 1) ──
-- Submenu (idempotente por vista_front_end)
INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
SELECT 32, 'Bancos', '/admin/portal-bancos/bancos', 50, true, false
WHERE NOT EXISTS (
  SELECT 1 FROM public.submenus WHERE vista_front_end = '/admin/portal-bancos/bancos'
);

-- Permisos disponibles del submenu Bancos: 1,2,3,4
INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
SELECT s.id, p.permiso_id, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(2),(3),(4)) AS p(permiso_id)
WHERE s.vista_front_end = '/admin/portal-bancos/bancos'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos_disponibles d
    WHERE d.submenu_id = s.id AND d.permiso_id = p.permiso_id
  );

-- Asignación a Super Admin (rol 1) para Bancos y Equipo
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, 1, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(2),(3),(4)) AS p(permiso_id)
WHERE s.vista_front_end IN ('/admin/portal-bancos/bancos', '/admin/portal-bancos/equipo')
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = 1
  );
