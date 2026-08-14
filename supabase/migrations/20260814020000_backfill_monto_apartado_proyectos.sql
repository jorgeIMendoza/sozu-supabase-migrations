-- =============================================================================
-- Backfill del monto de apartado en Margot, Bottura, Daiku y Monócolo
-- =============================================================================
-- Petición de comercial (2026-08-13): dejar el monto capturado en TODAS las unidades de
-- esos cuatro proyectos, para que `get_oferta_financials` lo lea por unidad y ninguna caiga
-- al default de $20,000 del COALESCE.
--
--   Proyecto   id     Monto pedido
--   Margot     1743   $20,000
--   Bottura    2      $20,000
--   Daiku      1453   $20,000
--   Monócolo   1902   $50,000
--
-- ─── Verificado read-only el 2026-08-14 en prod (tzmhgfjmddkfyffkkmto) ───────
--
--   Proyecto   monto hoy   unidades   con oferta activa
--   Bottura    NULL              36          36
--   Bottura    20,000           167         167
--   Daiku      20,000           163         156
--   Margot     NULL               2           2
--   Margot     20,000           320         319
--   Monócolo   100,000          145          64
--
-- Ninguna de las 833 unidades está inactiva. El UPDATE toca **183 filas**:
--   · 38 pasan de NULL a 20,000 (36 de Bottura y 2 de Margot). No cambian de monto
--     exhibido: hoy ya caen a 20,000 por el COALESCE de la RPC. Solo dejan de tener hueco.
--   · 145 de Monócolo bajan de 100,000 a 50,000. ESTE SÍ CAMBIA DINERO.
-- Las otras 650 ya están en el valor pedido y el `IS DISTINCT FROM` las deja intactas.
--
-- ─── OJO: Monócolo ───────────────────────────────────────────────────────────
-- Es el único proyecto donde el monto vigente cambia. Tiene 64 unidades con oferta activa,
-- que son 115 ofertas vivas. Como `get_oferta_financials` calcula al vuelo, esas 115
-- ofertas —incluidas las ya enviadas por correo— pasan a exhibir $50,000 en cuanto esto se
-- aplique, y su `enganche_neto` sube $50,000. El doc lo marca como pedido de comercial;
-- ese sí tiene que estar antes de mergear, porque las ofertas ya emitidas cambian de monto
-- de inmediato y revertir implica volver a mover las 145 filas.
--
-- ─── Orden ───────────────────────────────────────────────────────────────────
-- Va después de `20260813170000_oferta_apartado_de_la_propiedad.sql`, que es la que hace
-- que la RPC lea esta columna. Aplicar el backfill sin esa migración no cambia nada de lo
-- que ve el cliente: la RPC seguiría devolviendo el literal de 20,000.
--
-- No crea columnas: `propiedades.monto_apartado` ya existe y ya se edita en el Panel Admin
-- (EditPropertyDialog → "Monto Apartado").
-- =============================================================================

BEGIN;

-- Guard: los cuatro proyectos tienen que ser los que se auditaron. Si un id apunta a otro
-- proyecto —los catálogos no están sincronizados entre entornos— el backfill le cambiaría
-- el apartado a un desarrollo equivocado.
DO $guard$
DECLARE
  v_par   record;
  v_falta text := '';
BEGIN
  FOR v_par IN
    SELECT * FROM (VALUES (1743,'Margot'), (2,'Bottura'), (1453,'Daiku'), (1902,'Monócolo'))
                  AS t(id, nombre)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.proyectos
      WHERE id = v_par.id AND lower(btrim(nombre)) = lower(v_par.nombre)
    ) THEN
      v_falta := v_falta || format('id %s no es "%s"; ', v_par.id, v_par.nombre);
    END IF;
  END LOOP;

  IF v_falta <> '' THEN
    RAISE EXCEPTION 'Los ids de proyecto no corresponden a los auditados: %', v_falta;
  END IF;
END;
$guard$;

WITH objetivo (id_proyecto, monto) AS (
  VALUES (1743,  20000::numeric),  -- Margot
         (2,     20000::numeric),  -- Bottura
         (1453,  20000::numeric),  -- Daiku
         (1902,  50000::numeric)   -- Monócolo: baja desde 100,000
)
UPDATE public.propiedades p
SET monto_apartado = o.monto
FROM public.edificios_modelos em
JOIN public.edificios ed ON ed.id = em.id_edificio
JOIN objetivo o          ON o.id_proyecto = ed.id_proyecto
WHERE em.id = p.id_edificio_modelo
  AND p.monto_apartado IS DISTINCT FROM o.monto;

-- Self-verifying: los cuatro proyectos deben quedar con UN solo monto y sin NULLs.
DO $check$
DECLARE
  v_mal text;
BEGIN
  SELECT string_agg(format('%s → %s valores distintos, %s en NULL', nombre, n_montos, n_null), '; ')
    INTO v_mal
  FROM (
    SELECT pr.nombre,
           count(DISTINCT p.monto_apartado) AS n_montos,
           count(*) FILTER (WHERE p.monto_apartado IS NULL) AS n_null
    FROM public.propiedades p
    JOIN public.edificios_modelos em ON em.id = p.id_edificio_modelo
    JOIN public.edificios ed         ON ed.id = em.id_edificio
    JOIN public.proyectos pr         ON pr.id = ed.id_proyecto
    WHERE ed.id_proyecto IN (1743, 2, 1453, 1902)
    GROUP BY pr.nombre
    HAVING count(DISTINCT p.monto_apartado) <> 1 OR count(*) FILTER (WHERE p.monto_apartado IS NULL) > 0
  ) x;

  IF v_mal IS NOT NULL THEN
    RAISE EXCEPTION 'El backfill dejó proyectos disparejos: %', v_mal;
  END IF;
END;
$check$;

COMMIT;

-- =============================================================================
-- Verificación (read-only, correr después del deploy)
-- =============================================================================
-- SELECT pr.id, pr.nombre, p.monto_apartado, count(*) AS unidades
-- FROM propiedades p
-- JOIN edificios_modelos em ON em.id = p.id_edificio_modelo
-- JOIN edificios ed         ON ed.id = em.id_edificio
-- JOIN proyectos pr         ON pr.id = ed.id_proyecto
-- WHERE pr.id IN (1743, 2, 1453, 1902)
-- GROUP BY 1,2,3 ORDER BY 2,3;
-- Esperado: Bottura 20000/203 · Daiku 20000/163 · Margot 20000/322 · Monócolo 50000/145
--
-- -- Una oferta de Monócolo debe cobrar 50,000 (requiere 20260813170000 aplicada)
-- SELECT (public.get_oferta_financials(o.id) ->> 'apartado')::numeric
-- FROM ofertas o
-- JOIN propiedades p        ON p.id = o.id_propiedad
-- JOIN edificios_modelos em ON em.id = p.id_edificio_modelo
-- JOIN edificios ed         ON ed.id = em.id_edificio
-- WHERE ed.id_proyecto = 1902 AND COALESCE(o.activo, true) LIMIT 1;
-- =============================================================================
