#!/usr/bin/env bash
# Notifica por WhatsApp (vía webhook de n8n) cuando termina un deploy.
#
# Destinatarios:
#   - DEV:  autor del PR que entró a `dev` (commit que disparó el deploy).
#   - PROD: TODOS los autores de PRs mergeados a `dev` desde el último deploy
#           a prod (HEAD^1 del merge actual).
#
# El teléfono (10 dígitos) del autor se lee de Firestore sozu-admin-dev:
#   contributors/{githubLogin}.telefonoWhatsapp  ->  se envía como +521<telefono>
# El segundo destinatario es el APROBADOR del proyecto (ver abajo).
#
# Requiere en el entorno:
#   ENVIRONMENT       DEV | PROD
#   GITHUB_REPOSITORY owner/repo            (lo inyecta GitHub Actions)
#   GITHUB_SHA        commit que disparo    (lo inyecta GitHub Actions)
#   GH_TOKEN          token con lectura de PRs (secrets.GITHUB_TOKEN basta)
#   FIRESTORE_PROJECT proyecto con la configuracion y los telefonos
# Y autenticacion gcloud activa a ese proyecto (auth previo en el workflow).
#
# QUEDA REGISTRADO. El dashboard puede calcular a QUIEN le toca el aviso, pero no
# si el mensaje salio: un telefono sin capturar, una instancia de WhatsApp caida o
# una empresa apagada cambian el resultado sin cambiar nada de lo que se ve desde
# la interfaz. Asi que este script anota lo que hizo en
# `deployNotifications/{owner}__{repo}__{runId}` y CI/CD lo lee, en vez de afirmar
# una entrega que nadie comprobo. Cada salida temprana deja tambien su motivo,
# para que "el proyecto no tiene empresa" y "el deploy nunca llego a notificar"
# dejen de verse igual.
#
# TODO SALE DE LA EMPRESA DUENA DEL REPO. La instancia, el webhook y la apikey
# venian escritos a mano -la apikey, literal en el YAML del workflow- y el aviso
# administrativo iba a un numero fijo. Con eso, apagar los avisos de la empresa
# en el dashboard no apagaba nada: los mensajes seguian saliendo por la
# instancia fija y llegando al numero fijo, de una empresa que habia pedido no
# recibirlos. Ahora se lee su configuracion y enabled:false apaga de verdad:
#
#   repos/{owner__repo}.projectId             -> proyecto
#   projects/{projectId}.clientId             -> empresa
#   clients/{clientId}/private/notifications  -> instance, webhookUrl, enabled
#   clients/{clientId}/private/whatsappSecret -> apiKey
#
# El viejo ADMIN_PHONE tambien se fue: era un numero suelto que se quedaba viejo
# en cuanto cambiaba el responsable. En su lugar se avisa al APROBADOR del
# proyecto (projects/{id}.approverEmail -> users/{email}.githubLogin ->
# contributors/{login}.telefonoWhatsapp), que ya esta configurado en el
# dashboard y se mantiene en un solo lugar.
set -euo pipefail

: "${ENVIRONMENT:?falta ENVIRONMENT}"
: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_SHA:?}"
: "${GH_TOKEN:?}"
: "${FIRESTORE_PROJECT:?}"
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

ACCESS_TOKEN="$(gcloud auth print-access-token)"

# Nota de lo que se hizo con los avisos. Se escribe con la cuenta de servicio
# (ignora las reglas de Firestore); el navegador solo la lee. Un fallo al
# registrar no puede tumbar el deploy: es una nota, no el trabajo.
NOTIF_DOC="${GITHUB_REPOSITORY%%/*}__${GITHUB_REPOSITORY##*/}__${GITHUB_RUN_ID}"
AVISADOS=""
FALLIDOS="[]"
registrar() { # $1 = seMando (true|false) ; $2 = motivo
  BODY="$(jq -n --arg mando "$1" --arg motivo "$2" --arg av "$AVISADOS" \
    --argjson fal "$FALLIDOS" --arg run "${GITHUB_RUN_ID:-}" \
    '{fields:{
        seMando:{booleanValue:($mando=="true")},
        motivo:{stringValue:$motivo},
        runId:{stringValue:$run},
        avisados:{arrayValue:{values:(($av|split(","))|map(select(length>0)|{stringValue:.}))}},
        fallidos:{arrayValue:{values:($fal|map({mapValue:{fields:{login:{stringValue:.login},motivo:{stringValue:.motivo}}}}))}}
      }}')"
  curl -s -o /dev/null --max-time 20 -X PATCH \
    -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
    "https://firestore.googleapis.com/v1/projects/${FIRESTORE_PROJECT}/databases/(default)/documents/deployNotifications/${NOTIF_DOC}" \
    -d "$BODY" || echo "- no se pudo registrar el aviso (no afecta al deploy)"
}
anotar_fallo() { # $1 = login ; $2 = motivo
  FALLIDOS="$(printf '%s' "$FALLIDOS" | jq -c --arg l "$1" --arg m "$2" '. + [{login:$l,motivo:$m}]')"
}
FS="https://firestore.googleapis.com/v1/projects/${FIRESTORE_PROJECT}/databases/(default)/documents"
leer() { curl -s --max-time 20 -H "Authorization: Bearer $ACCESS_TOKEN" "${FS}/$1"; }
campo() { printf '%s' "$1" | jq -r --arg f "$2" '.fields[$f].stringValue // empty'; }
# enabled ausente = prendido. El "// empty" de jq no sirve para booleanos (trata
# false como vacio), asi que se mira el TIPO del campo.
prendido() { printf '%s' "$1" | jq -r 'if (.fields.enabled | type) == "object" then (.fields.enabled.booleanValue | tostring) else "true" end'; }
# Nunca devuelve estado != 0: con `set -e`, un `[ -n ... ] &&` que falla dentro
# de una asignacion por sustitucion tumbaria el script entero por un telefono
# que simplemente no esta capturado.
telefono_de() { p="$(campo "$(leer "contributors/$1")" telefonoWhatsapp)"; if [ -n "$p" ]; then printf '+521%s' "$p"; fi; return 0; }

# --- Empresa duena del repo ---------------------------------------------------
REPO_ID="${GITHUB_REPOSITORY%%/*}__${GITHUB_REPOSITORY##*/}"
PROJECT_ID="$(campo "$(leer "repos/${REPO_ID}")" projectId)"
if [ -z "$PROJECT_ID" ]; then
  echo "El repo '${GITHUB_REPOSITORY}' no esta dado de alta en el dashboard (repos/${REPO_ID}): no se sabe de que empresa es, no se notifica."
  registrar false "El repo no esta dado de alta en el dashboard, asi que no se sabe de que empresa es."
  exit 0
fi
PROY_DOC="$(leer "projects/${PROJECT_ID}")"
CLIENT_ID="$(campo "$PROY_DOC" clientId)"
if [ -z "$CLIENT_ID" ]; then
  echo "El proyecto '${PROJECT_ID}' no tiene empresa asignada (dashboard -> Proyectos): no se notifica."
  registrar false "El proyecto no tiene empresa asignada, y los avisos salen por la instancia de la empresa."
  exit 0
fi

C_DOC="$(leer "clients/${CLIENT_ID}/private/notifications")"
WA_INSTANCE="$(campo "$C_DOC" instance)"
WA_WEBHOOK="$(campo "$C_DOC" webhookUrl)"
WA_APIKEY="$(campo "$(leer "clients/${CLIENT_ID}/private/whatsappSecret")" apiKey)"
[ -n "$WA_APIKEY" ] && echo "::add-mask::${WA_APIKEY}"

if [ "$(prendido "$C_DOC")" != "true" ]; then
  echo "La empresa '${CLIENT_ID}' tiene los avisos de WhatsApp APAGADOS en el dashboard: no se manda nada."
  registrar false "La empresa tiene los avisos de WhatsApp apagados."
  exit 0
fi
if [ -z "$WA_INSTANCE" ] || [ -z "$WA_WEBHOOK" ] || [ -z "$WA_APIKEY" ]; then
  echo "A la empresa '${CLIENT_ID}' le falta configuracion de WhatsApp (instancia, webhook o apikey): no se manda nada."
  echo "Se completa en el dashboard -> Configuracion -> Notificaciones."
  registrar false "A la empresa le falta configuracion de WhatsApp (instancia, webhook o apikey)."
  exit 0
fi
echo "Empresa '${CLIENT_ID}' (proyecto '${PROJECT_ID}') | instancia: '${WA_INSTANCE}'"

send_wa() { # $1 = telefono E.164 ; $2 = etiqueta para el log
  cuerpo="$(mktemp)"
  payload="$(jq -nc --arg tel "$1" --arg msg "$MENSAJE" --arg inst "$WA_INSTANCE" '{tipo:"wa",telefono:$tel,mensajeWA:$msg,instanciaWA:$inst}')"
  codigo="$(curl -s -o "$cuerpo" -w '%{http_code}' --max-time 20 -X POST "$WA_WEBHOOK" -H "apikey: $WA_APIKEY" -H "Content-Type: application/json" -d "$payload" || echo 000)"
  # n8n contesta 200 aunque el mensaje NO se haya entregado: acepta la peticion
  # y mete el fallo de la instancia de WhatsApp en el cuerpo. Mirando solo el
  # codigo HTTP, esto cantaba "Notificado" mientras Evolution respondia
  # "Connection Closed" -la sesion caida- y nadie recibia nada.
  falla="$(jq -r 'if .datos_validos == false then (.error_validacion // "n8n rechazo los datos") elif (.error // null) != null then (.error | if type == "object" then (.message // tostring) else tostring end) else empty end' "$cuerpo" 2>/dev/null || true)"
  case "$codigo" in
    2*) if [ -z "$falla" ]; then echo "Notificado $2 ($1)"; rm -f "$cuerpo"; return 0; fi ;;
  esac
  echo "Fallo al notificar $2 ($1) - HTTP ${codigo}${falla:+ - n8n: ${falla:0:200}}"
  rm -f "$cuerpo"
  # Devuelve 1 para que quien llama lo anote como fallido. Nunca se usa dentro de
  # una lista `&&`/`||` que pueda tumbar el script: siempre en un `if`.
  return 1
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
    mapfile -t logins < <(
      gh_api "$API/repos/$GITHUB_REPOSITORY/pulls?state=closed&base=dev&sort=updated&direction=desc&per_page=50" \
        | jq -r --arg since "$PREV_MAIN_DATE" \
            '[.[] | select(.merged_at != null and .merged_at > $since)] | .[].user.login' \
        | sort -u
    )
    echo "Autores a notificar (${#logins[@]}): ${logins[*]:-ninguno}"
  else
    echo "No se pudo obtener fecha del deploy anterior; usando último PR a dev."
    a="$(gh_api "$API/repos/$GITHUB_REPOSITORY/pulls?state=closed&base=dev&sort=updated&direction=desc&per_page=10" \
        | jq -r '[.[] | select(.merged_at != null)] | .[0].user.login // empty')"
    [ -n "$a" ] && logins+=("$a")
  fi
else
  # DEV: solo el autor del PR que entró en este push.
  a="$(gh_api "$API/repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" \
      | jq -r '[.[] | select(.merged_at != null)] | .[0].user.login // empty')"
  [ -n "$a" ] && logins+=("$a")
fi

if [ "${#logins[@]}" -gt 0 ]; then
  mapfile -t recipients < <(printf '%s\n' "${logins[@]}" | awk 'NF' | sort -u)
  for login in "${recipients[@]}"; do
    phone="$(telefono_de "$login")"
    if [ -n "$phone" ]; then
      if send_wa "$phone" "$login"; then
        AVISADOS="${AVISADOS}${login},"
      else
        anotar_fallo "$login" "el webhook de n8n no acepto el mensaje"
      fi
    else
      echo "Sin teléfono guardado para '$login' en contributors; se omite."
      anotar_fallo "$login" "sin teléfono en Contribuidores"
    fi
  done
else
  echo "No se encontró autor de PR para el deploy."
fi

# --- Aprobador del proyecto ---------------------------------------------------
APROBADOR_EMAIL="$(campo "$PROY_DOC" approverEmail)"
if [ -z "$APROBADOR_EMAIL" ]; then
  echo "El proyecto '${PROJECT_ID}' no tiene aprobador configurado (dashboard -> Proyectos y repos): nadie mas recibe el aviso."
  registrar true ""
  exit 0
fi
APROBADOR_LOGIN="$(campo "$(leer "users/${APROBADOR_EMAIL}")" githubLogin)"
if [ -z "$APROBADOR_LOGIN" ]; then
  echo "El aprobador '${APROBADOR_EMAIL}' no tiene cuenta de GitHub registrada (dashboard -> Usuarios): no se le avisa."
  anotar_fallo "$APROBADOR_EMAIL" "el aprobador no tiene cuenta de GitHub registrada"
  registrar true ""
  exit 0
fi
for login in "${recipients[@]:-}"; do
  if [ "$login" = "$APROBADOR_LOGIN" ]; then
    echo "El aprobador ya fue notificado como autor."
    registrar true ""
    exit 0
  fi
done
APROBADOR_TEL="$(telefono_de "$APROBADOR_LOGIN")"
if [ -z "$APROBADOR_TEL" ]; then
  echo "El aprobador @${APROBADOR_LOGIN} no tiene telefono en Contribuidores: no se le avisa."
  anotar_fallo "$APROBADOR_LOGIN" "sin telefono en Contribuidores"
  registrar true ""
  exit 0
fi
if send_wa "$APROBADOR_TEL" "aprobador @${APROBADOR_LOGIN}"; then
  AVISADOS="${AVISADOS}${APROBADOR_LOGIN},"
else
  anotar_fallo "$APROBADOR_LOGIN" "el webhook de n8n no acepto el mensaje"
fi
registrar true ""
