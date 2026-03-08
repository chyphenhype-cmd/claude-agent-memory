#!/bin/bash
#############################################
# Cross-Project Session Capture
#
# Runs as the global Stop hook. Replaces capture-session-bridge.sh
# (which only captured the current project).
#
# Jobs:
#   1. Snapshot ALL projects (commits, patterns, activity)
#   2. Detail the CURRENT project's recent commits
#   3. Update session-bridge.md AUTO-CAPTURE block
#   4. Output session-end reminder
#############################################

source "$(dirname "$0")/_common.sh"

BRIDGE_FILE="$AGENT_DIR/memory/session-bridge.md"
BRAIN_DIR="$AGENT_DIR/memory"
PROJECT_DIR=$(pwd)
PROJECT_NAME=$(basename "$PROJECT_DIR")
DATE=$(date '+%Y-%m-%d %H:%M')
DATE_SHORT=$(date '+%Y-%m-%d')

# Refresh computed project status before snapshot
bash "$AGENT_DIR/scripts/snapshot-status.sh" 2>/dev/null || true

# Load projects from conf
load_projects

# --- 1. Build cross-project snapshot ---

SNAPSHOT_TABLE="| Project | Last Commit | 24h | 7d | Patterns (O/V/E) | Status |\n"
SNAPSHOT_TABLE="${SNAPSHOT_TABLE}|---------|-------------|-----|-----|------------------|--------|\n"

for SPEC in "${PROJECTS[@]}"; do
    DIR="${SPEC%%:*}"
    NAME="${SPEC#*:}"

    if [ ! -d "$DIR" ]; then
        continue
    fi

    COMMITS_24H=$(count_commits "$DIR" "24 hours ago")
    COMMITS_7D=$(count_commits "$DIR" "7 days ago")
    PATTERNS=$(pattern_counts "$DIR")
    DAYS_IDLE=$(days_since_last_commit "$DIR")

    # Last commit summary
    if [ -d "$DIR/.git" ]; then
        LAST_COMMIT=$(git -C "$DIR" log -1 --format='%cd — %s' --date=format:'%b %d' 2>/dev/null | head -c 60)
    else
        LAST_COMMIT="no git"
    fi

    # Status label
    if [ "$DAYS_IDLE" = "N/A" ]; then
        STATUS="unknown"
    elif [ "$DAYS_IDLE" -le 1 ]; then
        STATUS="active"
    elif [ "$DAYS_IDLE" -le 5 ]; then
        STATUS="idle (${DAYS_IDLE}d)"
    else
        STATUS="dormant (${DAYS_IDLE}d)"
    fi

    SNAPSHOT_TABLE="${SNAPSHOT_TABLE}| ${NAME} | ${LAST_COMMIT} | ${COMMITS_24H} | ${COMMITS_7D} | ${PATTERNS} | ${STATUS} |\n"
done

# --- 2. Current project commit detail (like old capture-session-bridge.sh) ---

CURRENT_DETAIL=""
if [ -d "$PROJECT_DIR/.git" ]; then
    # Extract last capture timestamp
    LAST_CAPTURE=$(grep -o 'Last auto-capture: [0-9-]* [0-9:]*' "$BRIDGE_FILE" 2>/dev/null | head -1 | sed 's/Last auto-capture: //')

    if [ -n "$LAST_CAPTURE" ]; then
        RECENT_COMMITS=$(git -C "$PROJECT_DIR" log --oneline --since="$LAST_CAPTURE" 2>/dev/null)
    else
        RECENT_COMMITS=$(git -C "$PROJECT_DIR" log --oneline --since="4 hours ago" 2>/dev/null)
    fi

    if [ -n "$RECENT_COMMITS" ]; then
        COMMIT_COUNT=$(echo "$RECENT_COMMITS" | wc -l | tr -d ' ')

        # Count by category
        FEAT_COUNT=$(echo "$RECENT_COMMITS" | grep -ciE '^[a-f0-9]+ feat:' || true)
        FIX_COUNT=$(echo "$RECENT_COMMITS" | grep -ciE '^[a-f0-9]+ fix:' || true)

        BREAKDOWN=""
        [ "$FEAT_COUNT" -gt 0 ] 2>/dev/null && BREAKDOWN="${BREAKDOWN}${FEAT_COUNT} features, "
        [ "$FIX_COUNT" -gt 0 ] 2>/dev/null && BREAKDOWN="${BREAKDOWN}${FIX_COUNT} fixes, "
        BREAKDOWN=$(echo "$BREAKDOWN" | sed 's/, $//')

        KEY_COMMITS=$(echo "$RECENT_COMMITS" | grep -iE '^[a-f0-9]+ (feat|fix|improve):' | head -5 | sed 's/^[a-f0-9]* /  - /')

        CURRENT_DETAIL="<!-- Current session ($PROJECT_NAME): $COMMIT_COUNT commits"
        [ -n "$BREAKDOWN" ] && CURRENT_DETAIL="$CURRENT_DETAIL ($BREAKDOWN)"
        CURRENT_DETAIL="$CURRENT_DETAIL -->"
        if [ -n "$KEY_COMMITS" ]; then
            CURRENT_DETAIL="$CURRENT_DETAIL
<!-- Key changes:
$KEY_COMMITS
-->"
        fi
    fi
fi

# --- 3. Detect brain file changes ---

BRAIN_CHANGES=""
for BFILE in "$BRAIN_DIR"/*.md; do
    FNAME=$(basename "$BFILE")
    if git -C "$AGENT_DIR" diff --name-only HEAD 2>/dev/null | grep -q "memory/$FNAME"; then
        BRAIN_CHANGES="${BRAIN_CHANGES}  - ${FNAME} (uncommitted changes)\n"
    fi
done

# --- 4. Update session-bridge.md ---

# Update the "Last updated:" line
sed -i '' "s/^Last updated: .*/Last updated: $DATE_SHORT/" "$BRIDGE_FILE"

# Remove existing auto-capture section
sed -i '' '/^<!-- AUTO-CAPTURE START -->/,/^<!-- AUTO-CAPTURE END -->/d' "$BRIDGE_FILE"

# Write the new auto-capture block
{
    echo "<!-- AUTO-CAPTURE START -->"
    echo "<!-- Last auto-capture: $DATE -->"
    echo "<!-- Cross-Project Snapshot:"
    echo -e "$SNAPSHOT_TABLE"
    echo "-->"
    if [ -n "$CURRENT_DETAIL" ]; then
        echo "$CURRENT_DETAIL"
    fi
    if [ -n "$BRAIN_CHANGES" ]; then
        echo "<!-- Brain files changed:"
        echo -e "$BRAIN_CHANGES" | sed '/^$/d'
        echo "-->"
    fi
    echo "<!-- AUTO-CAPTURE END -->"
} >> "$BRIDGE_FILE"

# --- 5. Check if retro is overdue ---
RETRO_NUDGE=""
LAST_RETRO=$(grep -o 'Last retro: [0-9-]*' "$AGENT_DIR/memory/learnings.md" 2>/dev/null | head -1 | sed 's/Last retro: //')
if [ -n "$LAST_RETRO" ]; then
    RETRO_DAYS=$(( ($(date +%s) - $(date -j -f "%Y-%m-%d" "$LAST_RETRO" +%s 2>/dev/null || echo $(date +%s))) / 86400 ))
    [ "$RETRO_DAYS" -gt 7 ] && RETRO_NUDGE="  Retro overdue (${RETRO_DAYS}d). Run: cd ~/agent && /project:retro"
fi

# --- 6. Output session-end prompt ---

# Detect corrections and architectural changes in this session
FIXES=$(git -C "$PROJECT_DIR" log --oneline --since="2 hours ago" 2>/dev/null | grep -ciE "fix:|revert:|correct:" || true)
ARCH=$(git -C "$PROJECT_DIR" diff --stat HEAD~5..HEAD 2>/dev/null | grep -ciE "schema|config|CLAUDE|decisions|architecture" || true)

cat >&2 << PROMPT

━━━ Session Wrap-Up ━━━
$DATE | $PROJECT_NAME | Cross-project snapshot updated
${RETRO_NUDGE:+$RETRO_NUDGE
}
Did you work WITH the user? Update Recent Sessions in session-bridge.md!
Did Active Work or project status change? Update session-bridge.md sections b-d!
Phase completed? Direction changed? -> Active Work MUST be updated.
Built something significant? -> Update the project's docs/evolution.md
PROMPT

# --- 7. Auto-commit brain files if changed ---
BRAIN_MODIFIED=$(git -C "$AGENT_DIR" diff --name-only HEAD -- memory/ 2>/dev/null)
BRAIN_UNTRACKED=$(git -C "$AGENT_DIR" ls-files --others --exclude-standard -- memory/ 2>/dev/null)

if [ -n "$BRAIN_MODIFIED" ] || [ -n "$BRAIN_UNTRACKED" ]; then
    git -C "$AGENT_DIR" add memory/ 2>/dev/null
    git -C "$AGENT_DIR" commit -m "chore: Auto-commit brain files on session end" --no-gpg-sign 2>/dev/null && \
        echo "Brain files auto-committed." >&2 || true
fi

# Evidence-based skill prompts instead of generic reminders
if [ "$FIXES" -gt 0 ] 2>/dev/null; then
    echo "*** $FIXES fix/revert commits detected — self-improve should have captured these patterns ***" >&2
fi
if [ "$ARCH" -gt 0 ] 2>/dev/null; then
    echo "*** Architectural files changed — memory-capture should have fired ***" >&2
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━" >&2
