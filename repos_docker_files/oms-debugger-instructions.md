# OMS (Order Management System) - Debugger Setup Instructions

This guide explains how to debug the `oms` service (Go application) using VSCode or GoLand.

## Prerequisites

- Docker and Docker Compose running
- `oms-api` service started via `make run` in local-dev repo
- VSCode with Go extension OR GoLand IDE

## Port Configuration

- **Application Port**: 8080
- **Debug Port**: 2345 (Delve debugger)

## Setup Instructions

### 1. Start the Service

From the `local-dev` repository:

```bash
make run
```

The service will start with Delve debugger installed and port 2345 exposed.

### 2. VSCode Setup

#### A. Copy Launch Configuration

The debug configuration file is already created in `repos_docker_files/vscode-launch.json`.

1. Copy it to your oms workspace:
   ```bash
   mkdir -p .vscode
   cp ../repos_docker_files/vscode-launch.json .vscode/launch.json
   ```

2. Copy VSCode settings (optional):
   ```bash
   cp ../repos_docker_files/vscode-settings.json .vscode/settings.json
   ```

3. Install Go extension for VSCode if not already installed

#### B. Start Debugging with Delve

To debug, you need to run the application with Delve. There are two approaches:

**Option 1: Run with Delve from the start**

Update the Dockerfile CMD to:
```dockerfile
CMD ["dlv", "debug", "--headless", "--listen=:2345", "--api-version=2", "--accept-multiclient", "main.go"]
```

Then rebuild and start:
```bash
make clean && make run
```

**Option 2: Attach Delve to running process**

1. Start the container normally
2. Execute Delve inside the running container:
   ```bash
   docker exec -it oms-api dlv attach $(docker exec oms-api pgrep -f "go run main.go") --headless --listen=:2345 --api-version=2
   ```

#### C. Connect Debugger

1. Open the `oms` folder in VSCode
2. Set breakpoints in your Go code (e.g., `main.go`, handlers)
3. Press `F5` or go to **Run → Start Debugging**
4. Select **"Go: Remote Attach - oms"**
5. Debugger will connect to Delve on port 2345
6. Make an API request - debugger will pause at breakpoints

### 3. GoLand Setup

#### A. Import Run Configuration

1. Copy the debug configuration:
   ```bash
   mkdir -p .idea/runConfigurations
   cp ../repos_docker_files/goland-oms.xml .idea/runConfigurations/
   ```

2. Restart GoLand or reload the project

#### B. Start with Delve

Similar to VSCode, update the Dockerfile to run with Delve:

```dockerfile
CMD ["dlv", "debug", "--headless", "--listen=:2345", "--api-version=2", "--accept-multiclient", "main.go"]
```

Rebuild:
```bash
make clean && make run
```

#### C. Connect Debugger

1. Open the `oms` project in GoLand
2. Set breakpoints in your code
3. Go to **Run → Debug → "Debug oms (Remote)"**
4. Debugger will attach to port 2345
5. Make an API request - debugger will pause at breakpoints

## Health Check Endpoint

Add a health check endpoint to your Go application:

```go
// Add to your main.go or routes file
package main

import (
    "encoding/json"
    "net/http"
    "time"
)

type HealthResponse struct {
    Status    string             `json:"status"`
    Timestamp int64              `json:"timestamp"`
    Checks    map[string]string  `json:"checks"`
}

func healthCheckHandler(w http.ResponseWriter, r *http.Request) {
    health := HealthResponse{
        Status:    "healthy",
        Timestamp: time.Now().Unix(),
        Checks:    make(map[string]string),
    }

    // Check database connection
    if err := db.Ping(); err != nil {
        health.Status = "unhealthy"
        health.Checks["database"] = "error: " + err.Error()
        w.WriteHeader(http.StatusServiceUnavailable)
    } else {
        health.Checks["database"] = "ok"
        w.WriteHeader(http.StatusOK)
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(health)
}

func readinessHandler(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(map[string]string{"status": "ready"})
}

func livenessHandler(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(map[string]string{"status": "alive"})
}

// Register routes
func main() {
    // ... your existing code

    http.HandleFunc("/health", healthCheckHandler)
    http.HandleFunc("/health/ready", readinessHandler)
    http.HandleFunc("/health/live", livenessHandler)

    // ... rest of your routes
}
```

### Testing Health Endpoints

```bash
# Full health check
curl http://localhost:8080/health

# Readiness check
curl http://localhost:8080/health/ready

# Liveness check
curl http://localhost:8080/health/live
```

## Troubleshooting

### Can't connect to debugger

**Check if container is running:**
```bash
docker ps | grep oms-api
```

**Check debug port is exposed:**
```bash
docker port oms-api 2345
# Should show: 2345/tcp -> 0.0.0.0:2345
```

**Check if Delve is installed:**
```bash
docker exec -it oms-api dlv version
```

**Check logs:**
```bash
make logs oms-api
```

### Delve not found

Ensure the Dockerfile installs Delve:
```dockerfile
RUN go install github.com/go-delve/delve/cmd/dlv@latest
```

Rebuild:
```bash
make clean && make run
```

### Breakpoints not hit

1. Ensure the application is built with debug symbols (no `-ldflags "-s -w"`)
2. Verify Delve is actually running and listening on port 2345
3. Check path mappings match between local and container

### Permission denied errors

If you get permission issues with Delve, run container with additional capabilities:

```yaml
# In docker-compose.yml
oms-api:
  cap_add:
    - SYS_PTRACE
  security_opt:
    - "apparmor=unconfined"
```

## Advanced Usage

### Debugging with Air (Hot Reload)

You can combine Air for hot reload with Delve for debugging:

Create `.air.toml` in your oms directory:
```toml
[build]
  cmd = "dlv debug --headless --listen=:2345 --api-version=2 --accept-multiclient main.go"
  bin = ""
  full_bin = ""
  include_ext = ["go"]
  exclude_dir = ["vendor", "tmp"]
  delay = 1000
```

Update Dockerfile CMD:
```dockerfile
CMD ["air"]
```

### Debugging Tests

To debug tests with Delve:

```bash
docker exec -it oms-api dlv test --headless --listen=:2345 --api-version=2 ./...
```

Then attach your debugger to port 2345.

## Docker Compose Port Mapping

The debug port is automatically mapped in docker-compose.yml:

```yaml
oms-api:
  ports:
    - "8080:8080"    # Application port
    - "2345:2345"    # Delve debug port
  cap_add:
    - SYS_PTRACE    # Required for Delve
```

## Summary

✅ **Delve debugger installed** in Docker container
✅ **Port 2345** exposed for debugging
✅ **VSCode & GoLand** configurations ready
✅ **Health endpoints** available at `/health`, `/health/ready`, `/health/live`
✅ **SYS_PTRACE** capability may be needed for debugging

## Quick Reference

```bash
# Start with debugging enabled
docker exec -it oms-api dlv debug --headless --listen=:2345 --api-version=2 main.go

# Attach to running process
docker exec -it oms-api dlv attach $(docker exec oms-api pgrep main) --headless --listen=:2345

# Debug tests
docker exec -it oms-api dlv test --headless --listen=:2345 ./...
```

Happy debugging! 🐛🔍
