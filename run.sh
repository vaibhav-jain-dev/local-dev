#!/bin/bash

# Don't exit on error - we handle errors explicitly
set +e

# Error handler for critical errors only
handle_error() {
    echo -e "${RED}Error occurred in script at line $2 (exit code: $1)${NC}"
    # Don't exit automatically, let the script handle it
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# Configuration
CONFIG_FILE="repos_docker_files/config.yaml"
LOG_DIR="logs"
CACHE_FILE="logs/cache.txt"
ENV_TAG=""
SPECIFIC_SERVICE=""

# Parse environment and service from args
while [[ $# -gt 0 ]]; do
    case $1 in
        --tag=*)
            ENV_TAG="${1#*=}"
            shift
            ;;
        --tag|-tag|tag)
            shift
            ENV_TAG="$1"
            shift
            ;;
        --service)
            shift
            SPECIFIC_SERVICE="$1"
            shift
            ;;
        *)
            # Store other args to process later
            break
            ;;
    esac
done

# Functions
get_service_name() {
    # Keep original service name with hyphens (don't convert to snake_case)
    echo "$1"
}

get_container_name() {
    # Keep service name as-is for container (with hyphens)
    echo "$1"
}

get_config_folder() {
    if [ -n "$ENV_TAG" ]; then
        echo "configs/${ENV_TAG}"
    else
        echo "configs"
    fi
}

get_dockerfile_path() {
    local service=$1
    if [ -n "$ENV_TAG" ]; then
        # Check for tag-specific dockerfile
        if [ -f "repos_docker_files/${ENV_TAG}/${service}.dev.Dockerfile" ]; then
            echo "repos_docker_files/${ENV_TAG}/${service}.dev.Dockerfile"
            return
        fi
    fi
    # Fall back to default dockerfile
    echo "repos_docker_files/${service}.dev.Dockerfile"
}

get_redis_namespace() {
    if [ -n "$ENV_TAG" ]; then
        echo "$ENV_TAG"
    else
        echo "$(yq eval '.redis.namespace' $CONFIG_FILE 2>/dev/null || echo 's5')"
    fi
}

execute_cmd() {
    local cmd_path=$1
    local cmd=$(yq eval "$cmd_path" $CONFIG_FILE 2>/dev/null || echo "")
    
    if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then
        local namespace=$(get_redis_namespace)
        cmd=${cmd//\{namespace\}/$namespace}
        eval "$cmd" >/dev/null 2>&1
        return $?
    fi
    return 1
}

cache_containers() {
    mkdir -p "$LOG_DIR"
    > "$CACHE_FILE"
    
    for service in $(yq eval '.services | keys | .[]' $CONFIG_FILE 2>/dev/null); do
        if [ "$(yq eval ".services.\"${service}\".enabled" $CONFIG_FILE 2>/dev/null)" = "true" ]; then
            container_name=$(get_container_name "$service")
            echo "$service:$container_name" >> "$CACHE_FILE"
        fi
    done
}

get_cached_container() {
    local service=$1
    if [ -f "$CACHE_FILE" ]; then
        grep "^$service:" "$CACHE_FILE" 2>/dev/null | cut -d: -f2
    else
        get_container_name "$service"
    fi
}

setup_repository() {
    local service=$1
    local repo=$(yq eval ".services.\"${service}\".git_repo" $CONFIG_FILE 2>/dev/null)
    local branch=$(yq eval ".services.\"${service}\".git_branch" $CONFIG_FILE 2>/dev/null)
    local dir_name=$(basename "$repo" .git)
    
    echo -n "  Setting up $service..."
    
    # Clone if needed
    if [ ! -d "cloned/$dir_name/.git" ]; then
        git clone -q "$repo" "cloned/$dir_name" 2>/dev/null || {
            echo -e " ${RED}✗ (clone failed)${NC}"
            return 1
        }
    fi
    
    # Handle branch checkout with local changes cleanup
    if cd "cloned/$dir_name" 2>/dev/null; then
        # Get current branch
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        
        # If branch is different, discard local changes and switch
        if [ "$current_branch" != "$branch" ]; then
            echo -n " (switching branch: $current_branch → $branch)..."
            # Discard all local changes
            git reset --hard HEAD 2>/dev/null || true
            git clean -fd 2>/dev/null || true
            
            # Fetch latest
            git fetch origin 2>/dev/null || true
            
            # Checkout target branch
            if git checkout "$branch" 2>/dev/null; then
                git pull origin "$branch" 2>/dev/null || true
            else
                # Try to create branch from remote
                git checkout -b "$branch" "origin/$branch" 2>/dev/null || {
                    echo -e " ${RED}✗ (branch checkout failed)${NC}"
                    cd - >/dev/null 2>&1
                    return 1
                }
            fi
        else
            # Same branch, just pull
            git pull -q 2>/dev/null || true
        fi
        
        cd - >/dev/null 2>&1
    else
        echo -e " ${RED}✗ (directory access failed)${NC}"
        return 1
    fi
    
    # Copy configs from tag-specific folder
    local config_folder=$(get_config_folder)
    configs_count=$(yq eval ".services.\"${service}\".configs | length" $CONFIG_FILE 2>/dev/null || echo 0)
    
    if [ "$configs_count" -gt 0 ]; then
        for i in $(seq 0 $((configs_count - 1))); do
            source=$(yq eval ".services.\"${service}\".configs[$i].source" $CONFIG_FILE 2>/dev/null)
            dest=$(yq eval ".services.\"${service}\".configs[$i].dest" $CONFIG_FILE 2>/dev/null)
            required=$(yq eval ".services.\"${service}\".configs[$i].required" $CONFIG_FILE 2>/dev/null)
            
            if [ -n "$source" ] && [ -n "$dest" ]; then
                # Replace 'configs/' with actual config folder path
                source_path="${source/configs\//$config_folder/}"
                
                if [ -f "$source_path" ]; then
                    mkdir -p "cloned/$dir_name/$(dirname $dest)" 2>/dev/null
                    cp "$source_path" "cloned/$dir_name/$dest" 2>/dev/null
                elif [ "$required" = "true" ]; then
                    echo -e " ${YELLOW}⚠ Required config missing: $source_path${NC}"
                elif [[ "$dest" == *.json ]]; then
                    mkdir -p "cloned/$dir_name/$(dirname $dest)" 2>/dev/null
                    echo '{}' > "cloned/$dir_name/$dest"
                elif [[ "$dest" == *.yaml ]] || [[ "$dest" == *.yml ]]; then
                    mkdir -p "cloned/$dir_name/$(dirname $dest)" 2>/dev/null
                    echo '{}' > "cloned/$dir_name/$dest"
                fi
            fi
        done
    fi
    
    # Copy Dockerfile
    local dockerfile_path=$(get_dockerfile_path "$service")
    if [ -f "$dockerfile_path" ]; then
        cp "$dockerfile_path" "cloned/$dir_name/dev.Dockerfile"
    else
        echo -e " ${RED}✗ No Dockerfile found: $dockerfile_path${NC}"
        return 1
    fi
    
    echo -e " ${GREEN}✓${NC}"
    return 0
}

generate_docker_compose() {
    local services_to_include="$1"
    
    cat > docker-compose.yml << 'COMPOSE'
services:
COMPOSE

    for service in $services_to_include; do
        local repo=$(yq eval ".services.\"${service}\".git_repo" $CONFIG_FILE 2>/dev/null)
        local port=$(yq eval ".services.\"${service}\".port" $CONFIG_FILE 2>/dev/null)
        local container_name=$(get_container_name "$service")
        local dir_name=$(basename "$repo" .git)
        
        # Skip if directory doesn't exist
        [ ! -d "cloned/$dir_name" ] && continue
        
        # Skip if no Dockerfile
        [ ! -f "cloned/$dir_name/dev.Dockerfile" ] && continue
        
        cat >> docker-compose.yml << COMPOSE
  ${service}:
    build:
      context: ./cloned/${dir_name}
      dockerfile: dev.Dockerfile
    container_name: ${container_name}
    ports: ["${port}:${port}"]
COMPOSE

        # Volume mapping based on service type
        if [[ "$service" == *"oms"* ]]; then
            echo "    volumes:" >> docker-compose.yml
            echo "      - ./cloned/${dir_name}:/go/src/github.com/Orange-Health/oms" >> docker-compose.yml
            echo "    environment:" >> docker-compose.yml
            echo "      CGO_ENABLED: 1" >> docker-compose.yml
            echo "      GO111MODULE: on" >> docker-compose.yml
        else
            echo "    volumes:" >> docker-compose.yml
            echo "      - ./cloned/${dir_name}/app:/app" >> docker-compose.yml
            echo "      - ./cloned/${dir_name}:/workspace" >> docker-compose.yml
            echo "    environment:" >> docker-compose.yml
            echo "      PYTHONDONTWRITEBYTECODE: 1" >> docker-compose.yml
            echo "      PYTHONUNBUFFERED: 1" >> docker-compose.yml
            echo "      DJANGO_SETTINGS_MODULE: app.secrets" >> docker-compose.yml
        fi
        
        echo "    networks: [oh-network]" >> docker-compose.yml
        echo "    platform: linux/amd64" >> docker-compose.yml
        echo "    restart: unless-stopped" >> docker-compose.yml
        echo "    stdin_open: true" >> docker-compose.yml
        echo "    tty: true" >> docker-compose.yml
        echo "" >> docker-compose.yml
    done

    cat >> docker-compose.yml << 'COMPOSE'
networks:
  oh-network:
    driver: bridge
COMPOSE
}

# Parse arguments
ACTION="start"
TARGET=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --tag=*|-tag=*|tag=*)
            # Already handled above
            shift
            ;;
        --tag|--env|-tag|tag|--service)
            # Already handled above, skip both flag and value
            shift
            [ $# -gt 0 ] && shift
            ;;
        --stop)
            ACTION="stop"
            shift
            ;;
        --clean)
            ACTION="clean"
            shift
            ;;
        --logs|--tail)
            ACTION="logs"
            shift
            [ $# -gt 0 ] && TARGET="$1" && shift
            ;;
        --stats)
            ACTION="stats"
            shift
            [ $# -gt 0 ] && TARGET="$1" && shift
            ;;
        *)
            # If action is start and we have an argument, treat it as service name
            if [ "$ACTION" = "start" ] && [ -z "$SPECIFIC_SERVICE" ] && [ -n "$1" ]; then
                SPECIFIC_SERVICE="$1"
            fi
            shift
            ;;
    esac
done

clear

# Header
echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  ${BOLD}Orange Health Local Development${NC}    ${CYAN}║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
echo ""

# Show environment tag if set
[ -n "$ENV_TAG" ] && echo -e "${BOLD}Environment Tag:${NC} ${ENV_TAG}"

# Create directories
mkdir -p repos_docker_files configs cloned logs 2>/dev/null

# Create default config if missing
if [ ! -f "$CONFIG_FILE" ]; then
    cat << 'CONFIG' > $CONFIG_FILE
services:
  health-api:
    enabled: true
    git_repo: git@github.com:Orange-Health/health-api.git
    git_branch: s5-health-common-sep
    port: 8000
    configs:
      - source: configs/health_secrets.py
        dest: app/app/secrets.py
        required: true
      - source: configs/health_creds.json
        dest: serviceAccountKey.json
        required: false

  scheduler-api:
    enabled: true
    git_repo: git@github.com:Orange-Health/scheduler-api.git
    git_branch: s5-dev-common-sep
    port: 8010
    configs:
      - source: configs/scheduler_secrets.py
        dest: app/app/secrets.py
        required: true

  oms:
    enabled: true
    git_repo: git@github.com:Orange-Health/oms.git
    git_branch: s5-oms-common-sep
    port: 8080
    configs:
      - source: configs/oms.yaml
        dest: config/config.yaml
        required: true
      - source: configs/oauth-client.json
        dest: config/oauth-client.json
        required: false

redis:
  namespace: s5
  deployment: redis
  port: 6379
  start_cmd: |
    kubectl port-forward -n {namespace} deployment/redis 6379:6379 >/dev/null 2>&1 &
  stop_cmd: |
    pkill -f "kubectl port-forward.*redis" 2>/dev/null || true
CONFIG
fi

# Stop action
if [ "$ACTION" = "stop" ]; then
    echo "⏹  Stopping services..."
    docker-compose down 2>/dev/null || true
    execute_cmd ".redis.stop_cmd" || pkill -f "kubectl port-forward.*redis" 2>/dev/null || true
    rm -f "$CACHE_FILE"
    echo -e "${GREEN}✓ All services stopped${NC}"
    exit 0
fi

# Clean action
if [ "$ACTION" = "clean" ]; then
    echo "🧹 Cleaning environment..."
    docker-compose down -v 2>/dev/null || true
    docker system prune -af 2>/dev/null || true
    rm -rf cloned docker-compose.yml logs/*
    execute_cmd ".redis.stop_cmd" || pkill -f "kubectl port-forward.*redis" 2>/dev/null || true
    echo -e "${GREEN}✓ Environment cleaned${NC}"
    exit 0
fi

# Logs action
if [ "$ACTION" = "logs" ]; then
    if [ -n "$TARGET" ]; then
        container=$(get_cached_container "$TARGET")
        echo -e "${CYAN}┌─── Logs: $TARGET ───┐${NC}"
        # Try docker-compose logs first, then docker logs
        if docker-compose logs --tail=100 -f $TARGET 2>/dev/null; then
            :
        else
            docker logs --tail=100 -f $container 2>&1
        fi
    else
        docker-compose logs -f --tail 100 2>&1
    fi
    exit 0
fi

# Stats action  
if [ "$ACTION" = "stats" ]; then
    echo -e "${CYAN}┌─── Resource Usage ───┐${NC}"
    if [ -n "$TARGET" ]; then
        container=$(get_cached_container "$TARGET")
        docker stats --no-stream $container 2>/dev/null
    else
        docker stats --no-stream 2>/dev/null
    fi
    exit 0
fi

# START ACTION

# Get enabled services or specific service
ENABLED_SERVICES=""
if [ -n "$SPECIFIC_SERVICE" ]; then
    # Check if service exists in config
    if yq eval ".services.\"${SPECIFIC_SERVICE}\"" $CONFIG_FILE >/dev/null 2>&1; then
        ENABLED_SERVICES="$SPECIFIC_SERVICE"
        echo -e "${BOLD}Starting specific service:${NC} $SPECIFIC_SERVICE"
    else
        echo -e "${RED}Service '$SPECIFIC_SERVICE' not found in config${NC}"
        exit 1
    fi
else
    # Get all enabled services
    for service in $(yq eval '.services | keys | .[]' $CONFIG_FILE 2>/dev/null); do
        if [ "$(yq eval ".services.\"${service}\".enabled" $CONFIG_FILE 2>/dev/null)" = "true" ]; then
            ENABLED_SERVICES="$ENABLED_SERVICES $service"
        fi
    done
    echo -e "${BOLD}Enabled Services:${NC} $ENABLED_SERVICES"
fi

if [ -z "$ENABLED_SERVICES" ]; then
    echo -e "${RED}No services to start${NC}"
    exit 1
fi

echo ""

# Phase 1: Repository Setup
echo -e "${YELLOW}▶ Phase 1: Repository Setup${NC}"

SERVICES_READY=""
for service in $ENABLED_SERVICES; do
    if setup_repository "$service"; then
        SERVICES_READY="$SERVICES_READY $service"
    fi
done

if [ -z "$SERVICES_READY" ]; then
    echo -e "${RED}No services ready to start${NC}"
    exit 1
fi

# Phase 2: Docker Configuration
echo -e "\n${YELLOW}▶ Phase 2: Docker Configuration${NC}"

# Generate docker-compose.yml for ALL enabled services
# This ensures inter-service communication works
ALL_SERVICES=""
for service in $(yq eval '.services | keys | .[]' $CONFIG_FILE 2>/dev/null); do
    if [ "$(yq eval ".services.\"${service}\".enabled" $CONFIG_FILE 2>/dev/null)" = "true" ]; then
        repo=$(yq eval ".services.\"${service}\".git_repo" $CONFIG_FILE 2>/dev/null)
        dir_name=$(basename "$repo" .git)
        if [ -d "cloned/$dir_name" ] && [ -f "cloned/$dir_name/dev.Dockerfile" ]; then
            ALL_SERVICES="$ALL_SERVICES $service"
        fi
    fi
done

generate_docker_compose "$ALL_SERVICES"
cache_containers
echo -e "${GREEN}✓ Configuration ready${NC}"

# Add /etc/hosts entries for inter-service communication
echo ""
echo -e "${YELLOW}▶ Inter-Service Communication Setup${NC}"
echo "  Services can reach each other by name:"
for service in $ALL_SERVICES; do
    port=$(yq eval ".services.\"${service}\".port" $CONFIG_FILE 2>/dev/null)
    echo -e "    ${CYAN}http://${service}${NC} ${DIM}(inside Docker)${NC}"
    echo -e "    ${CYAN}http://localhost:${port}${NC} ${DIM}(from host)${NC}"
done
echo ""

# Phase 3: Build
echo -e "${YELLOW}▶ Phase 3: Building Containers${NC}"

if [ -n "$SPECIFIC_SERVICE" ]; then
    echo "  Building $SPECIFIC_SERVICE..."
    docker-compose build $SPECIFIC_SERVICE 2>&1 | grep -E "Successfully|ERROR|Step" | tail -10
else
    echo "  Building all services..."
    docker-compose build --parallel 2>&1 | grep -E "Successfully|ERROR|Step" | tail -10
fi

echo -e "${GREEN}✓ Build complete${NC}"

# Phase 4: Start Services
echo -e "\n${YELLOW}▶ Phase 4: Starting Services${NC}"

# Check and start Redis port-forward if configured
echo "  Checking Redis connection..."
if lsof -Pi :6379 -sTCP:LISTEN -t >/dev/null 2>&1; then
    # Port 6379 is in use, check what's using it
    redis_proc=$(lsof -Pi :6379 -sTCP:LISTEN 2>/dev/null | grep -v COMMAND | head -1)
    if echo "$redis_proc" | grep -q "kubectl"; then
        echo -e "  ${GREEN}✓${NC} Redis port-forward already running"
    else
        echo -e "  ${GREEN}✓${NC} Redis accessible on port 6379"
        echo -e "    Process: $(echo $redis_proc | awk '{print $1}')"
    fi
else
    # Port not in use, try to start port-forward
    echo "  Starting Redis port-forward..."
    if execute_cmd ".redis.start_cmd"; then
        sleep 2
        if lsof -Pi :6379 -sTCP:LISTEN -t >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} Redis port-forward started"
        else
            echo -e "  ${YELLOW}⚠${NC} Redis port-forward may have failed"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} Could not start Redis port-forward"
        echo -e "    You may need to run manually: kubectl port-forward -n $(get_redis_namespace) deployment/redis 6379:6379"
    fi
fi

# Start only the specific service or all services
echo ""
echo "  Starting Docker containers..."
if [ -n "$SPECIFIC_SERVICE" ]; then
    if docker-compose up -d $SPECIFIC_SERVICE 2>&1 | tee /tmp/docker-compose-output.log | grep -q "ERROR"; then
        echo -e "  ${RED}✗${NC} Failed to start $SPECIFIC_SERVICE"
        echo "  Error details:"
        cat /tmp/docker-compose-output.log | grep -A 5 "ERROR" | sed 's/^/    /'
        exit 1
    fi
else
    if docker-compose up -d 2>&1 | tee /tmp/docker-compose-output.log | grep -q "ERROR"; then
        echo -e "  ${RED}✗${NC} Failed to start services"
        echo "  Error details:"
        cat /tmp/docker-compose-output.log | grep -A 5 "ERROR" | sed 's/^/    /'
        exit 1
    fi
fi

echo -e "  ${GREEN}✓${NC} Containers started"

sleep 3

# Final Status
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         Service Status                ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
echo ""

for service in $ENABLED_SERVICES; do
    container=$(get_cached_container "$service")
    port=$(yq eval ".services.\"${service}\".port" $CONFIG_FILE 2>/dev/null)
    
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
        echo -e "${GREEN}✓${NC} ${BOLD}$service${NC}"
        echo -e "  └─ Inside Docker: ${CYAN}http://${service}:${port}${NC}"
        echo -e "  └─ From Host:     ${CYAN}http://localhost:${port}${NC}"
        
        # Show health check for specific services
        if [[ "$service" == *"oms"* ]]; then
            sleep 1
            if docker exec $container wget -q -O- http://localhost:${port}/health 2>/dev/null | grep -q "ok"; then
                echo -e "  └─ Health: ${GREEN}OK${NC}"
            else
                echo -e "  └─ Health: ${YELLOW}Starting...${NC}"
            fi
        fi
    else
        echo -e "${RED}✗${NC} ${BOLD}$service${NC} → Failed to start"
        echo "    Last logs:"
        docker logs --tail=5 $container 2>&1 | sed 's/^/    /'
    fi
    echo ""
done

echo -e "${CYAN}┌─────────────────────────────────────┐${NC}"
echo "Commands:"
echo -e "  ${CYAN}make logs $service${NC}     - View service logs"
echo -e "  ${CYAN}make start $service${NC}    - Start specific service"
echo -e "  ${CYAN}make stats${NC}             - Resource usage"
echo -e "  ${CYAN}make stop${NC}              - Stop all services"
if [ -n "$ENV_TAG" ]; then
    echo -e "  ${CYAN}make start --env $ENV_TAG${NC} - Use specific environment"
fi
echo -e "${CYAN}└─────────────────────────────────────┘${NC}"
