#!/usr/bin/env bash
# Notifica por WhatsApp (vía webhook de n8n) cuando termina un deploy.
#
# Destinatarios:
#   - DEV:  autor del PR que entró a `dev` (commit que disparó el deploy).
#   - PROD: autor del PR que entró a `main` + autor del último PR mergeado a `dev`.
#
# El teléfono (10 dígitos) se lee de Firestore: contributors/{githubLogin}.telefonoWhatsapp
# y se envía como +521<telefono>.
#
# Requiere en el entorno:
#   ENVIRONMENT       DEV | PROD
#   GITHUB_REPOSITORY owner/repo            (lo inyecta GitHub Actions)
#   GITHUB_SHA        commit que disparó    (lo inyecta GitHub Actions)
#   GH_TOKEN          token con lectura de PRs (secrets.GITHUB_TOKEN basta)
#   FIRESTORE_PROJECT id del proyecto Firebase (ej. sozu-admin-dev)
#   N8N_WEBHOOK       URL del webhook
#   N8N_APIKEY        apikey del webhook
# Y autenticación gcloud activa (paso google-github-actions/auth previo).
set -euo pipefail

: "${ENVIRONMENT:?falta ENVIRONMENT}"
: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_SHA:?}"
: "${GH_TOKEN:?}"
: "${FIRESTORE_PROJECT:?}"
: "${N8N_WEBHOOK:?}"
: "${N8N_APIKEY:?}"

API="https://api.github.com"
gh() { curl -s -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

logins=()

# Autor del PR asociado al commit que disparó el deploy (PR -> dev en DEV, PR -> main en PROD).
pr_author="$(gh "$API/repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" \
  | jq -r '[.[] | select(.merged_at != null)] | .[0].user.login // empty')"
[ -n "$pr_author" ] && logins+=("$pr_author")

if [ "$ENVIRONMENT" = "PROD" ]; then
  # Autor del último PR mergeado a dev (el cambio que se promovió a prod).
  dev_author="$(gh "$API/repos/$GITHUB_REPOSITORY/pulls?state=closed&base=dev&sort=updated&direction=desc&per_page=10" \
    | jq -r '[.[] | select(.merged_at != null)] | .[0].user.login // empty')"
  [ -n "$dev_author" ] && logins+=("$dev_author")
fi

if [ "${#logins[@]}" -eq 0 ]; then
  echo "No se encontró autor de PR para el commit $GITHUB_SHA; no se notifica."
  exit 0
fi

# Únicos
mapfile -t recipients < <(printf '%s\n' "${logins[@]}" | awk 'NF' | sort -u)

ACCESS_TOKEN="$(gcloud auth print-access-token)"

for login in "${recipients[@]}"; do
  phone="$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://firestore.googleapis.com/v1/projects/$FIRESTORE_PROJECT/databases/(default)/documents/contributors/$login" \
    | jq -r '.fields.telefonoWhatsapp.stringValue // empty')"

  if [ -z "$phone" ]; then
    echo "Sin teléfono guardado para '$login' en contributors; se omite."
    continue
  fi

  curl -s -X POST "$N8N_WEBHOOK" \
    -H "apikey: $N8N_APIKEY" \
    -H "Content-Type: application/json" \
    -d "{\"tipo\":\"wa\",\"telefono\":\"+521${phone}\",\"mensajeWA\":\"Ha quedado listo tu deploy en ${ENVIRONMENT}, puedes revisar\",\"instanciaWA\":\"Pruebas de todo\"}" \
    && echo "Notificado $login (+521$phone)"
done
