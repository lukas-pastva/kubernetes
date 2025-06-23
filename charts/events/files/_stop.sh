#!/bin/bash
# --------------------------------------------------------------------
#  Stop an Argo CD application by deleting every Deployment it owns
#  (pure REST implementation – no argocd CLI)
# --------------------------------------------------------------------
set -Eeuo pipefail

###############################################################################
# Arguments handed‐in from the workflow
###############################################################################
var_name="{{inputs.parameters.var_name}}"
echo "Stopping Application: ${var_name}."

###############################################################################
# Configuration
###############################################################################
ARGOCD_URL="http://argocd-server.argocd.svc.cluster.local"
MAX_RETRIES=5        # how many times to retry API calls
RETRY_DELAY=5        # seconds between retries

###############################################################################
# Helpers
###############################################################################
log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }
die() { log "ERROR: $*"; exit 1; }

retry() {
  local max=$1 delay=$2; shift 2
  local n=1
  until "$@"; do
    (( n++ > max )) && return 1
    log "Retry $((n-1))/$max – again in ${delay}s …"
    sleep "$delay"
  done
}

###############################################################################
# 1) Authenticate – exchange username/password for a JWT
###############################################################################
get_token() {
  curl -sS -X POST "${ARGOCD_URL}/api/v1/session" \
       -H 'Content-Type: application/json' \
       -d "{\"username\":\"${ARGOCD_USERNAME:?must be set}\",\
            \"password\":\"${ARGOCD_PASSWORD:?must be set}\"}" |
       jq -r '.token'
}

log "Obtaining API token …"
if ! TOKEN=$(retry "$MAX_RETRIES" "$RETRY_DELAY" get_token); then
  die "Unable to log in to Argo CD."
fi
AUTH=(-H "Authorization: Bearer ${TOKEN}")

###############################################################################
# Thin wrappers around the REST API
###############################################################################
argo_get()  { curl -sS "${AUTH[@]}"    "${ARGOCD_URL}$1"; }
argo_put()  { curl -sS -X PUT  "${AUTH[@]}" -H 'Content-Type: application/json' -d "$2" "${ARGOCD_URL}$1"; }

###############################################################################
# 2) Load Application spec (with retries)
###############################################################################
get_app_json() { argo_get "/api/v1/applications/${var_name}"; }

log "Fetching application ${var_name} …"
if ! app_json=$(retry "$MAX_RETRIES" "$RETRY_DELAY" get_app_json); then
  die "Unable to load application ${var_name}."
fi

###############################################################################
# 3) Ensure Auto‑Sync is disabled
###############################################################################
if echo "${app_json}" | jq -e '.spec.syncPolicy.automated' >/dev/null; then
  log "Auto‑Sync is ENABLED – attempting to disable it."

  # Build a modified copy of the Application with syncPolicy.automated removed
  patched_app=$(echo "${app_json}" | jq 'del(.spec.syncPolicy.automated)')

  # PUT the whole (patched) resource back
  if ! retry "$MAX_RETRIES" "$RETRY_DELAY" argo_put \
        "/api/v1/applications/${var_name}" "${patched_app}"; then
    die "Failed to disable Auto‑Sync."
  fi

  sleep 10   # give Application controller time to reconcile
  app_json=$(get_app_json)
  if echo "${app_json}" | jq -e '.spec.syncPolicy.automated' >/dev/null; then
    die "Auto‑Sync was re‑enabled by an ApplicationSet/controller – aborting."
  fi
  log "Auto‑Sync successfully disabled."
else
  log "Auto‑Sync already disabled."
fi

###############################################################################
# 4) Discover all Deployments managed by the application
#    via /managed-resources endpoint
###############################################################################
resources_json=$(argo_get "/api/v1/applications/${var_name}/managed-resources")

mapfile -t deployments < <(
  echo "${resources_json}" |
  jq -r '.items[]
         | select(.kind=="Deployment")
         | "\(.namespace)\t\(.name)"'
)

if [[ ${#deployments[@]} -eq 0 ]]; then
  log "No Deployments found – nothing to delete."
  exit 0
fi

log "Deployments that will be deleted:"
for d in "${deployments[@]}"; do printf '  • %s\n' "${d}"; done

###############################################################################
# 5) Delete each Deployment (kubectl talks to the cluster directly)
###############################################################################
deleted=()
delete_dep() { kubectl -n "$1" delete deployment "$2" --ignore-not-found; }

for dep in "${deployments[@]}"; do
  ns=${dep%%$'\t'*}; name=${dep##*$'\t'}
  if retry "$MAX_RETRIES" "$RETRY_DELAY" delete_dep "$ns" "$name"; then
    deleted+=("$ns/$name")
  else
    die "Failed to delete deployment ${ns}/${name}."
  fi
done

###############################################################################
# 6) Summary
###############################################################################
log "Successfully deleted ${#deleted[@]} deployment(s):"
for d in "${deleted[@]}"; do printf '  • %s\n' "${d}"; done
