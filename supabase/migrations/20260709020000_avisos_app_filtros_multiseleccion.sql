-- avisos_app: filtros de multiselección (proyectos/modelos/propiedades en cascada)
-- Fecha: 2026-07-09
--
-- La nueva versión de la edge function admin-avisos-app permite filtrar el destinatario
-- por VARIOS proyectos/modelos/propiedades (arrays) en lugar de uno solo. La tabla se
-- creó (20260708050000) con columnas singulares id_proyecto/id_modelo/id_propiedad, que
-- ya no usa la función. Se agregan las columnas array y se quitan las singulares.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS + DROP COLUMN IF EXISTS. Tabla nueva sin datos
-- que dependan de las columnas singulares. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

ALTER TABLE public.avisos_app
  ADD COLUMN IF NOT EXISTS ids_proyectos   integer[],
  ADD COLUMN IF NOT EXISTS ids_modelos     integer[],
  ADD COLUMN IF NOT EXISTS ids_propiedades bigint[];

ALTER TABLE public.avisos_app
  DROP COLUMN IF EXISTS id_proyecto,
  DROP COLUMN IF EXISTS id_modelo,
  DROP COLUMN IF EXISTS id_propiedad;
