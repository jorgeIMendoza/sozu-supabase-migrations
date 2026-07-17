#!/usr/bin/env bash
# Notifica por WhatsApp (vía webhook de n8n) cuando termina un deploy.
#
# Destinatarios:
#   - DEV:  autores del PR que entró a `dev` (commit que disparó el deploy) + admin.
#   - PROD: TODOS los autores de PRs mergeados a `dev` desde el último deploy
#           a prod (HEAD^1 del merge actual) + admin.
#
# Autores reales: cada línea "<!-- pr_author: <login> -->" del body del PR
# (el dashboard embebe una por autor real de los commits). Sin marcadores se
# usa el creador del PR.
#
# El mensaje incluye la DESCRIPCIÓN de cada PR (obligatoria en el dashboard):
#   "Ha quedado listo tu deploy en PRD del repo X. Contiene: - desc1 - desc2. Puedes revisar."
# Cada autor recibe solo las descripciones de SUS PRs; el admin recibe todas.
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

API="https://api.github.com"
gh_api() { curl -s -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

send_wa() { # $1 = teléfono E.164 ; $2 = etiqueta para log ; $3 = mensaje
  local payload
  payload="$(jq -n --arg tel "$1" --arg msg "$3" \
    '{tipo:"wa",telefono:$tel,mensajeWA:$msg,instanciaWA:"Pruebas de todo"}')"
  curl -s -X POST "$N8N_WEBHOOK" \
    -H "apikey: $N8N_APIKEY" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    >/dev/null && echo "Notificado $2 ($1)" || echo "Fallo al notificar $2 ($1)"
}

# Extrae TODOS los logins del body del PR con líneas <!-- pr_author: login -->
extract_pr_authors_b64() { # $1 = body en base64
  printf '%s' "$1" | base64 -d 2>/dev/null \
    | grep -oP '(?<=<!-- pr_author: )[\w.-]+(?= -->)' 2>/dev/null | sort -u || true
}

# Descripción legible del PR: body sin marcadores internos, recortada.
clean_desc_b64() { # $1 = body en base64
  printf '%s' "$1" | base64 -d 2>/dev/null \
    | grep -v '^<!--' | grep -v '^> ' | grep -v 'Generated with' \
    | sed '/^[[:space:]]*$/d' | tr '\n' ' ' | head -c 250 || true
}

# Acumula autores y descripciones de un PR.
logins=()
declare -A DESCS_POR_AUTOR=()
ALL_DESCS=""
add_pr() { # $1 = login creador ; $2 = body en base64 ; $3 = título
  local marcados desc autores l
  marcados="$(extract_pr_authors_b64 "$2")"
  desc="$(clean_desc_b64 "$2")"
  [ -z "$desc" ] && desc="$3"
  autores="${marcados:-$1}"
  [ -n "$desc" ] && ALL_DESCS="${ALL_DESCS}- ${desc}
"
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    logins+=("$l")
    [ -n "$desc" ] && DESCS_POR_AUTOR[$l]="${DESCS_POR_AUTOR[$l]:-}- ${desc}
"
  done <<< "$autores"
}

if [ "$ENVIRONMENT" = "PROD" ]; then
  # PROD: notificar a TODOS los autores de PRs mergeados a dev desde el último
  # deploy a prod. HEAD^1 = tip de main antes de este merge = fecha del deploy
  # anterior a prod. Todos los PRs a dev mergeados DESPUÉS de esa fecha son
  # "nuevos" en este release.
  PREV_MAIN_DATE="$(git log HEAD^1 --format="%cI" -1 2>/dev/null || true)"
  if [ -n "$PREV_MAIN_DATE" ]; then
    echo "Buscando PRs a dev mergeados después de: ${PREV_MAIN_DATE}"
    PROD_PRS="$(gh_api "$API/repos/$GITHUB_REPOSITORY/pulls?state=closed&base=dev&sort=updated&direction=desc&per_page=50")"
    while IFS=$'\t' read -r login body_b64 title_b64; do
      add_pr "$login" "$body_b64" "$(printf '%s' "$title_b64" | base64 -d 2>/dev/null || true)"
    done < <(echo "$PROD_PRS" | jq -r --arg since "$PREV_MAIN_DATE" \
      '[.[] | select(.merged_at != null and .merged_at > $since)] | .[] |
       [.user.login, (.body // "" | @base64), (.title // "" | @base64)] | @tsv')
    echo "Autores a notificar: $(printf '%s\n' "${logins[@]:-}" | awk 'NF' | sort -u | paste -sd ', ')"
  else
    # Fallback: solo el último PR mergeado a dev
    echo "No se pudo obtener fecha del deploy anterior; usando último PR a dev."
    PR_JSON="$(gh_api "$API/repos/$GITHUB_REPOSITORY/pulls?state=closed&base=dev&sort=updated&direction=desc&per_page=10" \
        | jq -r '[.[] | select(.merged_at != null)] | .[0]')"
    add_pr "$(echo "$PR_JSON" | jq -r '.user.login // empty')" \
           "$(echo "$PR_JSON" | jq -r '.body // "" | @base64')" \
           "$(echo "$PR_JSON" | jq -r '.title // empty')"
  fi
else
  # DEV: todos los autores del PR que entró en este push.
  PR_JSON="$(gh_api "$API/repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" \
      | jq -r '[.[] | select(.merged_at != null)] | .[0]')"
  add_pr "$(echo "$PR_JSON" | jq -r '.user.login // empty')" \
         "$(echo "$PR_JSON" | jq -r '.body // "" | @base64')" \
         "$(echo "$PR_JSON" | jq -r '.title // empty')"
fi

# Mensaje por destinatario: base + descripciones de SUS PRs (o todas para admin).
build_msg() { # $1 = bloque de descripciones (puede ser vacío)
  if [ "$STATUS" != "success" ]; then
    printf 'FALLO el deploy en %s del repo %s. Logs: %s' "$ENVIRONMENT" "$REPO_NAME" "$RUN_URL"
    return
  fi
  if [ -n "$1" ]; then
    printf 'Ha quedado listo tu deploy en %s del repo %s. Contiene:\n%sPuedes revisar.' "$ENVIRONMENT" "$REPO_NAME" "$1"
  else
    printf 'Ha quedado listo tu deploy en %s del repo %s, puedes revisar.' "$ENVIRONMENT" "$REPO_NAME"
  fi
}

ACCESS_TOKEN="$(gcloud auth print-access-token)"

if [ "${#logins[@]}" -gt 0 ]; then
  mapfile -t recipients < <(printf '%s\n' "${logins[@]}" | awk 'NF' | sort -u)
  for login in "${recipients[@]}"; do
    phone="$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
      "https://firestore.googleapis.com/v1/projects/$FIRESTORE_PROJECT/databases/(default)/documents/contributors/$login" \
      | jq -r '.fields.telefonoWhatsapp.stringValue // empty')"
    if [ -n "$phone" ]; then
      send_wa "+521$phone" "$login" "$(build_msg "${DESCS_POR_AUTOR[$login]:-}")"
    else
      echo "Sin teléfono guardado para '$login' en contributors; se omite."
    fi
  done
else
  echo "No se encontró autor de PR para el deploy."
fi

# Siempre notificar al admin (con TODAS las descripciones del release).
send_wa "$ADMIN_PHONE" "admin" "$(build_msg "$ALL_DESCS")"
