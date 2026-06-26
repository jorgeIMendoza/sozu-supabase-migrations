y no funciona tu validacion de documentos jajaja, te mando la correcion:
# Fix `verificar-documento-identidad` — modelo Gemini inválido — 2026-06-25

## Problema

La edge function `verificar-documento-identidad` usa el modelo `google/gemini-3-flash-preview`
que **no existe** (Gemini 3 no está lanzado). El AI gateway devuelve error y la función
retorna 500. Afecta **dev y producción**.

## Fix — 1 línea en el código

Archivo: `supabase/functions/verificar-documento-identidad/index.ts`

```diff
- model: "google/gemini-3-flash-preview",
+ model: "google/gemini-2.0-flash",
```

> El archivo local ya tiene el fix aplicado (commit `729b9d60` en rama `dev-eddy`).

## Deploy a producción

Ejecutar desde la raíz del repo (con Supabase CLI autenticado):

```bash
supabase functions deploy verificar-documento-identidad --project-ref tzmhgfjmddkfyffkkmto
```

## Deploy a dev (VPS)

Desde el VPS o con CLI apuntando al self-hosted:

```bash
supabase functions deploy verificar-documento-identidad
```

## Verificar que funciona

Después del deploy, revisar en Supabase Dashboard → Edge Functions → `verificar-documento-identidad` → Logs.
No debe aparecer error 4xx/5xx del AI gateway.