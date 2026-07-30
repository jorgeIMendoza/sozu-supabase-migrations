-- Auditoría · Objetos de `public` cuyo dueño el CI no puede alcanzar
-- Fecha: 2026-07-29
--
-- MOTIVO
--   Dos migraciones abortaron ya por lo mismo, con horas de diferencia:
--     20260729204501  WARNING 01006 "no privileges could be revoked for user_has_role"
--                     → public.user_has_role(text,integer) pertenece a supabase_admin
--     20260729224501  ERROR 42501 "must be owner of table _bak_personas_ocupacion_20260722"
--                     → esa tabla pertenece a otro rol
--
--   El CI entra como `postgres`. Un objeto cuyo dueño no sea alcanzable desde ese rol no se
--   puede alterar: ni ENABLE ROW LEVEL SECURITY, ni CREATE POLICY, ni REVOKE efectivo, ni
--   CREATE OR REPLACE. Cada migración que lo toque falla o se convierte en no-op silencioso.
--
--   Verificado read-only contra prod (tzmhgfjmddkfyffkkmto): los 891 objetos de public
--   —456 relaciones, 245 tipos, 190 funciones— pertenecen a postgres. El drift es
--   exclusivo del dev self-hosted, y no había forma de inventariarlo desde fuera: por eso
--   la auditoría corre dentro del deploy y reporta en el log del CI de cada entorno.
--
-- QUÉ HACE Y QUÉ NO
--   SOLO AUDITA. No reasigna dueños, a propósito:
--     · Cambiar el dueño de una función SECURITY DEFINER cambia los privilegios con los que
--       se ejecuta. Sería una modificación de seguridad encubierta dentro de una migración
--       que dice "auditar".
--     · Los casos que importan (dueño supabase_admin) el CI no los puede reasignar igual:
--       ALTER ... OWNER TO exige ser el dueño actual o superusuario.
--   Emite un WARNING con el inventario y el comando de remediación por objeto. En prod es
--   no-op silencioso. En dev deja el problema a la vista en cada deploy hasta que se
--   resuelva con privilegios de supabase_admin.
--
--   Para las tablas añade el dato que decide la urgencia: si están expuestas a anon y si
--   tienen RLS apagado. Una tabla de dueño ajeno, sin RLS y con GRANT a anon es un agujero
--   abierto que ninguna migración de este repo puede cerrar.
--
-- Sin efectos secundarios: no modifica nada, así que es idempotente por construcción y
-- segura de re-ejecutar. Sin BEGIN/COMMIT (el CI envuelve en transacción).

DO $$
DECLARE
  r          record;
  v_reporte  text := '';
  n_total    int  := 0;
  n_criticas int  := 0;
BEGIN
  FOR r IN
    -- Relaciones: tablas, vistas, materializadas, secuencias, foráneas
    SELECT
      CASE c.relkind
        WHEN 'r' THEN 'TABLE' WHEN 'p' THEN 'TABLE'
        WHEN 'v' THEN 'VIEW'  WHEN 'm' THEN 'MATERIALIZED VIEW'
        WHEN 'S' THEN 'SEQUENCE' WHEN 'f' THEN 'FOREIGN TABLE'
      END                                        AS clase,
      format('%I.%I', n.nspname, c.relname)      AS obj,
      pg_get_userbyid(c.relowner)                AS duenio,
      -- Solo aplica a tablas: expuesta a anon y sin RLS
      (c.relkind IN ('r','p')
        AND NOT c.relrowsecurity
        AND (has_table_privilege('anon', c.oid, 'SELECT')
          OR has_table_privilege('anon', c.oid, 'INSERT')
          OR has_table_privilege('anon', c.oid, 'UPDATE')
          OR has_table_privilege('anon', c.oid, 'DELETE'))) AS critica
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r','p','v','m','S','f')
      AND NOT pg_has_role(current_user, c.relowner, 'USAGE')

    UNION ALL

    -- Funciones y procedimientos
    SELECT
      CASE p.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
      p.oid::regprocedure::text,
      pg_get_userbyid(p.proowner),
      -- Crítica si además es SECURITY DEFINER y anon puede ejecutarla
      (p.prosecdef AND has_function_privilege('anon', p.oid, 'EXECUTE'))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND NOT pg_has_role(current_user, p.proowner, 'USAGE')

    ORDER BY 4 DESC, 1, 2
  LOOP
    n_total := n_total + 1;
    IF r.critica THEN n_criticas := n_criticas + 1; END IF;

    v_reporte := v_reporte || format(
      E'\n  %s%-18s %-55s dueño: %s',
      CASE WHEN r.critica THEN '[EXPUESTO A ANON] ' ELSE '' END,
      r.clase, r.obj, r.duenio);
  END LOOP;

  IF n_total = 0 THEN
    RAISE NOTICE 'Auditoría de propiedad OK: los objetos de public son alcanzables desde %',
      current_user;
    RETURN;
  END IF;

  RAISE WARNING E'% objeto(s) de public con dueño NO alcanzable desde %, de los cuales % siguen expuestos a anon.\nNinguna migración de este repo puede alterarlos: fallan con 42501, o el REVOKE queda en no-op con WARNING 01006.%\n\nRemediación (requiere privilegios del dueño actual o superusuario, fuera del CI):\n  ALTER TABLE public.<tabla> OWNER TO postgres;\n  ALTER FUNCTION public.<funcion>(<args>) OWNER TO postgres;\nEn el dev self-hosted se ejecuta como supabase_admin. Después, re-desplegar las\nmigraciones que hayan quedado en no-op sobre esos objetos.',
    n_total, current_user, n_criticas, v_reporte;
END $$;
