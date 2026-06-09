CREATE OR REPLACE FUNCTION get_active_projects()
RETURNS json
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
SELECT COALESCE(
    json_agg(DISTINCT LOWER(ed.nombre) ORDER BY LOWER(ed.nombre)),
    '[]'::json
)
FROM pagos pg
JOIN cuentas_cobranza  cc   ON cc.id   = pg.id_cuenta_cobranza
LEFT JOIN ofertas      o    ON o.id    = cc.id_oferta
JOIN propiedades       prop ON prop.id = COALESCE(cc.id_propiedad, o.id_propiedad)
JOIN edificios_modelos em   ON em.id   = prop.id_edificio_modelo
JOIN edificios         ed   ON ed.id   = em.id_edificio
WHERE pg.activo = TRUE;
$$;

GRANT EXECUTE ON FUNCTION get_active_projects() TO service_role;
