# Orange Health Local Development Environment - AI Agent Guide

## Project Overview

This is a **local development orchestrator** for Orange Health's microservices architecture. It clones multiple service repositories, injects environment-specific configurations, and orchestrates them via Docker Compose with shared networking and Kubernetes-based Redis.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Local Development Orchestrator (this repo)                 │
│  ├─ run.sh: Main bash orchestrator (~2380 lines)            │
│  ├─ repos_docker_files/config.yaml: Service definitions     │
│  └─ configs/<namespace>/: Environment-specific secrets      │
└─────────────────────────────────────────────────────────────┘
                         │
                         ├──> Clones & orchestrates
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  Microservices (cloned into cloned/)                        │
│  ├─ health-api: Django 3.1 REST API (Python 3.8+)          │
│  ├─ scheduler-api: Django REST API (Python)                 │
│  ├─ oms-api: Go service (main entry point)                  │
│  ├─ oms-worker, oms-worker-scheduler, oms-consumer-worker   │
│  ├─ bifrost: Next.js web app (port 3000)                    │
│  └─ oms-web: Node.js web app (port 8182)                    │
└─────────────────────────────────────────────────────────────┘
                         │
                         ├──> Shared Docker network: oh-network
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  External Dependencies                                       │
│  └─ Redis: kubectl port-forward from K8s (port 6379)        │
└─────────────────────────────────────────────────────────────┘
```

**Key Services:**
- **health-api** (8000): Central healthcare backend - patient records, orders, payments, CRM
- **scheduler-api** (8010): Appointment and task scheduling service
- **oms-api** (8080): Order Management System (Go) with 3 workers
- **bifrost** (3000): Next.js customer-facing web app
- **oms-web** (8182): Internal admin dashboard

## Critical Developer Workflows

### Starting Services

```bash
# Default: Start all with s1 namespace
make run

# Specific namespace (s1, s2, s3, s4, s5, qa, auto)
make run s2

# Specific services only
make run s1 health-api oms-api

# Pull latest code (discards local changes)
make run refresh s2

# With web dashboard UI
make run --dashboard

# With live scrolling build logs
make run --live s1
```

**What happens internally:**
1. Validates namespace exists in `configs/<namespace>/`
2. Clones repos (parallel) into `cloned/` OR switches branches if already cloned
3. Copies namespace-specific secrets from `configs/<namespace>/` into cloned repos
4. Copies custom Dockerfiles from `repos_docker_files/` (namespace-specific override or default)
5. Auto-generates `docker-compose.yml`
6. Starts `kubectl port-forward -n <namespace> deployment/redis 6379:6379`
7. Runs `docker-compose up` with parallel builds

### Configuration Injection

Services require environment-specific secrets. The orchestrator **overwrites** files in cloned repos:

```yaml
# Example from repos_docker_files/config.yaml
services:
  health-api:
    configs:
      - source: configs/health_secrets.py
        dest: app/app/secrets.py      # Overwrites cloned repo file
        required: true
      - source: configs/health_creds.json
        dest: serviceAccountKey.json
        required: false
```

**IMPORTANT:** When modifying services, remember secrets are injected from `configs/<namespace>/`, not stored in service repos.

### Debugging Python Services

Both `health-api` and `scheduler-api` expose debugpy ports:

```yaml
# docker-compose.yml (auto-generated)
ports:
  - "8000:8000"
  - "5726:5678"  # debugpy port - NOTE: BOTH services use 5726, causing conflict!
environment:
  DEBUG_PORT: 5678
```

**Known Issue:** Both Python services map to `5726:5678`, causing port conflict. Only one can be debugged at a time. Change one to `5727:5678` when debugging both.

VSCode/PyCharm debug configs stored in `configs/<namespace>/debug-configs/` and auto-copied to cloned repos.

### Namespace System

Namespaces determine which Kubernetes environment to connect to:

- **s1-s5**: Staging environments (default: s1)
- **qa, auto**: QA/automation environments
- Each namespace has its own `configs/<namespace>/` folder with secrets
- Redis port-forward connects to `kubectl -n <namespace> deployment/redis`

**Config folder must exist** or `run.sh` will error. Validate with:
```bash
ls -la configs/s2/  # Must contain health_secrets.py, oms.yaml, etc.
```

## Project-Specific Conventions

### Service Workers (OMS)

When `oms-api` is started, **3 workers auto-start** with it:
- `oms-worker`: General background tasks
- `oms-worker-scheduler`: Scheduled job processor
- `oms-consumer-worker`: Queue consumer

All share the same `cloned/oms/` codebase but use different Dockerfiles:
```yaml
workers:
  oms-worker:
    dockerfile: oms-worker.dev.Dockerfile
  oms-worker-scheduler:
    dockerfile: oms-worker-scheduler.dev.Dockerfile
  oms-consumer-worker:
    dockerfile: oms-consumer-worker.dev.Dockerfile
```

### Refresh Behavior

- **Without `refresh`**: Preserves local code changes in `cloned/`
- **With `refresh`**: Runs `git reset --hard && git clean -fd && git pull`
- **Per-service override**: Add `always-refresh: true` in `config.yaml`

This allows iterating on one service while keeping others stable.

### Redis Port Management

`run.sh` checks if port 6379 is busy:
- **Busy**: Skips port-forward (assumes already running)
- **Free**: Starts `kubectl port-forward`
- **On restart**: Force-kills existing port-forward and reconnects

Use `make restart` to force Redis reconnection if stale.

### Docker Compose Generation

`docker-compose.yml` is **auto-generated** by `run.sh`. Manual edits will be overwritten.

To modify services:
1. Edit `repos_docker_files/config.yaml` (service definitions)
2. Edit `repos_docker_files/<service>.dev.Dockerfile` (Dockerfile)
3. Create namespace-specific override: `repos_docker_files/<namespace>/<service>.dev.Dockerfile`

### Private NPM Packages

Frontend services (bifrost, oms-web) require GitHub token for `@orange-health` packages:

```bash
export GITHUB_NPM_TOKEN="ghp_your_token_here"  # Read:packages scope
```

Dockerfiles inject this via build args:
```dockerfile
ARG GITHUB_NPM_TOKEN
RUN echo "//npm.pkg.github.com/:_authToken=${GITHUB_NPM_TOKEN}" > .npmrc
```

## Common Pitfalls

1. **Port conflicts**: Both Python services share debugger port 5726
2. **Manual compose edits**: Auto-generated file will be overwritten
3. **Missing secrets**: Namespace config folder must exist with all required secrets
4. **Redis stale connection**: Use `make restart` to force reconnect
5. **Dockerfile location**: Check for namespace-specific override before modifying default
6. **Local changes**: Use `refresh` flag to discard, or commit before pulling

## File Structure Reference

```
local-dev/
├── run.sh                          # Main orchestrator (2380 lines bash)
├── Makefile                        # User-facing commands
├── repos_docker_files/
│   ├── config.yaml                 # Service definitions (YAML)
│   ├── <service>.dev.Dockerfile    # Default Dockerfiles
│   └── <namespace>/                # Namespace-specific overrides
│       └── <service>.dev.Dockerfile
├── configs/
│   └── <namespace>/                # Environment secrets (s1, s2, ...)
│       ├── health_secrets.py
│       ├── scheduler_secrets.py
│       ├── oms.yaml
│       └── debug-configs/          # IDE debug configs
├── cloned/                         # Cloned service repos (gitignored)
│   ├── health-api/
│   ├── scheduler-api/
│   ├── oms/
│   ├── bifrost/
│   └── oms-web/
├── dashboard/                      # Optional web UI for monitoring
│   └── server.py                   # Flask dashboard (--dashboard flag)
└── logs/                           # Build logs, metrics, cache
    ├── build_output.log
    ├── run_metrics.json
    └── progress.json
```

## When Working on Services

1. **Clone happens automatically** - Don't manually clone into `cloned/`
2. **Secrets are injected** - Check `configs/<namespace>/` not service repo
3. **Test locally first** - Use `make run s1 <service>` before pushing
4. **Check dependencies** - Ensure Redis is accessible and other services are running
5. **Logs**: `make logs <service>` or check dashboard at `http://localhost:9999`

## Integration Points

- **Service-to-service**: Via Docker network `oh-network` using container names (e.g., `http://health-api:8000`)
- **Redis**: Shared state via `localhost:6379` (port-forwarded from K8s)
- **External APIs**: Configured per-namespace in secret files
- **K8s**: Only Redis - services run in Docker, not K8s

## Quick Reference Commands

```bash
make run s2 health-api              # Start health-api with s2 config
make run refresh                    # Pull latest code, start all
make restart                        # Force restart with Redis reconnect
make logs health-api                # View service logs
make stats                          # Docker resource usage
make stop                           # Stop all services
make clean                          # Stop + remove cloned repos + prune Docker
```
