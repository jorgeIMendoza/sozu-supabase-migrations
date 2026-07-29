-- Portal Jurídico Fase 2 · Catálogo etapas — Audiencia conciliatoria + Recurso de revocación
--   en Demanda civil (id_tipo_asunto=1) y Demanda mercantil (id_tipo_asunto=2)
-- Fecha: 2026-07-28
--
-- Amplía el selector "Cambiar etapa" para Demanda civil/mercantil con dos etapas que ya
-- existían en otros tipos de asunto. UNIQUE(codigo, id_tipo_asunto) → no colisiona (unicidad
-- por combinación). Ubicación:
--   · Recurso de revocación → orden 3 (después de Admisión, antes de Emplazamiento).
--   · Audiencia conciliatoria → orden 6 (después de Contestación, antes de Período de pruebas;
--     tras el shift del paso 1, Contestación queda en 5).
--
-- Solo columnas de catálogo (ningún RPC/trigger/RLS). id IDENTITY (no se fija).
-- creado_por/actualizado_por explícitos (enforce_audit_mutable los exige sin sesión).
-- Idempotente: shifts de orden en DO-block guardado por existencia (correrlo 2 veces = no-op).
-- Sin BEGIN/COMMIT (CI/CD envuelve en tx). AJ-P1/AJ-P2 del .md ya están en 20260527000003.

-- 1. Recurso de revocación — orden 3
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.cat_etapas_procesales WHERE id_tipo_asunto = 1 AND codigo = 'RECURSO_REVOCACION') THEN
    UPDATE public.cat_etapas_procesales SET orden = orden + 1 WHERE id_tipo_asunto IN (1, 2) AND orden >= 3;
    INSERT INTO public.cat_etapas_procesales (id_tipo_asunto, codigo, nombre, orden, es_terminal, activo, creado_por, actualizado_por)
    VALUES
      (1, 'RECURSO_REVOCACION', 'Recurso de revocación', 3, false, true, 'tomas.peterson@investimento.mx', 'tomas.peterson@investimento.mx'),
      (2, 'RECURSO_REVOCACION', 'Recurso de revocación', 3, false, true, 'tomas.peterson@investimento.mx', 'tomas.peterson@investimento.mx');
  END IF;
END $$;

-- 2. Audiencia conciliatoria — orden 6 (después del shift del paso 1)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.cat_etapas_procesales WHERE id_tipo_asunto = 1 AND codigo = 'AUDIENCIA_CONCILIATORIA') THEN
    UPDATE public.cat_etapas_procesales SET orden = orden + 1 WHERE id_tipo_asunto IN (1, 2) AND orden >= 6;
    INSERT INTO public.cat_etapas_procesales (id_tipo_asunto, codigo, nombre, orden, es_terminal, activo, creado_por, actualizado_por)
    VALUES
      (1, 'AUDIENCIA_CONCILIATORIA', 'Audiencia conciliatoria', 6, false, true, 'tomas.peterson@investimento.mx', 'tomas.peterson@investimento.mx'),
      (2, 'AUDIENCIA_CONCILIATORIA', 'Audiencia conciliatoria', 6, false, true, 'tomas.peterson@investimento.mx', 'tomas.peterson@investimento.mx');
  END IF;
END $$;
