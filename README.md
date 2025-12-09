# Orange Health Local Development

A local development environment orchestrator for running Orange Health microservices via Docker.

## Overview

This tool clones multiple repositories, overrides their configurations with environment-specific settings, and runs them in Docker containers on a shared network.

## Prerequisites

- Docker & Docker Compose
- Git (with SSH access to Orange-Health repositories)
- `yq` (YAML processor) - install via `brew install yq` or `apt install yq`
- `kubectl` (for Redis port-forwarding from Kubernetes)

## Quick Start

```bash
# Start all services with default config
make start

# Start all services with specific environment (s1, s2, s3, etc.)
make start tag=s1

# Start a specific service
make start health-api

# Start a specific service with environment
make start health-api tag=s2
```

## Directory Structure

```
local-dev/
├── configs/                    # Configuration files
│   ├── health_secrets.py       # Default configs
│   ├── oms.yaml
│   ├── scheduler_secrets.py
│   ├── s1/                     # Environment s1 configs
│   │   ├── health_secrets.py
│   │   ├── oms.yaml
│   │   └── scheduler_secrets.py
│   └── s2/                     # Environment s2 configs
│       └── ...
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

## Commands

| Command | Description |
|---------|-------------|
| `make start` | Start all enabled services |
| `make start <service>` | Start specific service |
| `make start tag=<env>` | Start with environment-specific configs |
| `make stop` | Stop all services |
| `make clean` | Stop services and remove cloned repos |
| `make logs` | View logs for all services |
| `make logs <service>` | View logs for specific service |
| `make stats` | View resource usage |

## Environment Tags

Use environment tags to switch between different configurations:

```bash
# Uses configs from configs/s1/
make start tag=s1

# Uses configs from configs/s2/
make start tag=s2
```

When a tag is specified:
1. Config files are loaded from `configs/<tag>/` instead of `configs/`
2. Redis namespace switches to the tag value (e.g., `kubectl port-forward -n s1 ...`)

## Services

| Service | Port | Repository |
|---------|------|------------|
| health-api | 8000 | Orange-Health/health-api |
| scheduler-api | 8010 | Orange-Health/scheduler-api |
| oms-api | 8080 | Orange-Health/oms |

## How It Works

1. **Clone**: Repositories are cloned into `cloned/` directory
2. **Override**: Config files from `configs/` (or `configs/<tag>/`) are copied into cloned repos
3. **Dockerfile**: Service-specific Dockerfiles are copied from `repos_docker_files/`
4. **Compose**: `docker-compose.yml` is auto-generated
5. **Build & Run**: Docker containers are built and started

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
- `configs/my_secrets.py` (and environment-specific versions)

### Redis Connection

Redis is accessed via kubectl port-forward. The namespace is determined by:
1. Environment tag if provided (`--tag=s2` uses namespace `s2`)
2. Default namespace from config.yaml (`redis.namespace`)

```yaml
redis:
  namespace: s5              # Default namespace
  deployment: redis
  port: 6379
  start_cmd: |
    kubectl port-forward -n {namespace} deployment/redis 6379:6379
```

## Inter-Service Communication

Services can reach each other by name within Docker:
- `http://health-api:8000` (from inside Docker)
- `http://localhost:8000` (from host machine)

## Secrets Handling

This repo uses git filters to mask secrets before committing:
- AWS keys are replaced with `MASKED_AWS_KEY`
- Slack tokens are replaced with `MASKED_SLACK_TOKEN`
- Private keys are replaced with `MASKED_PRIVATE_KEY`

To set up the filter:
```bash
./scripts/setup-filters.sh
```

## Troubleshooting

### Service won't start
```bash
# Check logs
make logs <service>

# Clean and restart
make clean
make start
```

### Redis connection failed
```bash
# Verify kubectl context
kubectl config current-context

# Manual port-forward
kubectl port-forward -n s5 deployment/redis 6379:6379
```

### Branch checkout failed
The script will discard local changes when switching branches. If issues persist:
```bash
rm -rf cloned/<service-name>
make start <service>
```

## Utilities

### Cross-Environment YAML Replacement

Replace environment prefixes in config files:
```bash
python replace_yaml_cross_env.py base.yaml target.yaml s1 s2
```

This changes URLs like `s1-api.orangehealth.dev` to `s2-api.orangehealth.dev`.
