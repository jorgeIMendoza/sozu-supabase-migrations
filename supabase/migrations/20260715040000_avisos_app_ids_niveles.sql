-- Avisos: filtro por Nivel (numero_piso) — columna ids_niveles en avisos_app
-- Fecha: 2026-07-15
--
-- Nueva cascada en "Enviar avisos": Proyecto → Modelo → Nivel → Propiedad. El nivel es el
-- valor de propiedades.numero_piso (sin catálogo propio). ids_niveles integer[] null = sin
-- filtro, mismo patrón que ids_proyectos/ids_modelos.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS. Sin BEGIN/COMMIT (CI/CD envuelve en tx).

ALTER TABLE public.avisos_app
  ADD COLUMN IF NOT EXISTS ids_niveles integer[] NULL;
