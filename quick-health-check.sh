#!/bin/bash
# Quick health-api diagnostic

echo "=== Quick Health API Diagnostic ==="
echo ""

echo "1. Container status:"
docker ps -a | grep health-api
echo ""

echo "2. Last 50 lines of logs:"
docker logs health-api 2>&1 | tail -50
echo ""

echo "3. Inspecting container:"
docker inspect health-api --format='State: {{.State.Status}}, ExitCode: {{.State.ExitCode}}, Error: {{.State.Error}}' 2>/dev/null
echo ""

echo "4. Checking if secrets.py exists inside container:"
docker exec health-api ls -la /app/app/secrets.py 2>/dev/null || echo "Cannot check - container not running or file missing"
echo ""

echo "5. Checking build directory structure:"
ls -la cloned/health-api/app/app/ 2>/dev/null | grep secrets || echo "secrets.py not found in build directory!"
echo ""

echo "6. Trying to rebuild without cache:"
echo "Run: docker-compose build health-api --no-cache"
echo ""
