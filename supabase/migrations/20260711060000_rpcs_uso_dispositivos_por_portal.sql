-- Mediciones — uso por dispositivo (clasificación desde user_agent de portal_sesiones)
-- Fecha: 2026-07-11
--
-- Dos RPCs de lectura (SECURITY DEFINER), sin cambios de esquema — clasifican el
-- user_agent ya guardado en portal_sesiones (retroactivo a sesiones existentes):
--   1. dispositivos_uso_por_portal   → conteo por portal x tipo (desktop/iphone/...).
--   2. desglose_uso_dispositivos_portal → para un portal, desglose en 4 dimensiones
--      (tipo, tecnologia, navegador, marca) que el front pivota en 4 donas.
--
-- Ninguna existía en dev ni estaba versionada. CREATE OR REPLACE (idempotente).
-- Sin BEGIN/COMMIT (CI/CD envuelve en tx). Requiere portal_sesiones (ya versionada,
-- 20260610000002).
--
-- Limitación conocida: iPadOS 13+ Safari reporta UA de "Macintosh" → algunos iPad
-- se cuentan como escritorio (no distinguible server-side por user_agent).

-- ================================================================
-- 1. dispositivos_uso_por_portal — conteo por portal x tipo
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

GRANT EXECUTE ON FUNCTION public.dispositivos_uso_por_portal(timestamptz, timestamptz) TO authenticated;

-- ================================================================
-- 2. desglose_uso_dispositivos_portal — 4 dimensiones para "Ver gráficos"
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
      -- tipo de dispositivo
      CASE
        WHEN ps.user_agent IS NULL OR btrim(ps.user_agent) = ''      THEN 'Desconocido'
        WHEN ps.user_agent ILIKE '%iPad%' OR ps.user_agent ILIKE '%Tablet%' THEN 'Tablet'
        WHEN ps.user_agent ILIKE '%iPhone%' OR ps.user_agent ILIKE '%iPod%' THEN 'Móvil'
        WHEN ps.user_agent ILIKE '%Android%' AND ps.user_agent ILIKE '%Mobile%' THEN 'Móvil'
        WHEN ps.user_agent ILIKE '%Android%'                         THEN 'Tablet'
        WHEN ps.user_agent ILIKE '%Mobile%'                          THEN 'Móvil'
        ELSE 'Escritorio / Laptop'
      END AS tipo,
      -- tecnología / sistema operativo
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
      -- navegador (orden importa)
      CASE
        WHEN ps.user_agent IS NULL OR btrim(ps.user_agent) = ''      THEN 'Desconocido'
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
      -- marca del dispositivo (móvil) / SO (escritorio)
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

GRANT EXECUTE ON FUNCTION public.desglose_uso_dispositivos_portal(text, timestamptz, timestamptz) TO authenticated;

NOTIFY pgrst, 'reload schema';
