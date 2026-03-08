#!/bin/bash
#############################################
# Shared utilities for agent hub scripts
#############################################

# Resolve the agent hub root directory
AGENT_DIR="${AGENT_DIR:-$HOME/agent}"
PROJECTS_CONF="${PROJECTS_CONF:-$AGENT_DIR/projects.conf}"
CLAUDE_PROJECTS="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"

# Load projects from projects.conf into PROJECTS array
# Format per entry: "expanded_path:DisplayName"
load_projects() {
    PROJECTS=()
    if [ ! -f "$PROJECTS_CONF" ]; then
        echo "WARNING: $PROJECTS_CONF not found. Run setup.sh or create it manually." >&2
        return 1
    fi
    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        # Expand ~ to $HOME
        local path="${line%%:*}"
        local name="${line#*:}"
        path="${path/#\~/$HOME}"
        PROJECTS+=("$path:$name")
    done < "$PROJECTS_CONF"
}

# Load only projects that have autopilot intelligence
load_autopilot_projects() {
    AUTOPILOT_PROJECTS=()
    load_projects || return 1
    for SPEC in "${PROJECTS[@]}"; do
        local dir="${SPEC%%:*}"
        if [ -d "$dir/.autopilot" ] && [ -f "$dir/.autopilot/intelligence.jsonl" ]; then
            AUTOPILOT_PROJECTS+=("$SPEC")
        fi
    done
}

# Load projects with Claude memory key (path:name:key format)
# Key = absolute path with / replaced by -
load_projects_with_keys() {
    ALL_PROJECTS=()
    load_projects || return 1
    for SPEC in "${PROJECTS[@]}"; do
        local dir="${SPEC%%:*}"
        local name="${SPEC#*:}"
        local key=$(echo "$dir" | sed 's|/|-|g')
        ALL_PROJECTS+=("$dir:$name:$key")
    done
}

# --- Common helper functions ---

# Count commits in a time range
count_commits() {
    local dir="$1" since="$2"
    if [ -d "$dir/.git" ]; then
        git -C "$dir" log --oneline --since="$since" 2>/dev/null | wc -l | tr -d ' '
    else
        echo "0"
    fi
}

# Get pattern counts (Observe/Validate/Enforce) for a project directory
pattern_counts() {
    local dir="$1"
    local memory_key=$(echo "$dir" | sed 's|/|-|g')
    local tracker="$CLAUDE_PROJECTS/$memory_key/memory/patterns.md"

    if [ ! -f "$tracker" ]; then
        printf "0/0/0"
        return
    fi

    local obs val enf
    obs=$(grep -c "tier: observe" "$tracker" 2>/dev/null || true)
    val=$(grep -c "tier: validate" "$tracker" 2>/dev/null || true)
    enf=$(grep -c "tier: enforce" "$tracker" 2>/dev/null || true)
    obs=$(echo "${obs:-0}" | tr -d '[:space:]')
    val=$(echo "${val:-0}" | tr -d '[:space:]')
    enf=$(echo "${enf:-0}" | tr -d '[:space:]')
    printf "%s/%s/%s" "$obs" "$val" "$enf"
}

# Days since last commit in a git repo
days_since_last_commit() {
    local dir="$1"
    if [ ! -d "$dir/.git" ]; then
        echo "N/A"
        return
    fi
    local last_epoch=$(git -C "$dir" log -1 --format=%ct 2>/dev/null)
    if [ -z "$last_epoch" ]; then
        echo "N/A"
        return
    fi
    local now_epoch=$(date +%s)
    echo $(( (now_epoch - last_epoch) / 86400 ))
}

# Last commit info (date + message, truncated)
last_commit_info() {
    local dir="$1"
    if [ -d "$dir/.git" ]; then
        git -C "$dir" log -1 --format='%cd — %s' --date=format:'%b %d' 2>/dev/null | head -c 60
    else
        echo "N/A"
    fi
}

# Safe grep — returns empty string instead of failing with set -e
sgrep() {
    grep "$@" 2>/dev/null || true
}
