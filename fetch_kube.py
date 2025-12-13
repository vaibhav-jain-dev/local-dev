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

2. (Optional) Enable SSL verification if needed:
      export VERIFY_SSL=true

   Note: SSL verification is DISABLED by default to avoid certificate errors.
   Only enable if you have proper certificates configured.

3. Run the script:
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
import ssl
import argparse
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Dict, List, Optional, Tuple
import logging
from collections import defaultdict

# ============================================================
# AUTO-INSTALL DEPENDENCIES
# ============================================================

try:
    import aiohttp
    from jinja2 import Template
except ImportError as e:
    missing_module = str(e).split("'")[1] if "'" in str(e) else "required modules"
    print("=" * 60)
    print(f"ERROR: Required module '{missing_module}' not found!")
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
# COMMAND LINE ARGUMENTS
# ============================================================

parser = argparse.ArgumentParser(description='Generate K8s deployment report')
parser.add_argument('namespace', nargs='?', default='s2', help='Kubernetes namespace (default: s2)')
parser.add_argument('--fresh', action='store_true', help='Bypass all caches and fetch fresh data')
args = parser.parse_args()

# ============================================================
# CONFIG & DIRECTORIES
# ============================================================

NAMESPACE = args.namespace
USE_CACHE = not args.fresh  # Skip cache if --fresh flag is used
MAX_CONCURRENT = 10  # Parallelism for service processing
MAX_GITHUB_CONCURRENT = 5  # Parallelism for GitHub API calls

# SSL Configuration - set to False to disable SSL verification (useful for corporate proxies)
VERIFY_SSL = os.environ.get("VERIFY_SSL", "false").lower() in ("true", "1", "yes")

CACHE_DIR = Path.home() / ".k8s-deploy-cache"
LOG_FILE = CACHE_DIR / "fetch_kube.log"
REPORT_FILE = Path("./report.html")

TAG_CACHE_DIR = CACHE_DIR / "tagcache"
CB_CACHE_DIR = CACHE_DIR / "common_branches"

# Create directories
CACHE_DIR.mkdir(exist_ok=True)
TAG_CACHE_DIR.mkdir(exist_ok=True)
CB_CACHE_DIR.mkdir(exist_ok=True)

# Setup minimal logging (only warnings and errors)
logging.basicConfig(
    level=logging.WARNING,
    format='%(message)s',
    handlers=[logging.FileHandler(LOG_FILE)]
)
log = logging.getLogger(__name__)

# Progress tracking
total_services = 0
completed_services = 0

def print_progress(message):
    """Print progress update."""
    global completed_services
    if completed_services > 0:
        print(f"\r[{completed_services}/{total_services}] {message}", end='', flush=True)
    else:
        print(f"{message}")

def iso_to_ist_human(iso_str: str) -> str:
    """Convert ISO timestamp to human-readable IST format."""
    if not iso_str or iso_str == "N/A":
        return "N/A"
    try:
        # Parse ISO format (handles both with/without timezone)
        if 'Z' in iso_str:
            dt = datetime.fromisoformat(iso_str.replace('Z', '+00:00'))
        elif '+' in iso_str or iso_str.count('-') > 2:
            dt = datetime.fromisoformat(iso_str)
        else:
            # Assume UTC if no timezone info
            dt = datetime.fromisoformat(iso_str).replace(tzinfo=timezone.utc)

        # Convert to IST (UTC+5:30)
        ist = dt + timedelta(hours=5, minutes=30)

        # Format: "07 Nov 2025, 07:06 PM IST"
        return ist.strftime("%d %b %Y, %I:%M %p IST")
    except Exception as e:
        log.warning(f"Date parsing error for '{iso_str}': {e}")
        return iso_str


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
    if not USE_CACHE:  # Skip cache if --fresh flag is used
        return None
    cache_file = tag_cache_file(service)
    if cache_file.exists():
        content = cache_file.read_text().strip()
        # Validate content doesn't have template artifacts or invalid characters
        if content and len(content) < 100 and not any(c in content for c in ['{', '}', '"', "'"]):
            return content
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
    """Get formatted pod information with IST timestamps."""
    for item in pod_json.get("items", []):
        if item.get("metadata", {}).get("name") == pod_name:
            name = item.get("metadata", {}).get("name", "")
            start_time = item.get("status", {}).get("startTime", "N/A")
            start_time_readable = iso_to_ist_human(start_time)

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

                return f"{name} | {start_time_readable} | ready:{ready} restarts:{restarts} | {state}"

            return f"{name} | {start_time_readable} | N/A"

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

    # CACHE HIT (only if USE_CACHE is True)
    if USE_CACHE and cache_file.exists():
        log.info(f"Cache hit for {repo}:{tag}")
        return cache_file.read_text()

    # CACHE MISS - fetch from GitHub API
    log.info(f"Fetching common branches for {repo}:{tag}")

    api_base = f"https://api.github.com/repos/Orange-Health/{repo}"
    # CRITICAL FIX: GitHub API requires "token" prefix, not "Bearer"
    headers = {"Authorization": f"token {GITHUB_TOKEN}"}

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
) -> dict:
    """Process a single service and return service data dict."""

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

    # Convert to IST human-readable format
    deployed_at_readable = iso_to_ist_human(deployed_at)

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
    pods_info = []
    if not pod_list:
        pods_info = ["No pods found"]
    else:
        pods_info = [get_pod_info(p, pod_json) for p in pod_list]

    # Get common branches (async)
    if tag == "<none>":
        common_branches = "Skipped (no tag)"
    else:
        common_branches = await fetch_common_branches(session, repo, tag)

    # Get history
    history = get_cb_history(repo)
    history_data = []
    for filename, content in history:
        history_data.append({"filename": filename, "content": content})

    # Update progress
    global completed_services
    completed_services += 1
    print_progress(f"Processed {service}")

    # Return structured data
    return {
        "service": service,
        "repo": repo,
        "tag": tag,
        "status": status,
        "status_class": status_class,
        "deployed_at": deployed_at_readable,  # Use IST readable format
        "replicas": replicas,
        "available": available,
        "pods_info": pods_info,
        "common_branches": common_branches,
        "history": history_data
    }


# ============================================================
# HTML TEMPLATE RENDERING
# ============================================================

def render_html_report(namespace: str, services_data: list, total: int, healthy: int, degraded: int, missing: int) -> str:
    """Render HTML report using Jinja2 template."""

    template_str = '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>K8s Deployment Report - {{ namespace }}</title>
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
  padding: 20px;
  border-radius: 12px;
  border: 1px solid var(--border);
  text-align: center;
  transition: transform 0.2s;
}

.stat-card:hover {
  transform: translateY(-2px);
}

.stat-number {
  font-size: 32px;
  font-weight: 700;
  margin-bottom: 8px;
}

.stat-label {
  font-size: 13px;
  color: var(--text-secondary);
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(400px, 1fr));
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
  box-shadow: 0 4px 16px var(--shadow);
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
  margin-bottom: 10px;
  font-size: 14px;
  display: flex;
  align-items: baseline;
  gap: 8px;
}

.info-item strong {
  color: var(--text-secondary);
  font-weight: 600;
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
  padding: 4px 10px;
  border-radius: 6px;
  font-family: 'Monaco', 'Consolas', monospace;
  font-size: 13px;
}

.deployed-time {
  font-size: 12px;
  color: var(--text-secondary);
}

.status {
  padding: 6px 14px;
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
  list-style: none;
}

.section summary::-webkit-details-marker {
  display: none;
}

.section summary::before {
  content: '▶ ';
  display: inline-block;
  transition: transform 0.2s;
}

.section[open] summary::before {
  transform: rotate(90deg);
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
  line-height: 1.6;
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
  <h1>🚀 K8s Deployment Report - {{ namespace }}</h1>
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
    <div class="stat-number">{{ total }}</div>
    <div class="stat-label">Total Services</div>
  </div>
  <div class="stat-card">
    <div class="stat-number" style="color: var(--status-ok)">{{ healthy }}</div>
    <div class="stat-label">Healthy</div>
  </div>
  <div class="stat-card">
    <div class="stat-number" style="color: var(--status-degraded)">{{ degraded }}</div>
    <div class="stat-label">Degraded</div>
  </div>
  <div class="stat-card">
    <div class="stat-number" style="color: var(--status-missing)">{{ missing }}</div>
    <div class="stat-label">Missing</div>
  </div>
</div>

<div class="grid" id="serviceGrid">
{% for svc in services %}
  <div class="card" data-service="{{ svc.service }}" data-repo="{{ svc.repo }}" data-status="{{ svc.status_class }}">
    <div class="svc-title">
      <span class="svc-name">{{ svc.service }}</span>
      <span class="status {{ svc.status_class }}">{{ svc.status }}</span>
    </div>
    <div class="svc-info">
      <div class="info-item">
        <strong>Repo:</strong>
        <a href="https://github.com/Orange-Health/{{ svc.repo }}" target="_blank">{{ svc.repo }}</a>
      </div>
      <div class="info-item">
        <strong>Tag:</strong>
        <code class="tag">{{ svc.tag }}</code>
      </div>
      <div class="info-item">
        <strong>Deployed:</strong>
        <span class="deployed-time">{{ svc.deployed_at }}</span>
      </div>
    </div>

    <details class="section">
      <summary>📦 Pods ({{ svc.pods_info|length }})</summary>
      <pre class="code-block">{% for pod in svc.pods_info %}{{ pod }}
{% endfor %}</pre>
    </details>

    <details open class="section">
      <summary>🌿 Common Branches (current)</summary>
      <pre class="code-block">{{ svc.common_branches }}</pre>
    </details>

    <details class="section">
      <summary>📚 History (last {{ svc.history|length }})</summary>
      <pre class="code-block">{% for h in svc.history %}--- {{ h.filename }} ---
{{ h.content }}

{% endfor %}{% if not svc.history %}No history available{% endif %}</pre>
    </details>
  </div>
{% endfor %}
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

// Auto-refresh notice
console.log('Report generated at: ' + new Date().toLocaleString());
console.log('Total services: {{ total }}');
console.log('Healthy: {{ healthy }}, Degraded: {{ degraded }}, Missing: {{ missing }}');
</script>

</body>
</html>
'''

    template = Template(template_str)
    return template.render(
        namespace=namespace,
        services=services_data,
        total=total,
        healthy=healthy,
        degraded=degraded,
        missing=missing
    )


# ============================================================
# MAIN EXECUTION
# ============================================================

async def main():
    global total_services

    # Print startup banner
    print("="*60)
    print("🚀 K8s Deployment Report Generator")
    print("="*60)
    print(f"📍 Namespace: {NAMESPACE}")
    print(f"💾 Cache: {'DISABLED (--fresh mode)' if not USE_CACHE else 'ENABLED'}")
    print(f"🔒 SSL Verification: {'ENABLED' if VERIFY_SSL else 'DISABLED'}")
    print("="*60 + "\n")

    # Load K8s data in parallel
    print("📦 Loading K8s data...")
    deploy_json, pod_json, rs_json = await load_k8s_data()
    print(f"✅ Loaded {len(deploy_json.get('items', []))} deployments, {len(pod_json.get('items', []))} pods\n")

    # Create SSL context
    ssl_context = None
    if not VERIFY_SSL:
        ssl_context = ssl.create_default_context()
        ssl_context.check_hostname = False
        ssl_context.verify_mode = ssl.CERT_NONE

    # Process services
    all_services = []
    for category, services in CATEGORIES.items():
        all_services.extend(services)

    total_services = len(all_services)
    print(f"🔄 Processing {total_services} services...\n")

    # Create HTTP session for GitHub API with SSL context
    connector = aiohttp.TCPConnector(ssl=ssl_context)
    async with aiohttp.ClientSession(connector=connector) as session:
        # Process all services with controlled concurrency
        semaphore = asyncio.Semaphore(MAX_CONCURRENT)

        async def process_with_semaphore(service: str):
            async with semaphore:
                return await process_service(service, deploy_json, pod_json, rs_json, session)

        # Process all services in parallel (with controlled concurrency)
        services_data = await asyncio.gather(*[process_with_semaphore(svc) for svc in all_services])

    print("\n")  # Newline after progress

    # Calculate stats
    total = len(services_data)
    healthy = sum(1 for s in services_data if s["status_class"] == "status-ok")
    degraded = sum(1 for s in services_data if s["status_class"] == "status-degraded")
    missing = sum(1 for s in services_data if s["status_class"] == "status-missing")

    # Render HTML using Jinja2 template
    html_content = render_html_report(NAMESPACE, services_data, total, healthy, degraded, missing)

    # Write report
    with open(REPORT_FILE, "w") as f:
        f.write(html_content)

    print("="*60)
    print("✅ Report generated successfully!")
    print("="*60)
    print(f"\n📊 Statistics:")
    print(f"  Total Services: {total}")
    print(f"  ✅ Healthy: {healthy}")
    print(f"  ⚠️  Degraded: {degraded}")
    print(f"  ❌ Missing: {missing}")
    print(f"\n📄 Report saved to: {REPORT_FILE}")
    print(f"\nOpen with: open {REPORT_FILE}\n")


if __name__ == "__main__":
    asyncio.run(main())
