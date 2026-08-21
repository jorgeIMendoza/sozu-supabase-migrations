-- =============================================================================
-- personas_relacionadas: UNIQUE parcial por vínculo ACTIVO + rol ADMINISTRADOR_CUENTA
-- =============================================================================
-- El UNIQUE actual `(id_persona, id_persona_relacion, id_tipo_relacion)` sin `WHERE
-- activo` significa que un trío existe UNA vez en la historia de la tabla. Revocar un
-- acceso delegado (activo=false) y volver a otorgarlo choca con 23505, y la única salida
-- sería un UPDATE que resucite la fila muerta, sobrescribiendo la bitácora de la
-- revocación — que es justo la evidencia que respalda a SOZU si alguien reclama el
-- acceso. Mismo problema con un accionista que sale y vuelve a entrar con otro
-- porcentaje: ya está roto hoy, solo que sin datos nadie lo ha pegado.
--
-- Se hace ahora porque la tabla está VACÍA en prod. Con datos encima, esto es un DROP
-- con deduplicación previa.
--
-- Además abre `ADMINISTRADOR_CUENTA` en `tipos_relacion`: el acceso delegado (familiar,
-- abogado, contador de un titular) es una clave del catálogo, no una tabla nueva.
--
-- ─── Verificado read-only el 2026-08-20 (prod tzmhgfjmddkfyffkkmto y dev) ─────
-- · personas_relacionadas: 0 filas en prod, 1 fila de prueba en dev. Nada que deduplicar.
-- · Owner `postgres` en los dos entornos → el ALTER TABLE no truena con 42501.
-- · `tipos_relacion_clave_uniq (clave) WHERE clave IS NOT NULL` YA existe
--   (20260813160000). NO se crea otro índice para lo mismo.
-- · `tipos_relacion.clave` con CHECK `^[A-Z][A-Z0-9_]*$` → 'ADMINISTRADOR_CUENTA' pasa.
-- · `tipos_relacion.id` es IDENTITY BY DEFAULT y hay UNIQUE (nombre): el id nuevo NO va a
--   coincidir entre dev y prod. El código ya resuelve por `clave`, nunca por id.
-- · `tipos_relacion.tipo`: las filas de rol persona↔persona usan 'el' (Representante
--   Legal, Accionista, Empleado). Se sigue esa convención.
-- · Índices existentes en personas_relacionadas: `idx_personas_relacionadas_persona_activo
--   (id_persona, activo)` e `idx_personas_relacionadas_relacion (id_persona_relacion)`.
--   Se conservan; los nombres nuevos son distintos a propósito (ver §4).
-- · Triggers `trg_personas_relacionadas_fecha` y `trg_personas_relacionadas_sin_ciclo`,
--   y los dos CHECK, quedan intactos.
--
-- ─── Fuera de alcance, a propósito ───────────────────────────────────────────
-- · Las 13 filas de `tipos_relacion` con clave NULL. Cada una es una decisión de negocio
--   y ninguna tiene consumidor; mientras sigan NULL son inertes. Inventar claves crea
--   vocabulario que después alguien usa creyendo que significa algo.
-- · La fila 6 'Administrador' NO se reutiliza: nombre ambiguo y choca semánticamente con
--   `tipos_entidad.20`, que también se llama 'Administrador' y significa otra cosa.
-- · `entidades_relacionadas` (111 vínculos activos) no se toca: es otro eje,
--   persona↔proyecto.
-- · Backfill de `personas.id_entidad_relacionada_rep_leg` / `_rep_com`: DML con criterio,
--   va aparte.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1. Documentar `clave` como el contrato con el código
-- -----------------------------------------------------------------------------
-- El UNIQUE parcial ya existe (tipos_relacion_clave_uniq). Solo se precisa el COMMENT.
COMMENT ON COLUMN public.tipos_relacion.clave IS
  'Identificador estable del rol, en MAYUSCULAS_CON_GUION_BAJO. Es por lo que el código '
  'resuelve el tipo (nunca por id ni por nombre: el id difiere entre entornos). '
  'NULL = fila del catálogo sin consumidor. Inmutable una vez asignada '
  '(trg_tipos_relacion_clave_inmutable).';

-- -----------------------------------------------------------------------------
-- §2. Rol nuevo: administrador de cuenta (acceso delegado)
-- -----------------------------------------------------------------------------
-- Se usa WHERE NOT EXISTS y no `ON CONFLICT (clave)`: el único índice sobre `clave` es
-- PARCIAL, y la inferencia del arbiter exige repetir su predicado, si no falla con 42P10.
INSERT INTO public.tipos_relacion (clave, nombre, tipo, activo)
SELECT 'ADMINISTRADOR_CUENTA', 'Administrador de cuenta', 'el', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.tipos_relacion WHERE clave = 'ADMINISTRADOR_CUENTA'
);

-- -----------------------------------------------------------------------------
-- §3. UNIQUE parcial: un vínculo ACTIVO por trío, históricos acumulables
-- -----------------------------------------------------------------------------
ALTER TABLE public.personas_relacionadas
  DROP CONSTRAINT IF EXISTS personas_relacionadas_unica;

CREATE UNIQUE INDEX IF NOT EXISTS uq_personas_relacionadas_activa
  ON public.personas_relacionadas (id_persona, id_persona_relacion, id_tipo_relacion)
  WHERE activo;

COMMENT ON INDEX public.uq_personas_relacionadas_activa IS
  'Un solo vínculo ACTIVO por (persona, relacionada, tipo). Parcial a propósito: los '
  'vínculos dados de baja se conservan como historial y el mismo trío puede volver a '
  'otorgarse. Reemplaza a personas_relacionadas_unica, que lo hacía imposible.';

-- El comentario de la tabla decía "reactivar la fila existente (UPDATE)". Ya no aplica.
COMMENT ON COLUMN public.personas_relacionadas.activo IS
  'Baja lógica. Nunca se borra: los documentos de esa persona siguen colgando de ella, y '
  'la fila inactiva es la bitácora de la revocación. Volver a otorgar el mismo vínculo se '
  'hace con un INSERT nuevo, NO reactivando la fila vieja.';

-- -----------------------------------------------------------------------------
-- §4. Lectura por el lado de la persona relacionada
-- -----------------------------------------------------------------------------
-- El portal pregunta "a quién administro yo" filtrando por id_persona_relacion + tipo +
-- activo. El índice existente `idx_personas_relacionadas_relacion` es solo
-- (id_persona_relacion) y no lleva el tipo. El otro lado ("quién me administra") lo cubre
-- ya el prefijo de uq_personas_relacionadas_activa.
--
-- Nombre nuevo a propósito: `idx_personas_relacionadas_relacion_activo` no colisiona con
-- nada, mientras que reusar `idx_personas_relacionadas_persona_activo` habría sido un
-- no-op silencioso — CREATE INDEX IF NOT EXISTS matchea por NOMBRE, no por definición.
CREATE INDEX IF NOT EXISTS idx_personas_relacionadas_relacion_activo
  ON public.personas_relacionadas (id_persona_relacion, id_tipo_relacion)
  WHERE activo;

-- -----------------------------------------------------------------------------
-- §5. Self-verifying: si algo de lo anterior no quedó, se aborta la migración
-- -----------------------------------------------------------------------------
DO $verifica$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.personas_relacionadas'::regclass
      AND conname  = 'personas_relacionadas_unica'
  ) THEN
    RAISE EXCEPTION 'personas_relacionadas_unica sigue existiendo: el DROP no aplicó';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indexrelid = 'public.uq_personas_relacionadas_activa'::regclass
      AND i.indisunique
      AND i.indpred IS NOT NULL          -- tiene que ser PARCIAL, si no no sirve de nada
  ) THEN
    RAISE EXCEPTION 'uq_personas_relacionadas_activa no existe o no es UNIQUE parcial';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.tipos_relacion
    WHERE clave = 'ADMINISTRADOR_CUENTA' AND activo
  ) THEN
    RAISE EXCEPTION 'falta el tipo ADMINISTRADOR_CUENTA en tipos_relacion';
  END IF;

  -- Los CHECK y los dos triggers de siempre no se tocaron.
  IF (SELECT count(*) FROM pg_constraint
        WHERE conrelid = 'public.personas_relacionadas'::regclass AND contype = 'c') <> 2
  THEN
    RAISE EXCEPTION 'los CHECK de personas_relacionadas cambiaron';
  END IF;

  IF (SELECT count(*) FROM pg_trigger
        WHERE tgrelid = 'public.personas_relacionadas'::regclass AND NOT tgisinternal) <> 2
  THEN
    RAISE EXCEPTION 'los triggers de personas_relacionadas cambiaron';
  END IF;
END
$verifica$;

COMMIT;
