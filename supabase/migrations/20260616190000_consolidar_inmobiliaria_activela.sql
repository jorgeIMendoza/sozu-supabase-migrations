-- Consolida la inmobiliaria "Activela Grupo Inmobiliario" duplicada en prod.
--
-- Problema: existen DOS personas para la misma inmobiliaria:
--   - 421  (canónica; usuario de acceso asesor@activeinmobiliaria.mx -> id_persona 421;
--            entidad inmobiliaria tipo 5 = id 421)
--   - 2833 (duplicada; entidad inmobiliaria tipo 5 = id 4021)
-- El resolver de personaId (useInmobiliariaPersonaId) devuelve 421, por lo que los
-- agentes creados con id_persona_duena_lead = 2833 (p. ej. Esteban Camarena) NO aparecían
-- en la lista de agentes de la inmobiliaria, aunque su alta fue exitosa.
--
-- Fix: reasignar todo lo colgado de 2833 a la persona canónica 421 y desactivar la
-- entidad inmobiliaria duplicada. Idempotente. En entornos sin estos ids (dev) los
-- UPDATE hacen match 0 -> inofensivo.

-- 1. Reasignar agentes/leads de la inmobiliaria duplicada (2833) a la canónica (421)
UPDATE public.entidades_relacionadas
SET id_persona_duena_lead = 421,
    fecha_actualizacion = now()
WHERE id_persona_duena_lead = 2833;

-- 2. Desactivar la entidad inmobiliaria (tipo 5) duplicada de la persona 2833
UPDATE public.entidades_relacionadas
SET activo = false,
    fecha_actualizacion = now()
WHERE id_persona = 2833
  AND id_tipo_entidad = 5
  AND activo = true;
