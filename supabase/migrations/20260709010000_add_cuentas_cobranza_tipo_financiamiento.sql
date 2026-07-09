-- cuentas_cobranza.tipo_financiamiento — versionar columna que faltaba en dev
-- Fecha: 2026-07-09
--
-- El flujo "Pago final" (portal admin y ahora el app cliente vía cliente-pago-final /
-- cliente-propiedad-detalle) lee y escribe cuentas_cobranza.tipo_financiamiento con
-- valores 'RECURSOS_PROPIOS' | 'CREDITO_HIPOTECARIO'. La columna existe en PROD (se
-- agregó a mano allá) pero NUNCA se versionó como migración, por lo que DEV no la tiene
-- (drift). El spec del feature decía "SQL nada que ejecutar" asumiendo que ya existía.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS → crea en dev, no-op en prod. text nullable
-- (el front la maneja graceful; sin CHECK para no divergir de la definición de prod).

ALTER TABLE public.cuentas_cobranza
  ADD COLUMN IF NOT EXISTS tipo_financiamiento text;
