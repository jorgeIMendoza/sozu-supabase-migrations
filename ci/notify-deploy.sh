#!/usr/bin/env bash
# Notifica por WhatsApp (vía webhook de n8n) cuando termina un deploy.
#
# Destinatarios:
#   - DEV:  autor del PR que entró a `dev` (commit que disparó el deploy) + admin.
#   - PROD: TODOS los autores de PRs mergeados a `dev` desde el último deploy
#           a prod (HEAD^1 del merge actual) + admin.
#
# Autor real: si el PR contiene "<!-- pr_author: <login> -->" en el body
# (embebido por el dashboard al crear el PR), se usa ese login en lugar del
# creador del PR (que siempre es jorgeIMendoza en repos de infra).
#
# El teléfono (10 dígitos) del autor se lee de Firestore:
#   contributors/{githubLogin}.telefonoWhatsapp  ->  se envía como +521<telefono>
# El admin es un número fijo (ADMIN_PHONE).
#
# Requiere en el entorno:
#   ENVIRONMENT       DEV | PROD
#   GITHUB_REPOSITORY owner/repo            (lo inyecta GitHub Actions)
#   GITHUB_SHA        commit que disparó    (lo inyecta GitHub Actions)
#   GH_TOKEN          token con lectura de PRs (secrets.GITHUB_TOKEN basta)
#   FIRESTORE_PROJECT id del proyecto Firebase con los teléfonos (sozu-admin-dev)
#   N8N_WEBHOOK       URL del webhook
#   N8N_APIKEY        apikey del webhook
#   ADMIN_PHONE       (opcional) número admin E.164. Default +5217221514185
# Y autenticación gcloud activa al proyecto FIRESTORE_PROJECT (auth previo).
set -euo pipefail

: "${ENVIRONMENT:?falta ENVIRONMENT}"
: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_SHA:?}"
: "${GH_TOKEN:?}"
: "${FIRESTORE_PROJECT:?}"
: "${N8N_WEBHOOK:?}"
: "${N8N_APIKEY:?}"
ADMIN_PHONE="${ADMIN_PHONE:-+5217221514185}"
REPO_NAME="${GITHUB_REPOSITORY##*/}"

STATUS="${STATUS:-success}"
RUN_URL="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-}"
if [ "$STATUS" = "success" ]; then
  MENSAJE="Ha quedado listo tu deploy en ${ENVIRONMENT} del repo ${REPO_NAME}, puedes revisar"
else
  MENSAJE="FALLO el deploy en ${ENVIRONMENT} del repo ${REPO_NAME}. Logs: ${RUN_URL}"
fi

API="https://api.github.com"
gh_api() { curl -s -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

send_wa() { # $1 = teléfono E.164 ; $2 = etiqueta para log
  curl -s -X POST "$N8N_WEBHOOK" \
    -H "apikey: $N8N_APIKEY" \
    -H "Content-Type: application/json" \
    -d "{\"tipo\":\"wa\",\"telefono\":\"$1\",\"mensajeWA\":\"${MENSAJE}\",\"instanciaWA\":\"Pruebas de todo\"}" \
    >/dev/null && echo "Notificado $2 ($1)" || echo "Fallo al notificar $2 ($1)"
}

# Extrae TODOS los logins del body del PR con líneas <!-- pr_author: login -->
# (el dashboard embebe una línea por autor real de los commits).
# $1 = body en base64 (para evitar problemas con caracteres especiales)
extract_pr_authors_b64() {
  printf '%s' "$1" | base64 -d 2>/dev/null \
    | grep -oP '(?<=<!-- pr_author: )[\w.-]+(?= -->)' 2>/dev/null | sort -u || true
}

# Agrega al array logins todos los autores del PR: los pr_author del body,
# o el creador del PR si no hay marcadores.
add_pr_authors() { # $1 = login creador ; $2 = body en base64
  local marcados
  marcados="$(extract_pr_authors_b64 "$2")"
  if [ -n "$marcados" ]; then
    while IFS= read -r l; do [ -n "$l" ] && logins+=("$l"); done <<< "$marcados"
  elif [ -n "$1" ]; then
    logins+=("$1")
  fi
}

logins=()
if [ "$ENVIRONMENT" = "PROD" ]; then
  # PROD: notificar a TODOS los autores de PRs mergeados a dev desde el último
  # deploy a prod. HEAD^1 = tip de main antes de este merge = fecha del deploy
  # anterior a prod. Todos los PRs a dev mergeados DESPUÉS de esa fecha son
  # "nuevos" en este release.
  PREV_MAIN_DATE="$(git log HEAD^1 --format="%cI" -1 2>/dev/null || true)"
  if [ -n "$PREV_MAIN_DATE" ]; then
    echo "Buscando PRs a dev mergeados después de: ${PREV_MAIN_DATE}"
    PROD_PRS="$(gh_api "$API/repos/$GITHUB_REPOSITORY/pulls?state=closed&base=dev&sort=updated&direction=desc&per_page=50")"
    # Procesar cada PR: todos los pr_author del body (o el creador si no hay)
    while IFS=$'\t' read -r login body_b64; do
      add_pr_authors "$login" "$body_b64"
    done < <(echo "$PROD_PRS" | jq -r --arg since "$PREV_MAIN_DATE" \
      '[.[] | select(.merged_at != null and .merged_at > $since)] | .[] |
       [.user.login, (.body // "" | @base64)] | @tsv')
    # Deduplicar
    mapfile -t logins < <(printf '%s\n' "${logins[@]}" | awk 'NF' | sort -u)
    echo "Autores a notificar (${#logins[@]}): ${logins[*]:-ninguno}"
  else
    # Fallback: solo el último PR mergeado a dev
    echo "No se pudo obtener fecha del deploy anterior; usando último PR a dev."
    PR_JSON="$(gh_api "$API/repos/$GITHUB_REPOSITORY/pulls?state=closed&base=dev&sort=updated&direction=desc&per_page=10" \
        | jq -r '[.[] | select(.merged_at != null)] | .[0]')"
    a="$(echo "$PR_JSON" | jq -r '.user.login // empty')"
    body_b64="$(echo "$PR_JSON" | jq -r '.body // "" | @base64')"
    add_pr_authors "$a" "$body_b64"
  fi
else
  # DEV: todos los autores del PR que entró en este push.
  PR_JSON="$(gh_api "$API/repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" \
      | jq -r '[.[] | select(.merged_at != null)] | .[0]')"
  a="$(echo "$PR_JSON" | jq -r '.user.login // empty')"
  body_b64="$(echo "$PR_JSON" | jq -r '.body // "" | @base64')"
  add_pr_authors "$a" "$body_b64"
fi

ACCESS_TOKEN="$(gcloud auth print-access-token)"

if [ "${#logins[@]}" -gt 0 ]; then
  mapfile -t recipients < <(printf '%s\n' "${logins[@]}" | awk 'NF' | sort -u)
  for login in "${recipients[@]}"; do
    phone="$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
      "https://firestore.googleapis.com/v1/projects/$FIRESTORE_PROJECT/databases/(default)/documents/contributors/$login" \
      | jq -r '.fields.telefonoWhatsapp.stringValue // empty')"
    if [ -n "$phone" ]; then
      send_wa "+521$phone" "$login"
    else
      echo "Sin teléfono guardado para '$login' en contributors; se omite."
    fi
  done
else
  echo "No se encontró autor de PR para el deploy."
fi

# Siempre notificar al admin.
send_wa "$ADMIN_PHONE" "admin"
