# Node.js Services - Debugger Setup Instructions

This guide explains how to debug Node.js/Next.js services (`bifrost`, `oms-web`) using VSCode or WebStorm.

## Services Covered

- **bifrost**: Next.js frontend (port 3000)
- **oms-web**: Node.js frontend (port 8182)

## Prerequisites

- Docker and Docker Compose running
- Service started via `make run` in local-dev repo
- VSCode with JavaScript Debugger OR WebStorm IDE

## Setup Instructions

### 1. Update Dockerfile for Debugging

To enable debugging, you need to run Node.js with the `--inspect` flag.

#### For bifrost (Next.js)

Update `/repos_docker_files/bifrost.dev.Dockerfile` CMD:

```dockerfile
# Enable debugging on port 9229
CMD ["sh", "-c", "echo '=== Starting application with debugger on port ${PORT} ===' && node --inspect=0.0.0.0:9229 node_modules/.bin/next dev -p ${PORT}"]
```

Expose the debug port:
```dockerfile
EXPOSE 3000 9229
```

#### For oms-web (Node.js)

Update `/repos_docker_files/oms-web.dev.Dockerfile` CMD:

```dockerfile
# Enable debugging on port 9230
CMD ["sh", "-c", "echo '=== Starting application with debugger on port ${PORT} ===' && node --inspect=0.0.0.0:9230 $(npm root)/.bin/react-scripts start || npm run dev --inspect=0.0.0.0:9230"]
```

Expose the debug port:
```dockerfile
EXPOSE 8182 9230
```

### 2. Update docker-compose.yml

Ensure debug ports are mapped in your docker-compose.yml:

```yaml
bifrost:
  ports:
    - "3000:3000"    # Application
    - "9229:9229"    # Debug port

oms-web:
  ports:
    - "8182:8182"    # Application
    - "9230:9230"    # Debug port
```

### 3. VSCode Setup

#### A. Create Launch Configuration

Create `.vscode/launch.json` in your service directory:

**For bifrost:**
```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Docker: Attach to bifrost",
      "type": "node",
      "request": "attach",
      "port": 9229,
      "address": "localhost",
      "localRoot": "${workspaceFolder}",
      "remoteRoot": "/app",
      "protocol": "inspector",
      "skipFiles": [
        "<node_internals>/**"
      ]
    }
  ]
}
```

**For oms-web:**
```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Docker: Attach to oms-web",
      "type": "node",
      "request": "attach",
      "port": 9230,
      "address": "localhost",
      "localRoot": "${workspaceFolder}",
      "remoteRoot": "/app",
      "protocol": "inspector",
      "skipFiles": [
        "<node_internals>/**"
      ]
    }
  ]
}
```

#### B. Start Debugging

1. Rebuild and start services:
   ```bash
   make clean && make run
   ```

2. Open the service folder in VSCode
3. Set breakpoints in your code
4. Press `F5` or go to **Run → Start Debugging**
5. Select the appropriate configuration
6. Access the app in browser - debugger will pause at breakpoints

### 4. WebStorm Setup

#### A. Create Debug Configuration

1. Go to **Run → Edit Configurations**
2. Click **+** → **Attach to Node.js/Chrome**
3. Configure:
   - **Host**: `localhost`
   - **Port**: `9229` (bifrost) or `9230` (oms-web)
   - **Path mappings**: Local path → `/app`

#### B. Start Debugging

1. Start the service: `make run`
2. Click **Run → Debug → [Your Configuration]**
3. Set breakpoints and access the app

## Browser DevTools Alternative

You can also debug using Chrome DevTools:

1. Start the service with `--inspect` flag (as shown above)
2. Open Chrome and navigate to `chrome://inspect`
3. Click **Configure** and add `localhost:9229` (or `9230`)
4. Click **inspect** under your Node.js target
5. Set breakpoints in the Sources tab

## Health Check for Node.js Services

Add a health endpoint to your Node.js app:

### Express.js Example

```javascript
// Add to your server.js or app.js
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'healthy',
    timestamp: Date.now(),
    uptime: process.uptime(),
    memory: process.memoryUsage()
  });
});

app.get('/health/ready', (req, res) => {
  res.status(200).json({ status: 'ready' });
});

app.get('/health/live', (req, res) => {
  res.status(200).json({ status: 'alive' });
});
```

### Next.js API Route Example

Create `pages/api/health.js` (bifrost):

```javascript
export default function handler(req, res) {
  res.status(200).json({
    status: 'healthy',
    timestamp: Date.now(),
    uptime: process.uptime(),
    memory: process.memoryUsage()
  });
}
```

### Testing

```bash
# bifrost
curl http://localhost:3000/api/health

# oms-web
curl http://localhost:8182/health
```

## Troubleshooting

### Can't connect to debugger

**Check if debug port is exposed:**
```bash
docker port bifrost 9229
docker port oms-web 9230
```

**Check if Node.js is running with --inspect:**
```bash
docker logs bifrost | grep inspect
docker logs oms-web | grep inspect
```

**Verify the container is running:**
```bash
docker ps | grep bifrost
docker ps | grep oms-web
```

### Breakpoints not binding

1. Ensure path mappings are correct:
   - Local: `${workspaceFolder}` or project root
   - Remote: `/app`

2. Source maps might be needed for transpiled code (TypeScript, Babel)

3. Try adding `"sourceMaps": true` to launch.json

### Connection keeps dropping

Some frameworks restart the Node.js process on file changes. Options:
- Use `"restart": true` in launch.json
- Disable hot reload temporarily
- Use `nodemon` with `--inspect` flag that maintains debug connection

## Advanced Configuration

### Debugging with Source Maps (TypeScript/Next.js)

```json
{
  "name": "Docker: Attach to bifrost (TypeScript)",
  "type": "node",
  "request": "attach",
  "port": 9229,
  "address": "localhost",
  "localRoot": "${workspaceFolder}",
  "remoteRoot": "/app",
  "sourceMaps": true,
  "outFiles": [
    "${workspaceFolder}/.next/**/*.js"
  ],
  "skipFiles": [
    "<node_internals>/**",
    "**/node_modules/**"
  ]
}
```

### Auto-attach in VSCode

Enable auto-attach in VSCode settings:
1. `Ctrl+Shift+P` → "Debug: Toggle Auto Attach"
2. Select "Always" or "Smart"

## Port Summary

| Service    | App Port | Debug Port |
|------------|----------|------------|
| bifrost    | 3000     | 9229       |
| oms-web    | 8182     | 9230       |

## Summary

✅ **Node.js debugging** enabled with `--inspect` flag
✅ **Debug ports exposed**: 9229 (bifrost), 9230 (oms-web)
✅ **VSCode & WebStorm** configurations available
✅ **Health endpoints** can be added to monitor service status
✅ **Chrome DevTools** as alternative debugging option

Happy debugging! 🐛🔍
