#!/bin/bash
# Comprehensive health-api diagnostic script

echo "=== Health API Comprehensive Diagnostics ==="
echo ""

echo "1. Checking if cloned/health-api directory exists..."
if [ -d "cloned/health-api" ]; then
    echo "✓ Directory exists"
    ls -la cloned/health-api/ | head -15
else
    echo "✗ Directory not found - run ./run.sh first"
    exit 1
fi
echo ""

echo "2. Checking if required config files were copied..."
if [ -f "cloned/health-api/app/app/secrets.py" ]; then
    echo "✓ secrets.py exists"
else
    echo "✗ secrets.py MISSING - this will cause container to fail!"
    echo "  Expected at: cloned/health-api/app/app/secrets.py"
fi

if [ -f "cloned/health-api/serviceAccountKey.json" ]; then
    echo "✓ serviceAccountKey.json exists"
else
    echo "⚠ serviceAccountKey.json missing (optional)"
fi
echo ""

echo "3. Checking if Dockerfile was copied..."
if [ -f "cloned/health-api/dev.Dockerfile" ]; then
    echo "✓ dev.Dockerfile exists"
else
    echo "✗ dev.Dockerfile MISSING"
fi
echo ""

echo "4. Checking Docker container status..."
docker ps -a | grep health-api || echo "No health-api container found"
echo ""

echo "5. Getting container logs (last 100 lines)..."
docker logs health-api 2>&1 | tail -100 || echo "Cannot get logs - container may not exist"
echo ""

echo "6. Checking if ports are in use..."
netstat -tlnp 2>/dev/null | grep -E ':(8000|5678)' || echo "Ports 8000 and 5678 are available"
echo ""

echo "7. Checking environment variables in container..."
docker exec health-api env 2>/dev/null | grep -E '(DJANGO|PYTHON)' || echo "Cannot exec - container not running"
echo ""

echo "8. Trying to inspect container exit code..."
docker inspect health-api --format='Exit Code: {{.State.ExitCode}}, Error: {{.State.Error}}' 2>/dev/null || echo "Container doesn't exist"
echo ""

echo "9. Checking if we can manually start the container..."
echo "Attempting to start..."
docker start health-api 2>&1
sleep 3
docker ps | grep health-api && echo "✓ Container is now running!" || echo "✗ Container failed to start"
echo ""

echo "10. Final container logs after start attempt..."
docker logs health-api 2>&1 | tail -50
echo ""

echo "=== Diagnostics Complete ==="
echo ""
echo "Common fixes:"
echo "  1. If secrets.py is missing: Check configs/health_secrets.py exists"
echo "  2. If app/ directory missing: Re-run ./run.sh to clone repos"
echo "  3. If build failed: Try 'docker-compose build health-api --no-cache'"
echo "  4. If port conflict: Kill process using port 8000"
