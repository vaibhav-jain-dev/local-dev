#!/bin/bash
# Comprehensive fix script for health-api and dashboard issues

set -e

echo "=== Health API & Dashboard Fix Script ==="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "Step 1: Checking dependencies..."
command -v jq >/dev/null 2>&1 || { echo -e "${RED}✗ jq not installed${NC}"; echo "Install with: apt-get install jq"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo -e "${RED}✗ docker not installed${NC}"; exit 1; }
echo -e "${GREEN}✓ Dependencies OK${NC}"
echo ""

echo "Step 2: Checking required config files..."
if [ ! -f "configs/health_secrets.py" ]; then
    echo -e "${RED}✗ configs/health_secrets.py NOT FOUND${NC}"
    echo "This file is required for health-api to work"
    exit 1
fi
echo -e "${GREEN}✓ health_secrets.py exists${NC}"
echo ""

echo "Step 3: Checking cloned repository..."
if [ ! -d "cloned/health-api" ]; then
    echo -e "${YELLOW}⚠ health-api not cloned yet - run ./run.sh first${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Repository cloned${NC}"
echo ""

echo "Step 4: Verifying secrets.py was copied..."
if [ ! -f "cloned/health-api/app/app/secrets.py" ]; then
    echo -e "${RED}✗ secrets.py NOT copied to build directory${NC}"
    echo "Copying now..."
    mkdir -p cloned/health-api/app/app
    cp configs/health_secrets.py cloned/health-api/app/app/secrets.py
    echo -e "${GREEN}✓ secrets.py copied${NC}"
else
    echo -e "${GREEN}✓ secrets.py already in build directory${NC}"
fi
echo ""

echo "Step 5: Checking Dockerfile..."
if [ ! -f "cloned/health-api/dev.Dockerfile" ]; then
    echo -e "${YELLOW}⚠ Dockerfile not in place - copying...${NC}"
    cp repos_docker_files/health-api.dev.Dockerfile cloned/health-api/dev.Dockerfile
    echo -e "${GREEN}✓ Dockerfile copied${NC}"
else
    echo -e "${GREEN}✓ Dockerfile exists${NC}"
fi
echo ""

echo "Step 6: Getting current container status..."
if docker ps -a | grep -q health-api; then
    echo "Current container status:"
    docker ps -a | grep health-api
    echo ""
    echo "Getting last 30 lines of logs:"
    docker logs health-api 2>&1 | tail -30
    echo ""
else
    echo -e "${YELLOW}⚠ No health-api container found${NC}"
fi
echo ""

echo "Step 7: Rebuilding health-api without cache..."
echo "Stopping and removing old container..."
docker stop health-api 2>/dev/null || true
docker rm health-api 2>/dev/null || true

echo "Removing old image..."
docker rmi $(docker images | grep health-api | awk '{print $3}') 2>/dev/null || true

echo "Building fresh..."
cd cloned/health-api
if docker build -t health-api:latest -f dev.Dockerfile . 2>&1 | tee /tmp/health-api-build.log; then
    echo -e "${GREEN}✓ Build succeeded${NC}"
else
    echo -e "${RED}✗ Build failed - check /tmp/health-api-build.log${NC}"
    echo "Last 50 lines:"
    tail -50 /tmp/health-api-build.log
    exit 1
fi
cd - >/dev/null
echo ""

echo "Step 8: Checking dashboard requirements..."
if [ ! -f "dashboard/server.py" ]; then
    echo -e "${RED}✗ Dashboard not found${NC}"
    exit 1
fi

if [ ! -f "logs/progress.json" ]; then
    echo -e "${YELLOW}⚠ progress.json not found - dashboard won't show stages${NC}"
    echo "This file is created when you run ./run.sh"
else
    echo -e "${GREEN}✓ progress.json exists${NC}"
    echo "Current progress:"
    jq -r '.current_phase, .phases' logs/progress.json 2>/dev/null || echo "Invalid JSON"
fi
echo ""

echo "Step 9: Checking if dashboard is running..."
if pgrep -f "dashboard/server.py" >/dev/null; then
    echo -e "${GREEN}✓ Dashboard is running${NC}"
    echo "URL: http://localhost:9999"
else
    echo -e "${YELLOW}⚠ Dashboard not running${NC}"
    echo "Run ./run.sh to start it"
fi
echo ""

echo "=== Fix Complete ==="
echo ""
echo "Next steps:"
echo "  1. Run: ./run.sh"
echo "  2. Open: http://localhost:9999"
echo "  3. Check health-api: docker logs -f health-api"
