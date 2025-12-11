#!/bin/bash

# Don't exit on error - we handle errors explicitly
set +e

# Cleanup trap for temp files
cleanup_on_exit() {
    [ -n "$TIMERS_DIR" ] && [ -d "$TIMERS_DIR" ] && rm -rf "$TIMERS_DIR" 2>/dev/null
}
trap cleanup_on_exit EXIT

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
INCLUDE_APP="false"

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
    yq -r '.redis.port' $CONFIG_FILE 2>/dev/null || echo "6379"
}

get_redis_deployment() {
    yq -r '.redis.deployment' $CONFIG_FILE 2>/dev/null || echo "redis"
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
# Note: Using temp files instead of associative arrays for bash 3.x compatibility
TIMERS_DIR=""
RUN_START_MS=0
CURRENT_RUN_PHASES="{}"
CURRENT_RUN_OPS="{}"

# Initialize timers directory (for bash 3.x compatibility - no associative arrays)
init_timers_dir() {
    TIMERS_DIR=$(mktemp -d)
    mkdir -p "$TIMERS_DIR/phases" "$TIMERS_DIR/operations"
    export TIMERS_DIR  # Export for subshells
}

# Cleanup timers directory
cleanup_timers_dir() {
    [ -n "$TIMERS_DIR" ] && [ -d "$TIMERS_DIR" ] && rm -rf "$TIMERS_DIR"
}

# Sanitize keys (replace spaces/colons with underscores)
sanitize_key() {
    echo "$1" | tr ' :' '__'
}

# Store timer value (bash 3.x compatible)
set_timer() {
    local type=$1  # "phases" or "operations"
    local key=$2
    local value=$3
    echo "$value" > "$TIMERS_DIR/$type/$key"
}

# Get timer value (bash 3.x compatible)
get_timer() {
    local type=$1  # "phases" or "operations"
    local key=$2
    if [ -f "$TIMERS_DIR/$type/$key" ]; then
        cat "$TIMERS_DIR/$type/$key"
    else
        echo "0"
    fi
}

start_run_timer() {
    init_timers_dir
    RUN_START_MS=$(now_ms)
    CURRENT_RUN_PHASES="{}"
    CURRENT_RUN_OPS="{}"
}

start_phase() {
    local phase="$1"
    local key=$(sanitize_key "$phase")
    set_timer "phases" "$key" "$(now_ms)"
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
    local start=$(get_timer "phases" "$key")
    local end=$(now_ms)
    local duration=$((end - start))
    CURRENT_RUN_PHASES=$(echo "$CURRENT_RUN_PHASES" | jq --arg p "$phase" --argjson d "$duration" '. + {($p): $d}')
    echo -e "  ${DIM}└─ completed in $(format_duration $duration)${NC}"
}

start_operation() {
    local op="$1"
    local key=$(sanitize_key "$op")
    set_timer "operations" "$key" "$(now_ms)"
}

end_operation() {
    local op="$1"
    local key=$(sanitize_key "$op")
    local start=$(get_timer "operations" "$key")
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

    # Cleanup timers directory
    cleanup_timers_dir
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
    local repo=$(yq -r ".services.\"${service}\".git_repo" $CONFIG_FILE 2>/dev/null)
    local branch=$(yq -r ".services.\"${service}\".git_branch" $CONFIG_FILE 2>/dev/null)
    local always_refresh=$(yq -r ".services.\"${service}\".always-refresh" $CONFIG_FILE 2>/dev/null)

    # Handle yq returning "null" for missing values
    [ "$repo" = "null" ] || [ -z "$repo" ] && { echo -e "    ${RED}✗ No git_repo configured for $service${NC}"; return 1; }
    [ "$branch" = "null" ] && branch="main"

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
    local configs_count=$(yq -r ".services.\"${service}\".configs | length" $CONFIG_FILE 2>/dev/null || echo 0)
    local configs_copied=0

    for i in $(seq 0 $((configs_count - 1))); do
        local source=$(yq -r ".services.\"${service}\".configs[$i].source" $CONFIG_FILE 2>/dev/null)
        local dest=$(yq -r ".services.\"${service}\".configs[$i].dest" $CONFIG_FILE 2>/dev/null)
        local required=$(yq -r ".services.\"${service}\".configs[$i].required" $CONFIG_FILE 2>/dev/null)

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

# Setup emulator app (clone and prepare for script execution)
setup_emulator() {
    local emulator=$1
    local repo=$(yq -r ".emulators.\"${emulator}\".git_repo" $CONFIG_FILE 2>/dev/null)
    local branch=$(yq -r ".emulators.\"${emulator}\".git_branch" $CONFIG_FILE 2>/dev/null)
    local script=$(yq -r ".emulators.\"${emulator}\".script" $CONFIG_FILE 2>/dev/null)

    [ "$repo" = "null" ] || [ -z "$repo" ] && { echo -e "    ${RED}✗ No git_repo configured for $emulator${NC}"; return 1; }
    [ "$branch" = "null" ] && branch="main"
    [ "$script" = "null" ] && script="run-android-emulator.sh"

    local dir_name=$(basename "$repo" .git)
    local repo_short=$(echo "$repo" | sed 's|.*github.com[:/]||')

    start_operation "setup:$emulator"

    echo -e "  ${BOLD}$emulator${NC} ${DIM}($repo_short → $branch)${NC} ${MAGENTA}[emulator]${NC}"

    # Clone if needed
    if [ ! -d "cloned/$dir_name/.git" ]; then
        echo -n "    ├─ cloning..."
        start_operation "clone:$emulator"
        local clone_success=false
        for attempt in 1 2 3; do
            if git clone "$repo" "cloned/$dir_name" >/dev/null 2>&1; then
                clone_success=true
                break
            fi
            [ $attempt -lt 3 ] && echo -n " retry $((attempt+1))..."
            sleep $((RANDOM % 3 + 1))
            rm -rf "cloned/$dir_name" 2>/dev/null
        done
        end_operation "clone:$emulator"

        if [ "$clone_success" = false ]; then
            echo -e " ${RED}✗ failed${NC}"
            return 1
        fi
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e "    ├─ repo exists ${GREEN}✓${NC}"
    fi

    # Handle branch checkout
    if cd "cloned/$dir_name" 2>/dev/null; then
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        git fetch origin >/dev/null 2>&1 || true

        if [ "$current_branch" != "$branch" ]; then
            echo -n "    ├─ switching to $branch..."
            git reset --hard HEAD >/dev/null 2>&1 || true
            git clean -fd >/dev/null 2>&1 || true

            if git checkout "$branch" >/dev/null 2>&1 || git checkout -b "$branch" "origin/$branch" >/dev/null 2>&1; then
                echo -e " ${GREEN}✓${NC}"
            else
                echo -e " ${RED}✗ branch not found${NC}"
                cd - >/dev/null 2>&1
                return 1
            fi
        else
            local commit=$(git rev-parse --short HEAD 2>/dev/null)
            echo -e "    ├─ on $branch ${DIM}@$commit${NC} ${GREEN}✓${NC}"
        fi
        cd - >/dev/null 2>&1
    fi

    # Check script exists
    if [ -f "cloned/$dir_name/$script" ]; then
        chmod +x "cloned/$dir_name/$script"
        echo -e "    └─ script ready: $script ${GREEN}✓${NC}"
    else
        echo -e "    └─ ${RED}✗ script not found: $script${NC}"
        return 1
    fi

    end_operation "setup:$emulator"
    return 0
}

# Setup worker (uses parent repo, different Dockerfile)
setup_worker() {
    local worker=$1
    local parent=$2
    local dockerfile=$3

    # Get parent repo info
    local parent_repo=$(yq -r ".services.\"${parent}\".git_repo" $CONFIG_FILE 2>/dev/null)
    local dir_name=$(basename "$parent_repo" .git)

    start_operation "setup:$worker"

    echo -e "  ${BOLD}$worker${NC} ${DIM}(uses $parent repo)${NC} ${BLUE}[worker]${NC}"

    # Check parent repo exists
    if [ ! -d "cloned/$dir_name/.git" ]; then
        echo -e "    └─ ${RED}✗ parent repo not cloned (run $parent first)${NC}"
        end_operation "setup:$worker"
        return 1
    fi
    echo -e "    ├─ parent repo exists ${GREEN}✓${NC}"

    # Copy worker Dockerfile from repos_docker_files
    local dockerfile_path="repos_docker_files/${dockerfile}"
    if [ -f "$dockerfile_path" ]; then
        cp "$dockerfile_path" "cloned/$dir_name/${dockerfile}"
        echo -e "    └─ dockerfile ready: $dockerfile ${GREEN}✓${NC}"
    else
        echo -e "    └─ ${RED}✗ no Dockerfile at $dockerfile_path${NC}"
        end_operation "setup:$worker"
        return 1
    fi

    end_operation "setup:$worker"
    return 0
}

# ============================================
# Docker Functions
# ============================================

generate_docker_compose() {
    local services_to_include="$1"
    local workers_to_include="$2"
    local skipped_services=""

    cat > docker-compose.yml << 'COMPOSE'
services:
COMPOSE

    for service in $services_to_include; do
        local repo=$(yq -r ".services.\"${service}\".git_repo" $CONFIG_FILE 2>/dev/null)
        local port=$(yq -r ".services.\"${service}\".port" $CONFIG_FILE 2>/dev/null)
        local service_type=$(yq -r ".services.\"${service}\".type" $CONFIG_FILE 2>/dev/null)
        local dir_name=$(basename "$repo" .git)

        # Check for missing directory or dockerfile with clear error messages
        if [ ! -d "cloned/$dir_name" ]; then
            echo -e "  ${YELLOW}⚠ Skipping $service: cloned/$dir_name directory not found${NC}"
            skipped_services="$skipped_services $service"
            continue
        fi
        if [ ! -f "cloned/$dir_name/dev.Dockerfile" ]; then
            echo -e "  ${YELLOW}⚠ Skipping $service: cloned/$dir_name/dev.Dockerfile not found${NC}"
            skipped_services="$skipped_services $service"
            continue
        fi

        # Handle different service types - build section varies by type
        if [ "$service_type" = "nextjs" ]; then
            # Next.js frontend service (e.g., bifrost) - needs GitHub npm token for @orange-health packages
            cat >> docker-compose.yml << COMPOSE
  ${service}:
    build:
      context: ./cloned/${dir_name}
      dockerfile: dev.Dockerfile
      args:
        GITHUB_NPM_TOKEN: \${GITHUB_NPM_TOKEN:-}
    container_name: ${service}
    ports: ["${port}:${port}"]
    volumes:
      - ./cloned/${dir_name}:/app
      - /app/node_modules
      - /app/.next
    environment:
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
      args:
        GITHUB_NPM_TOKEN: \${GITHUB_NPM_TOKEN:-}
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
      args:
        GITHUB_TOKEN: \${GITHUB_TOKEN:-}
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

        cat >> docker-compose.yml << COMPOSE
    networks: [oh-network]
    platform: linux/amd64
    restart: unless-stopped
    stdin_open: true
    tty: true

COMPOSE
    done

    # Add workers to docker-compose (format: "worker:parent:dockerfile")
    for worker_entry in $workers_to_include; do
        local worker=$(echo "$worker_entry" | cut -d: -f1)
        local parent=$(echo "$worker_entry" | cut -d: -f2)
        local dockerfile=$(echo "$worker_entry" | cut -d: -f3)
        local parent_repo=$(yq -r ".services.\"${parent}\".git_repo" $CONFIG_FILE 2>/dev/null)
        local dir_name=$(basename "$parent_repo" .git)

        # Check for missing dockerfile
        if [ ! -f "cloned/$dir_name/${dockerfile}" ]; then
            echo -e "  ${YELLOW}⚠ Skipping $worker: cloned/$dir_name/${dockerfile} not found${NC}"
            continue
        fi

        # Workers use Go OMS style (no ports exposed)
        cat >> docker-compose.yml << COMPOSE
  ${worker}:
    build:
      context: ./cloned/${dir_name}
      dockerfile: ${dockerfile}
    container_name: ${worker}
    volumes:
      - ./cloned/${dir_name}:/go/src/github.com/Orange-Health/oms
    environment:
      CGO_ENABLED: 1
      GO111MODULE: on
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
    for service in $(yq -r '.services | keys | .[]' $CONFIG_FILE 2>/dev/null); do
        if [ "$(yq -r ".services.\"${service}\".enabled" $CONFIG_FILE 2>/dev/null)" = "true" ]; then
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

    # Check for refresh and --include-app flags (can be anywhere in args)
    local remaining_args=""
    for arg in "$@"; do
        if [ "$arg" = "refresh" ]; then
            REFRESH="true"
        elif [ "$arg" = "--include-app" ]; then
            INCLUDE_APP="true"
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
        # Validate each service exists in config (check services or emulators)
        for svc in $SERVICES; do
            if yq -r ".services.\"${svc}\"" $CONFIG_FILE 2>/dev/null | grep -qv "null"; then
                services_to_run="$services_to_run $svc"
            elif yq -r ".emulators.\"${svc}\"" $CONFIG_FILE 2>/dev/null | grep -qv "null"; then
                # Emulator specified directly - will be handled below
                services_to_run="$services_to_run $svc"
            else
                echo -e "${RED}Service not found: $svc${NC}"
                exit 1
            fi
        done
    else
        # Get all enabled services
        for svc in $(yq -r '.services | keys | .[]' $CONFIG_FILE 2>/dev/null); do
            if [ "$(yq -r ".services.\"${svc}\".enabled" $CONFIG_FILE 2>/dev/null)" = "true" ]; then
                services_to_run="$services_to_run $svc"
            fi
        done
    fi

    services_to_run=$(echo $services_to_run | xargs)  # trim whitespace

    # Determine workers to run (workers defined under each service's workers map)
    # Format: "worker:parent:dockerfile" to track which service owns the worker and its dockerfile
    local workers_to_run=""
    for service in $services_to_run; do
        local workers_keys=$(yq -r ".services.\"${service}\".workers | keys | .[]" $CONFIG_FILE 2>/dev/null)
        if [ -n "$workers_keys" ] && [ "$workers_keys" != "null" ]; then
            for worker in $workers_keys; do
                local dockerfile=$(yq -r ".services.\"${service}\".workers.\"${worker}\".dockerfile" $CONFIG_FILE 2>/dev/null)
                if [ -n "$worker" ] && [ "$worker" != "null" ]; then
                    workers_to_run="$workers_to_run ${worker}:${service}:${dockerfile}"
                fi
            done
        fi
    done
    workers_to_run=$(echo $workers_to_run | xargs)

    # Determine emulators to run (only if --include-app flag is passed)
    local emulators_to_run=""
    if [ "$INCLUDE_APP" = "true" ]; then
        for emu in $(yq -r '.emulators | keys | .[]' $CONFIG_FILE 2>/dev/null); do
            emulators_to_run="$emulators_to_run $emu"
            # Remove emulator from services_to_run if it was explicitly requested
            services_to_run=$(echo "$services_to_run" | sed "s/\b$emu\b//g" | xargs)
        done
    else
        # Check if any emulator was explicitly requested
        for emu in $(yq -r '.emulators | keys | .[]' $CONFIG_FILE 2>/dev/null); do
            if echo "$services_to_run" | grep -qw "$emu"; then
                emulators_to_run="$emulators_to_run $emu"
                services_to_run=$(echo "$services_to_run" | sed "s/\b$emu\b//g" | xargs)
            fi
        done
    fi
    emulators_to_run=$(echo $emulators_to_run | xargs)

    local service_count=$(echo $services_to_run | wc -w | xargs)
    # Count workers (format is "worker:parent", so count entries)
    local worker_count=0
    [ -n "$workers_to_run" ] && worker_count=$(echo $workers_to_run | wc -w | xargs)
    local emulator_count=$(echo $emulators_to_run | wc -w | xargs)

    if [ -z "$services_to_run" ] && [ -z "$workers_to_run" ] && [ -z "$emulators_to_run" ]; then
        echo -e "${RED}No services to run${NC}"
        exit 1
    fi

    # Show total ETA if we have history
    local total_avg=$(jq -r "[.runs[-${MAX_METRICS_HISTORY}:][].total // empty] | if length > 0 then (add/length|floor) else 0 end" "$METRICS_FILE" 2>/dev/null)
    local eta_line=""
    [ "${total_avg:-0}" -gt 0 ] && eta_line=" ${DIM}(estimated ~$(format_duration $total_avg))${NC}"

    echo -e "${BOLD}Namespace:${NC} $NAMESPACE"
    echo -e "${BOLD}Services:${NC} $service_count services${eta_line}"
    [ "$worker_count" -gt 0 ] && echo -e "${BOLD}Workers:${NC} $worker_count workers"
    [ "$emulator_count" -gt 0 ] && echo -e "${BOLD}Emulators:${NC} $emulator_count apps"
    [ "$REFRESH" = "true" ] && echo -e "${BOLD}Refresh:${NC} ${GREEN}yes${NC} (will pull latest code)"
    [ "$INCLUDE_APP" = "true" ] && echo -e "${BOLD}Include Apps:${NC} ${GREEN}yes${NC} (Android emulators)"

    # ========== Phase 1: Repository Setup (Parallel) ==========
    start_phase "Phase 1: Repository Setup"

    local services_ready=""
    local workers_ready=""
    local emulators_ready=""
    local failed_services=""

    # Create temp directory for parallel job results
    local parallel_tmp=$(mktemp -d)
    local pids=""

    local total_setup_count=$((service_count + emulator_count))
    [ "$total_setup_count" -gt 0 ] && echo -e "  ${DIM}Setting up $total_setup_count repositories in parallel...${NC}"

    # Launch all repository setups in parallel (services + emulators)
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

    # Launch emulator setups in parallel
    for emulator in $emulators_to_run; do
        (
            if setup_emulator "$emulator" > "${parallel_tmp}/${emulator}.log" 2>&1; then
                echo "success" > "${parallel_tmp}/${emulator}.status"
            else
                echo "failed" > "${parallel_tmp}/${emulator}.status"
            fi
        ) &
        pids="$pids $!"
    done

    # Wait for all parallel jobs to complete
    for pid in $pids; do
        wait $pid 2>/dev/null || true
    done

    # Collect results and display output for services
    for service in $services_to_run; do
        if [ -f "${parallel_tmp}/${service}.log" ]; then
            cat "${parallel_tmp}/${service}.log"
        fi

        if [ -f "${parallel_tmp}/${service}.status" ]; then
            local status=$(cat "${parallel_tmp}/${service}.status")
            if [ "$status" = "success" ]; then
                services_ready="$services_ready $service"
            else
                failed_services="$failed_services $service"
                echo -e "  ${RED}✗ $service setup failed${NC}"
                if [ -f "${parallel_tmp}/${service}.log" ]; then
                    echo -e "    ${DIM}Last few lines of setup log:${NC}"
                    tail -5 "${parallel_tmp}/${service}.log" 2>/dev/null | sed 's/^/    /'
                fi
            fi
        else
            failed_services="$failed_services $service"
            echo -e "  ${RED}✗ $service setup incomplete (no status file)${NC}"
        fi
    done

    # Collect results for emulators
    for emulator in $emulators_to_run; do
        if [ -f "${parallel_tmp}/${emulator}.log" ]; then
            cat "${parallel_tmp}/${emulator}.log"
        fi

        if [ -f "${parallel_tmp}/${emulator}.status" ]; then
            local status=$(cat "${parallel_tmp}/${emulator}.status")
            if [ "$status" = "success" ]; then
                emulators_ready="$emulators_ready $emulator"
            else
                failed_services="$failed_services $emulator"
                echo -e "  ${RED}✗ $emulator setup failed${NC}"
            fi
        fi
    done

    # Setup workers (after services, as they depend on parent repos)
    # Format: "worker:parent:dockerfile"
    if [ -n "$workers_to_run" ]; then
        echo -e "  ${DIM}Setting up $worker_count workers...${NC}"
        for worker_entry in $workers_to_run; do
            local worker=$(echo "$worker_entry" | cut -d: -f1)
            local parent=$(echo "$worker_entry" | cut -d: -f2)
            local dockerfile=$(echo "$worker_entry" | cut -d: -f3)
            if setup_worker "$worker" "$parent" "$dockerfile" > "${parallel_tmp}/${worker}.log" 2>&1; then
                workers_ready="$workers_ready $worker_entry"
            else
                failed_services="$failed_services $worker"
            fi
            cat "${parallel_tmp}/${worker}.log" 2>/dev/null
        done
    fi

    # Cleanup temp directory
    rm -rf "$parallel_tmp"

    services_ready=$(echo $services_ready | xargs)
    workers_ready=$(echo $workers_ready | xargs)
    emulators_ready=$(echo $emulators_ready | xargs)

    if [ -z "$services_ready" ] && [ -z "$workers_ready" ] && [ -z "$emulators_ready" ]; then
        echo -e "  ${RED}No services ready to run${NC}"
        exit 1
    fi

    if [ -n "$failed_services" ]; then
        echo -e "  ${YELLOW}⚠ Some services failed:${NC}$failed_services"
    fi

    end_phase "Phase 1: Repository Setup"

    # ========== Phase 2: Docker Configuration ==========
    start_phase "Phase 2: Docker Configuration"

    echo -e "  Generating docker-compose.yml for: ${BOLD}$services_ready${NC}"
    [ -n "$workers_ready" ] && echo -e "  Workers: ${BOLD}$workers_ready${NC}"
    generate_docker_compose "$services_ready" "$workers_ready"
    cache_containers
    local compose_service_count=$(grep -c "^  [a-z]" docker-compose.yml 2>/dev/null || echo 0)
    echo -e "  ${GREEN}✓${NC} docker-compose.yml generated with $compose_service_count service(s)"

    end_phase "Phase 2: Docker Configuration"

    # ========== Phase 3: Build (parallel with BuildKit) ==========
    start_phase "Phase 3: Building Containers"

    # Check if any frontend service needs GITHUB_NPM_TOKEN
    local has_frontend_service=false
    local has_python_service=false
    for service in $services_to_include; do
        local service_type=$(yq -r ".services.\"${service}\".type" $CONFIG_FILE 2>/dev/null)
        if [ "$service_type" = "nextjs" ] || [ "$service_type" = "nodejs" ]; then
            has_frontend_service=true
        elif [ "$service_type" = "null" ] || [ -z "$service_type" ]; then
            # Default type (Python/Django)
            if [[ "$service" != "oms-api" ]]; then
                has_python_service=true
            fi
        fi
    done

    # Warn if GITHUB_NPM_TOKEN is missing for frontend services
    if [ "$has_frontend_service" = true ]; then
        if [ -z "${GITHUB_NPM_TOKEN:-}" ]; then
            echo -e "  ${RED}✗ ERROR: GITHUB_NPM_TOKEN not set${NC}"
            echo -e "  ${YELLOW}Frontend services (bifrost, oms-web) require this token for @orange-health packages${NC}"
            echo -e ""
            echo -e "  ${CYAN}To fix, run:${NC}"
            echo -e "    export GITHUB_NPM_TOKEN=\"ghp_your_token_here\""
            echo -e ""
            echo -e "  ${DIM}See README.md for instructions on creating a GitHub Personal Access Token${NC}"
            end_phase "Phase 3: Building Containers"
            return 1
        else
            echo -e "  ${GREEN}✓${NC} GITHUB_NPM_TOKEN is set"
            # Export for docker-compose to access
            export GITHUB_NPM_TOKEN
        fi
    fi

    # Warn if GITHUB_TOKEN is missing for Python services (needed for error_framework)
    if [ "$has_python_service" = true ]; then
        if [ -z "${GITHUB_TOKEN:-}" ]; then
            echo -e "  ${YELLOW}⚠${NC} GITHUB_TOKEN not set - error_framework may not install"
            echo -e "    ${DIM}To fix: export GITHUB_TOKEN=\"ghp_your_token_here\"${NC}"
        else
            echo -e "  ${GREEN}✓${NC} GITHUB_TOKEN is set"
            export GITHUB_TOKEN
        fi
    fi

    echo -e "  ${DIM}Building $service_count container(s) in parallel...${NC}"

    # Enable BuildKit for true parallel builds
    export COMPOSE_DOCKER_CLI_BUILD=1
    export DOCKER_BUILDKIT=1
    # Enable Compose Bake for better parallel build visualization (service-wise boxes)
    export COMPOSE_BAKE=true

    # Capture build output to log file
    local build_start=$(now_ms)
    local build_log="${LOG_DIR}/build_output.log"

    # BuildKit handles parallelism automatically, --parallel is for docker-compose v1 compatibility
    # --progress is a global compose flag and must come BEFORE the build subcommand
    # Use --progress=plain since output is piped to tee for logging (tty mode requires direct terminal)
    # Run build and capture output - show progress in real-time
    docker_compose --progress=plain build --parallel 2>&1 | tee "$build_log"

    # Get pipeline exit status (use PIPESTATUS on bash, check log on other shells)
    local build_status=0
    if grep -qiE "ERROR:|failed to solve|exited with code [1-9]|exit code: [1-9]|FAILED" "$build_log" 2>/dev/null; then
        build_status=1
    fi

    local build_end=$(now_ms)
    local build_duration=$((build_end - build_start))

    if [ $build_status -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} All containers built ${DIM}($(format_duration $build_duration))${NC}"
    else
        echo -e "\n  ${RED}✗ Build failed${NC}"
        echo -e "  ${YELLOW}─────────────────────────────────────${NC}"
        echo -e "  ${YELLOW}Build Error Summary:${NC}"
        echo -e "  ${YELLOW}─────────────────────────────────────${NC}"
        # Show last 40 lines which usually contain the actual error
        echo ""
        tail -40 "$build_log" | while IFS= read -r line; do
            if echo "$line" | grep -qiE "error|failed|npm ERR|yarn"; then
                echo -e "  ${RED}$line${NC}"
            else
                echo -e "  ${DIM}$line${NC}"
            fi
        done
        echo ""
        echo -e "  ${YELLOW}Full build log:${NC} $build_log"
        echo -e "  ${YELLOW}─────────────────────────────────────${NC}"
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

    # ========== Phase 5: Start Emulator Scripts ==========
    if [ -n "$emulators_ready" ]; then
        start_phase "Phase 5: Starting Android Emulators"

        for emulator in $emulators_ready; do
            local repo=$(yq -r ".emulators.\"${emulator}\".git_repo" $CONFIG_FILE 2>/dev/null)
            local script=$(yq -r ".emulators.\"${emulator}\".script" $CONFIG_FILE 2>/dev/null)
            local dir_name=$(basename "$repo" .git)

            echo -e "  ${MAGENTA}▶${NC} Starting $emulator..."
            if [ -f "cloned/$dir_name/$script" ]; then
                # Run emulator script in background
                (cd "cloned/$dir_name" && ./$script > "../../../logs/${emulator}.log" 2>&1) &
                echo -e "    └─ script started ${GREEN}✓${NC} (logs: logs/${emulator}.log)"
            else
                echo -e "    └─ ${RED}✗ script not found${NC}"
            fi
        done

        end_phase "Phase 5: Starting Android Emulators"
    fi

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

    # Show services status
    for service in $services_ready; do
        local port=$(yq -r ".services.\"${service}\".port" $CONFIG_FILE 2>/dev/null)

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

    # Show workers status (format: "worker:parent")
    for worker_entry in $workers_ready; do
        local worker=$(echo "$worker_entry" | cut -d: -f1)

        if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${worker}$"; then
            echo -e "${GREEN}✓${NC} ${BOLD}$worker${NC} ${BLUE}[worker]${NC}"
            running_count=$((running_count + 1))
        else
            echo -e "${RED}✗${NC} ${BOLD}$worker${NC} ${BLUE}[worker]${NC} - failed"
            docker logs --tail=3 $worker 2>&1 | sed 's/^/    /'
            failed_count=$((failed_count + 1))
        fi
    done

    # Show emulators status
    for emulator in $emulators_ready; do
        echo -e "${GREEN}✓${NC} ${BOLD}$emulator${NC} ${MAGENTA}[emulator]${NC}"
        echo -e "  └─ logs: logs/${emulator}.log"
        running_count=$((running_count + 1))
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
