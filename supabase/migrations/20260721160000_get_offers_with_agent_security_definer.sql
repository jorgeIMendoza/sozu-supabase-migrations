-- get_offers_with_agent · SECURITY DEFINER para evitar statement timeout (57014)
-- Fecha: 2026-07-21
--
-- El RPC junta ofertas + usuarios (10 policies RLS) + personas + cuentas_cobranza +
-- entidades_relacionadas. Al ejecutarse como SECURITY INVOKER (authenticated), la RLS
-- de todas esas tablas —incluidas las nuevas policies de Portal Socio Bancario
-- (socio_tiene_propiedad / current_socio_bancario_id)— se evalúa dentro de los joins y
-- dispara el statement_timeout (error 57014: "canceling statement due to statement timeout").
-- Como superusuario (RLS bypass) la misma consulta corre en ~15 ms.
--
-- Fix: SECURITY DEFINER (mismo patrón que get_oferta_financials). No expone datos extra:
-- la RLS actual de `ofertas` deja leer TODAS las ofertas a cualquier usuario no-socio
-- (policy passthrough current_socio_bancario_id() IS NULL); el acceso ya está acotado por
-- permisos de página + el filtro por property_id. El portal de socio bancario no usa este RPC.
--
-- Idempotente: CREATE OR REPLACE.

CREATE OR REPLACE FUNCTION public.get_offers_with_agent(property_id integer)
 RETURNS TABLE(id integer, fecha_generacion timestamp without time zone, activo boolean, id_persona_lead integer, agent_name text, lead_name text, lead_email text, lead_telefono text, esquema_id integer, esquema_nombre text, esquema_enganche numeric, esquema_mensualidades numeric, esquema_entrega numeric, esquema_numero_meses integer, esquema_es_manual boolean, cuenta_precio_final numeric, cuenta_fecha_compra date, cuenta_es_aprobado boolean, cuenta_clabe_stp text, id_persona_duena_lead integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  SELECT DISTINCT ON (o.id)
    o.id,
    o.fecha_generacion,
    o.activo,
    o.id_persona_lead,
    COALESCE(u.nombre, o.email_creador) as agent_name,
    p.nombre_legal as lead_name,
    p.email as lead_email,
    p.telefono as lead_telefono,
    ep.id as esquema_id,
    ep.nombre as esquema_nombre,
    ep.porcentaje_enganche as esquema_enganche,
    ep.porcentaje_mensualidades as esquema_mensualidades,
    ep.porcentaje_entrega as esquema_entrega,
    ep.numero_mensualidades as esquema_numero_meses,
    ep.es_manual as esquema_es_manual,
    cc.precio_final as cuenta_precio_final,
    cc.fecha_compra as cuenta_fecha_compra,
    cc.es_aprobado as cuenta_es_aprobado,
    cc.clabe_stp as cuenta_clabe_stp,
    er.id_persona_duena_lead::integer as id_persona_duena_lead
  FROM ofertas o
  LEFT JOIN usuarios u ON u.email = o.email_creador
  LEFT JOIN personas p ON p.id = o.id_persona_lead
  LEFT JOIN esquemas_pago ep ON ep.id = o.id_esquema_pago_seleccionado
  LEFT JOIN cuentas_cobranza cc ON cc.id_oferta = o.id
  LEFT JOIN entidades_relacionadas er ON er.id_persona = o.id_persona_lead AND er.id_tipo_entidad IN (2, 7) AND er.activo = true
  WHERE o.id_propiedad = property_id
    AND o.activo = true
    AND o.id_producto IS NULL
  ORDER BY o.id, o.fecha_generacion DESC;
END;
$function$;
