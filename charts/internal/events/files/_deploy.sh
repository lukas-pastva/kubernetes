#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  Git-Ops deploy: bump image tag, refresh + sync with Argo Workflows & Argo CD
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
[[ ${DEBUG:-false} == "true" ]] && set -x                 # DEBUG=true → bash -x

# -- pretty log helper ---------------------------------------------------------
log() { printf '\e[1;34m[%(%F %T)T]\e[0m %s\n' -1 "$*" >&2; }
trap 'log "❌  \"${BASH_COMMAND}\" failed (line $LINENO)"; exit 1' ERR

###############################################################################
# 0) Inputs (from the workflow template)
###############################################################################
var_name="{{inputs.parameters.var_name}}"
var_version="{{inputs.parameters.var_version}}"

log "Deploying application '${var_name}' with image tag '${var_version}'"

###############################################################################
# K8s helpers – create Workflow CRDs directly (no argo-server, no argo CLI)
###############################################################################
NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || true)"
NS="${NS:-argo-workflows}"
API="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}"
SA_TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
CA="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

k8s_create_workflow() {
  # Args: <templateName> <generateNamePrefix> [eventDataJson]
  local tmpl="$1" gen="$2" ed="${3:-}"

  # Build a Workflow manifest that references the WorkflowTemplate
  local wf_json
  if [[ -n "$ed" ]]; then
    wf_json="$(jq -nc --arg ns "$NS" --arg tmpl "$tmpl" --arg gen "$gen" --argjson ed "$ed" '
      {
        apiVersion: "argoproj.io/v1alpha1",
        kind: "Workflow",
        metadata: { generateName: ($gen + "-"), namespace: $ns },
        spec: {
          workflowTemplateRef: { name: $tmpl },
          arguments: {
            parameters: [
              { name: "event-data", value: ( $ed | tojson ) }
            ]
          }
        }
      }')"
  else
    wf_json="$(jq -nc --arg ns "$NS" --arg tmpl "$tmpl" --arg gen "$gen" '
      {
        apiVersion: "argoproj.io/v1alpha1",
        kind: "Workflow",
        metadata: { generateName: ($gen + "-"), namespace: $ns },
        spec: { workflowTemplateRef: { name: $tmpl } }
      }')"
  fi

  # POST to the Kubernetes API
  local url="${API}/apis/argoproj.io/v1alpha1/namespaces/${NS}/workflows"
  local resp
  resp="$(
    curl -sS --fail \
      --cacert "$CA" \
      -H "Authorization: Bearer ${SA_TOKEN}" \
      -H "Content-Type: application/json" \
      -X POST \
      --data "$wf_json" \
      "$url"
  )"

  # Return created Workflow name for logs
  jq -r '.metadata.name // empty' <<<"$resp"
}

###############################################################################
# 1) Log in to Argo CD and, if needed, disable auto-sync
###############################################################################
log "🔑  Logging into Argo CD"
argocd --loglevel debug login argocd-server.argocd.svc.cluster.local:80 \
       --username "$ARGOCD_USERNAME" --password "$ARGOCD_PASSWORD" --plaintext >/dev/null

# ─── BEGIN AUTOSYNC GUARD ─────────────────────────────────────────────────────
log "🔍  Checking whether auto-sync is enabled for ${var_name}"
autosync_enabled=false
if [[ "$(argocd app get "$var_name" -o json | jq -r '.spec.syncPolicy.automated // empty')" != "" ]]; then
  autosync_enabled=true
  log "🛑  Auto-sync is ON → temporarily disabling it"
  argocd app set "$var_name" --sync-policy none --source-position 1 >/dev/null
fi
# ─── END AUTOSYNC GUARD ───────────────────────────────────────────────────────

###############################################################################
# 2) Stop app & make a backup (block semantics handled by those workflows)
###############################################################################
log "🛑  Stopping ${var_name}"
stop_event_data="$(jq -cn --arg name "$var_name" '{name:$name}')"
stop_wf_name="$(k8s_create_workflow "event-stop" "event-stop" "$stop_event_data")"
log "📨  Submitted stop workflow: ${stop_wf_name:-<unknown>} (waiting handled inside that workflow)"

log "📦  Backup in progress"
backup_wf_name="$(k8s_create_workflow "event-backup-k8s" "event-backup-k8s")"
log "📨  Submitted backup workflow: ${backup_wf_name:-<unknown>}"

###############################################################################
# 3) Clone GitOps repo & bump the tag
###############################################################################
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/.ssh"
printf '%s\n' "$GIT_SSH_KEY" > "$tmpdir/.ssh/id_rsa"
chmod 600 "$tmpdir/.ssh/id_rsa"
export GIT_SSH_COMMAND="ssh -i $tmpdir/.ssh/id_rsa -o StrictHostKeyChecking=no"

git -C "$tmpdir" clone --depth 1 "$GITOPS_REPO" repo
cd "$tmpdir/repo"

git config user.email "$GIT_EMAIL"
git config user.name  "$GIT_USER"

vals="values/${var_name}.yaml"
[[ -f "$vals" ]] || { log "❌  ${vals} not found"; exit 1; }

log "🔧  Updating tag in $vals"
if command -v yq >/dev/null; then
  TAG=$var_version yq -i \
    '.deployments."'"$var_name"'".image |= sub(":[^:]+$"; ":" + env(TAG))' "$vals"
else
  sed -Ei "s#(^[[:space:]]*image:[[:space:]]*[^:]+:).*#\1${var_version}#" "$vals"
fi

git add "$vals"
if git diff --cached --quiet; then
  log "ℹ️   No change – nothing to commit."
else
  log "📤  Committing & pushing"
  git commit -m "feat(${var_name}): upgrade to ${var_version}"
  git push origin HEAD:main
fi

###############################################################################
# 4) Argo CD refresh, sync & wait
###############################################################################
log "🔄  Refreshing ${var_name}"
argocd app get "$var_name" --refresh >/dev/null

log "🚀  Syncing & waiting until healthy"
argocd app sync "$var_name" --timeout 600 >/dev/null
argocd app wait "$var_name" --health --operation --timeout 600 >/dev/null

###############################################################################
# 5) Re-enable auto-sync if we turned it off
###############################################################################
if $autosync_enabled; then
  log "🔓  Re-enabling auto-sync for ${var_name}"
  argocd app set "$var_name" --sync-policy automated --self-heal --source-position 1 >/dev/null
fi

log "✅  ${var_name} is now running image tag ${var_version}"
