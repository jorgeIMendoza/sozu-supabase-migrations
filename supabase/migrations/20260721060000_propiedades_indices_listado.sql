-- Índices para el listado de /admin/propiedades — fix statement timeout 57014
-- Fecha: 2026-07-21
--
-- El count=exact de PostgREST sobre propiedades (~54k filas) con el predicado del listado
-- hacía seq scan + heap fetch para count(*) OVER() y rebasaba statement_timeout (8s) en
-- cold cache -> HTTP 500 57014 -> lista vacía. count=estimated no sirve (stats del planner
-- desactualizados). Se conserva count=exact y se acelera con índice + ANALYZE.
--
-- Predicado del listado (tab Activos):
--   activo = true AND es_aprobado = true AND (id_tipo_propiedad IS NULL OR id_tipo_propiedad <= 10)
--
-- Diferencia vs el runbook: SIN CONCURRENTLY. CONCURRENTLY no corre dentro de transacción
-- y el CI (supabase db push) envuelve cada migración en tx -> fallaría. Con ~54k filas
-- (verificado prod 2026-07-21) un CREATE INDEX normal toma un lock ACCESS EXCLUSIVE breve
-- (~1-2s), aceptable. IF NOT EXISTS = idempotente.
--
-- Nota: ya existe idx_propiedades_activo_aprobado (activo, es_aprobado); el índice de 3
-- columnas de abajo lo cubre (superset) para el count del listado. No se dropea el viejo
-- (puede usarse en otras rutas); revisar aparte si se quiere consolidar.
-- ANALYZE es seguro dentro de transacción (a diferencia de VACUUM).

-- 1) Count del listado -> index scan cubriendo (activo, es_aprobado, id_tipo_propiedad)
CREATE INDEX IF NOT EXISTS idx_propiedades_listado
  ON public.propiedades (activo, es_aprobado, id_tipo_propiedad);

-- 2) Rango de precio / orden por precio del set publicado
CREATE INDEX IF NOT EXISTS idx_propiedades_precio_publicadas
  ON public.propiedades (precio_lista)
  WHERE activo AND es_aprobado;

-- 3) Refrescar estadísticas del planner
ANALYZE public.propiedades;
