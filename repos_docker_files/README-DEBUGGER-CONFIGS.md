# Debugger Configuration Files

This directory contains debugger configuration files and health check implementations for all services in the local-dev environment.

## 📁 Files Overview

### Health Check Implementations

| File | Description | Target Service |
|------|-------------|----------------|
| `health-api-health-check.py` | Django health check endpoints | health-api |
| `scheduler-api-health-check.py` | Django health check endpoints | scheduler-api |

### VSCode Debug Configurations

| File | Description | Services |
|------|-------------|----------|
| `vscode-launch.json` | Python & Go remote debug configs | health-api, scheduler-api, oms |
| `vscode-launch-nodejs.json` | Node.js/Next.js debug configs | bifrost, oms-web |
| `vscode-settings.json` | Editor settings for Python & Go | All services |

### PyCharm Debug Configurations

| File | Description | Service |
|------|-------------|---------|
| `pycharm-health-api.xml` | PyCharm remote debug config | health-api |
| `pycharm-scheduler-api.xml` | PyCharm remote debug config | scheduler-api |

### GoLand Debug Configurations

| File | Description | Service |
|------|-------------|---------|
| `goland-oms.xml` | GoLand remote debug config | oms |

### Service-Specific Instructions

| File | Service Type | Services Covered |
|------|--------------|------------------|
| `health-api-debugger-instructions.md` | Python/Django | health-api |
| `scheduler-api-debugger-instructions.md` | Python/Django | scheduler-api |
| `oms-debugger-instructions.md` | Go | oms |
| `nodejs-debugger-instructions.md` | Node.js/Next.js | bifrost, oms-web |

## 🚀 Quick Start

### For Python Services (health-api, scheduler-api)

1. **Debugger already enabled** in Dockerfiles (debugpy installed, port 5678 exposed)
2. **Copy VSCode config** to your service:
   ```bash
   cd cloned/health-api
   mkdir -p .vscode
   cp ../../repos_docker_files/vscode-launch.json .vscode/launch.json
   ```
3. **Start debugging**: Press F5 in VSCode, select "Python: Remote Attach - health-api"
4. **Add health checks**: Copy code from `health-api-health-check.py` to your views

### For Go Services (oms)

1. **Delve debugger installed** in Dockerfile
2. **Copy VSCode config**:
   ```bash
   cd cloned/oms
   mkdir -p .vscode
   cp ../../repos_docker_files/vscode-launch.json .vscode/launch.json
   ```
3. **Run with Delve**: Update Dockerfile CMD or attach manually (see instructions)
4. **Start debugging**: Press F5, select "Go: Remote Attach - oms"

### For Node.js Services (bifrost, oms-web)

1. **Update Dockerfile** to run with `--inspect` flag (see nodejs-debugger-instructions.md)
2. **Copy VSCode config**:
   ```bash
   cd cloned/bifrost
   mkdir -p .vscode
   cp ../../repos_docker_files/vscode-launch-nodejs.json .vscode/launch.json
   ```
3. **Rebuild**: `make clean && make run`
4. **Start debugging**: Press F5, select "Docker: Attach to bifrost"

## 📊 Debug Port Mapping

| Service | Type | App Port | Debug Port (Host) | Debug Port (Container) |
|---------|------|----------|-------------------|------------------------|
| health-api | Python | 8000 | 5678 | 5678 |
| scheduler-api | Python | 8010 | 5679 | 5678 |
| oms | Go | 8080 | 2345 | 2345 |
| bifrost | Next.js | 3000 | 9229 | 9229 |
| oms-web | Node.js | 8182 | 9230 | 9230 |

## 🔧 Modified Dockerfiles

The following Dockerfiles have been updated with debugger support:

### Python Services
- `health-api.dev.Dockerfile` - Added debugpy, exposed port 5678
- `scheduler-api.dev.Dockerfile` - Added debugpy, exposed port 5678

### Go Services
- `oms.dev.Dockerfile` - Added Delve, exposed port 2345

### Node.js Services (Manual Update Required)
- `bifrost.dev.Dockerfile` - Instructions provided to add --inspect
- `oms-web.dev.Dockerfile` - Instructions provided to add --inspect

## 📝 How These Files Are Used

### During Local Development

When you run `make run` from the local-dev repository:

1. **Dockerfiles** are copied to cloned repos and used to build containers
2. **Debug ports** are automatically exposed in docker-compose.yml
3. **Debugger** runs inside each container

### Setting Up Your IDE

1. **Navigate to cloned service**:
   ```bash
   cd cloned/health-api  # or scheduler-api, oms, etc.
   ```

2. **Copy appropriate config files**:
   ```bash
   # For VSCode
   mkdir -p .vscode
   cp ../../repos_docker_files/vscode-launch.json .vscode/

   # For PyCharm
   mkdir -p .idea/runConfigurations
   cp ../../repos_docker_files/pycharm-health-api.xml .idea/runConfigurations/

   # For GoLand
   mkdir -p .idea/runConfigurations
   cp ../../repos_docker_files/goland-oms.xml .idea/runConfigurations/
   ```

3. **Start debugging** from your IDE

## 🏥 Health Check Endpoints

All services should implement these standard endpoints:

### Endpoints

- `GET /health` - Full health check (includes DB, cache, dependencies)
- `GET /health/ready` - Readiness check (is service ready for traffic?)
- `GET /health/live` - Liveness check (is service alive?)

### Response Format

```json
{
  "status": "healthy",
  "timestamp": 1234567890,
  "checks": {
    "database": "ok",
    "cache": "ok"
  },
  "response_time_ms": 45.2
}
```

### Implementation Files

- Python/Django: `health-api-health-check.py`, `scheduler-api-health-check.py`
- Go: Code example in `oms-debugger-instructions.md`
- Node.js: Code examples in `nodejs-debugger-instructions.md`

## 🐛 Troubleshooting

### Can't connect to debugger

1. **Check container is running**:
   ```bash
   docker ps | grep <service-name>
   ```

2. **Check debug port is exposed**:
   ```bash
   docker port <service-name> <debug-port>
   ```

3. **Check logs**:
   ```bash
   make logs <service-name>
   ```

4. **Rebuild containers**:
   ```bash
   make clean && make run
   ```

### Breakpoints not hit

1. Verify path mappings (local vs remote paths)
2. Ensure source code matches running container code
3. Check you're using the correct debug configuration

### Connection refused

1. Firewall blocking debug port
2. Debugger not started in container
3. Wrong port mapping in docker-compose.yml

## 📚 Documentation Links

- [Main Debugger Setup Guide](../DEBUGGER_SETUP.md) - Overview in root directory
- Service-specific guides in this directory (see table above)

## 🎯 Summary

✅ **Health check templates** ready for Python, Go, and Node.js
✅ **Debugger support** added to Python and Go Dockerfiles
✅ **IDE configurations** created for VSCode, PyCharm, and GoLand
✅ **Instructions** provided for each service type
✅ **Debug ports** documented and exposed

All configurations are stored in `repos_docker_files/` and can be copied to individual service repos as needed.
