#!/bin/bash
#############################################
# Daily Pulse — Cross-Project Activity Dashboard
#
# Generates ~/agent/memory/project-pulse.md with a snapshot of
# all project activity, brain health, and flags.
#
# Runs daily at 7am via launchd. Also callable manually.
#############################################

set -euo pipefail

source "$(dirname "$0")/_common.sh"

PULSE_FILE="$AGENT_DIR/memory/project-pulse.md"
BRIDGE_FILE="$AGENT_DIR/memory/session-bridge.md"
LEARNINGS_FILE="$AGENT_DIR/memory/learnings.md"
LOG_DIR="$AGENT_DIR/logs"
DATE=$(date '+%Y-%m-%d %H:%M')
TOMORROW=$(date -v+1d '+%Y-%m-%d 07:00' 2>/dev/null || date -d "+1 day" '+%Y-%m-%d 07:00' 2>/dev/null || echo "tomorrow 7am")

mkdir -p "$LOG_DIR"
echo "pulse: $(date)" >> "$LOG_DIR/pulse-heartbeat.log"

# Refresh computed project status alongside pulse
bash "$AGENT_DIR/scripts/snapshot-status.sh" 2>/dev/null || true

# Compile intelligence briefing from all sources
bash "$AGENT_DIR/scripts/knowledge-compile.sh" 2>/dev/null || true

# Load projects from conf
load_projects

# --- Helper functions (project-specific, not in _common.sh) ---

top_commits_24h() {
    local dir="$1"
    if [ -d "$dir/.git" ]; then
        git -C "$dir" log --oneline --since="24 hours ago" 2>/dev/null | grep -iE '^[a-f0-9]+ (feat|fix|improve):' | head -3 | sed 's/^[a-f0-9]* /  - /' || true
    fi
}

last_session_date() {
    local project_name="$1"
    # Search Recent Sessions for this project name
    grep -i "\*\*${project_name}" "$BRIDGE_FILE" 2>/dev/null | head -1 | grep -oE '^\[?[0-9]{4}-[0-9]{2}-[0-9]{2}\]?' | tr -d '[]' || echo "unknown"
}

# --- Build activity table ---

ACTIVITY_TABLE="| Project | Status | Last Commit | 24h | 7d | Patterns |\n"
ACTIVITY_TABLE="${ACTIVITY_TABLE}|---------|--------|-------------|-----|-----|----------|\n"

COMMIT_DETAILS=""
FLAGS=""

for SPEC in "${PROJECTS[@]}"; do
    DIR="${SPEC%%:*}"
    NAME="${SPEC#*:}"

    if [ ! -d "$DIR" ]; then continue; fi

    C24=$(count_commits "$DIR" "24 hours ago")
    C7D=$(count_commits "$DIR" "7 days ago")
    PATTERNS=$(pattern_counts "$DIR")
    DAYS_IDLE=$(days_since_last_commit "$DIR")
    LAST=$(last_commit_info "$DIR")
    TOPS=$(top_commits_24h "$DIR")

    # Status
    if [ "$DAYS_IDLE" = "N/A" ]; then
        STATUS="unknown"
    elif [ "$DAYS_IDLE" -le 1 ]; then
        STATUS="active"
    elif [ "$DAYS_IDLE" -le 5 ]; then
        STATUS="idle (${DAYS_IDLE}d)"
    else
        STATUS="dormant (${DAYS_IDLE}d)"
        FLAGS="${FLAGS}- ${NAME} has been dormant for ${DAYS_IDLE} days\n"
    fi

    ACTIVITY_TABLE="${ACTIVITY_TABLE}| ${NAME} | ${STATUS} | ${LAST} | ${C24} | ${C7D} | ${PATTERNS} |\n"

    if [ -n "$TOPS" ]; then
        COMMIT_DETAILS="${COMMIT_DETAILS}\n**${NAME}** (${C24} commits in 24h):\n${TOPS}\n"
    fi
done

# --- Brain health ---

# Last digest
LAST_DIGEST="unknown"
if [ -f "$LOG_DIR/digest-heartbeat.log" ]; then
    LAST_DIGEST=$(tail -1 "$LOG_DIR/digest-heartbeat.log" | sed 's/heartbeat: //')
fi

# Last retro
LAST_RETRO=$(grep -o 'Last retro: [0-9-]*' "$LEARNINGS_FILE" 2>/dev/null | head -1 | sed 's/Last retro: //' || echo "unknown")
if [ -n "$LAST_RETRO" ] && [ "$LAST_RETRO" != "unknown" ]; then
    RETRO_DAYS=$(( ($(date +%s) - $(date -j -f "%Y-%m-%d" "$LAST_RETRO" +%s 2>/dev/null || echo $(date +%s))) / 86400 ))
    if [ "$RETRO_DAYS" -gt 7 ]; then
        RETRO_STATUS="OVERDUE (${RETRO_DAYS}d ago)"
        FLAGS="${FLAGS}- Retro is overdue (last: ${LAST_RETRO})\n"
    else
        RETRO_STATUS="$LAST_RETRO"
    fi
else
    RETRO_STATUS="never run"
    FLAGS="${FLAGS}- Retro has never been run\n"
fi

# Digest overdue check
if [ "$LAST_DIGEST" != "unknown" ]; then
    DIGEST_STATUS="$LAST_DIGEST"
else
    DIGEST_STATUS="never run"
    FLAGS="${FLAGS}- Digest has never been run\n"
fi

# Learnings count
LEARNINGS_COUNT=$(grep -cE "^[A-Z][A-Z _]+" "$LEARNINGS_FILE" 2>/dev/null | tr -d '[:space:]' || echo "0")
if [ "$LEARNINGS_COUNT" -gt 35 ]; then
    FLAGS="${FLAGS}- Learnings approaching cap: ${LEARNINGS_COUNT}/40\n"
fi

# Session bridge freshness
BRIDGE_DATE=$(grep "Last updated:" "$BRIDGE_FILE" 2>/dev/null | head -1 | sed 's/Last updated: //')
if [ -n "$BRIDGE_DATE" ]; then
    BRIDGE_DAYS=$(( ($(date +%s) - $(date -j -f "%Y-%m-%d" "$BRIDGE_DATE" +%s 2>/dev/null || echo $(date +%s))) / 86400 ))
    if [ "$BRIDGE_DAYS" -gt 3 ]; then
        BRIDGE_STATUS="stale (${BRIDGE_DAYS}d)"
        FLAGS="${FLAGS}- Session bridge is ${BRIDGE_DAYS} days old\n"
    elif [ "$BRIDGE_DAYS" -eq 0 ]; then
        BRIDGE_STATUS="current (today)"
    else
        BRIDGE_STATUS="${BRIDGE_DAYS}d ago"
    fi
else
    BRIDGE_STATUS="unknown"
fi

# Uncommitted brain files
UNCOMMITTED=$(git -C "$AGENT_DIR" status --porcelain memory/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$UNCOMMITTED" -gt 0 ]; then
    FLAGS="${FLAGS}- ${UNCOMMITTED} uncommitted brain file(s)\n"
fi

# Learnings capacity warning
if [ "$LEARNINGS_COUNT" -ge 38 ]; then
    FLAGS="${FLAGS}- Learnings at ${LEARNINGS_COUNT}/40 — prune before adding more\n"
fi

# Staleness: check if evolution.md files are older than last commit
for SPEC in "${PROJECTS[@]}"; do
    DIR="${SPEC%%:*}"
    NAME="${SPEC#*:}"
    EVO="$DIR/docs/evolution.md"
    if [ -f "$EVO" ]; then
        EVO_MOD=$(stat -f %m "$EVO" 2>/dev/null || stat -c %Y "$EVO" 2>/dev/null)
        LAST_COMMIT_EPOCH=$(git -C "$DIR" log -1 --format=%ct 2>/dev/null || echo 0)
        if [ "$LAST_COMMIT_EPOCH" -gt "$EVO_MOD" ]; then
            COMMITS_SINCE=$(git -C "$DIR" log --oneline --since="@$EVO_MOD" 2>/dev/null | wc -l | tr -d ' ')
            if [ "$COMMITS_SINCE" -gt 5 ]; then
                FLAGS="${FLAGS}- ${NAME} evolution.md may be stale (${COMMITS_SINCE} commits since last update)\n"
            fi
        fi
    fi
done

# --- Write pulse file ---

cat > "$PULSE_FILE" << EOF
# Project Pulse
Generated: ${DATE} | Next: ${TOMORROW}

## Activity
$(echo -e "$ACTIVITY_TABLE")
$(if [ -n "$COMMIT_DETAILS" ]; then echo -e "### Recent Highlights$COMMIT_DETAILS"; fi)

## Brain Health
- Digest: ${DIGEST_STATUS}
- Retro: ${RETRO_STATUS}
- Learnings: ${LEARNINGS_COUNT}/40
- Session bridge: ${BRIDGE_STATUS}

## Flags
$(if [ -n "$FLAGS" ]; then echo -e "$FLAGS"; else echo "No flags — system healthy."; fi)
EOF

echo "Pulse generated: $PULSE_FILE"
