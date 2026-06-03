#!/usr/bin/env bash
# Notifica por WhatsApp (vía webhook de n8n) cuando termina un deploy.
#
# Destinatarios:
#   - DEV:  autor del PR que entró a `dev` (commit que disparó el deploy) + admin.
#   - PROD: autor del último PR mergeado a `dev` (origen del cambio promovido) + admin.
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

API="https://api.github.com"
gh() { curl -s -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

send_wa() { # $1 = teléfono E.164 ; $2 = etiqueta para log
  curl -s -X POST "$N8N_WEBHOOK" \
    -H "apikey: $N8N_APIKEY" \
    -H "Content-Type: application/json" \
    -d "{\"tipo\":\"wa\",\"telefono\":\"$1\",\"mensajeWA\":\"Ha quedado listo tu deploy en ${ENVIRONMENT} del repo ${REPO_NAME}, puedes revisar\",\"instanciaWA\":\"Pruebas de todo\"}" \
    >/dev/null && echo "Notificado $2 ($1)" || echo "Fallo al notificar $2 ($1)"
}

logins=()
if [ "$ENVIRONMENT" = "PROD" ]; then
  # Autor del último PR mergeado a dev (el cambio que se promovió a prod).
  a="$(gh "$API/repos/$GITHUB_REPOSITORY/pulls?state=closed&base=dev&sort=updated&direction=desc&per_page=10" \
      | jq -r '[.[] | select(.merged_at != null)] | .[0].user.login // empty')"
  [ -n "$a" ] && logins+=("$a")
else
  # Autor del PR que entró a dev (commit que disparó el deploy).
  a="$(gh "$API/repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" \
      | jq -r '[.[] | select(.merged_at != null)] | .[0].user.login // empty')"
  [ -n "$a" ] && logins+=("$a")
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
