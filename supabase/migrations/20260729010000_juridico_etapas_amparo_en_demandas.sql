-- Portal Jurídico · Etapas "Amparo directo" y "Amparo indirecto" en Demanda civil/mercantil
-- Fecha: 2026-07-29
--
-- Agrega, al listado "Cambiar etapa" de asuntos tipo Demanda civil (id_tipo_asunto=1) y
-- Demanda mercantil (id_tipo_asunto=2), las etapas AMPARO_DIRECTO (orden 12) y AMPARO_INDIRECTO
-- (orden 13), entre "Recurso de apelación" (11) y "Sentencia definitiva". Permite marcar que el
-- asunto entró a fase de amparo SIN abrir un expediente aparte. Independiente de los tipos de
-- asunto AMPARO_DIRECTO/INDIRECTO (cat_tipos_asunto ids 15/16, instalados 20260728010000) — no
-- se tocan.
--
-- Requiere el estado de 14 etapas ya establecido por 20260728030000 (Recurso de revocación +
-- Audiencia conciliatoria en tipos 1/2). Resultado: 16 etapas por tipo, orden 1..16 sin huecos.
-- UNIQUE(codigo,id_tipo_asunto) no colisiona. asuntos_juridicos.id_etapa_actual referencia id
-- (no orden) → renumerar orden no rompe FK.
--
-- Idempotente: el shift +2 solo corre si AMPARO_DIRECTO aún no existe para ese tipo (NOT EXISTS
-- correlacionado); INSERT con ON CONFLICT (codigo,id_tipo_asunto) DO NOTHING. creado_por/
-- actualizado_por explícitos (enforce_audit_mutable). Sin BEGIN/COMMIT (CI/CD envuelve en tx).

-- 1. Desplazar +2 el orden de Sentencia definitiva, Ejecución y Cerrado (tipos 1 y 2)
UPDATE public.cat_etapas_procesales AS ep
SET orden = ep.orden + 2,
    actualizado_por = 'tomas.peterson@investimento.mx'
WHERE ep.id_tipo_asunto IN (1, 2)
  AND ep.codigo IN ('SENTENCIA_DEFINITIVA', 'EJECUCION', 'CERRADO')
  AND NOT EXISTS (
    SELECT 1 FROM public.cat_etapas_procesales ya
    WHERE ya.id_tipo_asunto = ep.id_tipo_asunto
      AND ya.codigo = 'AMPARO_DIRECTO'
  );

-- 2. Insertar las 2 etapas nuevas en el hueco (orden 12 y 13) para ambos tipos
INSERT INTO public.cat_etapas_procesales
  (id_tipo_asunto, codigo, nombre, orden, es_terminal, activo, creado_por, actualizado_por)
VALUES
  (1, 'AMPARO_DIRECTO',   'Amparo directo',   12, false, true, 'tomas.peterson@investimento.mx', 'tomas.peterson@investimento.mx'),
  (1, 'AMPARO_INDIRECTO', 'Amparo indirecto', 13, false, true, 'tomas.peterson@investimento.mx', 'tomas.peterson@investimento.mx'),
  (2, 'AMPARO_DIRECTO',   'Amparo directo',   12, false, true, 'tomas.peterson@investimento.mx', 'tomas.peterson@investimento.mx'),
  (2, 'AMPARO_INDIRECTO', 'Amparo indirecto', 13, false, true, 'tomas.peterson@investimento.mx', 'tomas.peterson@investimento.mx')
ON CONFLICT (codigo, id_tipo_asunto) DO NOTHING;
