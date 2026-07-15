-- P28 D.3 — RP: renombrar get_relacion_pagos -> get_pcobranza_relacion_pagos
-- ---------------------------------------------------------------------------
-- Estándar de nombres del portal cobranza: prefijo get_pcobranza_* (cuentas_cobranza,
-- inmuebles, complementos). Ésta era la única sin prefijo. Solo cambia el nombre;
-- firma y cuerpo intactos (ALTER RENAME preserva grants y definición). El front
-- (useRelacionPagos) ya llama al nombre nuevo.
--
-- Sin callers en DB (verificado: ninguna función public referencia get_relacion_pagos).
-- Guarded + idempotente: no-op si ya está renombrada; aborta si falta el objeto origen.

DO $mig$
BEGIN
  IF to_regprocedure('public.get_pcobranza_relacion_pagos(integer,integer,integer,text,text,text,text,text[],text[])') IS NOT NULL THEN
    RAISE NOTICE 'get_pcobranza_relacion_pagos ya existe — no-op';
    RETURN;
  END IF;

  IF to_regprocedure('public.get_relacion_pagos(integer,integer,integer,text,text,text,text,text[],text[])') IS NULL THEN
    RAISE EXCEPTION 'get_relacion_pagos(...) no existe — nada que renombrar';
  END IF;

  ALTER FUNCTION public.get_relacion_pagos(
    integer,   -- p_proyecto_id
    integer,   -- p_limit
    integer,   -- p_offset
    text,      -- p_clabe
    text,      -- p_cliente
    text,      -- p_unidad
    text,      -- p_cuenta
    text[],    -- p_tipos
    text[]     -- p_estatus
  ) RENAME TO get_pcobranza_relacion_pagos;
END
$mig$;
