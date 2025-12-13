#!/usr/bin/env bash
set -euo pipefail


# ============================================================
#  fetch_kube.sh
#
#  WHAT THIS SCRIPT DOES
#  ------------------------------------------------------------
#  • Fetches ALL deployments, pods, and replica sets in a given
#    Kubernetes namespace using only 3 kubectl calls.
#
#  • For every service in predefined categories (oms, health,
#    partner, occ, web):
#       - Finds the deployed image and extracts the tag.
#       - Shows deployed timestamp and replica availability.
#       - Lists all pods with state, restarts, readiness.
#
#  • Calls common_branches() for that service's GitHub repo
#    using GitHub API (NOT git clone).
#
#  • Caches common branch output per (repo + tag).
#    - If the tag didn’t change, results load instantly.
#    - Keeps last 3 historical tags for reference.
#
#  • Generates a clean HTML report with:
#       - Service cards in grid layout
#       - Current tag info
#       - Pods dropdown
#       - Common branches dropdown
#       - History dropdown (last 3 tags)
#
#  • Saves output to:  ./report.html
#
#
#  HOW TO RUN
#  ------------------------------------------------------------
#  1. Ensure GitHub token exported:
#        export GITHUB_TOKEN="xxxxxx"
#
#  2. Run the script:
#        ./fetch_kube.sh <namespace>
#
#     Example:
#        ./fetch_kube.sh s2
#
#     If namespace omitted, default = "s2"
#
#
#  PREREQUISITES
#  ------------------------------------------------------------
#  • macOS or Linux
#  • kubectl configured to correct cluster
#  • jq (for JSON parsing)
#  • curl
#  • bash
#
#
#  OUTPUT
#  ------------------------------------------------------------
#  - CLI logs written to ~/.k8s-deploy-cache/fetch_kube.log
#  - HTML report saved to ./report.html
#  - Cached tags and cached common branches stored under:
#        ~/.k8s-deploy-cache/
#
# ============================================================

#############################################
# CONFIG & DIRECTORIES
#############################################
NS="${1:-s2}"
PARALLEL=6

CACHE_DIR="${HOME}/.k8s-deploy-cache"
LOG_FILE="${CACHE_DIR}/fetch_kube.log"
REPORT_FILE="./report.html"

TAG_CACHE_DIR="${CACHE_DIR}/tagcache"
CB_CACHE_DIR="${CACHE_DIR}/common_branches"

mkdir -p "$CACHE_DIR" "$TAG_CACHE_DIR" "$CB_CACHE_DIR"

timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){ echo "[$(timestamp)] $*" | tee -a "$LOG_FILE"; }

#############################################
# CATEGORY STRUCTURE / REPO MAP (MACOS SAFE)
#############################################

declare -A REPO_MAP=(
  ["oms-api"]="oms"
  ["oms-consumer"]="oms"
  ["oms-scheduler"]="oms"
  ["oms-worker"]="oms"
  ["oms-web"]="oms-web"

  ["health-api"]="health-api"
  ["health-celery-beat"]="health-api"
  ["health-celery-worker"]="health-api"
  ["health-consumer"]="health-api"
  ["health-s3-nginx"]="health-api"

  ["partner-api"]="partner-api"
  ["partner-consumer"]="partner-api"
  ["partner-scheduler"]="partner-api"
  ["partner-web"]="partner-web"
  ["partner-worker-high"]="partner-api"
  ["partner-worker-low"]="partner-api"
  ["partner-worker-medium"]="partner-api"

  ["occ-api"]="occ"
  ["occ-web"]="occ-web"

  ["bifrost"]="bifrost"
)

declare -A CATEGORIES=(
  ["oms"]="oms-api oms-consumer oms-scheduler oms-web oms-worker"
  ["health"]="health-api health-celery-beat health-celery-worker health-consumer health-s3-nginx"
  ["partner"]="partner-api partner-consumer partner-scheduler partner-web partner-worker-high partner-worker-low partner-worker-medium"
  ["occ"]="occ-api occ-web"
  ["web"]="bifrost"
)


#############################################
# TAG CACHE HELPERS
#############################################

tag_cache_file(){ echo "${TAG_CACHE_DIR}/${1}.txt"; }

read_tag_cache() {
  local f
  f=$(tag_cache_file "$1")
  [[ -f "$f" ]] && cat "$f" || return 1
}

write_tag_cache() {
  local svc="$1"
  local tag="$2"
  echo "$tag" > "$(tag_cache_file "$svc")"
}

#############################################
# COMMON BRANCHES CACHE HELPERS
#############################################

cb_cache_file() {
  local repo="$1"
  local tag="$2"
  echo "${CB_CACHE_DIR}/${repo}-${tag}.txt"
}

cb_write_cache() {
  local repo="$1"
  local tag="$2"
  local tmp="$3"
  cp "$tmp" "$(cb_cache_file "$repo" "$tag")"

  # keep last 3 results only
  ls -1t "${CB_CACHE_DIR}/${repo}-"*.txt 2>/dev/null \
    | tail -n +4 \
    | xargs -I{} rm -f "{}" 2>/dev/null || true
}

#############################################
# BUILT-IN common_branches() USING GITHUB API
#############################################

common_branches() {
  local repo="$1"     # example: oms
  local tag="$2"      # example: vs2-dec-18

  local cache_file
  cache_file=$(cb_cache_file "$repo" "$tag")

  # CACHE HIT → super fast
  if [[ -f "$cache_file" ]]; then
    cat "$cache_file"
    return
  fi

  # CACHE MISS → fetch from GitHub API
  local api="https://api.github.com/repos/Orange-Health/${repo}"
  local auth=(-H "Authorization: Bearer $GITHUB_TOKEN")

  tmpfile=$(mktemp)

  branches=$(curl -sf "${auth[@]}" "$api/branches?per_page=200" || echo "[]")

  echo "$branches" \
    | jq -r '.[] | select(.name | ascii_downcase | contains("common")) | .name' \
    | while read -r br; do
        commit_json=$(curl -sf "${auth[@]}" "$api/commits/${br}" || echo "{}")

        sha=$(echo "$commit_json" | jq -r '.sha // empty')
        date=$(echo "$commit_json" | jq -r '.commit.committer.date // empty')
        author=$(echo "$commit_json" | jq -r '.commit.committer.name // empty')

        [[ -z "$sha" || -z "$date" ]] && continue

        # pretty date format
        pretty=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$date" "+%d %b %I:%M %p" 2>/dev/null || echo "$date")

        printf "%-22s %-16s %-20s https://github.com/Orange-Health/%s/commit/%s\n" \
          "$br" "$pretty" "$author" "$repo" "$sha"
      done | tee "$tmpfile"

  cb_write_cache "$repo" "$tag" "$tmpfile"
  rm -f "$tmpfile"
}

#############################################
# LOAD K8S JSON — ONLY 3 CALLS
#############################################

log "Loading K8s objects (deployments, pods, rs)…"

DEPLOY_JSON=$(kubectl -n "$NS" get deployments -o json)
POD_JSON=$(kubectl -n "$NS" get pods -o json)
RS_JSON=$(kubectl -n "$NS" get rs -o json)

#############################################
# IMAGE / TAG RESOLUTION (MACOS SAFE)
#############################################

resolve_image() {
  local svc="$1"
  local img=""

  # Deployment
  img=$(echo "$DEPLOY_JSON" \
    | jq -r --arg s "$svc" '
        .items[] | select(.metadata.name==$s)
        | .spec.template.spec.containers[0].image // empty')
  [[ -n "$img" ]] && { echo "$img"; return; }

  # ReplicaSet
  img=$(echo "$RS_JSON" \
    | jq -r --arg s "$svc" '
        .items[]
        | select(.metadata.ownerReferences[0].name==$s)
        | .spec.template.spec.containers[0].image // empty')
  [[ -n "$img" ]] && { echo "$img"; return; }

  # Pod by label
  img=$(echo "$POD_JSON" \
    | jq -r --arg s "$svc" '
        .items[] | select(.metadata.labels.pod==$s)
        | .spec.containers[0].image // empty')
  [[ -n "$img" ]] && { echo "$img"; return; }

  # Pod by prefix
  img=$(echo "$POD_JSON" \
    | jq -r --arg s "$svc" '
        .items[] | select(.metadata.name|startswith($s))
        | .spec.containers[0].image // empty')
  [[ -n "$img" ]] && { echo "$img"; return; }

  echo ""
}

extract_tag() {
  local img="$1"
  [[ -z "$img" ]] && { echo "<none>"; return; }
  [[ "$img" == *"@"* ]] && { echo "<none>"; return; }
  [[ "$img" == *":"* ]] && { echo "${img##*:}"; return; }
  echo "<none>"
}

#############################################
# POD INFO HELPER
#############################################

pod_info() {
  local pod="$1"
  echo "$POD_JSON" \
    | jq -r --arg p "$pod" '
        .items[] | select(.metadata.name==$p) |
        {
          name:.metadata.name,
          start:.status.startTime,
          restarts:(.status.containerStatuses[0].restartCount),
          ready:(.status.containerStatuses[0].ready),
          state:(if .status.containerStatuses[0].state.running then "Running"
                 elif .status.containerStatuses[0].state.waiting then "Waiting"
                 elif .status.containerStatuses[0].state.terminated then "Terminated"
                 else "Unknown" end)
        }
        | "\(.name) | \(.start) | ready:\(.ready) restarts:\(.restarts) | \(.state)"'
}


#############################################
# PROCESS A SINGLE SERVICE → HTML FRAGMENT
#############################################

TMPDIR=$(mktemp -d)

process_service() {
  local svc="$1"
  local frag="$TMPDIR/${svc}.html"

  log "Processing $svc …"

  # macOS-safe associative array lookup
  local repo="${REPO_MAP[$svc]:-unknown}"

  # TAG — from cache or fresh
  local tag=""
  if tag_cached=$(read_tag_cache "$svc" 2>/dev/null); then
    tag="$tag_cached"
  else
    local img
    img=$(resolve_image "$svc")
    tag=$(extract_tag "$img")
    write_tag_cache "$svc" "$tag"
  fi

  # DEPLOY TIME
  local deployed_at
  deployed_at=$(
    echo "$DEPLOY_JSON" \
      | jq -r --arg s "$svc" '
          .items[] | select(.metadata.name==$s)
          | (.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"]
             // .metadata.creationTimestamp
             // "N/A")'
  )

  # STATUS (replicas)
  local replicas available
  replicas=$(echo "$DEPLOY_JSON" | jq -r --arg s "$svc" '.items[] | select(.metadata.name==$s) | .spec.replicas // 0')
  available=$(echo "$DEPLOY_JSON" | jq -r --arg s "$svc" '.items[] | select(.metadata.name==$s) | .status.availableReplicas // 0')

  local status="avail:${available}/${replicas}"
  local status_class="status-degraded"
  if (( available >= replicas )) && (( replicas > 0 )); then
    status_class="status-ok"
  fi
  if (( replicas == 0 )); then
    status_class="status-missing"
  fi

  # PODS
  podlist=$(
    echo "$POD_JSON" \
      | jq -r --arg s "$svc" '
          .items[]
          | select(.metadata.labels.pod==$s or .metadata.name|startswith($s))
          | .metadata.name'
  )

  #############################################
  # BUILD HTML FRAGMENT
  #############################################
  {
    echo "<div class='card'>"
    echo "<div class='svc-title'>$svc</div>"
    echo "<div><b>Repo:</b> $repo</div>"
    echo "<div><b>Tag:</b> $tag</div>"

    echo "<div class='status-row'>"
    echo "<span class='status $status_class'>$status</span>"
    echo "<span class='deployed'>Deployed: $deployed_at</span>"
    echo "</div>"

    #############################################
    # PODS DROPDOWN
    #############################################
    echo "<details><summary>Pods</summary><pre>"
    if [[ -z "$podlist" ]]; then
      echo "No pods found"
    else
      while read -r p; do
        [[ -z "$p" ]] && continue
        pod_info "$p"
      done <<< "$podlist"
    fi
    echo "</pre></details>"

    #############################################
    # COMMON BRANCHES (CURRENT)
    #############################################
    echo "<details open><summary>common_branches (current)</summary><pre>"
    if [[ "$tag" == "<none>" ]]; then
      echo "Skipped (no tag)"
    else
      common_branches "$repo" "$tag"
    fi
    echo "</pre></details>"

    #############################################
    # COMMON BRANCHES HISTORY (LAST 3)
    #############################################
    echo "<details><summary>History (last 3)</summary><pre>"
    ls -1t "${CB_CACHE_DIR}/${repo}-"*.txt 2>/dev/null \
      | head -n 3 \
      | while read -r h; do
          echo "--- ${h##*/} ---"
          cat "$h"
          echo
        done
    echo "</pre></details>"

    echo "</div>"
  } > "$frag"
}

#############################################
# PARALLEL EXECUTION
#############################################

for cat in "${!CATEGORIES[@]}"; do
  log "Category: $cat"

  for svc in ${CATEGORIES[$cat]}; do
    process_service "$svc" &
    while (( $(jobs -r | wc -l) >= PARALLEL )); do
      sleep 0.05
    done
  done
done

wait

#############################################
# BUILD FINAL HTML REPORT
#############################################

cat > "$REPORT_FILE" <<'EOF'
<!doctype html>
<html><head>
<meta charset="utf-8">
<title>K8s Deployment Report</title>
<style>
body{font-family:-apple-system;background:#f5f6fa;margin:20px;}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(350px,1fr));gap:16px;}
.card{background:white;padding:14px;border-radius:12px;box-shadow:0 2px 6px rgba(0,0,0,0.08);}
.svc-title{font-size:18px;font-weight:600;margin-bottom:8px;}
.status{padding:4px 8px;border-radius:6px;font-size:12px;}
.status-ok{background:#d4f7da;color:#067a12;}
.status-degraded{background:#ffe7c2;color:#ad6200;}
.status-missing{background:#ffd4d4;color:#a40000;}
pre{background:#0b1220;color:#e7eef8;padding:10px;border-radius:8px;font-size:12px;white-space:pre-wrap;}
.summary{cursor:pointer;}
</style>
</head><body>
<h2>K8s Deployment Report</h2>
<div class="grid">
EOF

cat "$TMPDIR"/*.html >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<'EOF'
</div>
</body></html>
EOF

log "Report generated → $REPORT_FILE"
echo "Open report with: open $REPORT_FILE"

