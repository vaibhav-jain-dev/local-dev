# Scheduler API - Debugger Setup Instructions

This guide explains how to debug the `scheduler-api` service using VSCode or PyCharm.

## Prerequisites

- Docker and Docker Compose running
- `scheduler-api` service started via `make run` in local-dev repo
- VSCode with Python extension OR PyCharm Professional

## Port Configuration

- **Application Port**: 8010
- **Debug Port**: 5679 (mapped to container port 5678)

## Setup Instructions

### 1. Start the Service

From the `local-dev` repository:

```bash
make run
```

The service will start with `debugpy` listening on port 5678 (mapped to host port 5679).

### 2. VSCode Setup

#### A. Copy Launch Configuration

The debug configuration file is already created in `repos_docker_files/vscode-launch.json`.

1. Copy it to your scheduler-api workspace:
   ```bash
   mkdir -p .vscode
   cp ../repos_docker_files/vscode-launch.json .vscode/launch.json
   ```

2. Copy VSCode settings (optional):
   ```bash
   cp ../repos_docker_files/vscode-settings.json .vscode/settings.json
   ```

#### B. Start Debugging

1. Open the `scheduler-api` folder in VSCode
2. Set breakpoints in your code (e.g., `app/views.py`)
3. Press `F5` or go to **Run → Start Debugging**
4. Select **"Python: Remote Attach - scheduler-api"**
5. Debugger will connect to the running container
6. Make an API request - the debugger will pause at your breakpoints

### 3. PyCharm Professional Setup

#### A. Import Run Configuration

1. Copy the debug configuration:
   ```bash
   mkdir -p .idea/runConfigurations
   cp ../repos_docker_files/pycharm-scheduler-api.xml .idea/runConfigurations/
   ```

2. Restart PyCharm or reload the project

#### B. Start Debugging

1. Open the `scheduler-api` project in PyCharm
2. Set breakpoints in your code
3. Go to **Run → Debug → "Debug scheduler-api (Remote)"**
4. Debugger will attach to port 5679
5. Make an API request - debugger will pause at breakpoints

## Health Check Endpoints

The service includes health check endpoints for monitoring:

### Implementation

Copy the health check code from `repos_docker_files/scheduler-api-health-check.py` to your Django app and add to URLs:

```python
# In your urls.py
from .views import health_check, readiness_check, liveness_check

urlpatterns = [
    path('health/', health_check, name='health_check'),
    path('health/ready', readiness_check, name='readiness_check'),
    path('health/live', liveness_check, name='liveness_check'),
    # ... your other urls
]
```

### Testing Health Endpoints

```bash
# Full health check (includes DB and cache checks)
curl http://localhost:8010/health/

# Readiness check (is service ready to accept traffic?)
curl http://localhost:8010/health/ready

# Liveness check (is service alive?)
curl http://localhost:8010/health/live
```

## Troubleshooting

### Can't connect to debugger

**Check if container is running:**
```bash
docker ps | grep scheduler-api
```

**Check debug port is exposed:**
```bash
docker port scheduler-api 5678
# Should show: 5678/tcp -> 0.0.0.0:5679
```

**Check logs:**
```bash
make logs scheduler-api
# Should see: "Debugger listening on 0.0.0.0:5678"
```

### Breakpoints not hit

1. Ensure path mappings are correct:
   - Local: `${workspaceFolder}` or project root
   - Remote: `/app`

2. Check you're debugging the right service (scheduler-api uses port 5679)

3. Verify the code path being executed matches your local files

### Connection refused

1. Rebuild the container:
   ```bash
   make clean
   make run
   ```

2. Check firewall isn't blocking port 5679

3. Verify debugpy is installed in container:
   ```bash
   docker exec -it scheduler-api pip list | grep debugpy
   ```

## Advanced Usage

### Debugging with Wait-for-Client

If you want the service to wait for debugger before starting, modify the Dockerfile CMD:

```dockerfile
CMD ["python", "-m", "debugpy", "--listen", "0.0.0.0:5678", "--wait-for-client", "manage.py", "runserver", "0.0.0.0:8010", "--noreload"]
```

Then rebuild:
```bash
make clean && make run
```

### Debugging Specific Modules

To debug only specific modules, add conditional breakpoints or use `debugpy` programmatically:

```python
import debugpy

# Only in development
if settings.DEBUG:
    debugpy.listen(("0.0.0.0", 5678))
    # Optional: wait for debugger
    # debugpy.wait_for_client()
```

## Docker Compose Port Mapping

The debug port is automatically mapped in docker-compose.yml:

```yaml
scheduler-api:
  ports:
    - "8010:8010"    # Application port
    - "5679:5678"    # Debug port (host:container)
```

## Summary

✅ **Debugpy installed** in Docker container
✅ **Port 5679** (host) → **5678** (container) exposed for debugging
✅ **VSCode & PyCharm** configurations ready
✅ **Health endpoints** available at `/health/`, `/health/ready`, `/health/live`
✅ **Auto-reload disabled** (`--noreload`) for stable debugging

Happy debugging! 🐛🔍
