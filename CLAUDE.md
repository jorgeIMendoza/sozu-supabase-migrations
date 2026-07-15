# Reglas del repositorio `sozu-supabase-migrations`

## 0. Solo lectura y validación. NUNCA ejecución directa a la DB

Rol por defecto = **read-only + validación**. Prohibido escribir/mutar cualquier DB
(dev VPS, prod cloud, branches) por fuera del flujo de migraciones + CI. Esto incluye,
sin excepción:

- `CREATE/ALTER/DROP`, `CREATE OR REPLACE`, `INSERT/UPDATE/DELETE`, `EXECUTE`, bloques `DO`.
- `mcp__…Supabase__apply_migration`, `execute_sql` con DDL/DML, `deploy_edge_function`,
  `merge_branch`, etc.
- `ssh sozu-dev` + `docker exec … psql`, o cualquier `psql`/cliente que **escriba**.
- Tocar `supabase_migrations.schema_migrations` a mano.

**Permitido sin OK:** leer esquema/datos, `pg_get_functiondef`, `md5`, `SELECT`, comparar
dev↔prod, y **preparar** el trabajo (crear/editar el archivo de migración en el repo).

Todo cambio de DB va **siempre** como archivo en `supabase/migrations/` y se aplica por el
**CI** (`supabase db push` en deploy-dev / deploy-prod). Nunca aplicar el SQL a mano "para
verificar" — usar una DB desechable/transacción con ROLLBACK solo si el usuario lo autoriza.
Las migraciones que reemplazan funciones deben ser **self-verifying** (abortar si el anchor
no matchea) e **idempotentes** (guard/`IF NOT EXISTS`) para no romper el CI ni duplicar.

> Precedente (2026-07-13): apliqué E.3 con `docker exec psql` directo al VPS de dev —
> fuera de rol y saltando CI. No repetir. El fix correcto fue archivo de migración guarded.

## 1. Nada de commit/push/PR/merge/deploy sin OK explícito

Autorización **por acción**. Cada `git commit`, `git push` a rama de CI, `gh pr create`,
merge y **deploy** (incluido deploy directo por MCP a prod/dev) requiere el OK explícito
del usuario **antes** de ejecutarlo. Este repo lo usan varias personas: si el usuario
no te autoriza explícitamente esa acción, no la ejecutes.

- Preparar el trabajo (editar archivos, dejar la migración/rama lista) está bien.
- Un OK es solo para **esa** acción; **no** se extiende a los siguientes pasos.
  Autorizar un PR NO autoriza el siguiente PR ni el merge ni el deploy.
- Flujo de trabajo: dejar todo listo → preguntar "¿lo mando? / ¿abro el PR? / ¿despliego?"
  → esperar el sí.

## 2. Cuestionar; no asumir que la instrucción es correcta al 100%

No todo lo que se pide es correcto. Antes de ejecutar, **avisar** si algo:

- **Seguridad:** expone datos por RLS/SECURITY DEFINER, permite enumeración, filtra PII,
  otorga permisos de más, etc.
- **Ya existe:** la función/tabla/columna ya está, o el cambio duplica algo.
- **Está mal:** el SQL calcula mal, ignora un formato de datos real, revierte un fix previo,
  rompe una invariante de negocio, etc.

Verificar contra el esquema/datos reales (MCP read-only) antes de afirmar. Proponer la
**mejor opción** con su porqué y dejar que el usuario decida; no ejecutar a ciegas.

## Contexto de despliegue

- Migraciones SQL van en este repo; los cambios de edge functions van en `sozu-edge-functions`.
- dev y prod deben quedar idénticos (md5). Base los `CREATE OR REPLACE` en la definición
  viva (fuente de verdad), no solo en el archivo del repo (puede tener drift).
- Verificación de dinero/negocio: validar read-only contra prod antes de proponer el deploy.
