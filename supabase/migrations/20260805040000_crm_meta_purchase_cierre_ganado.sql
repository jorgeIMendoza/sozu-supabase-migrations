-- Siembra el mapeo "Cierre Ganado (Negocio) -> Purchase" en el catalogo gestionable
-- crm_meta_conversion_stages, DESACTIVADO por default (activo=false) para no
-- doble-contar con HubSpot durante la transicion. Se prende desde la UI (pestana
-- "Eventos de conversion") tras el corte de HubSpot. Idempotente.
-- id se omite: la columna es IDENTITY y se autogenera.

BEGIN;

INSERT INTO public.crm_meta_conversion_stages (etapa_ciclo_vida, meta_event_name, activo, orden)
SELECT 'cierre_ganado', 'Purchase', false, 60
WHERE NOT EXISTS (
  SELECT 1 FROM public.crm_meta_conversion_stages WHERE etapa_ciclo_vida = 'cierre_ganado'
);

COMMIT;
