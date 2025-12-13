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
      python3 fetch_kube.py <namespace> [--fresh] [--auto-refresh]

   Examples:
      python3 fetch_kube.py s2
      python3 fetch_kube.py s2 --fresh
      python3 fetch_kube.py s2 --auto-refresh

   Options:
      --fresh        : Bypass all caches and fetch fresh data
      --auto-refresh : Enable auto-refresh (checks every 5 min for tag changes)

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
parser.add_argument('--auto-refresh', action='store_true', help='Auto-refresh report every 5 minutes and show tag change alerts')
args = parser.parse_args()

# ============================================================
# CONFIG & DIRECTORIES
# ============================================================

NAMESPACE = args.namespace
USE_CACHE = not args.fresh  # Skip cache if --fresh flag is used
AUTO_REFRESH = args.auto_refresh  # Enable auto-refresh mode
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

# Categorized structure with BE/Workers/Web subcategories
CATEGORY_STRUCTURE = {
    "oms": {
        "name": "OMS",
        "be": ["oms-api"],
        "workers": ["oms-consumer", "oms-scheduler", "oms-worker"],
        "web": ["oms-web"]
    },
    "health": {
        "name": "Health API",
        "be": ["health-api"],
        "workers": ["health-celery-beat", "health-celery-worker", "health-consumer", "health-s3-nginx"],
        "web": []
    },
    "partner": {
        "name": "Partner",
        "be": ["partner-api"],
        "workers": ["partner-consumer", "partner-scheduler", "partner-worker-high", "partner-worker-low", "partner-worker-medium"],
        "web": ["partner-web"]
    },
    "occ": {
        "name": "OCC",
        "be": ["occ-api"],
        "workers": [],
        "web": ["occ-web"]
    },
    "d2c": {
        "name": "D2C Web",
        "be": [],
        "workers": [],
        "web": ["bifrost"]
    }
}

# Legacy flat structure for backward compatibility
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
# CATEGORY DATA ORGANIZATION
# ============================================================

def organize_by_categories(services_data: list) -> dict:
    """Organize services by categories with BE/Workers/Web subcategories."""
    # Create a map of service name to service data
    services_map = {svc["service"]: svc for svc in services_data}

    organized = {}
    for cat_key, cat_info in CATEGORY_STRUCTURE.items():
        cat_data = {
            "name": cat_info["name"],
            "be": [],
            "workers": [],
            "web": [],
            "all_healthy": True,
            "total_services": 0,
            "healthy_count": 0
        }

        # Add BE services
        for svc_name in cat_info["be"]:
            if svc_name in services_map:
                cat_data["be"].append(services_map[svc_name])
                cat_data["total_services"] += 1
                if services_map[svc_name]["status_class"] == "status-ok":
                    cat_data["healthy_count"] += 1
                else:
                    cat_data["all_healthy"] = False

        # Add Worker services
        for svc_name in cat_info["workers"]:
            if svc_name in services_map:
                cat_data["workers"].append(services_map[svc_name])
                cat_data["total_services"] += 1
                if services_map[svc_name]["status_class"] == "status-ok":
                    cat_data["healthy_count"] += 1
                else:
                    cat_data["all_healthy"] = False

        # Add Web services
        for svc_name in cat_info["web"]:
            if svc_name in services_map:
                cat_data["web"].append(services_map[svc_name])
                cat_data["total_services"] += 1
                if services_map[svc_name]["status_class"] == "status-ok":
                    cat_data["healthy_count"] += 1
                else:
                    cat_data["all_healthy"] = False

        organized[cat_key] = cat_data

    return organized


# ============================================================
# HTML TEMPLATE RENDERING
# ============================================================

def render_html_report(namespace: str, services_data: list, total: int, healthy: int, degraded: int, missing: int) -> str:
    """Render HTML report using Jinja2 template."""

    # Organize data by categories
    categorized_data = organize_by_categories(services_data)

    template_str = '''<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>K8s Report - {{ namespace }}</title>
<style>
:root{--bg-primary:#f5f7fa;--bg-secondary:#fff;--bg-code:#1e1e2e;--text-primary:#2c3e50;--text-secondary:#7f8c8d;
--text-code:#e0e0e0;--border:#e1e8ed;--shadow:rgba(0,0,0,0.08);--accent:#3498db;--status-ok:#2ecc71;
--status-ok-bg:#d4f7da;--status-degraded:#f39c12;--status-degraded-bg:#ffe7c2;--status-missing:#e74c3c;--status-missing-bg:#ffd4d4;}
[data-theme="dark"]{--bg-primary:#0d1117;--bg-secondary:#161b22;--bg-code:#0d1117;--text-primary:#c9d1d9;
--text-secondary:#8b949e;--text-code:#c9d1d9;--border:#30363d;--shadow:rgba(0,0,0,0.3);}
*{margin:0;padding:0;box-sizing:border-box;}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:var(--bg-primary);
color:var(--text-primary);padding:20px;line-height:1.6;}
.header{max-width:1600px;margin:0 auto 30px;display:flex;justify-content:space-between;align-items:center;
flex-wrap:wrap;gap:20px;}
.header h1{font-size:28px;font-weight:700;}
.stats{max-width:1600px;margin:0 auto 20px;display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:15px;}
.stat-card{background:var(--bg-secondary);padding:20px;border-radius:12px;border:1px solid var(--border);text-align:center;}
.stat-number{font-size:32px;font-weight:700;margin-bottom:8px;}
.stat-label{font-size:13px;color:var(--text-secondary);text-transform:uppercase;}
.categories{max-width:1600px;margin:0 auto;}
.category-section{background:var(--bg-secondary);border-radius:12px;padding:20px;margin-bottom:20px;
border:1px solid var(--border);box-shadow:0 2px 8px var(--shadow);}
.category-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:15px;cursor:pointer;
user-select:none;padding:10px;border-radius:8px;transition:background 0.2s;}
.category-header:hover{background:var(--bg-primary);}
.category-title{font-size:24px;font-weight:700;display:flex;align-items:center;gap:10px;}
.category-badge{font-size:12px;padding:4px 12px;border-radius:12px;font-weight:600;}
.category-badge.healthy{background:var(--status-ok-bg);color:var(--status-ok);}
.category-badge.degraded{background:var(--status-degraded-bg);color:var(--status-degraded);}
.subcategory{margin-bottom:15px;}
.subcategory-title{font-size:14px;font-weight:600;color:var(--text-secondary);margin-bottom:10px;
text-transform:uppercase;letter-spacing:0.5px;}
.services-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:12px;}
.service-card{background:var(--bg-primary);padding:12px;border-radius:8px;border:1px solid var(--border);
transition:transform 0.2s,box-shadow 0.2s;cursor:pointer;position:relative;}
.service-card:hover{transform:translateY(-2px);box-shadow:0 4px 12px var(--shadow);}
.service-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;}
.service-name{font-weight:600;font-size:15px;}
.status{padding:4px 10px;border-radius:6px;font-size:11px;font-weight:600;}
.status-ok{background:var(--status-ok-bg);color:var(--status-ok);}
.status-degraded{background:var(--status-degraded-bg);color:var(--status-degraded);}
.status-missing{background:var(--status-missing-bg);color:var(--status-missing);}
.service-info{font-size:12px;color:var(--text-secondary);}
.tag{background:var(--bg-code);color:var(--text-code);padding:2px 6px;border-radius:4px;
font-family:Monaco,monospace;font-size:11px;}
.tooltip{position:absolute;background:#000;color:#fff;padding:8px 12px;border-radius:6px;font-size:12px;
white-space:nowrap;z-index:1000;opacity:0;pointer-events:none;transition:opacity 0.2s;}
.service-card:hover .tooltip{opacity:0.95;}
.details-modal{display:none;position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);
background:var(--bg-secondary);border-radius:12px;padding:30px;max-width:800px;max-height:80vh;
overflow-y:auto;box-shadow:0 8px 24px rgba(0,0,0,0.3);z-index:2000;}
.details-modal.show{display:block;}
.modal-overlay{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.5);
z-index:1999;}
.modal-overlay.show{display:block;}
.details-section{margin:15px 0;border:1px solid var(--border);border-radius:8px;overflow:hidden;}
.details-section summary{padding:12px;background:var(--bg-primary);cursor:pointer;font-weight:600;}
.code-block{background:var(--bg-code);color:var(--text-code);padding:15px;font-size:12px;
font-family:Monaco,monospace;white-space:pre-wrap;overflow-x:auto;line-height:1.6;}
.theme-toggle{padding:10px 20px;border:none;border-radius:8px;background:var(--accent);color:white;
cursor:pointer;font-size:14px;font-weight:600;}
.alert{position:fixed;top:20px;right:20px;background:#ff9800;color:#fff;padding:15px 20px;border-radius:8px;
box-shadow:0 4px 12px rgba(0,0,0,0.3);z-index:3000;animation:slideIn 0.3s;max-width:400px;}
.alert.success{background:#4caf50;}
.alert.error{background:#f44336;}
@keyframes slideIn{from{transform:translateX(100%);}to{transform:translateX(0);}}
.close-btn{cursor:pointer;float:right;font-size:20px;font-weight:bold;margin-left:10px;}
.category-content{max-height:0;overflow:hidden;transition:max-height 0.3s ease;}
.category-content.expanded{max-height:5000px;}
.toggle-icon{transition:transform 0.3s;}
.toggle-icon.expanded{transform:rotate(90deg);}
</style>
</head><body>
<div class="header">
<h1>🚀 K8s Report - {{ namespace }}</h1>
<button class="theme-toggle" onclick="toggleTheme()">🌓 Theme</button>
</div>
<div class="stats">
<div class="stat-card"><div class="stat-number">{{ total }}</div><div class="stat-label">Total</div></div>
<div class="stat-card"><div class="stat-number" style="color:var(--status-ok)">{{ healthy }}</div><div class="stat-label">Healthy</div></div>
<div class="stat-card"><div class="stat-number" style="color:var(--status-degraded)">{{ degraded }}</div><div class="stat-label">Degraded</div></div>
<div class="stat-card"><div class="stat-number" style="color:var(--status-missing)">{{ missing }}</div><div class="stat-label">Missing</div></div>
</div>
<div class="categories">
{% for cat_key, cat_data in categories.items() %}
{% if cat_data.total_services > 0 %}
<div class="category-section">
<div class="category-header" onclick="toggleCategory('{{ cat_key }}')">
<div class="category-title">
<span class="toggle-icon" id="toggle-{{ cat_key }}">▶</span>
<span>{{ cat_data.name }}</span>
<span class="category-badge {% if cat_data.all_healthy %}healthy{% else %}degraded{% endif %}">
{{ cat_data.healthy_count }}/{{ cat_data.total_services }}
</span>
</div>
</div>
<div class="category-content" id="content-{{ cat_key }}">
{% if cat_data.be %}
<div class="subcategory">
<div class="subcategory-title">Backend API</div>
<div class="services-grid">
{% for svc in cat_data.be %}
<div class="service-card" onclick="showDetails('{{ svc.service }}')">
<div class="tooltip">{{ svc.tag }} | {{ svc.deployed_at }}</div>
<div class="service-header">
<span class="service-name">{{ svc.service }}</span>
<span class="status {{ svc.status_class }}">{{ svc.status }}</span>
</div>
<div class="service-info">
<div>Tag: <code class="tag">{{ svc.tag }}</code></div>
</div>
</div>
{% endfor %}
</div>
</div>
{% endif %}
{% if cat_data.workers %}
<div class="subcategory">
<div class="subcategory-title">Workers</div>
<div class="services-grid">
{% for svc in cat_data.workers %}
<div class="service-card" onclick="showDetails('{{ svc.service }}')">
<div class="service-header">
<span class="service-name">{{ svc.service }}</span>
<span class="status {{ svc.status_class }}">{{ svc.status }}</span>
</div>
<div class="service-info">
<div>Tag: <code class="tag">{{ svc.tag }}</code></div>
</div>
</div>
{% endfor %}
</div>
</div>
{% endif %}
{% if cat_data.web %}
<div class="subcategory">
<div class="subcategory-title">Web</div>
<div class="services-grid">
{% for svc in cat_data.web %}
<div class="service-card" onclick="showDetails('{{ svc.service }}')">
<div class="service-header">
<span class="service-name">{{ svc.service }}</span>
<span class="status {{ svc.status_class }}">{{ svc.status }}</span>
</div>
<div class="service-info">
<div>Tag: <code class="tag">{{ svc.tag }}</code></div>
</div>
</div>
{% endfor %}
</div>
</div>
{% endif %}
</div>
</div>
{% endif %}
{% endfor %}
</div>
<div class="modal-overlay" id="modalOverlay" onclick="closeModal()"></div>
<div class="details-modal" id="detailsModal"></div>
<script>
const serviceData={{ services_json|safe }};
const autoRefresh={{ auto_refresh|lower }};
const namespace='{{ namespace }}';
let lastTags={};
function toggleTheme(){const html=document.documentElement;const theme=html.getAttribute('data-theme');
html.setAttribute('data-theme',theme==='dark'?'light':'dark');localStorage.setItem('theme',theme==='dark'?'light':'dark');}
const savedTheme=localStorage.getItem('theme')||'light';document.documentElement.setAttribute('data-theme',savedTheme);
function toggleCategory(catKey){const content=document.getElementById('content-'+catKey);
const icon=document.getElementById('toggle-'+catKey);
content.classList.toggle('expanded');icon.classList.toggle('expanded');}
function showDetails(serviceName){const svc=serviceData.find(s=>s.service===serviceName);
if(!svc)return;const modal=document.getElementById('detailsModal');const overlay=document.getElementById('modalOverlay');
let html=`<h2>${svc.service}</h2><button class="close-btn" onclick="closeModal()">✕</button>
<div style="margin-top:20px"><strong>Repo:</strong> <a href="https://github.com/Orange-Health/${svc.repo}" target="_blank">${svc.repo}</a></div>
<div><strong>Tag:</strong> <code class="tag">${svc.tag}</code></div>
<div><strong>Deployed:</strong> ${svc.deployed_at}</div>
<div><strong>Status:</strong> <span class="status ${svc.status_class}">${svc.status}</span></div>
<details class="details-section" open><summary>📦 Pods (${svc.pods_info.length})</summary>
<pre class="code-block">${svc.pods_info.join('\\n')}</pre></details>
<details class="details-section"><summary>🌿 Common Branches</summary>
<pre class="code-block">${svc.common_branches}</pre></details>`;
if(svc.history.length>0){html+=`<details class="details-section"><summary>📚 History</summary><pre class="code-block">`;
svc.history.forEach(h=>{html+=`--- ${h.filename} ---\\n${h.content}\\n\\n`;});html+=`</pre></details>`;}
modal.innerHTML=html;modal.classList.add('show');overlay.classList.add('show');}
function closeModal(){document.getElementById('detailsModal').classList.remove('show');
document.getElementById('modalOverlay').classList.remove('show');}
function showAlert(message,type='success'){const alert=document.createElement('div');
alert.className=`alert ${type}`;alert.innerHTML=`<span class="close-btn" onclick="this.parentElement.remove()">✕</span>${message}`;
document.body.appendChild(alert);setTimeout(()=>alert.remove(),5000);}
function checkTagChanges(){fetch(`/api/services/${namespace}`).then(r=>r.json()).then(data=>{
let changes=[];data.forEach(svc=>{if(lastTags[svc.service]&&lastTags[svc.service]!==svc.tag){
changes.push(`${svc.service}: ${lastTags[svc.service]} → ${svc.tag}`);}
lastTags[svc.service]=svc.tag;});if(changes.length>0){showAlert(`Tag changes detected:\\n${changes.join('\\n')}`,'success');
location.reload();}}).catch(e=>console.error('Refresh error:',e));}
if(autoRefresh){serviceData.forEach(svc=>lastTags[svc.service]=svc.tag);setInterval(checkTagChanges,300000);}
</script>
</body></html>'''

    template = Template(template_str)
    return template.render(
        namespace=namespace,
        categories=categorized_data,
        services_json=json.dumps(services_data),
        total=total,
        healthy=healthy,
        degraded=degraded,
        missing=missing,
        auto_refresh=AUTO_REFRESH
    )

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
    if AUTO_REFRESH:
        print(f"🔄 Auto-Refresh: ENABLED (5 min intervals)")
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
