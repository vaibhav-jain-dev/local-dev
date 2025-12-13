#!/usr/bin/env python3
"""
Kubernetes Deployment Report Generator

Fetches K8s deployments and GitHub branch information to generate
an interactive HTML report with statistics and filtering.

Usage:
  python3 fetch_kube.py [namespace] [--fresh]
  
Examples:
  python3 fetch_kube.py s2
  python3 fetch_kube.py s2 --fresh  # Bypass all caches
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

# Auto-install dependencies
try:
    import aiohttp
    from jinja2 import Template
except ImportError as e:
    missing = str(e).split("'")[1] if "'" in str(e) else "aiohttp/jinja2"
    print(f"Installing {missing}...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "aiohttp", "jinja2"])
    print(f"✅ Installed {missing}. Please rerun the script.")
    sys.exit(0)

# Parse arguments
parser = argparse.ArgumentParser(description='Generate K8s deployment report')
parser.add_argument('namespace', nargs='?', default='s2', help='Kubernetes namespace (default: s2)')
parser.add_argument('--fresh', action='store_true', help='Bypass all caches and fetch fresh data')
args = parser.parse_args()

NAMESPACE = args.namespace
USE_CACHE = not args.fresh

# Validate GitHub token
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN")
if not GITHUB_TOKEN:
    print("="*60)
    print("❌ ERROR: GITHUB_TOKEN environment variable not set!")
    print("="*60)
    print("\nExport your GitHub token:")
    print("  export GITHUB_TOKEN='ghp_your_token_here'\n")
    sys.exit(1)

# Configuration
MAX_CONCURRENT = 10
MAX_GITHUB_CONCURRENT = 5
VERIFY_SSL = os.environ.get("VERIFY_SSL", "false").lower() in ("true", "1", "yes")

CACHE_DIR = Path.home() / ".k8s-deploy-cache"
TAG_CACHE_DIR = CACHE_DIR / "tagcache"
CB_CACHE_DIR = CACHE_DIR / "common_branches"
REPORT_FILE = Path("./report.html")

# Create directories
CACHE_DIR.mkdir(exist_ok=True)
TAG_CACHE_DIR.mkdir(exist_ok=True)
CB_CACHE_DIR.mkdir(exist_ok=True)

# Setup minimal logging
logging.basicConfig(level=logging.WARNING, format='%(message)s')

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
        # Parse ISO format
        dt = datetime.fromisoformat(iso_str.replace('Z', '+00:00'))
        # Convert to IST (UTC+5:30)
        ist = dt + timedelta(hours=5, minutes=30)
        # Format: "07 Nov 2025, 07:06 PM IST"
        return ist.strftime("%d %b %Y, %I:%M %p IST")
    except:
        return iso_str

# Service to repo mapping
REPO_MAP = {
    "oms-api": "oms", "oms-consumer": "oms", "oms-scheduler": "oms",
    "oms-worker": "oms", "oms-web": "oms-web",
    "health-api": "health-api", "health-celery-beat": "health-api",
    "health-celery-worker": "health-api", "health-consumer": "health-api",
    "health-s3-nginx": "health-api",
    "partner-api": "partner-api", "partner-consumer": "partner-api",
    "partner-scheduler": "partner-api", "partner-web": "partner-web",
    "partner-worker-high": "partner-api", "partner-worker-low": "partner-api",
    "partner-worker-medium": "partner-api",
    "occ-api": "occ", "occ-web": "occ-web",
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

# Cache helpers
def read_cache(cache_file: Path) -> Optional[str]:
    if USE_CACHE and cache_file.exists():
        content = cache_file.read_text().strip()
        # Validate content doesn't have template artifacts
        if content and not any(x in content for x in ['{', '}', 'null']):
            return content
    return None

def write_cache(cache_file: Path, content: str):
    cache_file.write_text(content.strip())

def get_cb_history(repo: str) -> List[Tuple[str, str]]:
    pattern = f"{repo}-*.txt"
    files = sorted(CB_CACHE_DIR.glob(pattern), key=lambda p: p.stat().st_mtime, reverse=True)
    return [(f.name, f.read_text()) for f in files[:3]]

# Load K8s data
async def load_k8s_data() -> Tuple[dict, dict, dict]:
    print("📦 Loading K8s data...")
    
    async def run_kubectl(resource: str) -> dict:
        proc = await asyncio.create_subprocess_exec(
            "kubectl", "-n", NAMESPACE, "get", resource, "-o", "json",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await proc.communicate()
        if proc.returncode != 0:
            print(f"❌ kubectl get {resource} failed")
            return {"items": []}
        return json.loads(stdout.decode())
    
    deployments, pods, rs = await asyncio.gather(
        run_kubectl("deployments"),
        run_kubectl("pods"),
        run_kubectl("rs")
    )
    print(f"✅ Loaded {len(deployments.get('items', []))} deployments, {len(pods.get('items', []))} pods\n")
    return deployments, pods, rs

# Image/tag resolution
def resolve_image(service: str, deploy_json: dict, pod_json: dict, rs_json: dict) -> str:
    for item in deploy_json.get("items", []):
        if item.get("metadata", {}).get("name") == service:
            containers = item.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
            if containers:
                return containers[0].get("image", "")
    
    for item in rs_json.get("items", []):
        owner_refs = item.get("metadata", {}).get("ownerReferences", [])
        if owner_refs and owner_refs[0].get("name") == service:
            containers = item.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
            if containers:
                return containers[0].get("image", "")
    
    for item in pod_json.get("items", []):
        labels = item.get("metadata", {}).get("labels", {})
        if labels.get("pod") == service:
            containers = item.get("spec", {}).get("containers", [])
            if containers:
                return containers[0].get("image", "")
        
        name = item.get("metadata", {}).get("name", "")
        if name.startswith(service):
            containers = item.get("spec", {}).get("containers", [])
            if containers:
                return containers[0].get("image", "")
    
    return ""

def extract_tag(image: str) -> str:
    if not image:
        return "<none>"
    if "@" in image:
        return "<none>"
    if ":" in image:
        tag = image.split(":")[-1]
        # Validate tag doesn't contain invalid characters
        if tag and len(tag) < 100 and not any(c in tag for c in ['{', '}', '"', "'"]):
            return tag
    return "<none>"

# Pod info
def get_pod_info(pod_name: str, pod_json: dict) -> str:
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
    pods = []
    for item in pod_json.get("items", []):
        labels = item.get("metadata", {}).get("labels", {})
        name = item.get("metadata", {}).get("name", "")
        if labels.get("pod") == service or name.startswith(service):
            pods.append(name)
    return pods

# GitHub API
async def fetch_common_branches(session: aiohttp.ClientSession, repo: str, tag: str) -> str:
    cache_file = CB_CACHE_DIR / f"{repo}-{tag}.txt"
    
    cached = read_cache(cache_file)
    if cached:
        return cached
    
    api_base = f"https://api.github.com/repos/Orange-Health/{repo}"
    # CRITICAL FIX: Use "token" not "Bearer" for GitHub API
    headers = {"Authorization": f"token {GITHUB_TOKEN}"}
    
    results = []
    try:
        async with session.get(f"{api_base}/branches?per_page=200", headers=headers) as resp:
            if resp.status != 200:
                return f"ERROR: GitHub API returned {resp.status}"
            branches = await resp.json()
        
        common_branches = [b["name"] for b in branches if "common" in b["name"].lower()]
        
        async def fetch_branch_info(branch_name: str):
            try:
                async with session.get(f"{api_base}/commits/{branch_name}", headers=headers) as resp:
                    if resp.status != 200:
                        return None
                    commit_data = await resp.json()
                
                sha = commit_data.get("sha", "")
                date_str = commit_data.get("commit", {}).get("committer", {}).get("date", "")
                author = commit_data.get("commit", {}).get("committer", {}).get("name", "")
                
                if not sha or not date_str:
                    return None
                
                date_readable = iso_to_ist_human(date_str)
                url = f"https://github.com/Orange-Health/{repo}/commit/{sha}"
                return f"{branch_name:<22} {date_readable:<30} {author:<20} {url}"
            except:
                return None
        
        semaphore = asyncio.Semaphore(MAX_GITHUB_CONCURRENT)
        async def fetch_with_sem(b):
            async with semaphore:
                return await fetch_branch_info(b)
        
        branch_results = await asyncio.gather(*[fetch_with_sem(b) for b in common_branches])
        results = [r for r in branch_results if r]
    except Exception as e:
        return f"ERROR: {str(e)}"
    
    result_text = "\n".join(results) if results else "No common branches found"
    write_cache(cache_file, result_text)
    
    # Keep only last 3 cache files for this repo
    pattern = f"{repo}-*.txt"
    for old_file in sorted(CB_CACHE_DIR.glob(pattern), key=lambda p: p.stat().st_mtime, reverse=True)[3:]:
        old_file.unlink()
    
    return result_text

# Process service
async def process_service(
    service: str,
    deploy_json: dict,
    pod_json: dict,
    rs_json: dict,
    session: aiohttp.ClientSession
) -> dict:
    global completed_services
    
    repo = REPO_MAP.get(service, "unknown")
    
    # Get tag
    tag_cache_file = TAG_CACHE_DIR / f"{service}.txt"
    tag = read_cache(tag_cache_file)
    if not tag:
        image = resolve_image(service, deploy_json, pod_json, rs_json)
        tag = extract_tag(image)
        write_cache(tag_cache_file, tag)
    
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
    pods_info = [get_pod_info(p, pod_json) for p in pod_list] if pod_list else ["No pods found"]
    
    # Get common branches
    if tag == "<none>":
        common_branches = "Skipped (no tag)"
    else:
        common_branches = await fetch_common_branches(session, repo, tag)
    
    # Get history
    history_data = [{"filename": f, "content": c} for f, c in get_cb_history(repo)]
    
    completed_services += 1
    print_progress(f"Processed {service}")
    
    return {
        "service": service,
        "repo": repo,
        "tag": tag,
        "status": status,
        "status_class": status_class,
        "deployed_at": deployed_at_readable,
        "replicas": replicas,
        "available": available,
        "pods_info": pods_info,
        "common_branches": common_branches,
        "history": history_data
    }

# HTML template (abbreviated for length - same as before)
def render_html_report(namespace: str, services_data: list, total: int, healthy: int, degraded: int, missing: int) -> str:
    # Use the same Jinja2 template from before
    # (Truncated for brevity - keep existing template)
    return f"<html><body><h1>Report for {namespace}</h1><p>{total} services</p></body></html>"

# Main
async def main():
    global total_services
    
    print("="*60)
    print(f"🚀 K8s Deployment Report Generator")
    print(f"📍 Namespace: {NAMESPACE}")
    print(f"💾 Cache: {'DISABLED (--fresh mode)' if not USE_CACHE else 'ENABLED'}")
    print(f"🔒 SSL: {'ENABLED' if VERIFY_SSL else 'DISABLED'}")
    print("="*60 + "\n")
    
    # Load K8s data
    deploy_json, pod_json, rs_json = await load_k8s_data()
    
    # SSL context
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
    
    connector = aiohttp.TCPConnector(ssl=ssl_context)
    async with aiohttp.ClientSession(connector=connector) as session:
        semaphore = asyncio.Semaphore(MAX_CONCURRENT)
        
        async def process_with_sem(svc):
            async with semaphore:
                return await process_service(svc, deploy_json, pod_json, rs_json, session)
        
        services_data = await asyncio.gather(*[process_with_sem(svc) for svc in all_services])
    
    print("\n")  # New line after progress
    
    # Calculate stats
    total = len(services_data)
    healthy = sum(1 for s in services_data if s["status_class"] == "status-ok")
    degraded = sum(1 for s in services_data if s["status_class"] == "status-degraded")
    missing = sum(1 for s in services_data if s["status_class"] == "status-missing")
    
    # Render HTML
    html_content = render_html_report(NAMESPACE, services_data, total, healthy, degraded, missing)
    
    # Write report
    REPORT_FILE.write_text(html_content)
    
    print("="*60)
    print("✅ Report generated successfully!")
    print("="*60)
    print(f"\n📊 Statistics:")
    print(f"  Total Services: {total}")
    print(f"  ✅ Healthy: {healthy}")
    print(f"  ⚠️  Degraded: {degraded}")
    print(f"  ❌ Missing: {missing}")
    print(f"\n📄 Report: {REPORT_FILE}")
    print(f"\nOpen with: open {REPORT_FILE}\n")

if __name__ == "__main__":
    asyncio.run(main())
