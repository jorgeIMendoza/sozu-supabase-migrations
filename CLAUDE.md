# Reglas del repositorio `sozu-supabase-migrations`

## 1. Nada de commit/push/PR/merge/deploy sin OK explícito

Autorización **por acción**. Cada `git commit`, `git push` a rama de CI, `gh pr create`,
merge y **deploy** (incluido deploy directo por MCP a prod/dev) requiere el OK explícito
de Eduardo **antes** de ejecutarlo.

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
**mejor opción** con su porqué y dejar que Eduardo decida; no ejecutar a ciegas.

## Contexto de despliegue

- Migraciones SQL van en este repo; los cambios de edge functions van en `sozu-edge-functions`.
- dev y prod deben quedar idénticos (md5). Base los `CREATE OR REPLACE` en la definición
  viva (fuente de verdad), no solo en el archivo del repo (puede tener drift).
- Verificación de dinero/negocio: validar read-only contra prod antes de proponer el deploy.
