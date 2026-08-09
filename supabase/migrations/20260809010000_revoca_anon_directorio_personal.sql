-- Corta la lectura anónima del Directorio de Personal (tablas heredadas)
-- Fecha: 2026-08-09
--
-- ─── Hallazgo (fuera del alcance de Ejecuciones/ejecusiones.md, se añade aquí) ──
-- `roles_organizacionales` y `puestos_organizacionales` tienen concedidos a `anon`
-- TODOS los privilegios (SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER)
-- — verificado read-only contra producción el 2026-08-09:
--
--   information_schema.role_table_grants
--     puestos_organizacionales | anon | DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE
--     roles_organizacionales   | anon | DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE
--
-- No viene de un GRANT explícito: son las default privileges de Supabase sobre `public`
-- (`postgres` concede `arwdDxtm` a anon/authenticated/service_role en cada tabla nueva).
--
-- `puestos_organizacionales` contiene sueldos, bonos y el correo del ocupante. Hoy la
-- fuga está contenida porque ambas tablas tienen RLS con una única policy dirigida a
-- `authenticated`: para `anon` no hay policy y el SELECT devuelve 0 filas. Pero el GRANT
-- sigue puesto, así que la primera policy permisiva (o un `FOR ALL TO public`) que alguien
-- añada abre la tabla entera al rol que viaja en el bundle público del front. Mismo
-- criterio que 20260806100000: se revoca el privilegio, no solo se confía en la policy.
--
-- ─── Por qué es seguro ────────────────────────────────────────────────────────
-- Único consumidor en el front (grep sobre `src/` del repo sozu-admin, rama
-- cambios_agente_alo): `useDirectorioPuestos.ts` y `DirectorioPuestosTab.tsx`, ambos del
-- panel /admin, que corren con sesión `authenticated`. Ninguna página de `src/pages/public/`
-- toca estas tablas. `useMotorComisionesSync.ts` solo las menciona en un comentario.
--
-- Idempotente (REVOKE sobre lo ya revocado no falla) y sin BEGIN/COMMIT.
--
-- NOTA: las tablas nuevas del modelo RRHH (personal_organizacional, personal_proyectos)
-- ya nacen sin `anon` — ver 20260809000000_directorio_personal_rrhh.sql, sección 4.

REVOKE ALL PRIVILEGES ON TABLE public.roles_organizacionales   FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.puestos_organizacionales FROM anon;

COMMENT ON TABLE public.roles_organizacionales IS
  'Catalogo de roles de empresa del Directorio de Personal (Estructura de Comisiones). '
  'Independiente de roles/usuarios.rol_id (auth y permisos). Sin acceso para el rol anon '
  'desde 20260809010000.';

-- ─── Validación (post-deploy, read-only) ──────────────────────────────────────
--   SELECT table_name, grantee, privilege_type
--   FROM information_schema.role_table_grants
--   WHERE table_schema = 'public'
--     AND table_name IN ('roles_organizacionales','puestos_organizacionales')
--     AND grantee = 'anon';
--   -- esperado: 0 filas
--
--   BEGIN; SET LOCAL ROLE anon;
--     SELECT count(*) FROM public.puestos_organizacionales;  -- esperado: permission denied
--   ROLLBACK;
--
-- El panel /admin -> Portal Estructura de Comisiones -> Directorio de Personal debe
-- seguir cargando igual (sesión authenticated).
