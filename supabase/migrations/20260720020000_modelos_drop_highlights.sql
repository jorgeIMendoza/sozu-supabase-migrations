-- Elimina modelos.highlights (jsonb) — sección "Esto la hace especial" removida de la oferta
-- Fecha: 2026-07-20
--
-- La sección se quitó de la oferta digital (las amenidades ya comunican lo destacado).
-- El front ya no lee ni escribe la columna (OfferPage.tsx, use-offer-db.ts,
-- EditModeloDialog.tsx, NewModeloDialog.tsx).
--
-- Verificado read-only contra prod 2026-07-20:
--  - 4329 modelos, 4318 con valor no-nulo pero 0 con contenido real (todos []/{}/null)
--    => no se pierde información útil.
--  - Ninguna vista/regla depende de la columna (pg_depend/pg_rewrite).
--  - Ninguna función plpgsql/sql referencia 'highlights' en su cuerpo.
--
-- Idempotente: DROP COLUMN IF EXISTS.

ALTER TABLE public.modelos DROP COLUMN IF EXISTS highlights;
