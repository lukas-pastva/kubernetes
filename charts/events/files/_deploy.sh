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
# 2) Stop app & make a backup (block with --wait)
###############################################################################
log "🛑  Stopping ${var_name}"
argo --argo-server "argo-workflows-server:2746" --secure=false --loglevel debug submit \
  -n "argo-workflows" \
  --from "workflowtemplate/event-stop" \
  --parameter "event-data={\"name\":\"${var_name}\"}" \
  --generate-name "event-stop-" \
  --wait --log

log "📦  Backup in progress"
argo --argo-server "argo-workflows-server:2746" --secure=false --loglevel debug submit \
  -n "argo-workflows" \
  --from "workflowtemplate/event-backup-k8s" \
  --generate-name "event-backup-k8s-" \
  --wait --log

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

vals="values/${var_name}.yml"
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
# ─── BEGIN AUTOSYNC GUARD ─────────────────────────────────────────────────────
if $autosync_enabled; then
  log "🔓  Re-enabling auto-sync for ${var_name}"
  argocd app set "$var_name" --sync-policy automated --self-heal --source-position 1 >/dev/null
fi
# ─── END AUTOSYNC GUARD ───────────────────────────────────────────────────────

log "✅  ${var_name} is now running image tag ${var_version}"
