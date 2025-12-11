# Debugger Setup Guide for PyCharm and VSCode

This guide shows you how to add debugger support to your Python backend services (health-api, scheduler-api, oms-api).

## 🎯 What's Already Configured

✅ **Docker Compose** - Debug ports exposed automatically:
- `health-api`: localhost:5678
- `scheduler-api`: localhost:5679
- `oms-api`: localhost:5680

✅ **Debug Configs** - Stored in `configs/s1/debug-configs/`
  - `.vscode/launch.json` - VSCode remote debug configurations
  - `.vscode/settings.json` - VSCode Python/Go settings
  - `.idea/runConfigurations/` - PyCharm debug configurations

✅ **Auto-Copy** - Debug configs automatically copied to `cloned/` repos during `make run`

## 📁 Config Structure

```
configs/s1/
└── debug-configs/
    ├── .vscode/
    │   ├── launch.json      # VSCode debug configs
    │   └── settings.json    # VSCode editor settings
    └── .idea/
        └── runConfigurations/
            ├── Debug_health_api.xml
            ├── Debug_scheduler_api.xml
            └── Debug_oms_api.xml
```

These get automatically copied to each cloned repo:
```
cloned/health-api/.vscode/launch.json
cloned/health-api/.idea/runConfigurations/Debug_health_api.xml
```

## 📝 Dockerfile Changes Required

You need to update each Python service's `dev.Dockerfile` to install and run `debugpy`.

### For health-api/dev.Dockerfile

```dockerfile
FROM python:3.9-slim

WORKDIR /app

# Install debugpy for remote debugging
RUN pip install debugpy

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install -r requirements.txt

# Copy application code
COPY ./app /app

# Expose application port and debug port
EXPOSE 8000 5678

# Run with debugpy enabled
# The app will wait for debugger to attach before starting
CMD python -m debugpy --listen 0.0.0.0:5678 --wait-for-client manage.py runserver 0.0.0.0:8000
```

### For scheduler-api/dev.Dockerfile

```dockerfile
FROM python:3.9-slim

WORKDIR /app

# Install debugpy for remote debugging
RUN pip install debugpy

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install -r requirements.txt

# Copy application code
COPY ./app /app

# Expose application port and debug port
EXPOSE 8010 5678

# Run with debugpy enabled
CMD python -m debugpy --listen 0.0.0.0:5678 --wait-for-client manage.py runserver 0.0.0.0:8010
```

### For oms-api (if it's Python)

If oms-api is Python/Django:

```dockerfile
FROM python:3.9-slim

WORKDIR /app

# Install debugpy for remote debugging
RUN pip install debugpy

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install -r requirements.txt

# Copy application code
COPY ./app /app

# Expose application port and debug port
EXPOSE 8080 5678

# Run with debugpy enabled
CMD python -m debugpy --listen 0.0.0.0:5678 --wait-for-client manage.py runserver 0.0.0.0:8080
```

If oms-api is **Go**, add Delve debugger:

```dockerfile
FROM golang:1.21-alpine

# Install Delve debugger
RUN go install github.com/go-delve/delve/cmd/dlv@latest

WORKDIR /go/src/github.com/Orange-Health/oms

# Copy go.mod and go.sum
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Expose application port and debug port
EXPOSE 8080 2345

# Run with Delve debugger
CMD ["dlv", "debug", "--headless", "--listen=:2345", "--api-version=2", "--accept-multiclient", "./cmd/api"]
```

## 🚀 How to Use

### VSCode

1. **Start your services:**
   ```bash
   make run
   ```

2. **Set breakpoints** in your code (e.g., `cloned/health-api/app/views.py`)

3. **Press F5** or go to Run → Start Debugging

4. **Select configuration:**
   - "Python: Remote Attach - health-api"
   - "Python: Remote Attach - scheduler-api"
   - "Python: Remote Attach - oms-api"

5. **Debugger will attach** to the running container

6. **Make a request** to your API - debugger will pause at breakpoints

### PyCharm Professional

1. **Start your services:**
   ```bash
   make run
   ```

2. **Set breakpoints** in your code

3. **Run → Debug** → Select:
   - "Debug health-api"
   - "Debug scheduler-api"
   - "Debug oms-api"

4. **Make a request** to your API - debugger will pause at breakpoints

## 🔧 Debugging Without Wait-for-Client

If you don't want the service to wait for debugger on startup, remove `--wait-for-client`:

```dockerfile
# Non-blocking debug mode (service starts immediately)
CMD python -m debugpy --listen 0.0.0.0:5678 manage.py runserver 0.0.0.0:8000
```

## 📍 Port Mappings

| Service        | App Port | Debug Port (Host) | Debug Port (Container) |
|---------------|----------|-------------------|------------------------|
| health-api    | 8000     | 5678              | 5678                   |
| scheduler-api | 8010     | 5679              | 5678                   |
| oms-api       | 8080     | 5680              | 5678                   |

## 🐛 Troubleshooting

**"Connection refused"**
- Check container is running: `docker ps`
- Check port is exposed: `docker port health-api`

**"Debugger doesn't stop at breakpoints"**
- Make sure you're using the correct path mappings
- VSCode: Check `.vscode/launch.json` `pathMappings`
- PyCharm: Check Run Configuration path mappings

**"Can't attach to debugger"**
- Container might not have started yet
- Check logs: `make logs health-api`
- Rebuild: `make clean && make run`

## 🎨 Alternative: Development Mode Without Debugger

If you want to run without debugger (faster startup):

```dockerfile
# Regular development mode
CMD python manage.py runserver 0.0.0.0:8000
```

Then attach debugger only when needed using `docker exec`:

```bash
# Attach debugpy to running container
docker exec -it health-api python -m debugpy --listen 0.0.0.0:5678 --wait-for-client manage.py runserver
```

## ✅ Verification

After updating Dockerfiles:

```bash
# Rebuild containers
make clean
make run

# Check debug ports are open
lsof -i :5678  # health-api
lsof -i :5679  # scheduler-api
lsof -i :5680  # oms-api

# Test debugger connection
telnet localhost 5678
```

Happy debugging! 🎉
