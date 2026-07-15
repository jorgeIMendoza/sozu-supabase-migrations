-- Fix clasificador de app nativa SOZU en mediciones de uso
-- Fecha: 2026-07-15
--
-- El app Flutter registra sesiones en portal_sesiones con user_agent sintético
-- 'Mozilla/5.0 (...) Mobile SozuClienteApp/<ver>' (lib/core/portal_tracking.dart). Los
-- clasificadores esperaban el token 'SozuApp/' AL INICIO (ILIKE 'SozuApp/%') → nunca
-- coincidía → las sesiones del app caían en 'Otro'.
--
-- Fix retroactivo (clasificación en lectura; no reescribe la tabla): reconocer
-- '%SozuClienteApp/%' (se conserva 'SozuApp/%' por builds viejos) → navegador 'App clientes'.
-- También se corrige el fallback de marca Android ('%(android%' no casaba con el UA
-- sintético '(Linux; Android ...)' → se usa '%Android%').
--
-- CREATE OR REPLACE (misma firma que las versiones aplicadas). Sin BEGIN/COMMIT.

-- ================================================================
-- Paso 1 — Donas del Resumen gráfico
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
      CASE
        WHEN ps.user_agent IS NULL OR btrim(ps.user_agent) = ''      THEN 'Desconocido'
        WHEN ps.user_agent ILIKE '%iPad%' OR ps.user_agent ILIKE '%Tablet%' THEN 'Tablet'
        WHEN ps.user_agent ILIKE '%iPhone%' OR ps.user_agent ILIKE '%iPod%' THEN 'Móvil'
        WHEN ps.user_agent ILIKE '%Android%' AND ps.user_agent ILIKE '%Mobile%' THEN 'Móvil'
        WHEN ps.user_agent ILIKE '%Android%'                         THEN 'Tablet'
        WHEN ps.user_agent ILIKE '%Mobile%'                          THEN 'Móvil'
        ELSE 'Escritorio / Laptop'
      END AS tipo,
      CASE
        WHEN ps.user_agent IS NULL OR btrim(ps.user_agent) = ''      THEN 'Desconocido'
        WHEN ps.user_agent ILIKE '%iPhone%' OR ps.user_agent ILIKE '%iPad%' OR ps.user_agent ILIKE '%iPod%' THEN 'iOS / iPadOS'
        WHEN ps.user_agent ILIKE '%Android%'                         THEN 'Android'
        WHEN ps.user_agent ILIKE '%CrOS%'                            THEN 'ChromeOS'
        WHEN ps.user_agent ILIKE '%Windows%'                         THEN 'Windows'
        WHEN ps.user_agent ILIKE '%Macintosh%' OR ps.user_agent ILIKE '%Mac OS X%' THEN 'macOS'
        WHEN ps.user_agent ILIKE '%Linux%' OR ps.user_agent ILIKE '%X11%' THEN 'Linux'
        ELSE 'Otro'
      END AS tecnologia,
      -- navegador (app nativa PRIMERO: su UA sintético no trae token de navegador)
      CASE
        WHEN ps.user_agent IS NULL OR btrim(ps.user_agent) = ''      THEN 'Desconocido'
        WHEN ps.user_agent ILIKE '%SozuClienteApp/%' OR ps.user_agent ILIKE 'SozuApp/%' THEN 'App clientes'
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
      CASE
        WHEN ps.user_agent IS NULL OR btrim(ps.user_agent) = '' THEN 'Desconocido'
        WHEN ps.user_agent ILIKE '%iPhone%' OR ps.user_agent ILIKE '%iPad%' OR ps.user_agent ILIKE '%iPod%' THEN 'Apple'
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
-- Paso 2 — Drill-down por usuario
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
      WHEN a.ua ILIKE 'SozuApp/%' OR a.ua ILIKE '%SozuClienteApp/%' THEN 'app'
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
      WHEN a.ua ILIKE 'SozuApp/%' OR a.ua ILIKE '%SozuClienteApp/%' THEN
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
      WHEN a.ua ILIKE 'SozuApp/%' OR a.ua ILIKE '%SozuClienteApp/%'             THEN 'App clientes'
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

NOTIFY pgrst, 'reload schema';
