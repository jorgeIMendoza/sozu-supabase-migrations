-- Fix: GeorgIA (MCP sozu-db) lee 0 filas en las tablas operativas con RLS.
--
-- Causa: la conexión MCP entra como el rol `georgia_readonly`, pero las 159
-- políticas de lectura de RLS (`georgia_mcp_ro_select`, qual = true) apuntan al
-- rol `georgia_mcp_ro`. Una política permissiva solo aplica si el rol de sesión
-- ES el rol de la política o es MIEMBRO de él. `georgia_readonly` no es miembro
-- de `georgia_mcp_ro`, así que ninguna política aplica y todo SELECT sobre esas
-- tablas devuelve 0 filas (sin error).
--
-- Comprobado en prod (SET ROLE):
--   georgia_readonly -> proyectos=0     propiedades=0     cuentas_cobranza=0
--   georgia_mcp_ro   -> proyectos=1043  propiedades=53941 cuentas_cobranza=1789
--
-- Solución (Opción A): hacer a `georgia_readonly` miembro de `georgia_mcp_ro`
-- para que las 159 políticas `georgia_mcp_ro_select` apliquen por herencia de
-- membresía. Se mantiene solo lectura: ninguno de los dos roles tiene
-- BYPASSRLS ni privilegios de escritura.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'georgia_readonly') THEN
    RAISE NOTICE 'Rol georgia_readonly no existe; se omite el GRANT.';
    RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'georgia_mcp_ro') THEN
    RAISE NOTICE 'Rol georgia_mcp_ro no existe; se omite el GRANT.';
    RETURN;
  END IF;

  -- Idempotente: GRANT sobre una membresía ya existente no falla.
  GRANT georgia_mcp_ro TO georgia_readonly;
  RAISE NOTICE 'georgia_readonly ahora es miembro de georgia_mcp_ro.';
END $$;

-- Verificación post-migración (manual):
--   SELECT pg_has_role('georgia_readonly','georgia_mcp_ro','MEMBER');  -- true
--   SET ROLE georgia_readonly;
--   SELECT count(*) FROM proyectos;         -- > 0
--   SELECT count(*) FROM cuentas_cobranza;  -- > 0
--   RESET ROLE;
