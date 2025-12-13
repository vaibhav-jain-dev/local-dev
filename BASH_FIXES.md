# Bash Script Fixes for Compatibility

## Issues:
1. `declare: -A: invalid option` - Associative arrays require bash 4.0+
2. Most macOS systems ship with bash 3.2
3. Need to replace REPO_MAP and CATEGORIES associative arrays

## Solution:
Replace associative arrays with case statements:

```bash
# Instead of: REPO_MAP["oms-api"]="oms"
get_repo() {
  local svc="$1"
  case "$svc" in
    oms-api|oms-consumer|oms-scheduler|oms-worker) echo "oms" ;;
    oms-web) echo "oms-web" ;;
    health-api|health-celery-beat|health-celery-worker|health-consumer|health-s3-nginx) echo "health-api" ;;
    # ... etc
    *) echo "unknown" ;;
  esac
}

# Instead of: CATEGORIES["oms"]="oms-api oms-consumer..."
ALL_SERVICES="oms-api oms-consumer oms-scheduler oms-web oms-worker health-api health-celery-beat..."
```

## Additional Fixes Needed:
1. Add --fresh flag via getopts
2. Add IST date conversion
3. Add progress indicators
4. Fix GitHub API (already uses curl correctly)

## Implementation:
Create fetch_kube_v3.sh with bash 3.2+ compatibility
