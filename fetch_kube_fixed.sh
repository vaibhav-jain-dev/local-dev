#!/usr/bin/env bash
set -eo pipefail  # Removed -u flag to fix unbound variable error


# ============================================================
#  fetch_kube_fixed.sh
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
#    - If the tag didn't change, results load instantly.
#    - Keeps last 3 historical tags for reference.
#
#  • Generates a clean, interactive HTML report with:
#       - Service cards in grid layout
#       - Search and filter functionality
#       - Real-time status indicators
#       - Expandable sections
#       - Dark/Light theme toggle
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
#        ./fetch_kube_fixed.sh <namespace>
#
#     Example:
#        ./fetch_kube_fixed.sh s2
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
#  • GITHUB_TOKEN environment variable
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
# VALIDATE GITHUB TOKEN
#############################################
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "============================================================"
  echo "❌ ERROR: GITHUB_TOKEN environment variable not set!"
  echo "============================================================"
  echo ""
  echo "Please export your GitHub token:"
  echo "  export GITHUB_TOKEN='your_github_token_here'"
  echo ""
  echo "Then rerun the script:"
  echo "  $0 $*"
  echo ""
  exit 1
fi

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
# CATEGORY STRUCTURE / REPO MAP (FIXED)
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
# IMAGE / TAG RESOLUTION (FIXED)
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

  # FIXED: Use default value syntax to prevent unbound variable error
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
    echo "<div class='card' data-service='$svc' data-repo='$repo' data-status='$status_class'>"
    echo "<div class='svc-title'>"
    echo "  <span class='svc-name'>$svc</span>"
    echo "  <span class='status $status_class'>$status</span>"
    echo "</div>"
    echo "<div class='svc-info'>"
    echo "  <div class='info-item'><strong>Repo:</strong> <a href='https://github.com/Orange-Health/$repo' target='_blank'>$repo</a></div>"
    echo "  <div class='info-item'><strong>Tag:</strong> <code class='tag'>$tag</code></div>"
    echo "  <div class='info-item'><strong>Deployed:</strong> <span class='deployed-time'>$deployed_at</span></div>"
    echo "</div>"

    #############################################
    # PODS DROPDOWN
    #############################################
    echo "<details class='section'><summary>📦 Pods</summary><pre class='code-block'>"
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
    echo "<details open class='section'><summary>🌿 Common Branches (current)</summary><pre class='code-block'>"
    if [[ "$tag" == "<none>" ]]; then
      echo "Skipped (no tag)"
    else
      common_branches "$repo" "$tag"
    fi
    echo "</pre></details>"

    #############################################
    # COMMON BRANCHES HISTORY (LAST 3)
    #############################################
    echo "<details class='section'><summary>📚 History (last 3)</summary><pre class='code-block'>"
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
# BUILD FINAL HTML REPORT (EMBEDDED TEMPLATE)
#############################################

cat > "$REPORT_FILE" <<'HTMLTEMPLATE'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>K8s Deployment Report</title>
<style>
:root {
  --bg-primary: #f5f7fa;
  --bg-secondary: #ffffff;
  --bg-code: #1e1e2e;
  --text-primary: #2c3e50;
  --text-secondary: #7f8c8d;
  --text-code: #e0e0e0;
  --border: #e1e8ed;
  --shadow: rgba(0, 0, 0, 0.08);
  --accent: #3498db;
  --status-ok: #2ecc71;
  --status-ok-bg: #d4f7da;
  --status-degraded: #f39c12;
  --status-degraded-bg: #ffe7c2;
  --status-missing: #e74c3c;
  --status-missing-bg: #ffd4d4;
}

[data-theme="dark"] {
  --bg-primary: #0d1117;
  --bg-secondary: #161b22;
  --bg-code: #0d1117;
  --text-primary: #c9d1d9;
  --text-secondary: #8b949e;
  --text-code: #c9d1d9;
  --border: #30363d;
  --shadow: rgba(0, 0, 0, 0.3);
}

* { margin: 0; padding: 0; box-sizing: border-box; }

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
  background: var(--bg-primary);
  color: var(--text-primary);
  padding: 20px;
  line-height: 1.6;
  transition: background 0.3s, color 0.3s;
}

.header {
  max-width: 1400px;
  margin: 0 auto 30px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-wrap: wrap;
  gap: 20px;
}

.header h1 {
  font-size: 28px;
  font-weight: 700;
  color: var(--text-primary);
}

.controls {
  display: flex;
  gap: 15px;
  flex-wrap: wrap;
  align-items: center;
}

.search-box {
  position: relative;
}

.search-box input {
  padding: 10px 40px 10px 15px;
  border: 2px solid var(--border);
  border-radius: 8px;
  background: var(--bg-secondary);
  color: var(--text-primary);
  font-size: 14px;
  width: 300px;
  transition: border-color 0.2s;
}

.search-box input:focus {
  outline: none;
  border-color: var(--accent);
}

.search-box::after {
  content: '🔍';
  position: absolute;
  right: 12px;
  top: 50%;
  transform: translateY(-50%);
}

.filter-group {
  display: flex;
  gap: 10px;
}

.filter-btn {
  padding: 8px 16px;
  border: 2px solid var(--border);
  border-radius: 8px;
  background: var(--bg-secondary);
  color: var(--text-primary);
  cursor: pointer;
  font-size: 13px;
  font-weight: 500;
  transition: all 0.2s;
}

.filter-btn:hover {
  border-color: var(--accent);
}

.filter-btn.active {
  background: var(--accent);
  color: white;
  border-color: var(--accent);
}

.theme-toggle {
  padding: 10px 20px;
  border: none;
  border-radius: 8px;
  background: var(--accent);
  color: white;
  cursor: pointer;
  font-size: 14px;
  font-weight: 600;
  transition: opacity 0.2s;
}

.theme-toggle:hover {
  opacity: 0.9;
}

.stats {
  max-width: 1400px;
  margin: 0 auto 20px;
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 15px;
}

.stat-card {
  background: var(--bg-secondary);
  padding: 15px;
  border-radius: 12px;
  border: 1px solid var(--border);
  text-align: center;
}

.stat-number {
  font-size: 28px;
  font-weight: 700;
  margin-bottom: 5px;
}

.stat-label {
  font-size: 13px;
  color: var(--text-secondary);
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(380px, 1fr));
  gap: 20px;
  max-width: 1400px;
  margin: 0 auto;
}

.card {
  background: var(--bg-secondary);
  padding: 20px;
  border-radius: 12px;
  box-shadow: 0 2px 8px var(--shadow);
  border: 1px solid var(--border);
  transition: transform 0.2s, box-shadow 0.2s;
  animation: fadeIn 0.3s ease-in;
}

.card:hover {
  transform: translateY(-2px);
  box-shadow: 0 4px 12px var(--shadow);
}

.card.hidden {
  display: none;
}

@keyframes fadeIn {
  from { opacity: 0; transform: translateY(10px); }
  to { opacity: 1; transform: translateY(0); }
}

.svc-title {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 15px;
  padding-bottom: 12px;
  border-bottom: 2px solid var(--border);
}

.svc-name {
  font-size: 20px;
  font-weight: 700;
  color: var(--text-primary);
}

.svc-info {
  margin-bottom: 15px;
}

.info-item {
  margin-bottom: 8px;
  font-size: 14px;
}

.info-item strong {
  color: var(--text-secondary);
  font-weight: 600;
  display: inline-block;
  min-width: 80px;
}

.info-item a {
  color: var(--accent);
  text-decoration: none;
}

.info-item a:hover {
  text-decoration: underline;
}

.tag {
  background: var(--bg-code);
  color: var(--text-code);
  padding: 3px 8px;
  border-radius: 4px;
  font-family: 'Monaco', 'Consolas', monospace;
  font-size: 13px;
}

.deployed-time {
  font-size: 12px;
  color: var(--text-secondary);
}

.status {
  padding: 6px 12px;
  border-radius: 6px;
  font-size: 12px;
  font-weight: 600;
  white-space: nowrap;
}

.status-ok {
  background: var(--status-ok-bg);
  color: var(--status-ok);
}

.status-degraded {
  background: var(--status-degraded-bg);
  color: var(--status-degraded);
}

.status-missing {
  background: var(--status-missing-bg);
  color: var(--status-missing);
}

.section {
  margin-bottom: 12px;
  border: 1px solid var(--border);
  border-radius: 8px;
  overflow: hidden;
}

.section summary {
  padding: 12px 15px;
  background: var(--bg-primary);
  cursor: pointer;
  font-weight: 600;
  font-size: 14px;
  user-select: none;
  transition: background 0.2s;
}

.section summary:hover {
  background: var(--border);
}

.section[open] summary {
  border-bottom: 1px solid var(--border);
}

.code-block {
  background: var(--bg-code);
  color: var(--text-code);
  padding: 15px;
  border-radius: 0;
  font-size: 12px;
  font-family: 'Monaco', 'Consolas', monospace;
  white-space: pre-wrap;
  overflow-x: auto;
  margin: 0;
  line-height: 1.5;
}

.no-results {
  text-align: center;
  padding: 60px 20px;
  color: var(--text-secondary);
  font-size: 18px;
  display: none;
}

.no-results.show {
  display: block;
}

@media (max-width: 768px) {
  .grid {
    grid-template-columns: 1fr;
  }

  .header {
    flex-direction: column;
    align-items: stretch;
  }

  .controls {
    flex-direction: column;
  }

  .search-box input {
    width: 100%;
  }
}
</style>
</head>
<body>

<div class="header">
  <h1>🚀 K8s Deployment Report - NAMESPACE_PLACEHOLDER</h1>
  <div class="controls">
    <div class="search-box">
      <input type="text" id="searchInput" placeholder="Search services...">
    </div>
    <div class="filter-group">
      <button class="filter-btn active" data-filter="all">All</button>
      <button class="filter-btn" data-filter="status-ok">✅ Healthy</button>
      <button class="filter-btn" data-filter="status-degraded">⚠️ Degraded</button>
      <button class="filter-btn" data-filter="status-missing">❌ Missing</button>
    </div>
    <button class="theme-toggle" onclick="toggleTheme()">🌓 Toggle Theme</button>
  </div>
</div>

<div class="stats">
  <div class="stat-card">
    <div class="stat-number" id="totalServices">0</div>
    <div class="stat-label">Total Services</div>
  </div>
  <div class="stat-card">
    <div class="stat-number" id="healthyServices" style="color: var(--status-ok)">0</div>
    <div class="stat-label">Healthy</div>
  </div>
  <div class="stat-card">
    <div class="stat-number" id="degradedServices" style="color: var(--status-degraded)">0</div>
    <div class="stat-label">Degraded</div>
  </div>
  <div class="stat-card">
    <div class="stat-number" id="missingServices" style="color: var(--status-missing)">0</div>
    <div class="stat-label">Missing</div>
  </div>
</div>

<div class="grid" id="serviceGrid">
CARDS_PLACEHOLDER
</div>

<div class="no-results" id="noResults">
  No services found matching your criteria
</div>

<script>
// Theme toggle
function toggleTheme() {
  const html = document.documentElement;
  const currentTheme = html.getAttribute('data-theme');
  const newTheme = currentTheme === 'dark' ? 'light' : 'dark';
  html.setAttribute('data-theme', newTheme);
  localStorage.setItem('theme', newTheme);
}

// Load saved theme
const savedTheme = localStorage.getItem('theme') || 'light';
document.documentElement.setAttribute('data-theme', savedTheme);

// Search functionality
const searchInput = document.getElementById('searchInput');
const cards = document.querySelectorAll('.card');
const noResults = document.getElementById('noResults');

searchInput.addEventListener('input', filterCards);

// Filter functionality
const filterBtns = document.querySelectorAll('.filter-btn');
let activeFilter = 'all';

filterBtns.forEach(btn => {
  btn.addEventListener('click', () => {
    filterBtns.forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    activeFilter = btn.dataset.filter;
    filterCards();
  });
});

function filterCards() {
  const searchTerm = searchInput.value.toLowerCase();
  let visibleCount = 0;

  cards.forEach(card => {
    const service = card.dataset.service.toLowerCase();
    const repo = card.dataset.repo.toLowerCase();
    const status = card.dataset.status;

    const matchesSearch = service.includes(searchTerm) || repo.includes(searchTerm);
    const matchesFilter = activeFilter === 'all' || status === activeFilter;

    if (matchesSearch && matchesFilter) {
      card.classList.remove('hidden');
      visibleCount++;
    } else {
      card.classList.add('hidden');
    }
  });

  noResults.classList.toggle('show', visibleCount === 0);
}

// Calculate stats
function updateStats() {
  const total = cards.length;
  const healthy = document.querySelectorAll('[data-status="status-ok"]').length;
  const degraded = document.querySelectorAll('[data-status="status-degraded"]').length;
  const missing = document.querySelectorAll('[data-status="status-missing"]').length;

  document.getElementById('totalServices').textContent = total;
  document.getElementById('healthyServices').textContent = healthy;
  document.getElementById('degradedServices').textContent = degraded;
  document.getElementById('missingServices').textContent = missing;
}

updateStats();

// Auto-refresh notice
console.log('Report generated at: ' + new Date().toLocaleString());
</script>

</body>
</html>
HTMLTEMPLATE

# Replace placeholders
sed -i.bak "s/NAMESPACE_PLACEHOLDER/$NS/g" "$REPORT_FILE"
sed -i.bak "s|CARDS_PLACEHOLDER|$(cat "$TMPDIR"/*.html 2>/dev/null)||g" "$REPORT_FILE"
rm -f "${REPORT_FILE}.bak"

log "Report generated → $REPORT_FILE"
echo ""
echo "============================================================"
echo "✅ Report generated successfully!"
echo "============================================================"
echo ""
echo "Open report with:"
echo "  open $REPORT_FILE"
echo ""
