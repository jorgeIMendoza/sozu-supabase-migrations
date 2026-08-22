-- =============================================================================
-- LIMPIEZA: contactos-lead duplicados por la ingesta directa de Meta
-- =============================================================================
-- Corrida unica de datos (DML). NO cambia esquema.
--
-- Contexto: al activar leads_retrieval (2026-08-20) se prendio la ingesta directa
-- Meta -> CRM (meta-leads-webhook). El webhook creaba SIEMPRE una entidad_relacionada
-- nueva por cada lead; la idempotencia solo mira meta_leadgen_id. Los contactos
-- capturados a mano (migrados desde HubSpot) NO tienen leadgen_id, asi que no se
-- reconocian y quedaron DUPLICADOS: misma persona con dos contactos-lead activos
-- (uno con historial + uno de Meta vacio).
--
-- El fix del webhook (sozu-edge-functions, PR #326) evita nuevos duplicados. Esta
-- migracion limpia los que ya existen.
--
-- --- Que hace --------------------------------------------------------------------
--   Por cada persona con >1 contacto-lead activo:
--     1) toma el DUPLICADO de Meta (origen=meta, con leadgen, SIN historial:
--        0 negocios/notas/tareas/citas, creado >= 2026-08-19),
--     2) copia su atribucion de Meta al contacto SUPERVIVIENTE (mas historial /
--        mas antiguo) si este aun no traia leadgen,
--     3) DESACTIVA el duplicado (activo=false). Soft-delete: reversible, no borra.
--
-- --- Por que es seguro -----------------------------------------------------------
--   * Solo toca duplicados de Meta VACIOS: los que tienen historial se dejan intactos.
--   * Solo dentro de la ventana del incidente (fecha_creacion >= 2026-08-19).
--   * No borra filas: usa activo=false (recuperable).
--   * Idempotente: al re-correr, los duplicados ya estan inactivos -> no hace nada.
-- =============================================================================

DO $$
DECLARE
  v_count integer;
BEGIN
  DROP TABLE IF EXISTS _pares_dedup;

  CREATE TEMP TABLE _pares_dedup AS
  WITH lead_er AS (
    SELECT er.id AS er_id, er.id_persona, er.fecha_creacion,
           a.id AS atr_id, a.origen, a.meta_leadgen_id,
           a.meta_campaign_id, a.meta_ad_id, a.meta_adgroup_id, a.meta_platform,
           a.meta_form_id, a.meta_form_name, a.meta_page_id, a.meta_created_time, a.meta_field_data,
           ( (SELECT count(*) FROM crm_negocios n WHERE n.id_entidad_relacionada = er.id)
           + (SELECT count(*) FROM crm_notas    x WHERE x.id_entidad_relacionada = er.id)
           + (SELECT count(*) FROM crm_tareas   y WHERE y.id_entidad_relacionada = er.id)
           + (SELECT count(*) FROM crm_citas    z WHERE z.id_entidad_relacionada = er.id) ) AS hijos
    FROM entidades_relacionadas er
    JOIN crm_leads_atribucion a
      ON a.id_entidad_relacionada = er.id AND a.activo = true
    WHERE er.activo = true
  ),
  grupos AS (
    SELECT id_persona FROM lead_er GROUP BY id_persona HAVING count(*) > 1
  ),
  dup AS (
    SELECT DISTINCT ON (id_persona) *
    FROM lead_er
    WHERE id_persona IN (SELECT id_persona FROM grupos)
      AND origen = 'meta' AND meta_leadgen_id IS NOT NULL
      AND hijos = 0
      AND fecha_creacion >= '2026-08-19'
    ORDER BY id_persona, fecha_creacion DESC
  ),
  sup AS (
    SELECT DISTINCT ON (le.id_persona) le.*
    FROM lead_er le
    JOIN dup ON dup.id_persona = le.id_persona
    WHERE le.er_id <> dup.er_id
    ORDER BY le.id_persona, le.hijos DESC, le.fecha_creacion ASC
  )
  SELECT d.id_persona,
         d.er_id  AS dup_er,  d.atr_id AS dup_atr, d.meta_leadgen_id AS dup_lg,
         d.meta_campaign_id, d.meta_ad_id, d.meta_adgroup_id, d.meta_platform,
         d.meta_form_id, d.meta_form_name, d.meta_page_id, d.meta_created_time, d.meta_field_data,
         s.er_id  AS sup_er,  s.atr_id AS sup_atr, s.meta_leadgen_id AS sup_lg
  FROM dup d
  JOIN sup s ON s.id_persona = d.id_persona;

  SELECT count(*) INTO v_count FROM _pares_dedup;
  RAISE NOTICE 'limpieza_contactos_duplicados_meta: % duplicados a desactivar', v_count;

  -- (1) Liberar el leadgen del duplicado y desactivar su atribucion (primero, para no
  --     chocar con la unicidad del leadgen_id al copiarlo al superviviente).
  UPDATE crm_leads_atribucion a
  SET meta_leadgen_id = NULL, activo = false, fecha_actualizacion = now()
  FROM _pares_dedup p
  WHERE a.id = p.dup_atr;

  -- (2) Pasar la atribucion de Meta al superviviente (solo si aun no tiene leadgen).
  UPDATE crm_leads_atribucion a
  SET origen            = 'meta',
      meta_leadgen_id   = p.dup_lg,
      meta_campaign_id  = COALESCE(a.meta_campaign_id,  p.meta_campaign_id),
      meta_ad_id        = COALESCE(a.meta_ad_id,        p.meta_ad_id),
      meta_adgroup_id   = COALESCE(a.meta_adgroup_id,   p.meta_adgroup_id),
      meta_platform     = COALESCE(a.meta_platform,     p.meta_platform),
      meta_form_id      = COALESCE(a.meta_form_id,      p.meta_form_id),
      meta_form_name    = COALESCE(a.meta_form_name,    p.meta_form_name),
      meta_page_id      = COALESCE(a.meta_page_id,      p.meta_page_id),
      meta_created_time = COALESCE(a.meta_created_time,  p.meta_created_time),
      meta_field_data   = COALESCE(a.meta_field_data,   p.meta_field_data),
      fecha_actualizacion = now()
  FROM _pares_dedup p
  WHERE a.id = p.sup_atr
    AND (p.sup_lg IS NULL OR p.sup_lg = '');

  -- (3) Desactivar el contacto duplicado (soft-delete, reversible).
  UPDATE entidades_relacionadas er
  SET activo = false, fecha_actualizacion = now()
  FROM _pares_dedup p
  WHERE er.id = p.dup_er;

  DROP TABLE IF EXISTS _pares_dedup;
END $$;
