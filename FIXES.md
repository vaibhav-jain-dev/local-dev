# Critical Fixes for fetch_kube Scripts

## Issues Found:
1. Tag extraction showing "30}}}}" - Jinja2 template artifacts in cache
2. Dates in ISO format (2025-11-07T13:36:51Z) - need IST human-readable
3. No --fresh flag to bypass cache
4. Bash error: `declare: -A: invalid option` - incompatible with bash < 4.0
5. Python getting 401 from GitHub API
6. No clear progress indicators in Python

## Solutions:

### 1. Tag Extraction Issue
- Problem: Jinja2 template syntax `}}}}` getting into cache files
- Fix: Clear cache before running, validate extracted tags

### 2. Date Formatting
- Convert ISO timestamps to IST (UTC+5:30)
- Format: "07 Nov 2025, 07:06 PM IST"

### 3. --fresh Flag
- Add argparse to both scripts
- When --fresh is used, skip cache reads

### 4. Bash Associative Arrays
- Replace with case statements or indexed arrays
- Works on bash 3.2+ (macOS default)

### 5. GitHub API 401 Error
- Issue: Token format or missing `token` prefix
- Fix: Use `Authorization: token GITHUB_TOKEN` (not Bearer)

### 6. Progress Indicators
- Add tqdm or simple print statements
- Show: X/Y services processed

## Implementation Priority:
1. Fix GitHub API auth (401 error) - CRITICAL
2. Fix bash compatibility (declare -A) - CRITICAL
3. Add human-readable IST dates - HIGH
4. Add --fresh flag - MEDIUM
5. Add progress bars - MEDIUM
6. Fix tag extraction cache - LOW (clear cache manually)
