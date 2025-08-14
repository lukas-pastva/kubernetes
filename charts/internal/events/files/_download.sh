#!/usr/bin/env bash
#───────────────────────────────────────────────────────────────────────────────
#  download.sh  –  v2.5  (2025-08-14)
#  *Optional GitLab Merge-Request flow, project ID supplied via env*
#───────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
[[ ${DEBUG:-false} == "true" ]] && set -x

###############################################################################
# A) USER-CONFIGURABLE SETTINGS
###############################################################################
CREATE_PR="${CREATE_PR:-false}" # true → open MR, false → push to main

# Where pulled charts are cached *inside the repo*.
# Default: charts/external   (override with CHARTS_ROOT=external/charts ./download.sh …)
CHARTS_ROOT="${CHARTS_ROOT:-charts/external}"

###############################################################################
# B) Logging helpers / traps
###############################################################################
log() { printf '\e[1;34m[%(%F %T)T]\e[0m %b\n' -1 "$*" >&2; }
trap 'log "❌  FAILED (line $LINENO) 👉 «$BASH_COMMAND»"; exit 1' ERR

echo -e "\n\e[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"

###############################################################################
# 0) Workflow inputs  (Argo substitutes these before execution)
###############################################################################
var_chart="{{inputs.parameters.var_chart}}"
var_version="{{inputs.parameters.var_version}}"
var_repo="{{inputs.parameters.var_repo}}"
var_owner="{{inputs.parameters.var_owner}}"

for p in var_chart var_version var_repo; do
  [[ ${!p} =~ \{\{.*\}\} ]] && { log "🚫  $p not substituted – abort"; exit 1; }
done

log "📦  Download request:"
log "    • chart     = ${var_chart}"
log "    • version   = ${var_version}"
log "    • helm repo = ${var_repo}"
log "    • owner     = ${var_owner}"
log "    • CREATE_PR = ${CREATE_PR}"
log "    • CHARTS_ROOT = ${CHARTS_ROOT}"

###############################################################################
# 1) Mandatory env
###############################################################################
: "${GIT_SSH_KEY:?need GIT_SSH_KEY}"
: "${GITOPS_REPO:?need GITOPS_REPO}"
: "${GIT_EMAIL:?need GIT_EMAIL}"
: "${GIT_USER:?need GIT_USER}"
if [[ $CREATE_PR == "true" ]]; then
  : "${GITLAB_TOKEN:?need GITLAB_TOKEN for MR creation}"
  : "${GITLAB_PROJECT_ID:?need GITLAB_PROJECT_ID for MR creation}"
  : "${GITLAB_API_URL:?need GITLAB_API_URL for MR creation}"
fi

log "🔑  Git user:    $GIT_USER <$GIT_EMAIL>"
log "🌐  GitOps repo: $GITOPS_REPO"

###############################################################################
# 2) Paths / branch selection
###############################################################################
chart_path="${CHARTS_ROOT}/${var_owner}/${var_chart}/${var_version}"
if [[ $CREATE_PR == "true" ]]; then
  branch="helm-download-${var_chart}-${var_version}-$(date +%Y%m%d%H%M%S)"
else
  branch="main"
fi
log "📁  chart_path   = ${chart_path}"
log "🌿  Target branch: \e[1m$branch\e[0m"

###############################################################################
# 3) Clone repo
###############################################################################
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
log "🐙  Cloning into ${tmp} …"

mkdir -p "$tmp/.ssh"
printf '%s\n' "$GIT_SSH_KEY" > "$tmp/.ssh/id_rsa"
chmod 600 "$tmp/.ssh/id_rsa"
export GIT_SSH_COMMAND="ssh -i $tmp/.ssh/id_rsa -o StrictHostKeyChecking=no"

git -C "$tmp" clone --depth 1 "$GITOPS_REPO" repo
cd "$tmp/repo"

git config user.email "$GIT_EMAIL"
git config user.name  "$GIT_USER"

git checkout "main"
[[ $CREATE_PR == "true" ]] && git checkout -b "$branch"

###############################################################################
# 4) Download chart (if not cached) – robust version handling + OCI fallback
###############################################################################
if [[ -d $chart_path ]]; then
  log "✅  Chart already present → $chart_path  (nothing to do)"
  exit 0
fi

log "⬇️   helm pull → $chart_path"
tempc="$(mktemp -d)"

helm_pull_untar() {
  local version="$1"
  # Use --untar so we do not depend on the tarball filename (handles v-prefixed versions).
  helm pull "${var_chart}" --repo "${var_repo}" \
    --version "${version}" --untar -d "$tempc" 2> /tmp/helm.err
}

# 4a) Try the provided version as-is.
effective_version="${var_version}"
if ! helm_pull_untar "${effective_version}"; then
  # 4b) If no leading 'v', retry with it (Jetstack charts like cert-manager use v-prefixed versions).
  if [[ ! $effective_version =~ ^v ]]; then
    log "🔁  Retry with leading 'v': v${effective_version}"
    rm -rf "$tempc"; tempc="$(mktemp -d)"
    if helm_pull_untar "v${effective_version}"; then
      effective_version="v${effective_version}"
    else
      # 4c) OCI fallback: prefer official Jetstack OCI for cert-manager; else keep generic Bitnami fallback.
      if [[ "$var_repo" == *"jetstack"* && "$var_chart" == "cert-manager" ]]; then
        log "🔄  Falling back to Jetstack OCI for cert-manager (${effective_version})"
        if ! helm pull "oci://quay.io/jetstack/charts/${var_chart}" \
              --version "v${var_version}" --untar -d "$tempc" 2>> /tmp/helm.err; then
          cat /tmp/helm.err >&2
          exit 1
        fi
        effective_version="v${var_version}"
      else
        if grep -q "invalid_reference" /tmp/helm.err; then
          log "🔄  Falling back to OCI (Bitnami) for ${var_chart} ${effective_version}"
          helm pull "oci://registry-1.docker.io/bitnamicharts/${var_chart}" \
                    --version "${effective_version}" --untar -d "$tempc"
        else
          cat /tmp/helm.err >&2
          exit 1
        fi
      fi
    fi
  else
    # Provided version already had 'v' and still failed → try Jetstack OCI for cert-manager, else Bitnami/exit
    if [[ "$var_repo" == *"jetstack"* && "$var_chart" == "cert-manager" ]]; then
      log "🔄  Falling back to Jetstack OCI for cert-manager (${effective_version})"
      helm pull "oci://quay.io/jetstack/charts/${var_chart}" \
                --version "${effective_version}" --untar -d "$tempc" 2>> /tmp/helm.err || {
        cat /tmp/helm.err >&2
        exit 1
      }
    elif grep -q "invalid_reference" /tmp/helm.err; then
      log "🔄  Falling back to OCI (Bitnami) for ${var_chart} ${effective_version}"
      helm pull "oci://registry-1.docker.io/bitnamicharts/${var_chart}" \
                --version "${effective_version}" --untar -d "$tempc"
    else
      cat /tmp/helm.err >&2
      exit 1
    fi
  fi
fi

# After --untar, the chart is in "$tempc/${var_chart}/"
[[ -f "$tempc/${var_chart}/Chart.yaml" ]] || { log "🚫  helm pull succeeded but chart dir missing"; exit 1; }

mkdir -p "$chart_path"
# Move the *contents* of the chart directory, not the folder itself
mv "$tempc/${var_chart}/"* "$chart_path/"
rm -rf "$tempc"
log "🗃  Chart extracted (version used: ${effective_version})"

###############################################################################
# 5) Commit
###############################################################################
git add "$chart_path"
git status --short
git commit -m "chore: cache ${var_chart} ${effective_version}"

###############################################################################
# 6) Push (direct OR MR)
###############################################################################
if [[ $CREATE_PR == "true" ]]; then
  log "📤  Pushing feature branch…"
  git push -u origin "$branch"

  log "🔧  Opening Merge Request on GitLab…"
  mr_response="$(
    curl -ksS -X POST "${GITLAB_API_URL}/projects/${GITLAB_PROJECT_ID}/merge_requests" \
         --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
         --form "source_branch=${branch}" \
         --form "target_branch=main" \
         --form "title=chore: cache ${var_chart} ${effective_version}" \
         --form "remove_source_branch=true"
  )" || { log "🚫  MR creation failed"; exit 1; }

  mr_url="$(jq -r '.web_url' <<<"$mr_response")"
  if [[ $mr_url == "null" || -z $mr_url ]]; then
    log "🚫  MR creation failed: $(jq -r '.message // empty' <<<"$mr_response")"
    exit 1
  fi
  log "🔗  Merge Request opened: $mr_url"
else
  log "📤  Pushing directly to main…"
  git push origin "main"
fi

log "🎉  Done – chart cached at \e[1m${chart_path}\e[0m!"
echo -e "\e[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m\n"
