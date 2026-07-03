-- Fix: ubicación incorrecta del showroom de Daiku (proyecto 1453) en la oferta digital
-- Fecha: 2026-07-02
-- Issue: keity.galindo@sozu.com
--
-- Causa: la oferta pública lee de showrooms_proyecto (use-offer-db.ts) pero la query no
-- filtraba activo y hacía limit(1) sin order, devolviendo a veces el showroom inactivo
-- "Monócolo Café" (Av. de las Américas 1501) cuyo pin cae junto a Punto Sao Paulo.
-- Fix funcional = código (ya aplicado: filtro activo=true + order by fecha_actualizacion desc).
--
-- Esta migración corrige/normaliza los DATOS (idempotente):
--   1. Desactiva cualquier showroom de Daiku que no sea Hidalgo 1995.
--   2. Normaliza la dirección del showroom activo a la nomenclatura de Google Maps.
--   3. Normaliza la dirección en la configuración de citas del proyecto.
-- Mismo punto físico (coords 20.74705, -103.41793); 2 y 3 solo homologan el texto.
-- Verificado en dev 2026-07-02: Monócolo ya inactivo (UPDATE 1 = no-op en dev), efectivo en prod.

-- 1. Desactivar cualquier showroom de Daiku que no sea el de Hidalgo 1995
UPDATE public.showrooms_proyecto
SET activo = false, fecha_actualizacion = now()
WHERE id_proyecto = 1453
  AND descripcion_direccion NOT ILIKE '%Hidalgo%1995%'
  AND activo = true;

-- 2. Normalizar dirección del showroom activo (colonia/CP según Google Maps)
UPDATE public.showrooms_proyecto
SET descripcion_direccion = 'Av. Miguel Hidalgo y Costilla 1995, Ladrón de Guevara, 44600 Guadalajara, Jal.',
    fecha_actualizacion = now()
WHERE id_proyecto = 1453
  AND descripcion_direccion ILIKE '%Hidalgo%1995%'
  AND descripcion_direccion IS DISTINCT FROM 'Av. Miguel Hidalgo y Costilla 1995, Ladrón de Guevara, 44600 Guadalajara, Jal.';

-- 3. Normalizar dirección en configuración de citas
UPDATE public.configuracion_citas_proyectos
SET ubicacion_direccion = 'Av. Miguel Hidalgo y Costilla 1995, Ladrón de Guevara, 44600 Guadalajara, Jal.'
WHERE id_proyecto = 1453
  AND ubicacion_direccion IS DISTINCT FROM 'Av. Miguel Hidalgo y Costilla 1995, Ladrón de Guevara, 44600 Guadalajara, Jal.';
