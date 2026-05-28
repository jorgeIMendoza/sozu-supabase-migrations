-- =============================================================
-- Fix: Agregar columna id_cuenta_cobranza formateada a reportes 1 y 2
-- Fecha: 2026-05-27
-- Fuente: sozu-supabase-migrations/Ejecuciones/ejecutar.md
--
-- Reporte 1: CC-XXXXXX  (cuentas_cobranza_propiedades)
-- Reporte 2: CCP-XXXXXX (cuentas_cobrar_productos)
-- =============================================================

DO $$
BEGIN

  -- Reporte 1 — insertar id_cuenta_cobranza después de numero_departamento
  UPDATE public.reportes
  SET query_sql = REPLACE(
    query_sql,
    '     p.numero_propiedad AS numero_departamento,',
    '     p.numero_propiedad AS numero_departamento,' || chr(10) ||
    '     ''CC-'' || LPAD(cc.id::text, 6, ''0'') AS id_cuenta_cobranza,'
  )
  WHERE id = 1;

  -- Reporte 2 — insertar id_cuenta_cobranza después de compradores
  UPDATE public.reportes
  SET query_sql = REPLACE(
    query_sql,
    '     string_agg(DISTINCT comprador.nombre_legal, '' / '') AS compradores,',
    '     string_agg(DISTINCT comprador.nombre_legal, '' / '') AS compradores,' || chr(10) ||
    '     ''CCP-'' || LPAD(cc.id::text, 6, ''0'') AS id_cuenta_cobranza,'
  )
  WHERE id = 2;

END;
$$;
