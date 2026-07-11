-- Mediciones · Drill-down de usuarios por portal, con dispositivo/navegador.
-- Fecha: 2026-07-11
--
-- Formaliza lo ejecutado a mano en PRD (Ejecuciones/ejecutar.md 2026-06-10 y
-- ampliación 2026-07-11) en su VERSIÓN FINAL: detalle por usuario de un portal
-- (sesiones, duración, online, días sin entrar) más 3 columnas derivadas del
-- user_agent de la sesión más reciente:
--   - tipo_dispositivo:  app | desktop | mobile | tablet | desconocido
--                        (app = UA 'SozuApp/...', la app nativa del cliente)
--   - marca_dispositivo: marca en móvil (Apple, Samsung, Xiaomi, ...) o SO en
--                        escritorio (Windows/macOS/Linux/ChromeOS); NULL si no
--                        se puede inferir.
--   - navegador:         Chrome, Safari, Edge, Firefox, Opera, etc.
--
-- Como la firma de RETURNS TABLE cambió respecto a la versión inicial, se hace
-- DROP antes del CREATE (CREATE OR REPLACE no puede alterar columnas de
-- salida). Idempotente: DROP IF EXISTS + CREATE.
--
-- Limitaciones conocidas: laptop vs escritorio no se distingue por UA; iPadOS
-- 13+ con Safari reporta UA de Macintosh (cae en desktop/macOS); marcas
-- Android por heurística de tokens del UA.

DROP FUNCTION IF EXISTS public.usuarios_actividad_por_portal(text, timestamptz, timestamptz);

CREATE FUNCTION public.usuarios_actividad_por_portal(
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
      -- user_agent de la sesión MÁS reciente (mayor ultima_actividad).
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
    -- ── Tipo de dispositivo ──
    CASE
      WHEN a.ua IS NULL OR btrim(a.ua) = ''                     THEN 'desconocido'
      WHEN a.ua ILIKE 'SozuApp/%'                               THEN 'app'
      WHEN a.ua ILIKE '%iPad%'                                  THEN 'tablet'
      WHEN a.ua ILIKE '%Tablet%'                                THEN 'tablet'
      WHEN a.ua ILIKE '%iPhone%' OR a.ua ILIKE '%iPod%'         THEN 'mobile'
      WHEN a.ua ILIKE '%Android%' AND a.ua ILIKE '%Mobile%'     THEN 'mobile'
      WHEN a.ua ILIKE '%Android%'                               THEN 'tablet'
      WHEN a.ua ILIKE '%Mobile%'                                THEN 'mobile'
      ELSE 'desktop'
    END AS tipo_dispositivo,
    -- ── Marca del dispositivo (móvil) / SO (escritorio) ──
    CASE
      WHEN a.ua IS NULL OR btrim(a.ua) = '' THEN NULL
      -- App nativa SOZU: UA 'SozuApp/<ver> (<os>; <modelo>)'
      WHEN a.ua ILIKE 'SozuApp/%' THEN
        CASE
          WHEN a.ua ILIKE '%(ios%' OR a.ua ILIKE '%iPhone%' OR a.ua ILIKE '%iPad%' THEN 'Apple'
          WHEN a.ua ILIKE '%SM-%' OR a.ua ILIKE '%Galaxy%'             THEN 'Samsung'
          WHEN a.ua ILIKE '%Pixel%'                                    THEN 'Google'
          WHEN a.ua ILIKE '%Redmi%' OR a.ua ILIKE '%POCO%'
            OR a.ua ILIKE '%Xiaomi%'                                   THEN 'Xiaomi'
          WHEN a.ua ILIKE '%HUAWEI%' OR a.ua ILIKE '%Honor%'           THEN 'Huawei'
          WHEN a.ua ILIKE '%moto%' OR a.ua ILIKE '%Motorola%'          THEN 'Motorola'
          WHEN a.ua ILIKE '%OnePlus%'                                  THEN 'OnePlus'
          WHEN a.ua ILIKE '%(android%'                                 THEN 'Android (otro)'
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
    -- ── Navegador (orden importa: variantes específicas primero) ──
    CASE
      WHEN a.ua IS NULL OR btrim(a.ua) = '' THEN NULL
      WHEN a.ua ILIKE 'SozuApp/%'                                               THEN 'App SOZU'
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

GRANT EXECUTE ON FUNCTION public.usuarios_actividad_por_portal(text, timestamptz, timestamptz)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
