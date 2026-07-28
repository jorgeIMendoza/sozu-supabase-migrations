-- Portal Jurídico Fase 2 · Catálogos — 2 tipos de asunto + etapas nuevas
-- Fecha: 2026-07-28
--
-- Amplía cat_tipos_asunto y cat_etapas_procesales:
--   1. Nuevos tipos: Amparo directo, Amparo indirecto (procedimientos distintos; el "Amparo"
--      genérico id=4 se deja intacto).
--   2. Etapas de Amparo indirecto (7) y Amparo directo (6).
--   3. "Audiencia conciliatoria" en Mediación/conciliación (id_tipo_asunto=7), orden 3.
--   4. "Recurso de revocación" en Incidente procesal (id_tipo_asunto=6), orden 3.
--
-- DML de catálogo puro (ningún RPC/trigger/RLS). ids IDENTITY (no se fijan). El trigger
-- enforce_audit_mutable exige creado_por/actualizado_por no vacíos cuando auth.uid() es NULL
-- (ejecución sin sesión, como CI/CD) → se fijan explícitos.
--
-- Idempotente: ON CONFLICT DO NOTHING (UNIQUE codigo / UNIQUE(codigo,id_tipo_asunto)); los
-- shifts de orden (pasos 3 y 4) van en DO-block guardado por existencia para no re-desplazar en
-- reejecuciones. Sin BEGIN/COMMIT (CI/CD envuelve en tx).
--
-- ⚠️ REVISAR (Diagnóstico §3 del .md): "Recurso de revocación" se asigna a Incidente procesal
-- (id_tipo_asunto=6) por defecto, sin confirmación del usuario. Si el destino correcto es otro
-- tipo, ajustar el paso 4 antes de mergear.

-- 1. Nuevos tipos de asunto
INSERT INTO public.cat_tipos_asunto (codigo, nombre, descripcion, activo, creado_por, actualizado_por)
VALUES
  ('AMPARO_DIRECTO',   'Amparo directo',   'Juicio de amparo directo ante Tribunal Colegiado, contra sentencias definitivas', true, 'tomas.peterson@investimento.mx', 'tomas.peterson@investimento.mx'),
  ('AMPARO_INDIRECTO', 'Amparo indirecto', 'Juicio de amparo indirecto ante Juzgado de Distrito', true, 'tomas.peterson@investimento.mx', 'tomas.peterson@investimento.mx')
ON CONFLICT (codigo) DO NOTHING;

-- 2. Etapas de Amparo indirecto
INSERT INTO public.cat_etapas_procesales (id_tipo_asunto, codigo, nombre, orden, es_terminal, activo, creado_por, actualizado_por)
SELECT ta.id, v.codigo, v.nombre, v.orden, v.es_terminal, true, 'tomas.peterson@investimento.mx', 'tomas.peterson@investimento.mx'
FROM public.cat_tipos_asunto ta
CROSS JOIN (VALUES
  ('PRESENTACION',            'Presentación de demanda',   1, false),
  ('ADMISION_SUSPENSION',     'Admisión y suspensión',     2, false),
  ('INFORME_JUSTIFICADO',     'Informe justificado',       3, false),
  ('AUDIENCIA_CONSTITUCIONAL','Audiencia constitucional',  4, false),
  ('SENTENCIA',               'Sentencia',                 5, false),
  ('RECURSO_REVISION',        'Recurso de revisión',       6, false),
  ('CERRADO',                 'Cerrado',                   7, true)
) AS v(codigo, nombre, orden, es_terminal)
WHERE ta.codigo = 'AMPARO_INDIRECTO'
ON CONFLICT (codigo, id_tipo_asunto) DO NOTHING;

-- 3. Etapas de Amparo directo
INSERT INTO public.cat_etapas_procesales (id_tipo_asunto, codigo, nombre, orden, es_terminal, activo, creado_por, actualizado_por)
SELECT ta.id, v.codigo, v.nombre, v.orden, v.es_terminal, true, 'tomas.peterson@investimento.mx', 'tomas.peterson@investimento.mx'
FROM public.cat_tipos_asunto ta
CROSS JOIN (VALUES
  ('PRESENTACION',        'Presentación de demanda',            1, false),
  ('TURNO_PONENTE',       'Turno a magistrado ponente',         2, false),
  ('INFORME_JUSTIFICADO', 'Informe justificado / Contestación', 3, false),
  ('PROYECTO_RESOLUCION', 'Proyecto de resolución',             4, false),
  ('SENTENCIA',           'Sentencia',                          5, false),
  ('CERRADO',             'Cerrado',                            6, true)
) AS v(codigo, nombre, orden, es_terminal)
WHERE ta.codigo = 'AMPARO_DIRECTO'
ON CONFLICT (codigo, id_tipo_asunto) DO NOTHING;

-- 4. "Audiencia conciliatoria" en Mediación / conciliación (id_tipo_asunto=7), orden 3.
--    Guardado: solo desplaza+inserta si aún no existe (no re-desplazar en reejecución).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.cat_etapas_procesales
    WHERE id_tipo_asunto = 7 AND codigo = 'AUDIENCIA_CONCILIATORIA'
  ) THEN
    UPDATE public.cat_etapas_procesales SET orden = orden + 1 WHERE id_tipo_asunto = 7 AND orden >= 3;
    INSERT INTO public.cat_etapas_procesales (id_tipo_asunto, codigo, nombre, orden, es_terminal, activo, creado_por, actualizado_por)
    VALUES (7, 'AUDIENCIA_CONCILIATORIA', 'Audiencia conciliatoria', 3, false, true, 'tomas.peterson@investimento.mx', 'tomas.peterson@investimento.mx');
  END IF;
END $$;

-- 5. "Recurso de revocación" en Incidente procesal (id_tipo_asunto=6), orden 3. ⚠️ destino por
--    revisar (ver cabecera). Guardado igual que el paso 4.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.cat_etapas_procesales
    WHERE id_tipo_asunto = 6 AND codigo = 'RECURSO_REVOCACION'
  ) THEN
    UPDATE public.cat_etapas_procesales SET orden = orden + 1 WHERE id_tipo_asunto = 6 AND orden >= 3;
    INSERT INTO public.cat_etapas_procesales (id_tipo_asunto, codigo, nombre, orden, es_terminal, activo, creado_por, actualizado_por)
    VALUES (6, 'RECURSO_REVOCACION', 'Recurso de revocación', 3, false, true, 'tomas.peterson@investimento.mx', 'tomas.peterson@investimento.mx');
  END IF;
END $$;
