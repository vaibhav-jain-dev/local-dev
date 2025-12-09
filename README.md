# Orange Health Local Development

A local development environment orchestrator for running Orange Health microservices via Docker.

---

## AI Context

> **For AI assistants**: This section provides a quick understanding of the repository.

### What This Repo Does
This is a **local development orchestrator** that:
1. Clones multiple Orange Health microservice repos into `cloned/`
2. Overrides their config files with environment-specific secrets from `configs/<namespace>/`
3. Copies custom Dockerfiles from `repos_docker_files/`
4. Auto-generates `docker-compose.yml`
5. Runs everything in Docker with Redis via kubectl port-forward

### Key Files
| File | Purpose |
|------|---------|
| `run.sh` | Main orchestrator script (~570 lines bash) |
| `Makefile` | User-facing commands (`make run`, `make restart`, etc.) |
| `repos_docker_files/config.yaml` | Service definitions (git repos, branches, ports, config mappings) |
| `repos_docker_files/*.dev.Dockerfile` | Custom Dockerfiles for each service |
| `configs/<namespace>/` | Environment-specific secrets (s1, s2, s3, s4, s5, qa, auto) |

### Core Concepts
- **Namespace**: Environment identifier (s1, s2, etc.) - determines which config folder to use and which k8s namespace for Redis
- **Refresh**: Flag to discard local changes and pull latest from git
- **always-refresh**: Per-service config to always pull latest

### Command Flow
```
make run s2 health-api
    │
    ├─→ Validate namespace (s2) exists in configs/s2/
    ├─→ Clone git@github.com:Orange-Health/health-api.git → cloned/health-api/
    ├─→ Copy configs/s2/health_secrets.py → cloned/health-api/app/app/secrets.py
    ├─→ Copy repos_docker_files/health-api.dev.Dockerfile → cloned/health-api/dev.Dockerfile
    ├─→ Generate docker-compose.yml
    ├─→ kubectl port-forward -n s2 deployment/redis 6379:6379
    └─→ docker-compose up -d
```

### Important Behaviors
- Default namespace: `s1`
- Redis port check: skips if already in use, force-kills on `restart`
- Without `refresh`: preserves local changes in cloned repos
- With `refresh`: `git reset --hard && git clean -fd && git pull`

---

## Overview

This tool clones multiple repositories, overrides their configurations with environment-specific settings, and runs them in Docker containers on a shared network.

## Prerequisites

- Docker & Docker Compose
- Git (with SSH access to Orange-Health repositories)
- `yq` (YAML processor) - install via `brew install yq` or `apt install yq`
- `kubectl` (for Redis port-forwarding from Kubernetes)

## Quick Start

```bash
# Start all services (default namespace: s1)
make run

# Start with specific namespace
make run s2

# Start specific services only
make run s1 health-api oms-api

# Restart all (force reconnect redis)
make restart

# Stop all services
make stop
```

## Commands

| Command | Description |
|---------|-------------|
| `make run` | Start all services (default: s1 namespace) |
| `make run <namespace>` | Start all services with specific namespace |
| `make run <namespace> <services...>` | Start specific services only |
| `make run refresh` | Start and pull latest code from git |
| `make run refresh <namespace> <services...>` | Pull latest and start specific services |
| `make restart` | Stop all, force reconnect redis, start again |
| `make restart refresh` | Restart with fresh pull from git |
| `make stop` | Stop all services |
| `make clean` | Stop services, remove cloned repos, prune docker |
| `make logs` | View logs for all services |
| `make logs <service>` | View logs for specific service |
| `make stats` | View resource usage |

## Valid Namespaces

```
s1, s2, s3, s4, s5, qa, auto
```

- Default namespace is **s1**
- Namespace folder must exist: `configs/<namespace>/`
- Script throws error if folder not found

## Examples

```bash
# Start all services with s1 (default)
make run

# Start all services with s2 namespace
make run s2

# Start only health-api with s1
make run s1 health-api

# Start health-api and oms-api with s2
make run s2 health-api oms-api

# Pull latest code and start (discards local changes)
make run refresh

# Pull latest for specific namespace
make run refresh s2

# Pull latest for specific service
make run refresh s1 health-api

# Restart everything (force kills redis port and reconnects)
make restart

# Restart with fresh pull
make restart refresh

# View logs for health-api
make logs health-api

# Stop everything
make stop
```

## Directory Structure

```
local-dev/
├── configs/                    # Configuration files (per namespace)
│   ├── s1/                     # Namespace s1 configs (default)
│   │   ├── health_secrets.py
│   │   ├── oms.yaml
│   │   └── scheduler_secrets.py
│   ├── s2/                     # Namespace s2 configs
│   │   └── ...
│   └── ...
├── repos_docker_files/         # Dockerfiles and main config
│   ├── config.yaml             # Service definitions
│   ├── health-api.dev.Dockerfile
│   ├── scheduler-api.dev.Dockerfile
│   └── oms-api.dev.Dockerfile
├── cloned/                     # Cloned repositories (gitignored)
├── logs/                       # Log files (gitignored)
├── run.sh                      # Main orchestrator script
└── Makefile                    # User-friendly commands
```

## Services

| Service | Port | Repository |
|---------|------|------------|
| health-api | 8000 | Orange-Health/health-api |
| scheduler-api | 8010 | Orange-Health/scheduler-api |
| oms-api | 8080 | Orange-Health/oms |

## How It Works

1. **Validate**: Check namespace is valid and folder exists
2. **Clone**: Repositories cloned into `cloned/` (parallel)
3. **Override**: Config files from `configs/<namespace>/` copied into repos
4. **Dockerfile**: Service-specific Dockerfiles copied from `repos_docker_files/`
5. **Compose**: `docker-compose.yml` auto-generated
6. **Redis**: Port-forward started (skipped if port already busy)
7. **Build**: Docker containers built in parallel
8. **Run**: Containers started

## Refresh Flag

Controls whether to pull latest code from git:

| Scenario | Behavior |
|----------|----------|
| `make run` (no refresh) | Keep local changes, only clone if missing or switch branch if different |
| `make run refresh` | Discard local changes, pull latest from git |
| Service has `always-refresh: true` | Always pull latest (even without refresh flag) |

### Per-Service Always Refresh

Add `always-refresh: true` to a service in config to always pull latest:

```yaml
services:
  health-api:
    enabled: true
    always-refresh: true  # Always pulls latest code
    git_repo: git@github.com:Orange-Health/health-api.git
    git_branch: master
    ...
```

## Redis Handling

- **On run**: Checks if redis port (6379) is busy
  - If busy → skips (assumes redis already running)
  - If free → starts `kubectl port-forward -n <namespace> deployment/redis 6379:6379`
- **On restart**: Force kills any process on redis port, then reconnects

```yaml
# repos_docker_files/config.yaml
redis:
  namespace: s5       # Fallback (overridden by command namespace)
  deployment: redis   # Kubernetes deployment name
  port: 6379          # Port to forward
```

## Configuration

### Adding a New Service

Edit `repos_docker_files/config.yaml`:

```yaml
services:
  my-new-service:
    enabled: true
    git_repo: git@github.com:Orange-Health/my-new-service.git
    git_branch: main
    port: 8020
    configs:
      - source: configs/my_secrets.py
        dest: app/secrets.py
        required: true
```

Then create:
- `repos_docker_files/my-new-service.dev.Dockerfile`
- `configs/s1/my_secrets.py` (and for other namespaces)

## Inter-Service Communication

Services can reach each other by name within Docker:
- `http://health-api:8000` (from inside Docker)
- `http://localhost:8000` (from host machine)

## Secrets Handling

This repo uses git filters to mask secrets before committing:
- AWS keys → `MASKED_AWS_KEY`
- Slack tokens → `MASKED_SLACK_TOKEN`
- Private keys → `MASKED_PRIVATE_KEY`

Setup:
```bash
./scripts/setup-filters.sh
```

## Troubleshooting

### Namespace folder not found
```bash
# Create the namespace folder with configs
mkdir -p configs/s3
cp configs/s1/* configs/s3/
# Edit configs as needed
```

### Service won't start
```bash
make logs <service>
make clean
make run
```

### Redis connection failed
```bash
# Check kubectl context
kubectl config current-context

# Force restart redis
make restart
```

### Branch checkout failed
```bash
rm -rf cloned/<service-name>
make run
```

## Utilities

### Cross-Environment YAML Replacement

Replace environment prefixes in config files:
```bash
python replace_yaml_cross_env.py base.yaml target.yaml s1 s2
```

Changes URLs like `s1-api.orangehealth.dev` to `s2-api.orangehealth.dev`.
