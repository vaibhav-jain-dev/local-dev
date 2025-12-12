#!/bin/bash
# Script to rebuild health-api with detailed logging

echo "=== Rebuilding Health API ===" 
echo ""

# Stop and remove existing container
echo "1. Stopping existing health-api container..."
docker stop health-api 2>/dev/null
docker rm health-api 2>/dev/null
echo "Done"
echo ""

# Remove old image to force rebuild
echo "2. Removing old health-api image..."
docker rmi $(docker images | grep health-api | awk '{print $3}') 2>/dev/null
echo "Done"
echo ""

# Navigate to cloned directory
if [ -d "cloned/health-api" ]; then
    cd cloned/health-api
    
    echo "3. Checking directory structure..."
    ls -la | head -20
    echo ""
    
    echo "4. Checking if app directory exists..."
    ls -la app/ 2>/dev/null || echo "WARNING: app/ directory not found!"
    echo ""
    
    echo "5. Checking if secrets.py was copied..."
    ls -la app/app/secrets.py 2>/dev/null || echo "WARNING: app/app/secrets.py not found!"
    echo ""
    
    echo "6. Checking if serviceAccountKey.json exists..."
    ls -la serviceAccountKey.json 2>/dev/null || echo "INFO: serviceAccountKey.json not found (not required)"
    echo ""
    
    echo "7. Rebuilding container..."
    docker-compose up -d --build health-api
    echo ""
    
    echo "8. Checking container status..."
    sleep 5
    docker ps | grep health-api || echo "Container not running!"
    echo ""
    
    echo "9. Showing logs..."
    docker logs health-api 2>&1 | tail -30
    
    cd - >/dev/null
else
    echo "ERROR: cloned/health-api directory not found!"
    echo "Please run ./run.sh first to clone and setup the repository"
fi

echo ""
echo "=== Rebuild Complete ==="
