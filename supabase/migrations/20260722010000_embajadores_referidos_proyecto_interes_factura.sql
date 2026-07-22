-- embajadores_referidos · columnas id_proyecto_interes + url_factura
-- Fecha: 2026-07-22
--
-- Formaliza dos ALTER TABLE de Ejecuciones/ejecutar.md (2026-06-08 y 2026-06-11):
--   · id_proyecto_interes: proyecto de interés del referido (FK a proyectos), para el
--     formulario de registro de referidos.
--   · url_factura: URL de la factura que el embajador sube/ve/modifica desde la pestaña
--     Comisiones del portal.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

ALTER TABLE public.embajadores_referidos
  ADD COLUMN IF NOT EXISTS id_proyecto_interes integer REFERENCES public.proyectos(id),
  ADD COLUMN IF NOT EXISTS url_factura         text;
