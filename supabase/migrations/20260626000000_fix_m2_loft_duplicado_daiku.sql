-- Fix M2 duplicados en recibo de depósito en garantía.
--
-- Reportado por luz.ochoa@sozu.com: el recibo de depósito en garantía imprime
-- el doble de los metros estimados (ej. Daiku 1003, modelo NOGAL: 62.65 m²
-- reales -> 125.30 m² en recibo).
--
-- Causa: NO es bug de código. El generador (generar-recibo-pago) y el de
-- contrato calculan m2_totales = m2_interiores + m2_exteriores + m2_loft, que
-- es correcto. El problema son datos: en el proyecto Daiku, 94 propiedades
-- tienen m2_loft capturado igual a m2_interiores (duplicado por mala
-- importación). Las unidades Daiku no tienen loft real.
--
-- Verificado en prod (proyecto Daiku): 94 props con m2_loft <> 0, TODAS son
-- duplicado (m2_loft = m2_interiores), 0 legítimas. El resto del sistema (196
-- props con loft en otros proyectos) tiene loft legítimo y NO se toca.
--
-- Fix idempotente: poner m2_loft = 0 solo donde duplica a m2_interiores dentro
-- de Daiku. Re-ejecutar no afecta nada (condición ya no se cumple).

UPDATE propiedades p
SET m2_loft = 0
FROM edificios_modelos em
JOIN edificios e ON e.id = em.id_edificio
WHERE p.id_edificio_modelo = em.id
  AND e.id_proyecto = (SELECT id FROM proyectos WHERE nombre = 'Daiku' LIMIT 1)
  AND p.activo = true
  AND COALESCE(p.m2_loft, 0) = p.m2_interiores
  AND COALESCE(p.m2_loft, 0) <> 0;
-- Filas afectadas esperadas: 94.
