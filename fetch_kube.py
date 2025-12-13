#!/usr/bin/env python3
"""
fetch_kube.py

WHAT THIS SCRIPT DOES
--------------------------------------------------------------
• Fetches ALL deployments, pods, and replica sets in a given
  Kubernetes namespace using only 3 kubectl calls.

• For every service in predefined categories (oms, health,
  partner, occ, web):
     - Finds the deployed image and extracts the tag.
     - Shows deployed timestamp and replica availability.
     - Lists all pods with state, restarts, readiness.

• Calls common_branches() for that service's GitHub repo
  using GitHub API (NOT git clone).

• Caches common branch output per (repo + tag).
  - If the tag didn't change, results load instantly.
  - Keeps last 3 historical tags for reference.

• Generates a clean HTML report with:
     - Service cards in grid layout
     - Current tag info
     - Pods dropdown
     - Common branches dropdown
     - History dropdown (last 3 tags)

• Saves output to:  ./report.html


HOW TO RUN
--------------------------------------------------------------
1. Ensure GitHub token exported:
      export GITHUB_TOKEN="xxxxxx"

2. Run the script:
      python3 fetch_kube.py <namespace>

   Example:
      python3 fetch_kube.py s2

   If namespace omitted, default = "s2"

   Note: Dependencies will be auto-installed on first run if missing.
   You'll be asked to rerun the script after installation.


PREREQUISITES
--------------------------------------------------------------
• Python 3.7+
• kubectl configured to correct cluster
• GITHUB_TOKEN environment variable (required)
• aiohttp library (auto-installs if missing)


OUTPUT
--------------------------------------------------------------
- CLI logs written to ~/.k8s-deploy-cache/fetch_kube.log
- HTML report saved to ./report.html
- Cached tags and cached common branches stored under:
      ~/.k8s-deploy-cache/
"""

import asyncio
import json
import os
import sys
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple
import logging
from collections import defaultdict

# ============================================================
# AUTO-INSTALL DEPENDENCIES
# ============================================================

try:
    import aiohttp
except ImportError:
    print("=" * 60)
    print("ERROR: Required module 'aiohttp' not found!")
    print("=" * 60)
    print("\nAttempting to install dependencies automatically...\n")

    script_dir = Path(__file__).parent
    requirements_file = script_dir / "requirements-fetch-kube.txt"

    if requirements_file.exists():
        try:
            subprocess.check_call([
                sys.executable, "-m", "pip", "install", "-r", str(requirements_file)
            ])
            print("\n" + "=" * 60)
            print("✅ Dependencies installed successfully!")
            print("=" * 60)
            print("\nPlease RERUN the script:")
            print(f"  python3 {sys.argv[0]} {' '.join(sys.argv[1:])}\n")
            sys.exit(0)
        except subprocess.CalledProcessError as e:
            print("\n" + "=" * 60)
            print("❌ Failed to install dependencies automatically")
            print("=" * 60)
            print(f"\nPlease install manually:")
            print(f"  pip install -r {requirements_file}\n")
            sys.exit(1)
    else:
        print(f"\n❌ Requirements file not found: {requirements_file}")
        print("\nPlease install manually:")
        print("  pip install aiohttp\n")
        sys.exit(1)


# ============================================================
# VALIDATE GITHUB TOKEN
# ============================================================

GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN")
if not GITHUB_TOKEN:
    print("=" * 60)
    print("❌ ERROR: GITHUB_TOKEN environment variable not set!")
    print("=" * 60)
    print("\nPlease export your GitHub token:")
    print("  export GITHUB_TOKEN='your_github_token_here'\n")
    print("Then rerun the script:")
    print(f"  python3 {sys.argv[0]} {' '.join(sys.argv[1:])}\n")
    sys.exit(1)


# ============================================================
# CONFIG & DIRECTORIES
# ============================================================

NAMESPACE = sys.argv[1] if len(sys.argv) > 1 else "s2"
MAX_CONCURRENT = 10  # Parallelism for service processing
MAX_GITHUB_CONCURRENT = 5  # Parallelism for GitHub API calls

CACHE_DIR = Path.home() / ".k8s-deploy-cache"
LOG_FILE = CACHE_DIR / "fetch_kube.log"
REPORT_FILE = Path("./report.html")

TAG_CACHE_DIR = CACHE_DIR / "tagcache"
CB_CACHE_DIR = CACHE_DIR / "common_branches"

# Create directories
CACHE_DIR.mkdir(exist_ok=True)
TAG_CACHE_DIR.mkdir(exist_ok=True)
CB_CACHE_DIR.mkdir(exist_ok=True)

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
log = logging.getLogger(__name__)


# ============================================================
# CATEGORY STRUCTURE / REPO MAP
# ============================================================

REPO_MAP = {
    "oms-api": "oms",
    "oms-consumer": "oms",
    "oms-scheduler": "oms",
    "oms-worker": "oms",
    "oms-web": "oms-web",

    "health-api": "health-api",
    "health-celery-beat": "health-api",
    "health-celery-worker": "health-api",
    "health-consumer": "health-api",
    "health-s3-nginx": "health-api",

    "partner-api": "partner-api",
    "partner-consumer": "partner-api",
    "partner-scheduler": "partner-api",
    "partner-web": "partner-web",
    "partner-worker-high": "partner-api",
    "partner-worker-low": "partner-api",
    "partner-worker-medium": "partner-api",

    "occ-api": "occ",
    "occ-web": "occ-web",

    "bifrost": "bifrost",
}

CATEGORIES = {
    "oms": ["oms-api", "oms-consumer", "oms-scheduler", "oms-web", "oms-worker"],
    "health": ["health-api", "health-celery-beat", "health-celery-worker", "health-consumer", "health-s3-nginx"],
    "partner": ["partner-api", "partner-consumer", "partner-scheduler", "partner-web",
                "partner-worker-high", "partner-worker-low", "partner-worker-medium"],
    "occ": ["occ-api", "occ-web"],
    "web": ["bifrost"],
}


# ============================================================
# TAG CACHE HELPERS
# ============================================================

def tag_cache_file(service: str) -> Path:
    return TAG_CACHE_DIR / f"{service}.txt"


def read_tag_cache(service: str) -> Optional[str]:
    cache_file = tag_cache_file(service)
    if cache_file.exists():
        return cache_file.read_text().strip()
    return None


def write_tag_cache(service: str, tag: str):
    cache_file = tag_cache_file(service)
    cache_file.write_text(tag)


# ============================================================
# COMMON BRANCHES CACHE HELPERS
# ============================================================

def cb_cache_file(repo: str, tag: str) -> Path:
    return CB_CACHE_DIR / f"{repo}-{tag}.txt"


def cb_write_cache(repo: str, tag: str, content: str):
    cache_file = cb_cache_file(repo, tag)
    cache_file.write_text(content)

    # Keep last 3 results only
    pattern = f"{repo}-*.txt"
    cache_files = sorted(CB_CACHE_DIR.glob(pattern), key=lambda p: p.stat().st_mtime, reverse=True)
    for old_file in cache_files[3:]:
        old_file.unlink()


def get_cb_history(repo: str) -> List[Tuple[str, str]]:
    """Get last 3 cached common branches results for a repo."""
    pattern = f"{repo}-*.txt"
    cache_files = sorted(CB_CACHE_DIR.glob(pattern), key=lambda p: p.stat().st_mtime, reverse=True)
    history = []
    for cache_file in cache_files[:3]:
        content = cache_file.read_text()
        history.append((cache_file.name, content))
    return history


# ============================================================
# KUBERNETES DATA LOADING
# ============================================================

async def load_k8s_data() -> Tuple[dict, dict, dict]:
    """Load deployments, pods, and replica sets in parallel."""
    log.info("Loading K8s objects (deployments, pods, rs)…")

    async def run_kubectl(resource: str) -> dict:
        cmd = ["kubectl", "-n", NAMESPACE, "get", resource, "-o", "json"]
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await proc.communicate()
        if proc.returncode != 0:
            log.error(f"kubectl get {resource} failed: {stderr.decode()}")
            return {"items": []}
        return json.loads(stdout.decode())

    # Run all kubectl commands in parallel
    deployments, pods, rs = await asyncio.gather(
        run_kubectl("deployments"),
        run_kubectl("pods"),
        run_kubectl("rs")
    )

    return deployments, pods, rs


# ============================================================
# IMAGE / TAG RESOLUTION
# ============================================================

def resolve_image(service: str, deploy_json: dict, pod_json: dict, rs_json: dict) -> str:
    """Resolve the image for a service from K8s data."""

    # Try Deployment
    for item in deploy_json.get("items", []):
        if item.get("metadata", {}).get("name") == service:
            containers = item.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
            if containers:
                return containers[0].get("image", "")

    # Try ReplicaSet
    for item in rs_json.get("items", []):
        owner_refs = item.get("metadata", {}).get("ownerReferences", [])
        if owner_refs and owner_refs[0].get("name") == service:
            containers = item.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
            if containers:
                return containers[0].get("image", "")

    # Try Pod by label
    for item in pod_json.get("items", []):
        labels = item.get("metadata", {}).get("labels", {})
        if labels.get("pod") == service:
            containers = item.get("spec", {}).get("containers", [])
            if containers:
                return containers[0].get("image", "")

    # Try Pod by prefix
    for item in pod_json.get("items", []):
        name = item.get("metadata", {}).get("name", "")
        if name.startswith(service):
            containers = item.get("spec", {}).get("containers", [])
            if containers:
                return containers[0].get("image", "")

    return ""


def extract_tag(image: str) -> str:
    """Extract tag from image string."""
    if not image:
        return "<none>"
    if "@" in image:
        return "<none>"
    if ":" in image:
        return image.split(":")[-1]
    return "<none>"


# ============================================================
# POD INFO HELPER
# ============================================================

def get_pod_info(pod_name: str, pod_json: dict) -> str:
    """Get formatted pod information."""
    for item in pod_json.get("items", []):
        if item.get("metadata", {}).get("name") == pod_name:
            name = item.get("metadata", {}).get("name", "")
            start_time = item.get("status", {}).get("startTime", "N/A")

            container_statuses = item.get("status", {}).get("containerStatuses", [{}])
            if container_statuses:
                container = container_statuses[0]
                restarts = container.get("restartCount", 0)
                ready = container.get("ready", False)

                state = "Unknown"
                if container.get("state", {}).get("running"):
                    state = "Running"
                elif container.get("state", {}).get("waiting"):
                    state = "Waiting"
                elif container.get("state", {}).get("terminated"):
                    state = "Terminated"

                return f"{name} | {start_time} | ready:{ready} restarts:{restarts} | {state}"

            return f"{name} | {start_time} | N/A"

    return f"{pod_name} | Not found"


def get_pods_for_service(service: str, pod_json: dict) -> List[str]:
    """Get all pod names for a service."""
    pods = []
    for item in pod_json.get("items", []):
        labels = item.get("metadata", {}).get("labels", {})
        name = item.get("metadata", {}).get("name", "")

        if labels.get("pod") == service or name.startswith(service):
            pods.append(name)

    return pods


# ============================================================
# GITHUB API - COMMON BRANCHES
# ============================================================

async def fetch_common_branches(session: aiohttp.ClientSession, repo: str, tag: str) -> str:
    """Fetch common branches for a repo using GitHub API."""

    cache_file = cb_cache_file(repo, tag)

    # CACHE HIT
    if cache_file.exists():
        log.info(f"Cache hit for {repo}:{tag}")
        return cache_file.read_text()

    # CACHE MISS - fetch from GitHub API
    log.info(f"Fetching common branches for {repo}:{tag}")

    api_base = f"https://api.github.com/repos/Orange-Health/{repo}"
    headers = {"Authorization": f"Bearer {GITHUB_TOKEN}"}

    results = []

    try:
        # Fetch branches
        async with session.get(f"{api_base}/branches?per_page=200", headers=headers) as resp:
            if resp.status != 200:
                return f"ERROR: GitHub API returned {resp.status}"
            branches = await resp.json()

        # Filter common branches
        common_branches = [
            b["name"] for b in branches
            if "common" in b["name"].lower()
        ]

        # Fetch commit info for each branch (in parallel with limit)
        semaphore = asyncio.Semaphore(MAX_GITHUB_CONCURRENT)

        async def fetch_branch_info(branch_name: str):
            async with semaphore:
                try:
                    async with session.get(f"{api_base}/commits/{branch_name}", headers=headers) as resp:
                        if resp.status != 200:
                            return None
                        commit_data = await resp.json()

                    sha = commit_data.get("sha", "")
                    commit_info = commit_data.get("commit", {})
                    date_str = commit_info.get("committer", {}).get("date", "")
                    author = commit_info.get("committer", {}).get("name", "")

                    if not sha or not date_str:
                        return None

                    # Parse and format date
                    try:
                        dt = datetime.fromisoformat(date_str.replace("Z", "+00:00"))
                        pretty_date = dt.strftime("%d %b %I:%M %p")
                    except:
                        pretty_date = date_str

                    url = f"https://github.com/Orange-Health/{repo}/commit/{sha}"

                    return f"{branch_name:<22} {pretty_date:<16} {author:<20} {url}"

                except Exception as e:
                    log.error(f"Error fetching branch {branch_name}: {e}")
                    return None

        # Fetch all branch info in parallel
        branch_results = await asyncio.gather(*[fetch_branch_info(b) for b in common_branches])
        results = [r for r in branch_results if r]

    except Exception as e:
        log.error(f"Error fetching common branches for {repo}: {e}")
        return f"ERROR: {str(e)}"

    result_text = "\n".join(results) if results else "No common branches found"

    # Cache the result
    cb_write_cache(repo, tag, result_text)

    return result_text


# ============================================================
# SERVICE PROCESSING
# ============================================================

async def process_service(
    service: str,
    deploy_json: dict,
    pod_json: dict,
    rs_json: dict,
    session: aiohttp.ClientSession
) -> str:
    """Process a single service and return HTML fragment."""

    log.info(f"Processing {service}…")

    repo = REPO_MAP.get(service, "unknown")

    # Get tag (from cache or fresh)
    tag = read_tag_cache(service)
    if not tag:
        image = resolve_image(service, deploy_json, pod_json, rs_json)
        tag = extract_tag(image)
        write_tag_cache(service, tag)

    # Get deployment time
    deployed_at = "N/A"
    for item in deploy_json.get("items", []):
        if item.get("metadata", {}).get("name") == service:
            annotations = item.get("spec", {}).get("template", {}).get("metadata", {}).get("annotations", {})
            deployed_at = annotations.get(
                "kubectl.kubernetes.io/restartedAt",
                item.get("metadata", {}).get("creationTimestamp", "N/A")
            )
            break

    # Get replica status
    replicas = 0
    available = 0
    for item in deploy_json.get("items", []):
        if item.get("metadata", {}).get("name") == service:
            replicas = item.get("spec", {}).get("replicas", 0)
            available = item.get("status", {}).get("availableReplicas", 0)
            break

    status = f"avail:{available}/{replicas}"
    if replicas == 0:
        status_class = "status-missing"
    elif available >= replicas and replicas > 0:
        status_class = "status-ok"
    else:
        status_class = "status-degraded"

    # Get pods
    pod_list = get_pods_for_service(service, pod_json)
    pods_html = ""
    if not pod_list:
        pods_html = "No pods found"
    else:
        pods_html = "\n".join([get_pod_info(p, pod_json) for p in pod_list])

    # Get common branches (async)
    if tag == "<none>":
        common_branches_html = "Skipped (no tag)"
    else:
        common_branches_html = await fetch_common_branches(session, repo, tag)

    # Get history
    history_html = ""
    history = get_cb_history(repo)
    for filename, content in history:
        history_html += f"--- {filename} ---\n{content}\n\n"
    if not history_html:
        history_html = "No history available"

    # Build HTML fragment
    html = f"""<div class='card'>
<div class='svc-title'>{service}</div>
<div><b>Repo:</b> {repo}</div>
<div><b>Tag:</b> {tag}</div>
<div class='status-row'>
<span class='status {status_class}'>{status}</span>
<span class='deployed'>Deployed: {deployed_at}</span>
</div>
<details><summary>Pods</summary><pre>
{pods_html}
</pre></details>
<details open><summary>common_branches (current)</summary><pre>
{common_branches_html}
</pre></details>
<details><summary>History (last 3)</summary><pre>
{history_html}
</pre></details>
</div>
"""

    return html


# ============================================================
# MAIN EXECUTION
# ============================================================

async def main():
    log.info(f"Starting fetch_kube.py for namespace: {NAMESPACE}")

    # Load K8s data in parallel
    deploy_json, pod_json, rs_json = await load_k8s_data()

    # Create HTTP session for GitHub API
    async with aiohttp.ClientSession() as session:
        # Process all services with controlled concurrency
        semaphore = asyncio.Semaphore(MAX_CONCURRENT)

        async def process_with_semaphore(service: str):
            async with semaphore:
                return await process_service(service, deploy_json, pod_json, rs_json, session)

        # Collect all services
        all_services = []
        for category, services in CATEGORIES.items():
            log.info(f"Category: {category}")
            all_services.extend(services)

        # Process all services in parallel (with controlled concurrency)
        html_fragments = await asyncio.gather(*[process_with_semaphore(svc) for svc in all_services])

    # Build final HTML report
    html_header = """<!doctype html>
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
.status-row{display:flex;justify-content:space-between;align-items:center;margin:8px 0;}
.deployed{font-size:11px;color:#666;}
</style>
</head><body>
<h2>K8s Deployment Report - {namespace}</h2>
<div class="grid">
""".replace("{namespace}", NAMESPACE)

    html_footer = """</div>
</body></html>
"""

    # Write report
    with open(REPORT_FILE, "w") as f:
        f.write(html_header)
        f.write("\n".join(html_fragments))
        f.write(html_footer)

    log.info(f"Report generated → {REPORT_FILE}")
    print(f"\nOpen report with: open {REPORT_FILE}")


if __name__ == "__main__":
    asyncio.run(main())
