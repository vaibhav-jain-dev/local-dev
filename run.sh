#!/bin/bash

# Don't exit on error - we handle errors explicitly
set +e

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

# Valid namespaces
VALID_NAMESPACES="s1 s2 s3 s4 s5 qa auto"
DEFAULT_NAMESPACE="s1"

# Global variables
NAMESPACE=""
SERVICES=""
ACTION=""
TARGET=""
REFRESH="false"

# ============================================
# Utility Functions
# ============================================

is_valid_namespace() {
    local ns=$1
    for valid in $VALID_NAMESPACES; do
        [ "$ns" = "$valid" ] && return 0
    done
    return 1
}

get_config_folder() {
    echo "configs/${NAMESPACE}"
}

get_dockerfile_path() {
    local service=$1
    # Check for namespace-specific dockerfile
    if [ -f "repos_docker_files/${NAMESPACE}/${service}.dev.Dockerfile" ]; then
        echo "repos_docker_files/${NAMESPACE}/${service}.dev.Dockerfile"
        return
    fi
    # Fall back to default dockerfile
    echo "repos_docker_files/${service}.dev.Dockerfile"
}

get_redis_port() {
    yq eval '.redis.port' $CONFIG_FILE 2>/dev/null || echo "6379"
}

get_redis_deployment() {
    yq eval '.redis.deployment' $CONFIG_FILE 2>/dev/null || echo "redis"
}

is_port_busy() {
    local port=$1
    lsof -Pi :${port} -sTCP:LISTEN -t >/dev/null 2>&1
}

# ============================================
# Redis Functions
# ============================================

start_redis_portforward() {
    local port=$(get_redis_port)
    local deployment=$(get_redis_deployment)

    # Skip if port already busy
    if is_port_busy "$port"; then
        echo -e "  ${GREEN}✓${NC} Redis port $port already in use - skipping"
        return 0
    fi

    echo -n "  Starting Redis port-forward (namespace: $NAMESPACE)..."
    kubectl port-forward -n "$NAMESPACE" "deployment/$deployment" "${port}:${port}" >/dev/null 2>&1 &
    sleep 2

    if is_port_busy "$port"; then
        echo -e " ${GREEN}✓${NC}"
        return 0
    else
        echo -e " ${YELLOW}⚠${NC}"
        echo -e "    Manual: kubectl port-forward -n $NAMESPACE deployment/$deployment $port:$port"
        return 1
    fi
}

stop_redis_portforward() {
    local deployment=$(get_redis_deployment)
    pkill -f "kubectl port-forward.*$deployment" 2>/dev/null || true
}

force_kill_redis_port() {
    local port=$(get_redis_port)
    echo -n "  Force closing Redis port $port..."

    # Kill any kubectl port-forward
    pkill -f "kubectl port-forward.*redis" 2>/dev/null || true

    # Kill any process on that port
    local pid=$(lsof -Pi :${port} -sTCP:LISTEN -t 2>/dev/null)
    if [ -n "$pid" ]; then
        kill -9 $pid 2>/dev/null || true
    fi

    sleep 1
    echo -e " ${GREEN}✓${NC}"
}

# ============================================
# Repository Functions
# ============================================

setup_repository() {
    local service=$1
    local repo=$(yq eval ".services.\"${service}\".git_repo" $CONFIG_FILE 2>/dev/null)
    local branch=$(yq eval ".services.\"${service}\".git_branch" $CONFIG_FILE 2>/dev/null)
    local always_refresh=$(yq eval ".services.\"${service}\".always-refresh" $CONFIG_FILE 2>/dev/null)
    local dir_name=$(basename "$repo" .git)

    # Determine if we should refresh this repo
    local should_refresh="$REFRESH"
    [ "$always_refresh" = "true" ] && should_refresh="true"

    echo -n "  Setting up $service..."

    # Clone if needed (with retry for parallel SSH contention)
    if [ ! -d "cloned/$dir_name/.git" ]; then
        local clone_success=false
        for attempt in 1 2 3; do
            if git clone -q "$repo" "cloned/$dir_name" 2>/dev/null; then
                clone_success=true
                break
            fi
            # Random backoff (1-3 seconds) to avoid SSH contention
            sleep $((RANDOM % 3 + 1))
            rm -rf "cloned/$dir_name" 2>/dev/null  # Clean up partial clone
        done
        if [ "$clone_success" = false ]; then
            echo -e " ${RED}✗ (clone failed)${NC}"
            return 1
        fi
        echo -n " (cloned)"
    fi

    # Handle branch checkout and refresh
    if cd "cloned/$dir_name" 2>/dev/null; then
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

        # Refresh: always discard local changes and pull latest
        if [ "$should_refresh" = "true" ]; then
            echo -n " (refreshing)"
            git reset --hard HEAD 2>/dev/null || true
            git clean -fd 2>/dev/null || true
            git fetch origin 2>/dev/null || true

            if [ "$current_branch" != "$branch" ]; then
                if git checkout "$branch" 2>/dev/null; then
                    git pull origin "$branch" 2>/dev/null || true
                else
                    git checkout -b "$branch" "origin/$branch" 2>/dev/null || {
                        echo -e " ${RED}✗ (branch failed)${NC}"
                        cd - >/dev/null 2>&1
                        return 1
                    }
                fi
            else
                git pull origin "$branch" 2>/dev/null || true
            fi
        # No refresh: only switch branch if different
        elif [ "$current_branch" != "$branch" ]; then
            echo -n " (switching branch)"
            git reset --hard HEAD 2>/dev/null || true
            git clean -fd 2>/dev/null || true
            git fetch origin 2>/dev/null || true

            if git checkout "$branch" 2>/dev/null; then
                git pull origin "$branch" 2>/dev/null || true
            else
                git checkout -b "$branch" "origin/$branch" 2>/dev/null || {
                    echo -e " ${RED}✗ (branch failed)${NC}"
                    cd - >/dev/null 2>&1
                    return 1
                }
            fi
        fi
        # If no refresh and same branch: do nothing (keep local changes)

        cd - >/dev/null 2>&1
    fi

    # Copy configs from namespace folder
    local config_folder=$(get_config_folder)
    local configs_count=$(yq eval ".services.\"${service}\".configs | length" $CONFIG_FILE 2>/dev/null || echo 0)

    for i in $(seq 0 $((configs_count - 1))); do
        local source=$(yq eval ".services.\"${service}\".configs[$i].source" $CONFIG_FILE 2>/dev/null)
        local dest=$(yq eval ".services.\"${service}\".configs[$i].dest" $CONFIG_FILE 2>/dev/null)
        local required=$(yq eval ".services.\"${service}\".configs[$i].required" $CONFIG_FILE 2>/dev/null)

        if [ -n "$source" ] && [ -n "$dest" ]; then
            local source_path="${source/configs\//$config_folder/}"

            if [ -f "$source_path" ]; then
                mkdir -p "cloned/$dir_name/$(dirname $dest)" 2>/dev/null
                cp "$source_path" "cloned/$dir_name/$dest" 2>/dev/null
            elif [ "$required" = "true" ]; then
                echo -e " ${YELLOW}⚠ Missing: $source_path${NC}"
            fi
        fi
    done

    # Copy Dockerfile
    local dockerfile_path=$(get_dockerfile_path "$service")
    if [ -f "$dockerfile_path" ]; then
        cp "$dockerfile_path" "cloned/$dir_name/dev.Dockerfile"
    else
        echo -e " ${RED}✗ No Dockerfile${NC}"
        return 1
    fi

    echo -e " ${GREEN}✓${NC}"
    return 0
}

# ============================================
# Docker Functions
# ============================================

generate_docker_compose() {
    local services_to_include="$1"

    cat > docker-compose.yml << 'COMPOSE'
services:
COMPOSE

    for service in $services_to_include; do
        local repo=$(yq eval ".services.\"${service}\".git_repo" $CONFIG_FILE 2>/dev/null)
        local port=$(yq eval ".services.\"${service}\".port" $CONFIG_FILE 2>/dev/null)
        local dir_name=$(basename "$repo" .git)

        [ ! -d "cloned/$dir_name" ] && continue
        [ ! -f "cloned/$dir_name/dev.Dockerfile" ] && continue

        cat >> docker-compose.yml << COMPOSE
  ${service}:
    build:
      context: ./cloned/${dir_name}
      dockerfile: dev.Dockerfile
    container_name: ${service}
    ports: ["${port}:${port}"]
COMPOSE

        if [[ "$service" == *"oms"* ]]; then
            cat >> docker-compose.yml << COMPOSE
    volumes:
      - ./cloned/${dir_name}:/go/src/github.com/Orange-Health/oms
    environment:
      CGO_ENABLED: 1
      GO111MODULE: on
COMPOSE
        else
            cat >> docker-compose.yml << COMPOSE
    volumes:
      - ./cloned/${dir_name}/app:/app
      - ./cloned/${dir_name}:/workspace
    environment:
      PYTHONDONTWRITEBYTECODE: 1
      PYTHONUNBUFFERED: 1
      DJANGO_SETTINGS_MODULE: app.secrets
COMPOSE
        fi

        cat >> docker-compose.yml << COMPOSE
    networks: [oh-network]
    platform: linux/amd64
    restart: unless-stopped
    stdin_open: true
    tty: true

COMPOSE
    done

    cat >> docker-compose.yml << 'COMPOSE'
networks:
  oh-network:
    driver: bridge
COMPOSE
}

cache_containers() {
    mkdir -p "$LOG_DIR"
    > "$CACHE_FILE"
    for service in $(yq eval '.services | keys | .[]' $CONFIG_FILE 2>/dev/null); do
        if [ "$(yq eval ".services.\"${service}\".enabled" $CONFIG_FILE 2>/dev/null)" = "true" ]; then
            echo "$service:$service" >> "$CACHE_FILE"
        fi
    done
}

# ============================================
# Parse Arguments
# ============================================

parse_args() {
    # First arg determines action
    case $1 in
        --run)
            ACTION="run"
            shift
            ;;
        --restart)
            ACTION="restart"
            shift
            ;;
        --stop)
            ACTION="stop"
            return
            ;;
        --clean)
            ACTION="clean"
            return
            ;;
        --logs)
            ACTION="logs"
            shift
            TARGET="$1"
            return
            ;;
        --stats)
            ACTION="stats"
            shift
            TARGET="$1"
            return
            ;;
        *)
            ACTION="run"
            ;;
    esac

    # Check for refresh flag (can be anywhere in args)
    local remaining_args=""
    for arg in "$@"; do
        if [ "$arg" = "refresh" ]; then
            REFRESH="true"
        else
            remaining_args="$remaining_args $arg"
        fi
    done
    set -- $remaining_args

    # Parse namespace and services
    # First positional arg might be namespace
    if [ -n "$1" ]; then
        if is_valid_namespace "$1"; then
            NAMESPACE="$1"
            shift
        fi
    fi

    # Default namespace if not set
    [ -z "$NAMESPACE" ] && NAMESPACE="$DEFAULT_NAMESPACE"

    # Rest are services
    SERVICES="$*"
}

# ============================================
# Action Handlers
# ============================================

do_stop() {
    echo -e "${YELLOW}⏹  Stopping services...${NC}"
    docker-compose down 2>/dev/null || true
    stop_redis_portforward
    rm -f "$CACHE_FILE"
    echo -e "${GREEN}✓ All services stopped${NC}"
}

do_clean() {
    echo -e "${YELLOW}🧹 Cleaning environment...${NC}"
    docker-compose down -v 2>/dev/null || true
    docker system prune -af 2>/dev/null || true
    rm -rf cloned docker-compose.yml logs/*
    stop_redis_portforward
    echo -e "${GREEN}✓ Environment cleaned${NC}"
}

do_logs() {
    if [ -n "$TARGET" ]; then
        echo -e "${CYAN}┌─── Logs: $TARGET ───┐${NC}"
        docker-compose logs --tail=100 -f $TARGET 2>/dev/null || docker logs --tail=100 -f $TARGET 2>&1
    else
        docker-compose logs -f --tail 100 2>&1
    fi
}

do_stats() {
    echo -e "${CYAN}┌─── Resource Usage ───┐${NC}"
    if [ -n "$TARGET" ]; then
        docker stats --no-stream $TARGET 2>/dev/null
    else
        docker stats --no-stream 2>/dev/null
    fi
}

do_restart() {
    echo -e "${YELLOW}🔄 Restarting services...${NC}"
    echo ""

    # Stop docker containers
    echo -e "${YELLOW}▶ Stopping Docker containers${NC}"
    docker-compose down 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Containers stopped"

    # Force kill redis port
    echo -e "\n${YELLOW}▶ Force reconnecting Redis${NC}"
    force_kill_redis_port

    # Now do regular run
    echo ""
    do_run
}

do_run() {
    local config_folder=$(get_config_folder)

    # Validate namespace folder exists
    if [ ! -d "$config_folder" ]; then
        echo -e "${RED}ERROR: Namespace folder not found: $config_folder${NC}"
        echo -e "Valid namespaces: $VALID_NAMESPACES"
        echo -e "Create the folder: mkdir -p $config_folder"
        exit 1
    fi

    # Determine services to run
    local services_to_run=""
    if [ -n "$SERVICES" ]; then
        # Validate each service exists in config
        for svc in $SERVICES; do
            if yq eval ".services.\"${svc}\"" $CONFIG_FILE >/dev/null 2>&1; then
                services_to_run="$services_to_run $svc"
            else
                echo -e "${RED}Service not found: $svc${NC}"
                exit 1
            fi
        done
    else
        # Get all enabled services
        for svc in $(yq eval '.services | keys | .[]' $CONFIG_FILE 2>/dev/null); do
            if [ "$(yq eval ".services.\"${svc}\".enabled" $CONFIG_FILE 2>/dev/null)" = "true" ]; then
                services_to_run="$services_to_run $svc"
            fi
        done
    fi

    services_to_run=$(echo $services_to_run | xargs)  # trim whitespace

    if [ -z "$services_to_run" ]; then
        echo -e "${RED}No services to run${NC}"
        exit 1
    fi

    echo -e "${BOLD}Namespace:${NC} $NAMESPACE"
    echo -e "${BOLD}Services:${NC} $services_to_run"
    [ "$REFRESH" = "true" ] && echo -e "${BOLD}Refresh:${NC} ${GREEN}yes${NC} (will pull latest code)"
    echo ""

    # ========== Phase 1: Repository Setup (parallel where possible) ==========
    echo -e "${YELLOW}▶ Phase 1: Repository Setup${NC}"

    local services_ready=""
    local pids=""

    # Setup repositories in parallel using background jobs
    for service in $services_to_run; do
        setup_repository "$service" &
        pids="$pids $!"
    done

    # Wait for all background jobs
    for pid in $pids; do
        wait $pid && services_ready="$services_ready ok"
    done

    # Re-run setup serially to get actual results (parallel was for speed)
    services_ready=""
    for service in $services_to_run; do
        local repo=$(yq eval ".services.\"${service}\".git_repo" $CONFIG_FILE 2>/dev/null)
        local dir_name=$(basename "$repo" .git)
        if [ -d "cloned/$dir_name" ] && [ -f "cloned/$dir_name/dev.Dockerfile" ]; then
            services_ready="$services_ready $service"
        fi
    done

    if [ -z "$services_ready" ]; then
        echo -e "${RED}No services ready${NC}"
        exit 1
    fi

    # ========== Phase 2: Docker Configuration ==========
    echo -e "\n${YELLOW}▶ Phase 2: Docker Configuration${NC}"

    generate_docker_compose "$services_ready"
    cache_containers
    echo -e "  ${GREEN}✓${NC} docker-compose.yml generated"

    # ========== Phase 3: Build (parallel) ==========
    echo -e "\n${YELLOW}▶ Phase 3: Building Containers${NC}"

    echo "  Building in parallel..."
    docker-compose build --parallel 2>&1 | grep -E "Successfully|ERROR|Building|Built" | tail -15
    echo -e "  ${GREEN}✓${NC} Build complete"

    # ========== Phase 4: Redis ==========
    echo -e "\n${YELLOW}▶ Phase 4: Redis Connection${NC}"
    start_redis_portforward

    # ========== Phase 5: Start Services ==========
    echo -e "\n${YELLOW}▶ Phase 5: Starting Containers${NC}"

    if [ -n "$SERVICES" ]; then
        docker-compose up -d $services_ready 2>&1 | grep -v "^$"
    else
        docker-compose up -d 2>&1 | grep -v "^$"
    fi

    echo -e "  ${GREEN}✓${NC} Containers started"
    sleep 2

    # ========== Final Status ==========
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         Service Status                ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    for service in $services_ready; do
        local port=$(yq eval ".services.\"${service}\".port" $CONFIG_FILE 2>/dev/null)

        if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${service}$"; then
            echo -e "${GREEN}✓${NC} ${BOLD}$service${NC}"
            echo -e "  └─ http://localhost:${port}"
        else
            echo -e "${RED}✗${NC} ${BOLD}$service${NC} - failed"
            docker logs --tail=3 $service 2>&1 | sed 's/^/    /'
        fi
    done

    echo ""
    echo -e "${CYAN}Commands:${NC}"
    echo -e "  make logs <service>  - View logs"
    echo -e "  make restart         - Restart all"
    echo -e "  make stop            - Stop all"
}

# ============================================
# Main
# ============================================

mkdir -p repos_docker_files configs cloned logs 2>/dev/null

parse_args "$@"

clear

echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  ${BOLD}Orange Health Local Development${NC}    ${CYAN}║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
echo ""

case $ACTION in
    stop)
        do_stop
        ;;
    clean)
        do_clean
        ;;
    logs)
        do_logs
        ;;
    stats)
        do_stats
        ;;
    restart)
        do_restart
        ;;
    run|*)
        do_run
        ;;
esac
