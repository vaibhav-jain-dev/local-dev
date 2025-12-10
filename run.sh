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
BRANCH_CACHE_FILE="logs/branch_cache.txt"
METRICS_FILE="logs/run_metrics.json"
MAX_METRICS_HISTORY=30

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

# Docker Compose command helper (uses v2 if available, fallback to v1)
docker_compose() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

# ============================================
# Branch Cache Functions
# ============================================

get_cached_branch() {
    local service=$1
    if [ -f "$BRANCH_CACHE_FILE" ]; then
        grep "^${service}:" "$BRANCH_CACHE_FILE" 2>/dev/null | cut -d: -f2
    fi
}

save_cached_branch() {
    local service=$1
    local branch=$2
    mkdir -p "$LOG_DIR"
    # Remove old entry if exists
    if [ -f "$BRANCH_CACHE_FILE" ]; then
        grep -v "^${service}:" "$BRANCH_CACHE_FILE" > "${BRANCH_CACHE_FILE}.tmp" 2>/dev/null || true
        mv "${BRANCH_CACHE_FILE}.tmp" "$BRANCH_CACHE_FILE"
    fi
    # Add new entry
    echo "${service}:${branch}" >> "$BRANCH_CACHE_FILE"
}

# Try to checkout a branch, returns 0 on success
try_checkout_branch() {
    local branch=$1
    local dir=$2

    cd "$dir" 2>/dev/null || return 1

    # Try local checkout first
    if git checkout "$branch" >/dev/null 2>&1; then
        cd - >/dev/null 2>&1
        return 0
    fi

    # Try creating from remote
    if git checkout -b "$branch" "origin/$branch" >/dev/null 2>&1; then
        cd - >/dev/null 2>&1
        return 0
    fi

    cd - >/dev/null 2>&1
    return 1
}

# ============================================
# Metrics & Timing Functions
# ============================================

# Initialize metrics file if needed
init_metrics() {
    if [ ! -f "$METRICS_FILE" ]; then
        echo '{"runs":[]}' > "$METRICS_FILE"
    fi
}

# Get current timestamp in milliseconds
now_ms() {
    echo $(($(date +%s%N)/1000000))
}

# Format duration from ms to human readable
format_duration() {
    local ms=$1
    if [ "$ms" -lt 1000 ]; then
        echo "${ms}ms"
    elif [ "$ms" -lt 60000 ]; then
        echo "$(echo "scale=1; $ms/1000" | bc)s"
    else
        local mins=$((ms/60000))
        local secs=$(((ms%60000)/1000))
        echo "${mins}m ${secs}s"
    fi
}

# Get average duration for a phase from last N runs
get_phase_avg() {
    local phase=$1
    if [ ! -f "$METRICS_FILE" ]; then
        echo "0"
        return
    fi
    # Get average of last MAX_METRICS_HISTORY runs for this phase
    local avg=$(jq -r "[.runs[-${MAX_METRICS_HISTORY}:][].phases.\"${phase}\" // empty] | if length > 0 then (add/length|floor) else 0 end" "$METRICS_FILE" 2>/dev/null)
    echo "${avg:-0}"
}

# Get average for a specific operation (e.g., clone:oms-api)
get_operation_avg() {
    local operation=$1
    if [ ! -f "$METRICS_FILE" ]; then
        echo "0"
        return
    fi
    local avg=$(jq -r "[.runs[-${MAX_METRICS_HISTORY}:][].operations.\"${operation}\" // empty] | if length > 0 then (add/length|floor) else 0 end" "$METRICS_FILE" 2>/dev/null)
    echo "${avg:-0}"
}

# Start timing for current run
declare -A PHASE_TIMERS
declare -A OPERATION_TIMERS
RUN_START_MS=0
CURRENT_RUN_PHASES="{}"
CURRENT_RUN_OPS="{}"

# Sanitize keys for associative arrays (replace spaces/colons with underscores)
sanitize_key() {
    echo "$1" | tr ' :' '__'
}

start_run_timer() {
    RUN_START_MS=$(now_ms)
    CURRENT_RUN_PHASES="{}"
    CURRENT_RUN_OPS="{}"
}

start_phase() {
    local phase="$1"
    local key=$(sanitize_key "$phase")
    PHASE_TIMERS["$key"]=$(now_ms)
    local avg=$(get_phase_avg "$phase")
    local eta=""
    if [ "$avg" -gt 0 ]; then
        eta=" ${DIM}(~$(format_duration $avg))${NC}"
    fi
    echo -e "\n${YELLOW}▶ ${phase}${NC}${eta}"
}

end_phase() {
    local phase="$1"
    local key=$(sanitize_key "$phase")
    local start="${PHASE_TIMERS["$key"]}"
    local end=$(now_ms)
    local duration=$((end - start))
    CURRENT_RUN_PHASES=$(echo "$CURRENT_RUN_PHASES" | jq --arg p "$phase" --argjson d "$duration" '. + {($p): $d}')
    echo -e "  ${DIM}└─ completed in $(format_duration $duration)${NC}"
}

start_operation() {
    local op="$1"
    local key=$(sanitize_key "$op")
    OPERATION_TIMERS["$key"]=$(now_ms)
}

end_operation() {
    local op="$1"
    local key=$(sanitize_key "$op")
    local start="${OPERATION_TIMERS["$key"]}"
    local end=$(now_ms)
    local duration=$((end - start))
    CURRENT_RUN_OPS=$(echo "$CURRENT_RUN_OPS" | jq --arg o "$op" --argjson d "$duration" '. + {($o): $d}')
}

# Save metrics for this run
save_run_metrics() {
    local end_ms=$(now_ms)
    local total_duration=$((end_ms - RUN_START_MS))
    local timestamp=$(date -Iseconds)

    # Create new run entry
    local new_run=$(jq -n \
        --arg ts "$timestamp" \
        --argjson total "$total_duration" \
        --argjson phases "$CURRENT_RUN_PHASES" \
        --argjson ops "$CURRENT_RUN_OPS" \
        '{timestamp: $ts, total: $total, phases: $phases, operations: $ops}')

    # Append to metrics file, keeping only last MAX_METRICS_HISTORY runs
    if [ -f "$METRICS_FILE" ]; then
        jq --argjson run "$new_run" --argjson max "$MAX_METRICS_HISTORY" \
            '.runs = (.runs + [$run])[-$max:]' "$METRICS_FILE" > "${METRICS_FILE}.tmp" \
            && mv "${METRICS_FILE}.tmp" "$METRICS_FILE"
    fi
}

# Show run summary with comparison to average
show_run_summary() {
    local end_ms=$(now_ms)
    local total=$((end_ms - RUN_START_MS))
    local avg_total=$(jq -r "[.runs[-${MAX_METRICS_HISTORY}:][].total // empty] | if length > 0 then (add/length|floor) else 0 end" "$METRICS_FILE" 2>/dev/null)

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         Run Complete                  ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo -e "  Total time: ${BOLD}$(format_duration $total)${NC}"
    if [ "${avg_total:-0}" -gt 0 ]; then
        local diff=$((total - avg_total))
        if [ "$diff" -gt 0 ]; then
            echo -e "  vs average: ${RED}+$(format_duration $diff) slower${NC}"
        else
            echo -e "  vs average: ${GREEN}$(format_duration ${diff#-}) faster${NC}"
        fi
    fi
}

# Log with timestamp
log() {
    local level=$1
    shift
    local msg="$*"
    local ts=$(date '+%H:%M:%S')
    case $level in
        info)  echo -e "  ${DIM}[$ts]${NC} $msg" ;;
        ok)    echo -e "  ${DIM}[$ts]${NC} ${GREEN}✓${NC} $msg" ;;
        warn)  echo -e "  ${DIM}[$ts]${NC} ${YELLOW}⚠${NC} $msg" ;;
        error) echo -e "  ${DIM}[$ts]${NC} ${RED}✗${NC} $msg" ;;
        step)  echo -e "  ${DIM}[$ts]${NC} ${CYAN}→${NC} $msg" ;;
    esac
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
    local repo_short=$(echo "$repo" | sed 's|.*github.com[:/]||')

    # Determine if we should refresh this repo
    local should_refresh="$REFRESH"
    [ "$always_refresh" = "true" ] && should_refresh="true"

    start_operation "setup:$service"

    echo -e "  ${BOLD}$service${NC} ${DIM}($repo_short → $branch)${NC}"

    # Clone if needed (with retry for parallel SSH contention)
    if [ ! -d "cloned/$dir_name/.git" ]; then
        local clone_avg=$(get_operation_avg "clone:$service")
        local eta_msg=""
        [ "$clone_avg" -gt 0 ] && eta_msg=" ${DIM}~$(format_duration $clone_avg)${NC}"
        echo -n "    ├─ cloning${eta_msg}..."

        start_operation "clone:$service"
        local clone_success=false
        local clone_error=""
        for attempt in 1 2 3; do
            clone_error=$(git clone "$repo" "cloned/$dir_name" 2>&1)
            if [ $? -eq 0 ]; then
                clone_success=true
                break
            fi
            [ $attempt -lt 3 ] && echo -n " retry $((attempt+1))..."
            sleep $((RANDOM % 3 + 1))
            rm -rf "cloned/$dir_name" 2>/dev/null
        done
        end_operation "clone:$service"

        if [ "$clone_success" = false ]; then
            echo -e " ${RED}✗ failed${NC}"
            echo -e "    │  ${DIM}$clone_error${NC}" | head -1
            return 1
        fi
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e "    ├─ repo exists ${GREEN}✓${NC}"
    fi

    # Handle branch checkout and refresh
    if cd "cloned/$dir_name" 2>/dev/null; then
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

        # Check for cached branch (overrides config if exists)
        local cached_branch=$(get_cached_branch "$service")
        local target_branch="$branch"
        if [ -n "$cached_branch" ]; then
            target_branch="$cached_branch"
        fi

        # Determine alternative branch (main <-> master fallback)
        local alt_branch=""
        if [ "$branch" = "master" ]; then
            alt_branch="main"
        elif [ "$branch" = "main" ]; then
            alt_branch="master"
        fi

        git fetch origin >/dev/null 2>&1 || true

        if [ "$should_refresh" = "true" ]; then
            echo -n "    ├─ pulling latest ($target_branch)..."
            git reset --hard HEAD >/dev/null 2>&1 || true
            git clean -fd >/dev/null 2>&1 || true

            if [ "$current_branch" != "$target_branch" ]; then
                if git checkout "$target_branch" >/dev/null 2>&1; then
                    git pull origin "$target_branch" >/dev/null 2>&1 || true
                    save_cached_branch "$service" "$target_branch"
                elif git checkout -b "$target_branch" "origin/$target_branch" >/dev/null 2>&1; then
                    save_cached_branch "$service" "$target_branch"
                elif [ -n "$alt_branch" ]; then
                    # Try alternative branch
                    echo -e " ${YELLOW}trying $alt_branch${NC}"
                    echo -n "    ├─ pulling latest ($alt_branch)..."
                    if git checkout "$alt_branch" >/dev/null 2>&1 || git checkout -b "$alt_branch" "origin/$alt_branch" >/dev/null 2>&1; then
                        git pull origin "$alt_branch" >/dev/null 2>&1 || true
                        save_cached_branch "$service" "$alt_branch"
                        target_branch="$alt_branch"
                    else
                        echo -e " ${RED}✗ branch not found${NC}"
                        cd - >/dev/null 2>&1
                        return 1
                    fi
                else
                    echo -e " ${RED}✗ branch not found${NC}"
                    cd - >/dev/null 2>&1
                    return 1
                fi
            else
                git pull origin "$target_branch" >/dev/null 2>&1 || true
            fi
            local commit=$(git rev-parse --short HEAD 2>/dev/null)
            echo -e " ${GREEN}✓${NC} ${DIM}@$commit${NC}"
        elif [ "$current_branch" != "$target_branch" ]; then
            echo -n "    ├─ switching to $target_branch..."
            git reset --hard HEAD >/dev/null 2>&1 || true
            git clean -fd >/dev/null 2>&1 || true

            if git checkout "$target_branch" >/dev/null 2>&1; then
                git pull origin "$target_branch" >/dev/null 2>&1 || true
                save_cached_branch "$service" "$target_branch"
            elif git checkout -b "$target_branch" "origin/$target_branch" >/dev/null 2>&1; then
                save_cached_branch "$service" "$target_branch"
            elif [ -n "$alt_branch" ]; then
                # Try alternative branch
                echo -e " ${YELLOW}trying $alt_branch${NC}"
                echo -n "    ├─ switching to $alt_branch..."
                if git checkout "$alt_branch" >/dev/null 2>&1 || git checkout -b "$alt_branch" "origin/$alt_branch" >/dev/null 2>&1; then
                    save_cached_branch "$service" "$alt_branch"
                    target_branch="$alt_branch"
                else
                    echo -e " ${RED}✗ branch not found${NC}"
                    cd - >/dev/null 2>&1
                    return 1
                fi
            else
                echo -e " ${RED}✗ branch not found${NC}"
                cd - >/dev/null 2>&1
                return 1
            fi
            echo -e " ${GREEN}✓${NC}"
        else
            local commit=$(git rev-parse --short HEAD 2>/dev/null)
            echo -e "    ├─ on $target_branch ${DIM}@$commit${NC} ${GREEN}✓${NC}"
        fi

        cd - >/dev/null 2>&1
    fi

    # Copy configs from namespace folder
    local config_folder=$(get_config_folder)
    local configs_count=$(yq eval ".services.\"${service}\".configs | length" $CONFIG_FILE 2>/dev/null || echo 0)
    local configs_copied=0

    for i in $(seq 0 $((configs_count - 1))); do
        local source=$(yq eval ".services.\"${service}\".configs[$i].source" $CONFIG_FILE 2>/dev/null)
        local dest=$(yq eval ".services.\"${service}\".configs[$i].dest" $CONFIG_FILE 2>/dev/null)
        local required=$(yq eval ".services.\"${service}\".configs[$i].required" $CONFIG_FILE 2>/dev/null)

        if [ -n "$source" ] && [ -n "$dest" ]; then
            local source_path="${source/configs\//$config_folder/}"

            if [ -f "$source_path" ]; then
                mkdir -p "cloned/$dir_name/$(dirname $dest)" 2>/dev/null
                cp "$source_path" "cloned/$dir_name/$dest" 2>/dev/null
                configs_copied=$((configs_copied + 1))
            elif [ "$required" = "true" ]; then
                echo -e "    ├─ ${YELLOW}⚠ missing config: $(basename $source_path)${NC}"
            fi
        fi
    done
    [ "$configs_copied" -gt 0 ] && echo -e "    ├─ copied $configs_copied config(s) ${GREEN}✓${NC}"

    # Copy Dockerfile
    local dockerfile_path=$(get_dockerfile_path "$service")
    if [ -f "$dockerfile_path" ]; then
        cp "$dockerfile_path" "cloned/$dir_name/dev.Dockerfile"
        echo -e "    └─ dockerfile ready ${GREEN}✓${NC}"
    else
        echo -e "    └─ ${RED}✗ no Dockerfile at $dockerfile_path${NC}"
        return 1
    fi

    end_operation "setup:$service"
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
        local service_type=$(yq eval ".services.\"${service}\".type" $CONFIG_FILE 2>/dev/null)
        local dir_name=$(basename "$repo" .git)

        [ ! -d "cloned/$dir_name" ] && continue
        [ ! -f "cloned/$dir_name/dev.Dockerfile" ] && continue

        # Handle different service types with appropriate build config
        if [ "$service_type" = "nextjs" ]; then
            # Next.js frontend service (e.g., bifrost)
            # Uses /usr/src/app as workdir and needs GITHUB_TOKEN for private packages
            cat >> docker-compose.yml << COMPOSE
  ${service}:
    build:
      context: ./cloned/${dir_name}
      dockerfile: dev.Dockerfile
      args:
        GITHUB_TOKEN: \${GITHUB_TOKEN:-}
    container_name: ${service}
    ports: ["${port}:${port}"]
    volumes:
      - ./cloned/${dir_name}:/usr/src/app
      - /usr/src/app/node_modules
      - /usr/src/app/.next
    environment:
      ENV: development
      NODE_ENV: development
      NEXT_TELEMETRY_DISABLED: 1
      WATCHPACK_POLLING: 'true'
COMPOSE
        elif [ "$service_type" = "nodejs" ]; then
            # Node.js frontend service (e.g., oms-web)
            cat >> docker-compose.yml << COMPOSE
  ${service}:
    build:
      context: ./cloned/${dir_name}
      dockerfile: dev.Dockerfile
    container_name: ${service}
    ports: ["${port}:${port}"]
    volumes:
      - ./cloned/${dir_name}:/app
      - /app/node_modules
    environment:
      NODE_ENV: development
      PORT: ${port}
COMPOSE
        elif [[ "$service" == "oms-api" ]]; then
            # Go OMS API service
            cat >> docker-compose.yml << COMPOSE
  ${service}:
    build:
      context: ./cloned/${dir_name}
      dockerfile: dev.Dockerfile
    container_name: ${service}
    ports: ["${port}:${port}"]
    volumes:
      - ./cloned/${dir_name}:/go/src/github.com/Orange-Health/oms
    environment:
      CGO_ENABLED: 1
      GO111MODULE: on
COMPOSE
        else
            # Python/Django services (default)
            cat >> docker-compose.yml << COMPOSE
  ${service}:
    build:
      context: ./cloned/${dir_name}
      dockerfile: dev.Dockerfile
    container_name: ${service}
    ports: ["${port}:${port}"]
    volumes:
      - ./cloned/${dir_name}/app:/app
      - ./cloned/${dir_name}:/workspace
    environment:
      PYTHONDONTWRITEBYTECODE: 1
      PYTHONUNBUFFERED: 1
      DJANGO_SETTINGS_MODULE: app.secrets
COMPOSE
        fi

        # Add common service settings
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
    docker_compose down 2>/dev/null || true
    stop_redis_portforward
    rm -f "$CACHE_FILE"
    echo -e "${GREEN}✓ All services stopped${NC}"
}

do_clean() {
    echo -e "${YELLOW}🧹 Cleaning environment...${NC}"
    docker_compose down -v 2>/dev/null || true
    docker system prune -af 2>/dev/null || true
    rm -rf cloned docker-compose.yml logs/*
    stop_redis_portforward
    echo -e "${GREEN}✓ Environment cleaned${NC}"
}

do_logs() {
    if [ -n "$TARGET" ]; then
        echo -e "${CYAN}┌─── Logs: $TARGET ───┐${NC}"
        docker_compose logs --tail=100 -f $TARGET 2>/dev/null || docker logs --tail=100 -f $TARGET 2>&1
    else
        docker_compose logs -f --tail 100 2>&1
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
    docker_compose down 2>/dev/null || true
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

    # Initialize metrics tracking
    init_metrics
    start_run_timer

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
    local service_count=$(echo $services_to_run | wc -w | xargs)

    if [ -z "$services_to_run" ]; then
        echo -e "${RED}No services to run${NC}"
        exit 1
    fi

    # Show total ETA if we have history
    local total_avg=$(jq -r "[.runs[-${MAX_METRICS_HISTORY}:][].total // empty] | if length > 0 then (add/length|floor) else 0 end" "$METRICS_FILE" 2>/dev/null)
    local eta_line=""
    [ "${total_avg:-0}" -gt 0 ] && eta_line=" ${DIM}(estimated ~$(format_duration $total_avg))${NC}"

    echo -e "${BOLD}Namespace:${NC} $NAMESPACE"
    echo -e "${BOLD}Services:${NC} $service_count services${eta_line}"
    [ "$REFRESH" = "true" ] && echo -e "${BOLD}Refresh:${NC} ${GREEN}yes${NC} (will pull latest code)"

    # ========== Phase 1: Repository Setup (Parallel) ==========
    start_phase "Phase 1: Repository Setup"

    local services_ready=""
    local failed_services=""

    # Create temp directory for parallel job results
    local parallel_tmp=$(mktemp -d)
    local pids=""

    echo -e "  ${DIM}Setting up $service_count repositories in parallel...${NC}"

    # Launch all repository setups in parallel
    for service in $services_to_run; do
        (
            if setup_repository "$service" > "${parallel_tmp}/${service}.log" 2>&1; then
                echo "success" > "${parallel_tmp}/${service}.status"
            else
                echo "failed" > "${parallel_tmp}/${service}.status"
            fi
        ) &
        pids="$pids $!"
    done

    # Wait for all parallel jobs to complete
    for pid in $pids; do
        wait $pid 2>/dev/null || true
    done

    # Collect results and display output
    for service in $services_to_run; do
        # Show the captured output
        if [ -f "${parallel_tmp}/${service}.log" ]; then
            cat "${parallel_tmp}/${service}.log"
        fi

        # Check status
        if [ -f "${parallel_tmp}/${service}.status" ]; then
            local status=$(cat "${parallel_tmp}/${service}.status")
            if [ "$status" = "success" ]; then
                services_ready="$services_ready $service"
            else
                failed_services="$failed_services $service"
            fi
        else
            failed_services="$failed_services $service"
        fi
    done

    # Cleanup temp directory
    rm -rf "$parallel_tmp"

    services_ready=$(echo $services_ready | xargs)

    if [ -z "$services_ready" ]; then
        echo -e "  ${RED}No services ready to run${NC}"
        exit 1
    fi

    if [ -n "$failed_services" ]; then
        echo -e "  ${YELLOW}⚠ Some services failed:${NC}$failed_services"
    fi

    end_phase "Phase 1: Repository Setup"

    # ========== Phase 2: Docker Configuration ==========
    start_phase "Phase 2: Docker Configuration"

    echo -n "  Generating docker-compose.yml..."
    generate_docker_compose "$services_ready"
    cache_containers
    echo -e " ${GREEN}✓${NC}"

    end_phase "Phase 2: Docker Configuration"

    # ========== Phase 3: Build (parallel with BuildKit) ==========
    start_phase "Phase 3: Building Containers"

    echo -e "  ${DIM}Building $service_count container(s) in parallel...${NC}"

    # Enable BuildKit for true parallel builds
    export COMPOSE_DOCKER_CLI_BUILD=1
    export DOCKER_BUILDKIT=1

    # Capture build output with better formatting
    local build_start=$(now_ms)
    # BuildKit handles parallelism automatically, --parallel is for docker-compose v1 compatibility
    local build_output=$(docker_compose build --parallel 2>&1)
    local build_status=$?
    local build_end=$(now_ms)
    local build_duration=$((build_end - build_start))

    # Show relevant build output
    echo "$build_output" | while IFS= read -r line; do
        if echo "$line" | grep -qE "Building|Step|Successfully built|ERROR|error:"; then
            # Extract service name from "Building <service>"
            if echo "$line" | grep -q "Building "; then
                local svc=$(echo "$line" | sed 's/Building //' | awk '{print $1}')
                echo -e "  ${CYAN}→${NC} Building ${BOLD}$svc${NC}..."
            elif echo "$line" | grep -q "Successfully built"; then
                echo -e "    ${GREEN}✓${NC} image ready"
            elif echo "$line" | grep -qiE "ERROR|error:"; then
                echo -e "    ${RED}$line${NC}"
            fi
        fi
    done

    if [ $build_status -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} All containers built ${DIM}($(format_duration $build_duration))${NC}"
    else
        echo -e "  ${RED}✗ Build failed${NC}"
    fi

    end_phase "Phase 3: Building Containers"

    # ========== Phase 4 & 5: Redis + Start Containers (Parallel) ==========
    start_phase "Phase 4: Redis + Starting Containers"

    # Start Redis port-forward in background
    start_redis_portforward &
    local redis_pid=$!

    # Start all containers at once (faster than one-by-one)
    echo -e "  ${DIM}Starting all containers in parallel...${NC}"
    local up_output=$(docker_compose up -d 2>&1)
    local up_status=$?

    # Wait for Redis setup to complete
    wait $redis_pid 2>/dev/null || true

    if [ $up_status -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} All containers started"
    else
        echo -e "  ${YELLOW}⚠${NC} Some containers may have failed"
        echo "$up_output" | grep -i error | head -3 | sed 's/^/    /'
    fi

    sleep 2
    end_phase "Phase 4: Redis + Starting Containers"

    # Save metrics for this run
    save_run_metrics

    # ========== Final Status ==========
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         Service Status                ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    local running_count=0
    local failed_count=0

    for service in $services_ready; do
        local port=$(yq eval ".services.\"${service}\".port" $CONFIG_FILE 2>/dev/null)

        if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${service}$"; then
            echo -e "${GREEN}✓${NC} ${BOLD}$service${NC}"
            echo -e "  └─ http://localhost:${port}"
            running_count=$((running_count + 1))
        else
            echo -e "${RED}✗${NC} ${BOLD}$service${NC} - failed"
            docker logs --tail=3 $service 2>&1 | sed 's/^/    /'
            failed_count=$((failed_count + 1))
        fi
    done

    # Show run summary
    show_run_summary
    echo -e "  Services: ${GREEN}$running_count running${NC}"
    [ $failed_count -gt 0 ] && echo -e "  Failed: ${RED}$failed_count${NC}"

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
