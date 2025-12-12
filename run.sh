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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="repos_docker_files/config.yaml"
LOG_DIR="logs"
CACHE_FILE="logs/cache.txt"
BRANCH_CACHE_FILE="logs/branch_cache.txt"
METRICS_FILE="logs/run_metrics.json"
PROGRESS_FILE="logs/progress.json"
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
LIVE_LOGS="true"
LOCAL_REDIS="false"
DASHBOARD="false"

# ============================================
# Utility Functions
# ============================================

# Cross-platform timeout function (works on macOS without GNU coreutils)
run_with_timeout() {
    local timeout_seconds=$1
    shift
    local cmd="$@"

    # Try GNU timeout first (Linux, or macOS with coreutils installed)
    if command -v timeout &>/dev/null; then
        timeout "$timeout_seconds" $cmd
        return $?
    fi

    # Try gtimeout (macOS with coreutils via brew)
    if command -v gtimeout &>/dev/null; then
        gtimeout "$timeout_seconds" $cmd
        return $?
    fi

    # Fallback: use background process with kill (works on any POSIX system)
    $cmd &
    local pid=$!
    local count=0
    while [ $count -lt $timeout_seconds ]; do
        if ! kill -0 $pid 2>/dev/null; then
            # Process finished
            wait $pid
            return $?
        fi
        sleep 1
        count=$((count + 1))
    done
    # Timeout reached, kill the process
    kill -9 $pid 2>/dev/null
    wait $pid 2>/dev/null
    return 124  # Same exit code as GNU timeout
}

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

# Helper to get service config from new structure (services or clients.web)
get_service_config_path() {
    local service=$1
    local field=$2

    # Try services first
    local value=$(yq -r ".services.\"${service}\".${field}" $CONFIG_FILE 2>/dev/null)
    if [ "$value" != "null" ] && [ -n "$value" ]; then
        echo "$value"
        return 0
    fi

    # Try clients.web
    value=$(yq -r ".clients.web.\"${service}\".${field}" $CONFIG_FILE 2>/dev/null)
    if [ "$value" != "null" ] && [ -n "$value" ]; then
        echo "$value"
        return 0
    fi

    # Try clients.android (emulators)
    value=$(yq -r ".clients.android.\"${service}\".${field}" $CONFIG_FILE 2>/dev/null)
    if [ "$value" != "null" ] && [ -n "$value" ]; then
        echo "$value"
        return 0
    fi

    # Return null if not found
    echo "null"
    return 1
}

# Check if service is a web client
is_web_client() {
    local service=$1
    local value=$(yq -r ".clients.web.\"${service}\"" $CONFIG_FILE 2>/dev/null)
    [ "$value" != "null" ] && [ -n "$value" ]
}

# Docker Compose command helper (uses v2 if available, fallback to v1)
# Cache the compose command to avoid repeated slow checks
DOCKER_COMPOSE_CMD=""

# Pre-detect docker compose command (call this before parallel operations)
detect_docker_compose() {
    if [ -n "$DOCKER_COMPOSE_CMD" ]; then
        return 0
    fi
    # Use timeout to avoid hanging if Docker daemon is unresponsive
    if command -v docker &>/dev/null && run_with_timeout 5 docker compose version &>/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        echo "Error: Docker Compose not found. Please install Docker with Compose plugin." >&2
        return 1
    fi
    export DOCKER_COMPOSE_CMD  # Export for subshells
}

docker_compose() {
    # Cache the docker compose command detection on first use
    if [ -z "$DOCKER_COMPOSE_CMD" ]; then
        detect_docker_compose || return 1
    fi
    $DOCKER_COMPOSE_CMD "$@"
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

# ============================================
# Progress File Functions (for Dashboard)
# ============================================

# Initialize/clear progress file for fresh run
init_progress_file() {
    mkdir -p "$LOG_DIR"
    cat > "$PROGRESS_FILE" << 'EOF'
{
    "run_id": "",
    "start_time": "",
    "current_phase": 0,
    "phases": {
        "1": {"name": "Repository Setup", "status": "pending", "start_time": null, "end_time": null, "eta_ms": 0, "operations": {}},
        "2": {"name": "Docker Configuration", "status": "pending", "start_time": null, "end_time": null, "eta_ms": 0, "operations": {}},
        "3": {"name": "Building Containers", "status": "pending", "start_time": null, "end_time": null, "eta_ms": 0, "operations": {}},
        "4": {"name": "Starting Services", "status": "pending", "start_time": null, "end_time": null, "eta_ms": 0, "operations": {}},
        "5": {"name": "Complete", "status": "pending", "start_time": null, "end_time": null, "eta_ms": 0, "operations": {}}
    },
    "services": [],
    "namespace": "",
    "completed": false
}
EOF
    # Set run_id and start_time
    local run_id=$(date +%s%N | md5sum | head -c 8)
    local start_time=$(date -Iseconds)
    jq --arg id "$run_id" --arg st "$start_time" \
        '.run_id = $id | .start_time = $st' "$PROGRESS_FILE" > "${PROGRESS_FILE}.tmp" \
        && mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
}

# Update progress file with namespace and services
update_progress_config() {
    local namespace=$1
    shift
    local services_json="[]"
    for svc in "$@"; do
        services_json=$(echo "$services_json" | jq --arg s "$svc" '. + [$s]')
    done
    jq --arg ns "$namespace" --argjson svcs "$services_json" \
        '.namespace = $ns | .services = $svcs' "$PROGRESS_FILE" > "${PROGRESS_FILE}.tmp" \
        && mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
}

# Start a phase
progress_start_phase() {
    local phase_num=$1
    local eta_ms=${2:-0}
    local start_time=$(date -Iseconds)
    jq --arg p "$phase_num" --arg st "$start_time" --argjson eta "$eta_ms" \
        '.current_phase = ($p | tonumber) | .phases[$p].status = "in_progress" | .phases[$p].start_time = $st | .phases[$p].eta_ms = $eta' \
        "$PROGRESS_FILE" > "${PROGRESS_FILE}.tmp" \
        && mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
}

# End a phase
progress_end_phase() {
    local phase_num=$1
    local end_time=$(date -Iseconds)
    jq --arg p "$phase_num" --arg et "$end_time" \
        '.phases[$p].status = "complete" | .phases[$p].end_time = $et' \
        "$PROGRESS_FILE" > "${PROGRESS_FILE}.tmp" \
        && mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
}

# Start an operation within a phase (for parallel tracking)
progress_start_operation() {
    local phase_num=$1
    local op_name=$2
    local eta_ms=${3:-0}
    local start_time=$(date -Iseconds)
    jq --arg p "$phase_num" --arg op "$op_name" --arg st "$start_time" --argjson eta "$eta_ms" \
        '.phases[$p].operations[$op] = {"status": "in_progress", "start_time": $st, "end_time": null, "eta_ms": $eta}' \
        "$PROGRESS_FILE" > "${PROGRESS_FILE}.tmp" \
        && mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
}

# End an operation within a phase
progress_end_operation() {
    local phase_num=$1
    local op_name=$2
    local status=${3:-"complete"}  # complete or failed
    local end_time=$(date -Iseconds)
    jq --arg p "$phase_num" --arg op "$op_name" --arg s "$status" --arg et "$end_time" \
        '.phases[$p].operations[$op].status = $s | .phases[$p].operations[$op].end_time = $et' \
        "$PROGRESS_FILE" > "${PROGRESS_FILE}.tmp" \
        && mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
}

# Mark run as complete
progress_complete() {
    jq '.completed = true | .current_phase = 5 | .phases["5"].status = "complete"' \
        "$PROGRESS_FILE" > "${PROGRESS_FILE}.tmp" \
        && mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
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

# Service colors for live logs (cycle through colors)
SERVICE_COLORS=("$RED" "$GREEN" "$YELLOW" "$CYAN" "$BLUE" "$MAGENTA")

get_service_color() {
    local service=$1
    local hash=0
    for (( i=0; i<${#service}; i++ )); do
        hash=$(( (hash + $(printf '%d' "'${service:$i:1}")) % ${#SERVICE_COLORS[@]} ))
    done
    echo "${SERVICE_COLORS[$hash]}"
}

# Stream build output with colorized service prefix
stream_build_log() {
    local service=$1
    local log_file=$2
    local color=$(get_service_color "$service")
    local prefix_width=20
    local service_padded=$(printf "%-${prefix_width}s" "$service")

    # Use tail -f to stream the log file, adding colorized prefix
    # Show ALL logs without filtering for complete visibility
    tail -f "$log_file" 2>/dev/null | while IFS= read -r line; do
        # Only skip completely empty lines
        if [ -n "$line" ]; then
            # Allow longer lines for complete log output (500 chars)
            if [ ${#line} -gt 500 ]; then
                line="${line:0:497}..."
            fi
            echo -e "${color}${service_padded}${NC} │ ${DIM}$line${NC}"
        fi
    done
}

# Live build monitor - streams logs from all builds in real-time
live_build_monitor() {
    local build_tmp=$1
    shift
    local services="$@"

    # Output header to stderr so it displays (not captured by command substitution)
    echo -e "\n  ${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}" >&2
    echo -e "  ${CYAN}║${NC}              ${BOLD}Live Build Output${NC}  (auto-scrolling)              ${CYAN}║${NC}" >&2
    echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n" >&2

    # Start tail processes for each service
    local tail_pids=""
    for svc in $services; do
        local svc_log="${build_tmp}/${svc}.log"
        # Create log file if it doesn't exist
        touch "$svc_log"
        # Start streaming in background
        stream_build_log "$svc" "$svc_log" &
        tail_pids="$tail_pids $!"
    done

    # Return the PIDs so they can be killed later (to stdout for capture)
    echo "$tail_pids"
}

# Stop all live log streaming processes
stop_live_monitor() {
    local pids="$1"
    for pid in $pids; do
        # Kill the process and its children (including tail -f in the pipeline)
        kill $pid 2>/dev/null || true
        # Also kill any child processes (tail -f runs in a subshell)
        pkill -P $pid 2>/dev/null || true
    done
    # Small delay to ensure clean output
    sleep 0.3
    echo -e "\n  ${CYAN}════════════════════════════════════════════════════════════════${NC}\n"
}

# ============================================
# Dashboard Functions
# ============================================

start_dashboard() {
    local dashboard_dir="${SCRIPT_DIR}/dashboard"

    # Check if dashboard exists
    if [ ! -f "$dashboard_dir/server.py" ]; then
        echo -e "  ${YELLOW}⚠${NC} Dashboard not found at $dashboard_dir"
        return 1
    fi

    # Kill any existing dashboard
    pkill -f "dashboard/server.py" 2>/dev/null || true

    # Check if Python3 is available
    if ! command -v python3 &>/dev/null; then
        echo -e "  ${YELLOW}⚠${NC} Python3 not found - skipping dashboard"
        return 1
    fi

    # Setup virtual environment if needed
    if [ ! -d "$dashboard_dir/venv" ]; then
        echo -e "  ${DIM}Setting up dashboard environment...${NC}"
        if ! python3 -m venv "$dashboard_dir/venv" 2>&1 | grep -v "^$"; then
            echo -e "  ${YELLOW}⚠${NC} Failed to create virtual environment"
            return 1
        fi
    fi

    # Install dependencies if needed
    if [ ! -f "$dashboard_dir/venv/.deps_installed" ]; then
        echo -e "  ${DIM}Installing dashboard dependencies (Flask, PyYAML)...${NC}"
        if ! (source "$dashboard_dir/venv/bin/activate" && pip install -q flask flask-cors pyyaml 2>&1); then
            echo -e "  ${YELLOW}⚠${NC} Failed to install dependencies - dashboard disabled"
            return 1
        fi
        touch "$dashboard_dir/venv/.deps_installed"
    fi

    # Ensure logs directory exists
    mkdir -p "$LOG_DIR"

    # Store absolute paths before changing directory
    local log_file="${SCRIPT_DIR}/${LOG_DIR}/dashboard.log"
    local pid_file="${SCRIPT_DIR}/${LOG_DIR}/dashboard.pid"

    # Start dashboard in background
    (
        cd "$dashboard_dir"
        source venv/bin/activate
        python3 server.py > "$log_file" 2>&1
    ) &

    DASHBOARD_PID=$!
    echo $DASHBOARD_PID > "$pid_file"

    # Wait for server to start
    sleep 2

    if kill -0 $DASHBOARD_PID 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Dashboard started"
        echo ""
        echo -e "  ${CYAN}╔══════════════════════════════════════════════════╗${NC}"
        echo -e "  ${CYAN}║${NC}  ${BOLD}Dashboard:${NC} \033]8;;http://localhost:9999\033\\${CYAN}${BOLD}http://localhost:9999${NC}\033]8;;\033\\  ${CYAN}║${NC}"
        echo -e "  ${CYAN}╚══════════════════════════════════════════════════╝${NC}"
        echo ""

        # Auto-open dashboard in browser
        local dashboard_url="http://localhost:9999"
        if command -v open &>/dev/null; then
            # macOS
            open "$dashboard_url" 2>/dev/null &
            echo -e "  ${DIM}Opening dashboard in browser...${NC}"
        elif command -v xdg-open &>/dev/null; then
            # Linux
            xdg-open "$dashboard_url" 2>/dev/null &
            echo -e "  ${DIM}Opening dashboard in browser...${NC}"
        fi

        return 0
    else
        echo -e "  ${YELLOW}⚠${NC} Dashboard failed to start - check $LOG_DIR/dashboard.log"
        cat "$LOG_DIR/dashboard.log" 2>/dev/null | tail -5
        return 1
    fi
}

stop_dashboard() {
    if [ -f "$LOG_DIR/dashboard.pid" ]; then
        local pid=$(cat "$LOG_DIR/dashboard.pid")
        kill $pid 2>/dev/null || true
        rm -f "$LOG_DIR/dashboard.pid"
    fi
    pkill -f "dashboard/server.py" 2>/dev/null || true
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
# Local Redis Docker Functions
# ============================================

LOCAL_REDIS_CONTAINER="oh-local-redis"

is_local_redis_running() {
    docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${LOCAL_REDIS_CONTAINER}$"
}

is_local_redis_exists() {
    docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${LOCAL_REDIS_CONTAINER}$"
}

start_local_redis() {
    local port=$(get_redis_port)

    # Check if already running
    if is_local_redis_running; then
        echo -e "  ${GREEN}✓${NC} Local Redis already running on port $port"
        return 0
    fi

    # If container exists but not running, start it
    if is_local_redis_exists; then
        echo -n "  Starting existing local Redis container..."
        docker start "$LOCAL_REDIS_CONTAINER" >/dev/null 2>&1
        sleep 1
        if is_local_redis_running; then
            echo -e " ${GREEN}✓${NC}"
            return 0
        else
            echo -e " ${RED}✗${NC}"
            # Remove failed container and try fresh
            docker rm -f "$LOCAL_REDIS_CONTAINER" >/dev/null 2>&1
        fi
    fi

    # Force close the port before starting
    echo -n "  Checking port $port..."
    if is_port_busy "$port"; then
        echo -e " ${YELLOW}busy${NC}"
        force_kill_redis_port
    else
        echo -e " ${GREEN}free${NC}"
    fi

    # Create new Redis container on host network (localhost accessible)
    echo -n "  Starting new local Redis container..."
    docker run -d \
        --name "$LOCAL_REDIS_CONTAINER" \
        --network host \
        --restart unless-stopped \
        redis:7-alpine \
        redis-server --port "$port" >/dev/null 2>&1

    sleep 2

    if is_local_redis_running; then
        echo -e " ${GREEN}✓${NC}"
        echo -e "  Redis running on localhost:$port"
        return 0
    else
        echo -e " ${RED}✗${NC}"
        echo -e "  ${YELLOW}Failed to start local Redis. Check docker logs:${NC}"
        echo -e "    docker logs $LOCAL_REDIS_CONTAINER"
        return 1
    fi
}

stop_local_redis() {
    if is_local_redis_exists; then
        echo -n "  Stopping local Redis container..."
        docker stop "$LOCAL_REDIS_CONTAINER" >/dev/null 2>&1 || true
        echo -e " ${GREEN}✓${NC}"
    fi
}

# ============================================
# Repository Functions
# ============================================

setup_repository() {
    local service=$1
    local repo=$(get_service_config_path "$service" "git_repo")
    local branch=$(get_service_config_path "$service" "git_branch")
    local always_refresh=$(get_service_config_path "$service" "always-refresh")

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
            # Add 60s timeout to git clone to prevent hanging (macOS compatible)
            clone_error=$(run_with_timeout 60 git clone "$repo" "cloned/$dir_name" 2>&1)
            local clone_exit=$?
            if [ $clone_exit -eq 0 ]; then
                clone_success=true
                break
            elif [ $clone_exit -eq 124 ]; then
                clone_error="Git clone timed out after 60s - check network/SSH keys"
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
    # Check both services and clients.web for configs
    local configs_count=0
    local config_base_path=""
    if yq -r ".services.\"${service}\".configs" $CONFIG_FILE 2>/dev/null | grep -qv "null"; then
        config_base_path=".services.\"${service}\""
        configs_count=$(yq -r ".services.\"${service}\".configs | length" $CONFIG_FILE 2>/dev/null || echo 0)
    elif yq -r ".clients.web.\"${service}\".configs" $CONFIG_FILE 2>/dev/null | grep -qv "null"; then
        config_base_path=".clients.web.\"${service}\""
        configs_count=$(yq -r ".clients.web.\"${service}\".configs | length" $CONFIG_FILE 2>/dev/null || echo 0)
    fi
    local configs_copied=0

    for i in $(seq 0 $((configs_count - 1))); do
        local source=$(yq -r "${config_base_path}.configs[$i].source" $CONFIG_FILE 2>/dev/null)
        local dest=$(yq -r "${config_base_path}.configs[$i].dest" $CONFIG_FILE 2>/dev/null)
        local required=$(yq -r "${config_base_path}.configs[$i].required" $CONFIG_FILE 2>/dev/null)

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
        echo -e "    ├─ dockerfile ready ${GREEN}✓${NC}"
    else
        echo -e "    ├─ ${RED}✗ no Dockerfile at $dockerfile_path${NC}"
        return 1
    fi

    # Copy debug configurations (VSCode and PyCharm) for IDE support
    local debug_configs_copied=0
    if [ -d "$config_folder/debug-configs/.vscode" ]; then
        mkdir -p "cloned/$dir_name/.vscode"
        cp -r "$config_folder/debug-configs/.vscode/"* "cloned/$dir_name/.vscode/" 2>/dev/null && debug_configs_copied=$((debug_configs_copied + 1))
    fi
    if [ -d "$config_folder/debug-configs/.idea" ]; then
        mkdir -p "cloned/$dir_name/.idea/runConfigurations"
        cp -r "$config_folder/debug-configs/.idea/"* "cloned/$dir_name/.idea/" 2>/dev/null && debug_configs_copied=$((debug_configs_copied + 1))
    fi
    [ "$debug_configs_copied" -gt 0 ] && echo -e "    ├─ debug configs ready ${GREEN}✓${NC}"

    echo -e "    └─ setup complete ${GREEN}✓${NC}"

    end_operation "setup:$service"
    return 0
}

# Setup emulator app (clone and prepare for script execution)
setup_emulator() {
    local emulator=$1
    local repo=$(yq -r ".clients.android.\"${emulator}\".git_repo" $CONFIG_FILE 2>/dev/null)
    local branch=$(yq -r ".clients.android.\"${emulator}\".git_branch" $CONFIG_FILE 2>/dev/null)
    local script=$(yq -r ".clients.android.\"${emulator}\".script" $CONFIG_FILE 2>/dev/null)

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
    local web_clients=""

    # Separate web clients from backend services
    local backend_services=""
    for service in $services_to_include; do
        if is_web_client "$service"; then
            web_clients="$web_clients $service"
        else
            backend_services="$backend_services $service"
        fi
    done
    backend_services=$(echo $backend_services | xargs)
    web_clients=$(echo $web_clients | xargs)

    # Generate main docker-compose.yml for backend services
    cat > docker-compose.yml << 'COMPOSE'
services:
COMPOSE

    for service in $backend_services; do
        local repo=$(get_service_config_path "$service" "git_repo")
        local port=$(get_service_config_path "$service" "port")
        local service_type=$(get_service_config_path "$service" "type")
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
            # Assign unique debug port for each service (5678 + offset)
            local debug_port=$((5678 + ${#services_ready}))
            cat >> docker-compose.yml << COMPOSE
  ${service}:
    build:
      context: ./cloned/${dir_name}
      dockerfile: dev.Dockerfile
      args:
        PYTHON_CORE_UTILS_TOKEN: \${PYTHON_CORE_UTILS_TOKEN:-}
    container_name: ${service}
    ports:
      - "${port}:${port}"
      - "${debug_port}:5678"  # Python debugger port (debugpy)
    volumes:
      - ./cloned/${dir_name}/app:/app
      - ./cloned/${dir_name}:/workspace
    environment:
      PYTHONDONTWRITEBYTECODE: 1
      PYTHONUNBUFFERED: 1
      DJANGO_SETTINGS_MODULE: app.secrets
      DEBUG_PORT: 5678
COMPOSE
        fi

        cat >> docker-compose.yml << COMPOSE
    networks: [oh-network]
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

    # Generate separate docker-compose-web.yml for web clients
    if [ -n "$web_clients" ]; then
        echo -e "  ${DIM}Generating docker-compose-web.yml for web clients: $web_clients${NC}"
        cat > docker-compose-web.yml << 'COMPOSE'
services:
COMPOSE

        for service in $web_clients; do
            local repo=$(get_service_config_path "$service" "git_repo")
            local port=$(get_service_config_path "$service" "port")
            local service_type=$(get_service_config_path "$service" "type")
            local dir_name=$(basename "$repo" .git)

            # Check for missing directory or dockerfile
            if [ ! -d "cloned/$dir_name" ]; then
                echo -e "  ${YELLOW}⚠ Skipping $service: cloned/$dir_name directory not found${NC}"
                continue
            fi
            if [ ! -f "cloned/$dir_name/dev.Dockerfile" ]; then
                echo -e "  ${YELLOW}⚠ Skipping $service: cloned/$dir_name/dev.Dockerfile not found${NC}"
                continue
            fi

            # Web clients use host network to access localhost backend endpoints
            if [ "$service_type" = "nextjs" ]; then
                cat >> docker-compose-web.yml << COMPOSE
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
    network_mode: host
    restart: unless-stopped
    stdin_open: true
    tty: true

COMPOSE
            elif [ "$service_type" = "nodejs" ]; then
                cat >> docker-compose-web.yml << COMPOSE
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
    network_mode: host
    restart: unless-stopped
    stdin_open: true
    tty: true

COMPOSE
            fi
        done
    fi
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

    # Check for refresh, --include-app, --live, and --local flags (can be anywhere in args)
    local remaining_args=""
    local expect_local_value="false"
    for arg in "$@"; do
        if [ "$expect_local_value" = "true" ]; then
            if [ "$arg" = "redis" ]; then
                LOCAL_REDIS="true"
            else
                echo -e "${RED}Error: --local only supports 'redis' currently${NC}"
                echo -e "Usage: make run --local redis"
                exit 1
            fi
            expect_local_value="false"
        elif [ "$arg" = "refresh" ]; then
            REFRESH="true"
        elif [ "$arg" = "--include-app" ]; then
            INCLUDE_APP="true"
        elif [ "$arg" = "--live" ] || [ "$arg" = "-l" ]; then
            LIVE_LOGS="true"
        elif [ "$arg" = "--dashboard" ] || [ "$arg" = "-d" ]; then
            DASHBOARD="true"
        elif [ "$arg" = "--local" ]; then
            expect_local_value="true"
        else
            remaining_args="$remaining_args $arg"
        fi
    done

    # Check if --local was specified without a value
    if [ "$expect_local_value" = "true" ]; then
        echo -e "${RED}Error: --local requires a value (e.g., --local redis)${NC}"
        exit 1
    fi

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
    stop_local_redis
    rm -f "$CACHE_FILE"
    echo -e "${GREEN}✓ All services stopped${NC}"
}

do_clean() {
    echo -e "${YELLOW}🧹 Cleaning environment...${NC}"
    docker_compose down -v 2>/dev/null || true
    # Remove local Redis container completely
    docker rm -f "$LOCAL_REDIS_CONTAINER" 2>/dev/null || true
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
    # Early Docker check - fail fast if Docker isn't available
    echo -e "${YELLOW}Checking Docker availability...${NC}"
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}✗ Docker is not installed${NC}"
        echo -e "${YELLOW}Please install Docker Desktop from: https://www.docker.com/products/docker-desktop${NC}"
        exit 1
    fi

    # Quick Docker daemon check with short timeout (using custom run_with_timeout for macOS compatibility)
    if ! run_with_timeout 5 docker info &>/dev/null 2>&1; then
        echo -e "${RED}✗ Docker daemon is not running${NC}"
        echo -e "${YELLOW}Please start Docker Desktop and try again${NC}"
        echo -e "${DIM}Tip: Check if Docker Desktop is fully started (not just opened)${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓${NC} Docker is ready"
    echo ""

    local config_folder=$(get_config_folder)

    # Initialize metrics tracking
    init_metrics
    start_run_timer

    # Initialize progress file for dashboard (clears previous run)
    init_progress_file

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
        # Validate each service exists in config (check services, clients.web, or clients.android)
        for svc in $SERVICES; do
            if yq -r ".services.\"${svc}\"" $CONFIG_FILE 2>/dev/null | grep -qv "null"; then
                services_to_run="$services_to_run $svc"
            elif yq -r ".clients.web.\"${svc}\"" $CONFIG_FILE 2>/dev/null | grep -qv "null"; then
                services_to_run="$services_to_run $svc"
            elif yq -r ".clients.android.\"${svc}\"" $CONFIG_FILE 2>/dev/null | grep -qv "null"; then
                # Emulator specified directly - will be handled below
                services_to_run="$services_to_run $svc"
            else
                echo -e "${RED}Service not found: $svc${NC}"
                exit 1
            fi
        done
    else
        # Get all enabled backend services
        for svc in $(yq -r '.services | keys | .[]' $CONFIG_FILE 2>/dev/null); do
            if [ "$(yq -r ".services.\"${svc}\".enabled" $CONFIG_FILE 2>/dev/null)" = "true" ]; then
                services_to_run="$services_to_run $svc"
            fi
        done
        # Get all enabled web clients
        for svc in $(yq -r '.clients.web | keys | .[]' $CONFIG_FILE 2>/dev/null); do
            if [ "$(yq -r ".clients.web.\"${svc}\".enabled" $CONFIG_FILE 2>/dev/null)" = "true" ]; then
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
        for emu in $(yq -r '.clients.android | keys | .[]' $CONFIG_FILE 2>/dev/null); do
            emulators_to_run="$emulators_to_run $emu"
            # Remove emulator from services_to_run if it was explicitly requested
            services_to_run=$(echo "$services_to_run" | sed "s/\b$emu\b//g" | xargs)
        done
    else
        # Check if any emulator was explicitly requested
        for emu in $(yq -r '.clients.android | keys | .[]' $CONFIG_FILE 2>/dev/null); do
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
    [ "$LOCAL_REDIS" = "true" ] && echo -e "${BOLD}Local Redis:${NC} ${GREEN}yes${NC} (Docker container on localhost)"
    [ "$DASHBOARD" = "true" ] && echo -e "${BOLD}Dashboard:${NC} ${GREEN}yes${NC} (Web UI at http://localhost:9999)"

    # Update progress file with config
    update_progress_config "$NAMESPACE" $services_to_run

    # Start dashboard if enabled
    if [ "$DASHBOARD" = "true" ]; then
        echo ""
        start_dashboard
    fi

    # ========== Phase 1: Repository Setup (Parallel) ==========
    local phase1_eta=$(get_phase_avg "Phase 1: Repository Setup")
    start_phase "Phase 1: Repository Setup"
    progress_start_phase "1" "$phase1_eta"

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
        local svc_eta=$(get_operation_avg "setup:$service")
        progress_start_operation "1" "$service" "$svc_eta"
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
        local emu_eta=$(get_operation_avg "setup:$emulator")
        progress_start_operation "1" "$emulator" "$emu_eta"
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
                progress_end_operation "1" "$service" "complete"
            else
                failed_services="$failed_services $service"
                progress_end_operation "1" "$service" "failed"
                echo -e "  ${RED}✗ $service setup failed${NC}"
                if [ -f "${parallel_tmp}/${service}.log" ]; then
                    echo -e "    ${DIM}Last few lines of setup log:${NC}"
                    tail -5 "${parallel_tmp}/${service}.log" 2>/dev/null | sed 's/^/    /'
                fi
            fi
        else
            failed_services="$failed_services $service"
            progress_end_operation "1" "$service" "failed"
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
                progress_end_operation "1" "$emulator" "complete"
            else
                failed_services="$failed_services $emulator"
                progress_end_operation "1" "$emulator" "failed"
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
    progress_end_phase "1"

    # ========== Phase 2: Docker Configuration ==========
    local phase2_eta=$(get_phase_avg "Phase 2: Docker Configuration")
    start_phase "Phase 2: Docker Configuration"
    progress_start_phase "2" "$phase2_eta"

    echo -e "  Generating docker-compose.yml for: ${BOLD}$services_ready${NC}"
    [ -n "$workers_ready" ] && echo -e "  Workers: ${BOLD}$workers_ready${NC}"
    generate_docker_compose "$services_ready" "$workers_ready"
    cache_containers
    local compose_service_count=$(grep -c "^  [a-z]" docker-compose.yml 2>/dev/null || echo 0)
    echo -e "  ${GREEN}✓${NC} docker-compose.yml generated with $compose_service_count service(s)"

    end_phase "Phase 2: Docker Configuration"
    progress_end_phase "2"

    # ========== Phase 3: Build (parallel with BuildKit) ==========
    local phase3_eta=$(get_phase_avg "Phase 3: Building Containers")
    start_phase "Phase 3: Building Containers"
    progress_start_phase "3" "$phase3_eta"

    # Check if any frontend service needs GITHUB_NPM_TOKEN
    local has_frontend_service=false
    local has_python_service=false
    for service in $services_ready; do
        local service_type=$(get_service_config_path "$service" "type")
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

    # Check for PYTHON_CORE_UTILS_TOKEN (needed for private repos: python-core-utils, error_framework)
    if [ "$has_python_service" = true ]; then
        if [ -z "${PYTHON_CORE_UTILS_TOKEN:-}" ]; then
            echo -e "  ${YELLOW}⚠${NC} PYTHON_CORE_UTILS_TOKEN not set - private packages may not install"
            echo -e "    ${DIM}To fix: export PYTHON_CORE_UTILS_TOKEN=\"ghp_your_classic_token_here\"${NC}"
        else
            echo -e "  ${GREEN}✓${NC} PYTHON_CORE_UTILS_TOKEN is set"
            export PYTHON_CORE_UTILS_TOKEN
        fi
    fi

    echo -e "  ${DIM}Building $service_count container(s) in parallel...${NC}"

    # Enable BuildKit for true parallel builds
    export COMPOSE_DOCKER_CLI_BUILD=1
    export DOCKER_BUILDKIT=1
    # Enable Compose Bake for better parallel build visualization (service-wise boxes)
    export COMPOSE_BAKE=true

    # Verify Docker is responsive before starting parallel builds
    # Use retry logic since Docker can be slow to respond, especially on macOS
    echo -ne "  ${DIM}Checking Docker availability...${NC}"
    local docker_ready=false
    local docker_attempts=0
    local docker_max_attempts=5

    while [ $docker_attempts -lt $docker_max_attempts ]; do
        docker_attempts=$((docker_attempts + 1))

        # First check if docker command exists
        if ! command -v docker &>/dev/null; then
            echo -e "\r  ${RED}✗${NC} Docker command not found. Please install Docker."
            return 1
        fi

        # Try docker info with a generous timeout (30s per attempt)
        if run_with_timeout 30 docker info &>/dev/null 2>&1; then
            docker_ready=true
            break
        fi

        # Show retry status
        if [ $docker_attempts -lt $docker_max_attempts ]; then
            echo -ne "\r  ${DIM}Checking Docker availability... (attempt $docker_attempts/$docker_max_attempts)${NC}"
            sleep 2
        fi
    done

    if [ "$docker_ready" = false ]; then
        echo -e "\r  ${RED}✗${NC} Docker is not responding after $docker_max_attempts attempts."
        echo -e "    ${DIM}Please ensure Docker Desktop is running and fully started.${NC}"
        echo -e "    ${DIM}Diagnostics:${NC}"
        # Show what's happening with docker
        echo -ne "    ${DIM}Docker socket: ${NC}"
        if [ -S /var/run/docker.sock ]; then
            echo -e "${GREEN}exists${NC}"
        elif [ -S "$HOME/.docker/run/docker.sock" ]; then
            echo -e "${GREEN}exists (user socket)${NC}"
        else
            echo -e "${RED}not found${NC}"
        fi
        echo -e "    ${DIM}Try: 'docker info' to diagnose${NC}"
        return 1
    fi
    echo -e "\r  ${GREEN}✓${NC} Docker is ready                  "

    # Pre-detect docker compose command BEFORE parallel builds
    # This prevents each subshell from re-detecting and potentially hanging
    echo -ne "  ${DIM}Detecting Docker Compose...${NC}"
    if ! detect_docker_compose; then
        echo -e "\r  ${RED}✗${NC} Docker Compose not available"
        return 1
    fi
    echo -e "\r  ${GREEN}✓${NC} Docker Compose ready ($DOCKER_COMPOSE_CMD)"

    # Capture build output to log file
    local build_start=$(now_ms)
    local build_log="${LOG_DIR}/build_output.log"

    # Initialize build output log
    > "$build_log"
    echo "=== Build Started $(date) ===" >> "$build_log"

    echo -e "  ${DIM}Launching parallel builds...${NC}"

    # Build each service individually in parallel to allow continuation when one fails
    # This prevents one failing build from cancelling others (default BuildKit behavior)
    local build_tmp=$(mktemp -d)
    local build_pids=""

    # Separate backend and web services
    local backend_services=""
    local web_services=""
    for svc in $services_ready; do
        if is_web_client "$svc"; then
            web_services="$web_services $svc"
        else
            backend_services="$backend_services $svc"
        fi
    done

    # Add workers to backend services
    for worker_entry in $workers_ready; do
        local worker_name="${worker_entry%%:*}"
        backend_services="$backend_services $worker_name"
    done

    backend_services=$(echo $backend_services | xargs)
    web_services=$(echo $web_services | xargs)
    local all_services="$backend_services $web_services"
    all_services=$(echo $all_services | xargs)

    # Safety check: ensure we have services to build
    if [ -z "$all_services" ]; then
        echo -e "  ${RED}✗${NC} No services to build"
        return 1
    fi
    echo -e "  ${DIM}Backend services to build: ${NC}${BOLD}$backend_services${NC}"
    [ -n "$web_services" ] && echo -e "  ${DIM}Web services to build: ${NC}${BOLD}$web_services${NC}"

    # Disable live monitor - use direct Docker output instead
    export DOCKER_COMPOSE_CMD

    # Build backend services using docker-compose.yml (let Docker handle parallelization)
    if [ -n "$backend_services" ]; then
        echo -e "\n  ${CYAN}═══ Building Backend Services ═══${NC}\n"
        echo -e "\n=== Building Backend Services ===" >> "$build_log"
        local backend_log="${LOG_DIR}/backend_build.log"
        # Let docker compose build all backend services - Docker BuildKit parallelizes automatically
        # Show output directly to terminal and capture to both logs
        if $DOCKER_COMPOSE_CMD build --progress=plain $backend_services 2>&1 | tee -a "$build_log" "$backend_log"; then
            echo -e "\n  ${GREEN}✓${NC} Backend services built successfully"
            # Mark all as success
            for svc in $backend_services; do
                echo "success" > "${build_tmp}/${svc}.status"
                progress_end_operation "3" "$svc" "complete"
            done
        else
            echo -e "\n  ${YELLOW}⚠${NC} Some backend services failed to build"
            # Check each service individually to determine which failed
            for svc in $backend_services; do
                if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${svc}:"; then
                    echo "success" > "${build_tmp}/${svc}.status"
                    progress_end_operation "3" "$svc" "complete"
                else
                    echo "failed" > "${build_tmp}/${svc}.status"
                    progress_end_operation "3" "$svc" "failed"
                fi
            done
        fi
    fi

    # Build web services using docker-compose-web.yml
    if [ -n "$web_services" ] && [ -f "docker-compose-web.yml" ]; then
        echo -e "\n  ${CYAN}═══ Building Web Client Services ═══${NC}\n"
        echo -e "\n=== Building Web Client Services ===" >> "$build_log"
        local web_log="${LOG_DIR}/web_build.log"
        # Let docker compose build all web services and capture to both logs
        if $DOCKER_COMPOSE_CMD -f docker-compose-web.yml build --progress=plain $web_services 2>&1 | tee -a "$build_log" "$web_log"; then
            echo -e "\n  ${GREEN}✓${NC} Web client services built successfully"
            # Mark all as success
            for svc in $web_services; do
                echo "success" > "${build_tmp}/${svc}.status"
                progress_end_operation "3" "$svc" "complete"
            done
        else
            echo -e "\n  ${YELLOW}⚠${NC} Some web client services failed to build"
            # Check each service individually
            for svc in $web_services; do
                if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${svc}:"; then
                    echo "success" > "${build_tmp}/${svc}.status"
                    progress_end_operation "3" "$svc" "complete"
                else
                    echo "failed" > "${build_tmp}/${svc}.status"
                    progress_end_operation "3" "$svc" "failed"
                fi
            done
        fi
    fi

    # Collect build results from status files
    local build_succeeded=""
    local build_failed=""

    for svc in $all_services; do
        if [ -f "${build_tmp}/${svc}.status" ]; then
            local status=$(cat "${build_tmp}/${svc}.status")
            if [ "$status" = "success" ]; then
                build_succeeded="$build_succeeded $svc"
            else
                build_failed="$build_failed $svc"
            fi
        fi
    done

    # Cleanup temp directory
    rm -rf "$build_tmp"

    local build_end=$(now_ms)
    local build_duration=$((build_end - build_start))

    # Trim whitespace
    build_succeeded=$(echo $build_succeeded | xargs)
    build_failed=$(echo $build_failed | xargs)

    local succeeded_count=$(echo $build_succeeded | wc -w | xargs)
    local failed_count=$(echo $build_failed | wc -w | xargs)

    echo ""
    if [ -z "$build_failed" ]; then
        echo -e "  ${GREEN}✓${NC} All containers built successfully ${DIM}($(format_duration $build_duration))${NC}"
    else
        echo -e "  ${YELLOW}⚠${NC} Build completed with some failures ${DIM}($(format_duration $build_duration))${NC}"
        echo -e "  ${GREEN}Succeeded:${NC} $succeeded_count ${DIM}($build_succeeded)${NC}"
        echo -e "  ${RED}Failed:${NC} $failed_count ${DIM}($build_failed)${NC}"
        echo -e "  ${YELLOW}Build logs:${NC} logs/backend_build.log, logs/web_build.log"

        if [ -z "$build_succeeded" ]; then
            echo -e "\n${RED}Aborting: No containers built successfully${NC}"
            end_phase "Phase 3: Building Containers"
            return 1
        fi

        echo -e "\n  ${CYAN}Continuing with successfully built containers...${NC}"
        # Update services_ready to only include successfully built services
        local old_services_ready="$services_ready"
        services_ready=""
        for svc in $build_succeeded; do
            # Check if it's a service (not a worker) by checking if it was in the original services_ready
            if echo " $old_services_ready " | grep -q " $svc "; then
                services_ready="$services_ready $svc"
            fi
        done
        services_ready=$(echo $services_ready | xargs)
        # Update workers_ready to only include successfully built workers
        local new_workers_ready=""
        for worker_entry in $workers_ready; do
            local worker_name="${worker_entry%%:*}"
            if echo " $build_succeeded " | grep -q " $worker_name "; then
                new_workers_ready="$new_workers_ready $worker_entry"
            fi
        done
        workers_ready=$(echo $new_workers_ready | xargs)
    fi

    end_phase "Phase 3: Building Containers"
    progress_end_phase "3"

    # ========== Phase 4: Redis + Start Containers (Parallel) ==========
    local phase4_eta=$(get_phase_avg "Phase 4: Redis + Starting Containers")
    start_phase "Phase 4: Redis + Starting Containers"
    progress_start_phase "4" "$phase4_eta"

    # Start Redis (local Docker or Kubernetes port-forward)
    local redis_pid=""
    if [ "$LOCAL_REDIS" = "true" ]; then
        echo -e "  ${CYAN}Using local Docker Redis${NC}"
        start_local_redis &
        redis_pid=$!
    else
        start_redis_portforward &
        redis_pid=$!
    fi

    # Separate backend and web clients from services_ready
    local backend_to_start=""
    local web_to_start=""
    for svc in $services_ready; do
        if is_web_client "$svc"; then
            web_to_start="$web_to_start $svc"
        else
            backend_to_start="$backend_to_start $svc"
        fi
    done
    backend_to_start=$(echo $backend_to_start | xargs)
    web_to_start=$(echo $web_to_start | xargs)

    # Add workers to backend services
    for worker_entry in $workers_ready; do
        local worker_name="${worker_entry%%:*}"
        backend_to_start="$backend_to_start $worker_name"
    done
    backend_to_start=$(echo $backend_to_start | xargs)

    # Start backend services first (using docker-compose.yml)
    if [ -n "$backend_to_start" ]; then
        local backend_count=$(echo $backend_to_start | wc -w | xargs)
        echo -e "  ${DIM}Starting $backend_count backend container(s): ${NC}${BOLD}$backend_to_start${NC}"
        local up_log="${LOG_DIR}/up_output.log"
        echo -e "  ${DIM}Running: docker compose up -d $backend_to_start${NC}"
        docker_compose up -d $backend_to_start 2>&1 | tee "$up_log"
        local up_status=${PIPESTATUS[0]}

        # Check for errors in output (be specific to Docker errors, avoid false positives from app logs)
        if grep -qE "^ERROR: |Cannot start container|failed to start|is not running" "$up_log" 2>/dev/null; then
            up_status=1
        fi

        if [ $up_status -eq 0 ]; then
            echo -e "  ${GREEN}✓${NC} Backend containers started"
        else
            echo -e "  ${YELLOW}⚠${NC} Some backend containers may have failed to start"
            echo -e "  ${DIM}Check the output above for details${NC}"
            echo -e "  ${DIM}Full log: $up_log${NC}"
        fi
    fi

    # Start web clients separately (using docker-compose-web.yml with host network)
    if [ -n "$web_to_start" ] && [ -f "docker-compose-web.yml" ]; then
        local web_count=$(echo $web_to_start | wc -w | xargs)
        echo -e "  ${DIM}Starting $web_count web client container(s): ${NC}${BOLD}$web_to_start${NC}"
        local up_web_log="${LOG_DIR}/up_web_output.log"
        echo -e "  ${DIM}Running: docker compose -f docker-compose-web.yml up -d $web_to_start${NC}"
        docker_compose -f docker-compose-web.yml up -d $web_to_start 2>&1 | tee "$up_web_log"
        local up_web_status=${PIPESTATUS[0]}

        if grep -qE "^ERROR: |Cannot start container|failed to start|is not running" "$up_web_log" 2>/dev/null; then
            up_web_status=1
        fi

        if [ $up_web_status -eq 0 ]; then
            echo -e "  ${GREEN}✓${NC} Web client containers started"
        else
            echo -e "  ${YELLOW}⚠${NC} Some web client containers may have failed to start"
            echo -e "  ${DIM}Check the output above for details${NC}"
            echo -e "  ${DIM}Full log: $up_web_log${NC}"
        fi
    fi

    # Wait for Redis setup to complete
    wait $redis_pid 2>/dev/null || true

    # Debug: show what containers were actually created
    local created_containers=$(docker ps -a --format "{{.Names}}" 2>/dev/null | tr '\n' ' ')
    if [ -n "$created_containers" ]; then
        echo -e "  ${DIM}Containers created: $created_containers${NC}"
    else
        echo -e "  ${YELLOW}⚠${NC} No containers were created"
    fi

    sleep 2
    end_phase "Phase 4: Redis + Starting Containers"
    progress_end_phase "4"

    # ========== Phase 5: Start Emulator Scripts ==========
    if [ -n "$emulators_ready" ]; then
        start_phase "Phase 5: Starting Android Emulators"
        progress_start_phase "5" "0"

        for emulator in $emulators_ready; do
            local repo=$(yq -r ".clients.android.\"${emulator}\".git_repo" $CONFIG_FILE 2>/dev/null)
            local script=$(yq -r ".clients.android.\"${emulator}\".script" $CONFIG_FILE 2>/dev/null)
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
        progress_end_phase "5"
    fi

    # Mark progress as complete
    progress_complete

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
        local port=$(get_service_config_path "$service" "port")

        if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${service}$"; then
            echo -e "${GREEN}✓${NC} ${BOLD}$service${NC}"
            echo -e "  └─ http://localhost:${port}"
            running_count=$((running_count + 1))
        else
            echo -e "${RED}✗${NC} ${BOLD}$service${NC} - failed"
            # Check if container exists but is not running
            if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${service}$"; then
                echo -e "    ${DIM}Container exists but not running. Last logs:${NC}"
                docker logs --tail=5 $service 2>&1 | sed 's/^/    /'
            else
                echo -e "    ${DIM}Container was not created. Check build output above.${NC}"
            fi
            failed_count=$((failed_count + 1))
        fi
    done

    # Show workers status (format: "worker:parent:dockerfile")
    for worker_entry in $workers_ready; do
        local worker=$(echo "$worker_entry" | cut -d: -f1)

        if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${worker}$"; then
            echo -e "${GREEN}✓${NC} ${BOLD}$worker${NC} ${BLUE}[worker]${NC}"
            running_count=$((running_count + 1))
        else
            echo -e "${RED}✗${NC} ${BOLD}$worker${NC} ${BLUE}[worker]${NC} - failed"
            # Check if container exists but is not running
            if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${worker}$"; then
                echo -e "    ${DIM}Container exists but not running. Last logs:${NC}"
                docker logs --tail=5 $worker 2>&1 | sed 's/^/    /'
            else
                echo -e "    ${DIM}Container was not created. Check build output above.${NC}"
            fi
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

    # Show dashboard link if running
    if [ "$DASHBOARD" = "true" ] && [ -f "$LOG_DIR/dashboard.pid" ]; then
        local dashboard_pid=$(cat "$LOG_DIR/dashboard.pid")
        if kill -0 $dashboard_pid 2>/dev/null; then
            echo ""
            echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
            echo -e "${CYAN}║${NC}  ${BOLD}Dashboard:${NC} \033]8;;http://localhost:9999\033\\${CYAN}${BOLD}http://localhost:9999${NC}\033]8;;\033\\  ${CYAN}║${NC}"
            echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
        fi
    fi

    echo ""
    echo -e "${CYAN}Commands:${NC}"
    echo -e "  make logs <service>  - View logs"
    echo -e "  make restart         - Restart all"
    echo -e "  make stop            - Stop all"
    [ "$DASHBOARD" = "true" ] && echo -e "  make dashboard       - Open dashboard (if closed)"
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
