-- Fix: comisiones_reglas.id_rol de bigint FK -> text (sin FK)
-- Fecha: 2026-07-15
--
-- comisiones_reglas.id_rol se creo como bigint REFERENCES roles_organizacionales(id)
-- ("Directorio de Personal"). Pero el Motor de Comisiones (CommissionsTab) usa el catalogo
-- "Puestos y Sueldos" (StructureTab), 100% local (localStorage), con ids de texto tipo
-- 'role-dir-sozu'. Al guardar/sincronizar una regla se hacia Number('role-dir-sozu') -> NaN
-- y Postgres rechazaba con 22P02 (invalid input syntax for type bigint: "NaN"), mostrando el
-- toast "No se pudo guardar la regla de comision en el servidor".
--
-- Fix: id_rol pasa a text (sin FK). "Puestos y Sueldos" no tiene tabla propia hoy; el lado
-- puesto queda como id de texto del mock local (como ya funcionaba). Si a futuro se quiere
-- relacional/compartido, migrar "Puestos y Sueldos" a su tabla con id IDENTITY (aparte).
--
-- Idempotente: DROP CONSTRAINT IF EXISTS + ALTER TYPE (USING). Sin BEGIN/COMMIT (CI/CD en tx).

ALTER TABLE public.comisiones_reglas
  DROP CONSTRAINT IF EXISTS comisiones_reglas_id_rol_fkey;

ALTER TABLE public.comisiones_reglas
  ALTER COLUMN id_rol TYPE text USING id_rol::text;
