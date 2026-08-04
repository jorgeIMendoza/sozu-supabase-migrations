-- Portal Tickets de Seguimiento — categorías de atención por pipeline.
--
-- Asigna el catálogo de categorías (Calentador, Plomería, etc.) a los pipelines de atención
-- ("Atención al Cliente" y "Atención a clientes Bottura") como categorías propias de cada uno.
-- Además desactiva las categorías globales originales (id_pipeline NULL), que ya no se usan
-- (decisión: las categorías son siempre por pipeline).
--
-- Idempotente: en Preview inserta para los pipelines que existan por nombre; en Producción solo
-- para los que existan (el WHERE por nombre excluye los que no). NOT EXISTS evita duplicados.
-- Sin BEGIN/COMMIT (el CI/CD envuelve en transacción). Corre en Preview y Producción.

INSERT INTO public.tickets_categorias (nombre, orden, activo, id_pipeline)
SELECT v.nombre, v.orden, true, p.id
FROM public.tickets_pipelines p
CROSS JOIN (VALUES
    ('Calentador Eléctrico',        10),
    ('Carpintería',                 20),
    ('Agua y drenaje',              30),
    ('Desperfecto Infraestructura', 40),
    ('Electricidad',                50),
    ('Plomería',                    60),
    ('Pintura y acabados',          70),
    ('Cerrajería',                  80),
    ('Jardinería y áreas comunes',  90),
    ('Limpieza',                    100)
) AS v(nombre, orden)
WHERE p.nombre IN ('Atención al Cliente', 'Atención a clientes Bottura')
  AND p.activo = true
  AND NOT EXISTS (
    SELECT 1 FROM public.tickets_categorias c
    WHERE c.id_pipeline = p.id AND c.nombre = v.nombre
  );

-- Las categorías globales originales (sin pipeline) ya no se usan -> desactivar.
UPDATE public.tickets_categorias
SET activo = false
WHERE id_pipeline IS NULL AND activo = true;
