-- Mediciones de uso: app clientes como categoría propia + sesiones en vivo + realtime
-- Fecha: 2026-07-15
--
-- Contexto (Alta Dirección → Uso por portal):
--   1. El donut "Tipo de dispositivo" clasificaba las sesiones de la app nativa
--      como Móvil/Tablet — ahora salen como 'App clientes'.
--   2. La tabla "Uso por tipo de dispositivo" (RPC dispositivos_uso_por_portal)
--      no tenía bucket de app — se agrega 'app'.
--   3. Se agrega el token 'Despia' a los detectores de app: el portal web de
--      clientes también corre dentro del wrapper nativo Despia, cuyo WebView
--      puede reportar 'Despia' en el user_agent (y el frontend ahora antepone
--      'SozuClienteApp/1.0' cuando detecta window.Despia).
--   4. Nueva RPC sesiones_activas_por_portal → pestaña "En vivo" del Resumen
--      gráfico: lista de sesiones conectadas ahora, con clasificación de
--      dispositivo/navegador/marca.
--   5. Realtime: portal_sesiones entra a la publicación supabase_realtime y
--      recibe policy SELECT para staff (rol <> 23), para que el dashboard se
--      actualice al momento vía postgres_changes. Los clientes finales no
--      pueden leer la tabla (la escritura sigue vía RPCs SECURITY DEFINER).
--
-- Detector de app (mismo criterio en todas las funciones):
--   user_agent ILIKE '%SozuClienteApp/%' OR ILIKE 'SozuApp/%' OR ILIKE '%Despia%'
--
-- CREATE OR REPLACE con las mismas firmas ya aplicadas. Sin BEGIN/COMMIT.

-- ================================================================
-- Paso 1 — Donas del Resumen gráfico: 'App clientes' en tipo,
--          Despia en detectores, cobertura '(iOS' en tecnología/marca
-- ================================================================
CREATE OR REPLACE FUNCTION public.desglose_uso_dispositivos_portal(
  p_portal text,
  p_desde timestamptz DEFAULT NULL,
  p_hasta timestamptz DEFAULT NULL
)
RETURNS TABLE (
  dimension        text,
  valor            text,
  usuarios_unicos  bigint,
  total_sesiones   bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH clasificado AS (
    SELECT
      ps.id_usuario,
      -- Tipo de dispositivo: la app nativa es una categoría propia
      CASE
        WHEN ps.user_agent IS NULL OR btrim(ps.user_agent) = ''      THEN 'Desconocido'
        WHEN ps.user_agent ILIKE '%SozuClienteApp/%' OR ps.user_agent ILIKE 'SozuApp/%'
          OR ps.user_agent ILIKE '%Despia%'                          THEN 'App clientes'
        WHEN ps.user_agent ILIKE '%iPad%' OR ps.user_agent ILIKE '%Tablet%' THEN 'Tablet'
        WHEN ps.user_agent ILIKE '%iPhone%' OR ps.user_agent ILIKE '%iPod%' THEN 'Móvil'
        WHEN ps.user_agent ILIKE '%Android%' AND ps.user_agent ILIKE '%Mobile%' THEN 'Móvil'
        WHEN ps.user_agent ILIKE '%Android%'                         THEN 'Tablet'
        WHEN ps.user_agent ILIKE '%Mobile%'                          THEN 'Móvil'
        ELSE 'Escritorio / Laptop'
      END AS tipo,
      -- Tecnología (SO): el UA de la app conserva la plataforma real
      -- ('(iOS ...' / iPhone / iPad / Android), así la app suma a iOS/Android
      CASE
        WHEN ps.user_agent IS NULL OR btrim(ps.user_agent) = ''      THEN 'Desconocido'
        WHEN ps.user_agent ILIKE '%iPhone%' OR ps.user_agent ILIKE '%iPad%'
          OR ps.user_agent ILIKE '%iPod%' OR ps.user_agent ILIKE '%(iOS%' THEN 'iOS / iPadOS'
        WHEN ps.user_agent ILIKE '%Android%'                         THEN 'Android'
        WHEN ps.user_agent ILIKE '%CrOS%'                            THEN 'ChromeOS'
        WHEN ps.user_agent ILIKE '%Windows%'                         THEN 'Windows'
        WHEN ps.user_agent ILIKE '%Macintosh%' OR ps.user_agent ILIKE '%Mac OS X%' THEN 'macOS'
        WHEN ps.user_agent ILIKE '%Linux%' OR ps.user_agent ILIKE '%X11%' THEN 'Linux'
        ELSE 'Otro'
      END AS tecnologia,
      -- Navegador (app nativa PRIMERO: su UA sintético no trae token de navegador)
      CASE
        WHEN ps.user_agent IS NULL OR btrim(ps.user_agent) = ''      THEN 'Desconocido'
        WHEN ps.user_agent ILIKE '%SozuClienteApp/%' OR ps.user_agent ILIKE 'SozuApp/%'
          OR ps.user_agent ILIKE '%Despia%'                          THEN 'App clientes'
        WHEN ps.user_agent ILIKE '%SamsungBrowser%'                  THEN 'Samsung Internet'
        WHEN ps.user_agent ILIKE '%Edg/%' OR ps.user_agent ILIKE '%EdgA/%' OR ps.user_agent ILIKE '%EdgiOS%' THEN 'Edge'
        WHEN ps.user_agent ILIKE '%OPR/%' OR ps.user_agent ILIKE '%Opera%' THEN 'Opera'
        WHEN ps.user_agent ILIKE '%CriOS%'                           THEN 'Chrome (iOS)'
        WHEN ps.user_agent ILIKE '%FxiOS%'                           THEN 'Firefox (iOS)'
        WHEN ps.user_agent ILIKE '%Firefox%'                         THEN 'Firefox'
        WHEN ps.user_agent ILIKE '%Chrome%' OR ps.user_agent ILIKE '%Chromium%' THEN 'Chrome'
        WHEN ps.user_agent ILIKE '%Safari%'                          THEN 'Safari'
        WHEN ps.user_agent ILIKE '%MSIE%' OR ps.user_agent ILIKE '%Trident%' THEN 'Internet Explorer'
        ELSE 'Otro'
      END AS navegador,
      -- Marca: el UA de la app conserva el modelo del dispositivo real
      CASE
        WHEN ps.user_agent IS NULL OR btrim(ps.user_agent) = '' THEN 'Desconocido'
        WHEN ps.user_agent ILIKE '%iPhone%' OR ps.user_agent ILIKE '%iPad%'
          OR ps.user_agent ILIKE '%iPod%' OR ps.user_agent ILIKE '%(iOS%' THEN 'Apple'
        WHEN ps.user_agent ILIKE '%Android%' THEN
          CASE
            WHEN ps.user_agent ILIKE '%SM-%' OR ps.user_agent ILIKE '%Galaxy%' OR ps.user_agent ILIKE '%SamsungBrowser%' THEN 'Samsung'
            WHEN ps.user_agent ILIKE '%Pixel%'                        THEN 'Google'
            WHEN ps.user_agent ILIKE '%Redmi%' OR ps.user_agent ILIKE '%POCO%'
              OR ps.user_agent ILIKE '%Xiaomi%' OR ps.user_agent ILIKE '%MIUI%' THEN 'Xiaomi'
            WHEN ps.user_agent ILIKE '%HUAWEI%' OR ps.user_agent ILIKE '%Honor%' THEN 'Huawei'
            WHEN ps.user_agent ILIKE '%moto%' OR ps.user_agent ILIKE '%Motorola%' THEN 'Motorola'
            WHEN ps.user_agent ILIKE '%OnePlus%'                      THEN 'OnePlus'
            WHEN ps.user_agent ILIKE '%OPPO%'                         THEN 'OPPO'
            WHEN ps.user_agent ILIKE '%vivo%'                         THEN 'vivo'
            WHEN ps.user_agent ILIKE '%Realme%'                       THEN 'realme'
            WHEN ps.user_agent ILIKE '%Nokia%'                        THEN 'Nokia'
            WHEN ps.user_agent ILIKE '%Sony%'                         THEN 'Sony'
            ELSE 'Android (otro)'
          END
        WHEN ps.user_agent ILIKE '%Macintosh%' OR ps.user_agent ILIKE '%Mac OS X%' THEN 'macOS'
        WHEN ps.user_agent ILIKE '%Windows%'                          THEN 'Windows'
        WHEN ps.user_agent ILIKE '%CrOS%'                             THEN 'ChromeOS'
        WHEN ps.user_agent ILIKE '%Linux%' OR ps.user_agent ILIKE '%X11%' THEN 'Linux'
        ELSE 'Otro'
      END AS marca
    FROM public.portal_sesiones ps
    WHERE ps.portal = p_portal
      AND (p_desde IS NULL OR ps.sesion_inicio >= p_desde)
      AND (p_hasta IS NULL OR ps.sesion_inicio <  p_hasta)
  )
  SELECT 'tipo'::text,       tipo,       COUNT(DISTINCT id_usuario), COUNT(*) FROM clasificado GROUP BY tipo
  UNION ALL
  SELECT 'tecnologia'::text, tecnologia, COUNT(DISTINCT id_usuario), COUNT(*) FROM clasificado GROUP BY tecnologia
  UNION ALL
  SELECT 'navegador'::text,  navegador,  COUNT(DISTINCT id_usuario), COUNT(*) FROM clasificado GROUP BY navegador
  UNION ALL
  SELECT 'marca'::text,      marca,      COUNT(DISTINCT id_usuario), COUNT(*) FROM clasificado GROUP BY marca
  ORDER BY 1, 4 DESC;
$$;

-- ================================================================
-- Paso 2 — Tabla "Uso por tipo de dispositivo": bucket 'app'
-- ================================================================
CREATE OR REPLACE FUNCTION public.dispositivos_uso_por_portal(
  p_desde timestamptz DEFAULT NULL,
  p_hasta timestamptz DEFAULT NULL
)
RETURNS TABLE (
  portal           text,
  tipo_dispositivo text,
  usuarios_unicos  bigint,
  total_sesiones   bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    portal,
    CASE
      WHEN user_agent IS NULL OR btrim(user_agent) = '' THEN 'desconocido'
      WHEN user_agent ILIKE '%SozuClienteApp/%' OR user_agent ILIKE 'SozuApp/%'
        OR user_agent ILIKE '%Despia%' THEN 'app'
      WHEN user_agent ILIKE '%iPad%' THEN 'ipad'
      WHEN user_agent ILIKE '%iPhone%' OR user_agent ILIKE '%iPod%' THEN 'iphone'
      WHEN user_agent ILIKE '%Android%' AND user_agent ILIKE '%Mobile%' THEN 'android_phone'
      WHEN user_agent ILIKE '%Android%' THEN 'android_tablet'
      ELSE 'desktop'
    END AS tipo_dispositivo,
    COUNT(DISTINCT id_usuario) AS usuarios_unicos,
    COUNT(*)                   AS total_sesiones
  FROM public.portal_sesiones
  WHERE (p_desde IS NULL OR sesion_inicio >= p_desde)
    AND (p_hasta IS NULL OR sesion_inicio <  p_hasta)
  GROUP BY portal, 2
  ORDER BY portal, total_sesiones DESC;
$$;

-- ================================================================
-- Paso 3 — Drill-down por usuario: agregar 'Despia' a los detectores de app
--          (resto idéntico a 20260715010000)
-- ================================================================
CREATE OR REPLACE FUNCTION public.usuarios_actividad_por_portal(
  p_portal text,
  p_desde timestamptz DEFAULT NULL,
  p_hasta timestamptz DEFAULT NULL
) RETURNS TABLE (
  id_usuario                   uuid,
  email_usuario                text,
  nombre_usuario               text,
  primera_sesion               timestamptz,
  ultima_actividad             timestamptz,
  total_sesiones               bigint,
  duracion_total_min           numeric,
  esta_online                  boolean,
  dias_desde_ultima_actividad  integer,
  tipo_dispositivo             text,
  marca_dispositivo            text,
  navegador                    text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH agg AS (
    SELECT
      ps.id_usuario,
      MAX(ps.email_usuario)    AS email_usuario,
      MAX(u.nombre)            AS nombre_usuario,
      MIN(ps.sesion_inicio)    AS primera_sesion,
      MAX(ps.ultima_actividad) AS ultima_actividad,
      COUNT(*)                 AS total_sesiones,
      ROUND(
        SUM(
          EXTRACT(EPOCH FROM (COALESCE(ps.sesion_fin, ps.ultima_actividad) - ps.sesion_inicio)) / 60
        )::numeric,
        1
      )                        AS duracion_total_min,
      BOOL_OR(
        ps.sesion_fin IS NULL AND ps.ultima_actividad > now() - interval '15 minutes'
      )                        AS esta_online,
      EXTRACT(DAY FROM (now() - MAX(ps.ultima_actividad)))::int AS dias_desde_ultima_actividad,
      (array_agg(ps.user_agent ORDER BY ps.ultima_actividad DESC NULLS LAST))[1] AS ua
    FROM public.portal_sesiones ps
    LEFT JOIN public.usuarios u ON u.email = ps.email_usuario
    WHERE ps.portal = p_portal
      AND (p_desde IS NULL OR ps.sesion_inicio >= p_desde)
      AND (p_hasta IS NULL OR ps.sesion_inicio <  p_hasta)
    GROUP BY ps.id_usuario
  )
  SELECT
    a.id_usuario,
    a.email_usuario,
    a.nombre_usuario,
    a.primera_sesion,
    a.ultima_actividad,
    a.total_sesiones,
    a.duracion_total_min,
    a.esta_online,
    a.dias_desde_ultima_actividad,
    -- Tipo de dispositivo
    CASE
      WHEN a.ua IS NULL OR btrim(a.ua) = ''                     THEN 'desconocido'
      WHEN a.ua ILIKE 'SozuApp/%' OR a.ua ILIKE '%SozuClienteApp/%'
        OR a.ua ILIKE '%Despia%'                                THEN 'app'
      WHEN a.ua ILIKE '%iPad%'                                  THEN 'tablet'
      WHEN a.ua ILIKE '%Tablet%'                                THEN 'tablet'
      WHEN a.ua ILIKE '%iPhone%' OR a.ua ILIKE '%iPod%'         THEN 'mobile'
      WHEN a.ua ILIKE '%Android%' AND a.ua ILIKE '%Mobile%'     THEN 'mobile'
      WHEN a.ua ILIKE '%Android%'                               THEN 'tablet'
      WHEN a.ua ILIKE '%Mobile%'                                THEN 'mobile'
      ELSE 'desktop'
    END AS tipo_dispositivo,
    -- Marca del dispositivo (móvil) / SO (escritorio)
    CASE
      WHEN a.ua IS NULL OR btrim(a.ua) = '' THEN NULL
      WHEN a.ua ILIKE 'SozuApp/%' OR a.ua ILIKE '%SozuClienteApp/%' OR a.ua ILIKE '%Despia%' THEN
        CASE
          WHEN a.ua ILIKE '%(ios%' OR a.ua ILIKE '%iPhone%' OR a.ua ILIKE '%iPad%' THEN 'Apple'
          WHEN a.ua ILIKE '%SM-%' OR a.ua ILIKE '%Galaxy%'             THEN 'Samsung'
          WHEN a.ua ILIKE '%Pixel%'                                    THEN 'Google'
          WHEN a.ua ILIKE '%Redmi%' OR a.ua ILIKE '%POCO%'
            OR a.ua ILIKE '%Xiaomi%'                                   THEN 'Xiaomi'
          WHEN a.ua ILIKE '%HUAWEI%' OR a.ua ILIKE '%Honor%'           THEN 'Huawei'
          WHEN a.ua ILIKE '%moto%' OR a.ua ILIKE '%Motorola%'          THEN 'Motorola'
          WHEN a.ua ILIKE '%OnePlus%'                                  THEN 'OnePlus'
          WHEN a.ua ILIKE '%Android%'                                  THEN 'Android (otro)'
          ELSE NULL
        END
      WHEN a.ua ILIKE '%iPhone%' OR a.ua ILIKE '%iPad%' OR a.ua ILIKE '%iPod%' THEN 'Apple'
      WHEN a.ua ILIKE '%Android%' THEN
        CASE
          WHEN a.ua ILIKE '%SM-%' OR a.ua ILIKE '%Galaxy%' OR a.ua ILIKE '%SamsungBrowser%' THEN 'Samsung'
          WHEN a.ua ILIKE '%Pixel%'                                    THEN 'Google'
          WHEN a.ua ILIKE '%Redmi%' OR a.ua ILIKE '%POCO%'
            OR a.ua ILIKE '%Xiaomi%' OR a.ua ILIKE '%MIUI%'            THEN 'Xiaomi'
          WHEN a.ua ILIKE '%HUAWEI%' OR a.ua ILIKE '%Honor%'           THEN 'Huawei'
          WHEN a.ua ILIKE '%moto%' OR a.ua ILIKE '%Motorola%'          THEN 'Motorola'
          WHEN a.ua ILIKE '%OnePlus%'                                  THEN 'OnePlus'
          WHEN a.ua ILIKE '%OPPO%'                                     THEN 'OPPO'
          WHEN a.ua ILIKE '%vivo%'                                     THEN 'vivo'
          WHEN a.ua ILIKE '%Realme%'                                   THEN 'realme'
          WHEN a.ua ILIKE '%Nokia%'                                    THEN 'Nokia'
          WHEN a.ua ILIKE '%Sony%'                                     THEN 'Sony'
          ELSE 'Android (otro)'
        END
      WHEN a.ua ILIKE '%Macintosh%' OR a.ua ILIKE '%Mac OS X%'         THEN 'macOS'
      WHEN a.ua ILIKE '%Windows%'                                      THEN 'Windows'
      WHEN a.ua ILIKE '%CrOS%'                                         THEN 'ChromeOS'
      WHEN a.ua ILIKE '%Linux%' OR a.ua ILIKE '%X11%'                  THEN 'Linux'
      ELSE NULL
    END AS marca_dispositivo,
    -- Navegador (orden importa: variantes específicas primero)
    CASE
      WHEN a.ua IS NULL OR btrim(a.ua) = '' THEN NULL
      WHEN a.ua ILIKE 'SozuApp/%' OR a.ua ILIKE '%SozuClienteApp/%'
        OR a.ua ILIKE '%Despia%'                                                THEN 'App clientes'
      WHEN a.ua ILIKE '%SamsungBrowser%'                                        THEN 'Samsung Internet'
      WHEN a.ua ILIKE '%Edg/%' OR a.ua ILIKE '%EdgA/%' OR a.ua ILIKE '%EdgiOS%' THEN 'Edge'
      WHEN a.ua ILIKE '%OPR/%' OR a.ua ILIKE '%Opera%'                          THEN 'Opera'
      WHEN a.ua ILIKE '%CriOS%'                                                 THEN 'Chrome (iOS)'
      WHEN a.ua ILIKE '%FxiOS%'                                                 THEN 'Firefox (iOS)'
      WHEN a.ua ILIKE '%Firefox%'                                               THEN 'Firefox'
      WHEN a.ua ILIKE '%Chrome%' OR a.ua ILIKE '%Chromium%'                     THEN 'Chrome'
      WHEN a.ua ILIKE '%Safari%'                                                THEN 'Safari'
      WHEN a.ua ILIKE '%MSIE%' OR a.ua ILIKE '%Trident%'                        THEN 'Internet Explorer'
      ELSE 'Otro'
    END AS navegador
  FROM agg a
  ORDER BY a.ultima_actividad DESC;
$$;

-- ================================================================
-- Paso 4 — Pestaña "En vivo": sesiones conectadas ahora, clasificadas
-- ================================================================
CREATE OR REPLACE FUNCTION public.sesiones_activas_por_portal(
  p_portal text,
  p_minutos_inactividad integer DEFAULT 15
)
RETURNS TABLE (
  session_id        uuid,
  email_usuario     text,
  nombre_usuario    text,
  sesion_inicio     timestamptz,
  ultima_actividad  timestamptz,
  tipo_dispositivo  text,
  tecnologia        text,
  navegador         text,
  marca_dispositivo text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ps.id AS session_id,
    ps.email_usuario,
    u.nombre AS nombre_usuario,
    ps.sesion_inicio,
    ps.ultima_actividad,
    -- Tipo de dispositivo (mismos buckets que usuarios_actividad_por_portal)
    CASE
      WHEN ps.user_agent IS NULL OR btrim(ps.user_agent) = ''            THEN 'desconocido'
      WHEN ps.user_agent ILIKE 'SozuApp/%' OR ps.user_agent ILIKE '%SozuClienteApp/%'
        OR ps.user_agent ILIKE '%Despia%'                                THEN 'app'
      WHEN ps.user_agent ILIKE '%iPad%' OR ps.user_agent ILIKE '%Tablet%' THEN 'tablet'
      WHEN ps.user_agent ILIKE '%iPhone%' OR ps.user_agent ILIKE '%iPod%' THEN 'mobile'
      WHEN ps.user_agent ILIKE '%Android%' AND ps.user_agent ILIKE '%Mobile%' THEN 'mobile'
      WHEN ps.user_agent ILIKE '%Android%'                               THEN 'tablet'
      WHEN ps.user_agent ILIKE '%Mobile%'                                THEN 'mobile'
      ELSE 'desktop'
    END AS tipo_dispositivo,
    -- Tecnología (SO)
    CASE
      WHEN ps.user_agent IS NULL OR btrim(ps.user_agent) = ''            THEN 'Desconocido'
      WHEN ps.user_agent ILIKE '%iPhone%' OR ps.user_agent ILIKE '%iPad%'
        OR ps.user_agent ILIKE '%iPod%' OR ps.user_agent ILIKE '%(iOS%'  THEN 'iOS / iPadOS'
      WHEN ps.user_agent ILIKE '%Android%'                               THEN 'Android'
      WHEN ps.user_agent ILIKE '%CrOS%'                                  THEN 'ChromeOS'
      WHEN ps.user_agent ILIKE '%Windows%'                               THEN 'Windows'
      WHEN ps.user_agent ILIKE '%Macintosh%' OR ps.user_agent ILIKE '%Mac OS X%' THEN 'macOS'
      WHEN ps.user_agent ILIKE '%Linux%' OR ps.user_agent ILIKE '%X11%'  THEN 'Linux'
      ELSE 'Otro'
    END AS tecnologia,
    -- Navegador
    CASE
      WHEN ps.user_agent IS NULL OR btrim(ps.user_agent) = ''            THEN 'Desconocido'
      WHEN ps.user_agent ILIKE 'SozuApp/%' OR ps.user_agent ILIKE '%SozuClienteApp/%'
        OR ps.user_agent ILIKE '%Despia%'                                THEN 'App clientes'
      WHEN ps.user_agent ILIKE '%SamsungBrowser%'                        THEN 'Samsung Internet'
      WHEN ps.user_agent ILIKE '%Edg/%' OR ps.user_agent ILIKE '%EdgA/%' OR ps.user_agent ILIKE '%EdgiOS%' THEN 'Edge'
      WHEN ps.user_agent ILIKE '%OPR/%' OR ps.user_agent ILIKE '%Opera%' THEN 'Opera'
      WHEN ps.user_agent ILIKE '%CriOS%'                                 THEN 'Chrome (iOS)'
      WHEN ps.user_agent ILIKE '%FxiOS%'                                 THEN 'Firefox (iOS)'
      WHEN ps.user_agent ILIKE '%Firefox%'                               THEN 'Firefox'
      WHEN ps.user_agent ILIKE '%Chrome%' OR ps.user_agent ILIKE '%Chromium%' THEN 'Chrome'
      WHEN ps.user_agent ILIKE '%Safari%'                                THEN 'Safari'
      ELSE 'Otro'
    END AS navegador,
    -- Marca
    CASE
      WHEN ps.user_agent IS NULL OR btrim(ps.user_agent) = ''            THEN 'Desconocido'
      WHEN ps.user_agent ILIKE '%iPhone%' OR ps.user_agent ILIKE '%iPad%'
        OR ps.user_agent ILIKE '%iPod%' OR ps.user_agent ILIKE '%(iOS%'  THEN 'Apple'
      WHEN ps.user_agent ILIKE '%Android%' THEN
        CASE
          WHEN ps.user_agent ILIKE '%SM-%' OR ps.user_agent ILIKE '%Galaxy%' OR ps.user_agent ILIKE '%SamsungBrowser%' THEN 'Samsung'
          WHEN ps.user_agent ILIKE '%Pixel%'  THEN 'Google'
          WHEN ps.user_agent ILIKE '%Redmi%' OR ps.user_agent ILIKE '%POCO%'
            OR ps.user_agent ILIKE '%Xiaomi%' OR ps.user_agent ILIKE '%MIUI%' THEN 'Xiaomi'
          WHEN ps.user_agent ILIKE '%HUAWEI%' OR ps.user_agent ILIKE '%Honor%' THEN 'Huawei'
          WHEN ps.user_agent ILIKE '%moto%' OR ps.user_agent ILIKE '%Motorola%' THEN 'Motorola'
          WHEN ps.user_agent ILIKE '%OnePlus%' THEN 'OnePlus'
          WHEN ps.user_agent ILIKE '%OPPO%'    THEN 'OPPO'
          WHEN ps.user_agent ILIKE '%vivo%'    THEN 'vivo'
          WHEN ps.user_agent ILIKE '%Realme%'  THEN 'realme'
          ELSE 'Android (otro)'
        END
      WHEN ps.user_agent ILIKE '%Macintosh%' OR ps.user_agent ILIKE '%Mac OS X%' THEN 'macOS'
      WHEN ps.user_agent ILIKE '%Windows%'                               THEN 'Windows'
      WHEN ps.user_agent ILIKE '%CrOS%'                                  THEN 'ChromeOS'
      WHEN ps.user_agent ILIKE '%Linux%' OR ps.user_agent ILIKE '%X11%'  THEN 'Linux'
      ELSE 'Otro'
    END AS marca_dispositivo
  FROM public.portal_sesiones ps
  LEFT JOIN public.usuarios u ON u.email = ps.email_usuario
  WHERE ps.portal = p_portal
    AND ps.sesion_fin IS NULL
    AND ps.ultima_actividad > now() - make_interval(mins => p_minutos_inactividad)
  ORDER BY ps.ultima_actividad DESC;
$$;

-- ================================================================
-- Paso 5 — Realtime: publicación + policy SELECT para staff
-- ================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'portal_sesiones'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.portal_sesiones;
  END IF;
END $$;

-- RLS está activo en portal_sesiones sin policies (todo el acceso va por RPCs
-- SECURITY DEFINER). Realtime postgres_changes respeta RLS: sin policy SELECT
-- no se emite ningún evento. Staff (rol <> 23 = no Cliente) puede leer;
-- clientes finales siguen sin acceso directo a la tabla.
DROP POLICY IF EXISTS portal_sesiones_staff_select ON public.portal_sesiones;
CREATE POLICY portal_sesiones_staff_select ON public.portal_sesiones
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.auth_user_id = auth.uid()
        AND u.rol_id <> 23
        AND u.activo
    )
  );

NOTIFY pgrst, 'reload schema';
