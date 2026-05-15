-- Fix esquema_pago 1050 (Escalonado)
-- Pone en cero los campos de % que el escalonado anula y registra el tramo
-- único de 31 mensualidades de $25,000 (jun-2026 → dic-2028).

UPDATE public.esquemas_pago
SET
  porcentaje_mensualidades = 0,
  porcentaje_entrega       = 0,
  numero_mensualidades     = 0,
  tramos_mensualidad = '[
    {"orden":1,"numero_mensualidades":31,"monto_mensualidad":2500000,"fecha_limite":"2028-12-31"}
  ]'::jsonb,
  fecha_actualizacion = now()
WHERE id = 1050;
