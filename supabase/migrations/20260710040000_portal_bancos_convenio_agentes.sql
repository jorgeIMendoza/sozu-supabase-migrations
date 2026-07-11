-- Portal Bancos — tablas bancos_convenio / bancos_agentes + seed + submenu
-- Fecha: 2026-07-10 (DDL original 2026-06-18)
--
-- Versiona lo que ya se ejecutó a mano en dev (el spec original decía "ejecútalo el
-- usuario en BD"): tablas del Portal Bancos, seed de los 3 convenios y el submenu Bancos.
-- Idempotente (CREATE TABLE IF NOT EXISTS, ON CONFLICT DO NOTHING, WHERE NOT EXISTS) →
-- no-op en dev (ya existe), efectiva en prod si falta.
--
-- id como GENERATED ALWAYS AS IDENTITY (convención de la casa). Como en dev las tablas ya
-- existen creadas con SERIAL, un bloque convierte esas columnas serial → identity de forma
-- idempotente (guard is_identity='NO'). Sin BEGIN/COMMIT (CI/CD envuelve en tx).

-- ==============================================================
-- 1. Tablas (instalaciones nuevas: id IDENTITY)
-- ==============================================================

CREATE TABLE IF NOT EXISTS public.bancos_convenio (
  id                   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
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
  id                   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
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

-- ==============================================================
-- 1b. Convertir id SERIAL → IDENTITY donde las tablas ya existían así (dev)
-- ==============================================================
DO $$
DECLARE
  t text;
  v_seq text;
  v_max bigint;
BEGIN
  FOREACH t IN ARRAY ARRAY['bancos_convenio','bancos_agentes'] LOOP
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = t
        AND column_name = 'id' AND is_identity = 'NO'
    ) THEN
      v_seq := pg_get_serial_sequence('public.' || t, 'id');
      EXECUTE format('ALTER TABLE public.%I ALTER COLUMN id DROP DEFAULT', t);
      IF v_seq IS NOT NULL THEN
        EXECUTE format('DROP SEQUENCE IF EXISTS %s', v_seq);
      END IF;
      EXECUTE format('ALTER TABLE public.%I ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY', t);
      -- Ajustar la secuencia de identidad al max(id) actual para no colisionar.
      EXECUTE format('SELECT COALESCE(MAX(id), 0) FROM public.%I', t) INTO v_max;
      IF v_max > 0 THEN
        EXECUTE format(
          'SELECT setval(pg_get_serial_sequence(''public.%I'', ''id''), %s, true)', t, v_max);
      END IF;
    END IF;
  END LOOP;
END $$;

-- ==============================================================
-- 2. Seed de los 3 convenios actuales (BBVA, Santander, Banorte)
-- ==============================================================
-- Resuelve id_banco por prefijo (ILIKE) tolerante a variaciones del nombre real.
-- bancos_agentes queda SIN seed (los agentes reales los captura el Super Admin).
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

-- ==============================================================
-- 3. Submenu "Bancos" del Portal Bancos (menu_id = 32) + permisos Super Admin (rol 1)
-- ==============================================================
WITH nuevo AS (
  INSERT INTO public.submenus (menu_id, nombre, vista_front_end, orden, activo, solo_usuarioa)
  SELECT 32, 'Bancos', '/admin/portal-bancos/bancos', 50, true, false
  WHERE NOT EXISTS (
    SELECT 1 FROM public.submenus WHERE vista_front_end = '/admin/portal-bancos/bancos'
  )
  RETURNING id
),
disp AS (
  INSERT INTO public.submenus_permisos_disponibles (submenu_id, permiso_id, activo)
  SELECT n.id, p.permiso_id, true
  FROM nuevo n CROSS JOIN (VALUES (1),(2),(3),(4)) AS p(permiso_id)
  RETURNING 1
)
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT n.id, p.permiso_id, 1, true
FROM nuevo n CROSS JOIN (VALUES (1),(2),(3),(4)) AS p(permiso_id);

-- Asegurar permisos de Super Admin sobre el submenu "Equipo" ya existente.
INSERT INTO public.submenus_permisos (submenu_id, permiso_id, rol_id, activo)
SELECT s.id, p.permiso_id, 1, true
FROM public.submenus s
CROSS JOIN (VALUES (1),(2),(3),(4)) AS p(permiso_id)
WHERE s.vista_front_end = '/admin/portal-bancos/equipo'
  AND NOT EXISTS (
    SELECT 1 FROM public.submenus_permisos sp
    WHERE sp.submenu_id = s.id AND sp.permiso_id = p.permiso_id AND sp.rol_id = 1
  );
