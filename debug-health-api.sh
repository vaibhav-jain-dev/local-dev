#!/bin/bash
# Debug script for health-api container issues

echo "=== Health API Debug Script ==="
echo ""

echo "1. Checking if health-api container exists..."
docker ps -a | grep health-api
echo ""

echo "2. Getting full container logs..."
docker logs health-api 2>&1 | tail -50
echo ""

echo "3. Checking container status..."
docker inspect health-api --format='{{.State.Status}}' 2>/dev/null
echo ""

echo "4. Checking exit code..."
docker inspect health-api --format='{{.State.ExitCode}}' 2>/dev/null
echo ""

echo "5. Checking if ports are available..."
netstat -tlnp | grep -E ':(8000|5678)' || echo "Ports 8000 and 5678 are available"
echo ""

echo "6. Checking if config files were copied..."
docker exec health-api ls -la /app/app/secrets.py 2>/dev/null || echo "Config file check failed"
docker exec health-api ls -la /serviceAccountKey.json 2>/dev/null || echo "Service account key check failed"
echo ""

echo "7. Trying to start container manually..."
docker start health-api
sleep 3
docker logs health-api 2>&1 | tail -20
echo ""

echo "=== Debug Complete ==="
