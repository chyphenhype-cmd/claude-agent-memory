#!/bin/bash
#############################################
# Weekly Digest — Cross-Project Learning Escalation
#
# Delegates pattern extraction to Claude CLI (LLM task, not bash grep).
# Bash handles: health metrics, staleness checks, capacity warnings.
# Claude handles: semantic dedup, pattern quality, promotion recommendations.
#
# Run via cron every Sunday:
#   0 10 * * 0 ~/agent/scripts/weekly-digest.sh >> ~/agent/logs/weekly-digest.log 2>&1
#
# Usage: weekly-digest.sh [--dry-run]
#############################################

set -euo pipefail

# Cron runs with minimal PATH — ensure homebrew tools are available
export PATH="/opt/homebrew/bin:/opt/homebrew/opt/node@22/bin:/usr/local/bin:$PATH"

source "$(dirname "$0")/_common.sh"

LEARNINGS_FILE="$AGENT_DIR/memory/learnings.md"
LOG_DIR="$AGENT_DIR/logs"
DATE=$(date '+%Y-%m-%d')
DRY_RUN=false

if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
fi

mkdir -p "$LOG_DIR"

# Heartbeat — proves the script was invoked (even if Claude fails later)
echo "heartbeat: $(date)" >> "$LOG_DIR/digest-heartbeat.log"

echo "=== Weekly Digest — $DATE ==="
echo ""

# --- 1. Quick Health Metrics ---

echo "=== Pipeline Health ==="

if [ -f "$LEARNINGS_FILE" ]; then
    TOTAL=$(grep -cE "^[A-Z][A-Z _]+" "$LEARNINGS_FILE" 2>/dev/null || echo "0")
    echo "Global learnings: $TOTAL / 40 max"
    [ "$TOTAL" -gt 35 ] && echo "  WARNING: Approaching cap. Prune before adding."
fi

BRIDGE="$AGENT_DIR/memory/session-bridge.md"
if [ -f "$BRIDGE" ]; then
    LAST_UPDATE=$(grep -o 'Last updated: [0-9-]*' "$BRIDGE" | head -1 | sed 's/Last updated: //')
    if [ -n "$LAST_UPDATE" ]; then
        DAYS_AGO=$(( ($(date +%s) - $(date -j -f "%Y-%m-%d" "$LAST_UPDATE" +%s 2>/dev/null || echo $(date +%s))) / 86400 ))
        echo "Session bridge: ${DAYS_AGO}d old"
        [ "$DAYS_AGO" -gt 7 ] && echo "  WARNING: Stale session bridge."
    fi
fi

UNCOMMITTED=$(git -C "$AGENT_DIR" status --porcelain memory/ 2>/dev/null | wc -l | tr -d ' ')
[ "$UNCOMMITTED" -gt 0 ] && echo "Uncommitted brain files: $UNCOMMITTED"

echo ""

# --- 2. Delegate to Claude for Pattern Extraction ---

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would invoke claude -p for pattern extraction."
    echo "Run without --dry-run to execute."
else
    echo "=== Claude Pattern Extraction ==="
    echo ""

    if ! command -v claude &> /dev/null; then
        echo "ERROR: claude CLI not found. PATH=$PATH"
        exit 1
    fi

    cd "$AGENT_DIR"

    # --- Gather autopilot intelligence for Claude context ---
    load_autopilot_projects
    AP_CONTEXT=""
    for AP_SPEC in "${AUTOPILOT_PROJECTS[@]}"; do
        AP_DIR="${AP_SPEC%%:*}/.autopilot"
        AP_NAME="${AP_SPEC#*:}"

        if [ ! -d "$AP_DIR" ]; then continue; fi

        AP_CONTEXT="${AP_CONTEXT}

### ${AP_NAME} Autopilot Intelligence"

        # Last 20 intelligence entries
        if [ -f "$AP_DIR/intelligence.jsonl" ]; then
            AP_CONTEXT="${AP_CONTEXT}
#### Recent Cycles (last 20):
$(tail -20 "$AP_DIR/intelligence.jsonl" | while IFS= read -r line; do
    echo "$line" | jq -r '"- Cycle \(.cycle) [\(.mode)] \(.result): \(.summary[0:120]) — Learning: \(.learning[0:150])"' 2>/dev/null || echo "- (unparseable entry)"
done)"
        fi

        # Last 10 failed attempts
        if [ -f "$AP_DIR/failed_attempts.md" ]; then
            FAILURES=$(grep -E "^- Cycle" "$AP_DIR/failed_attempts.md" | tail -10)
            if [ -n "$FAILURES" ]; then
                AP_CONTEXT="${AP_CONTEXT}
#### Failed Attempts:
${FAILURES}"
            fi
        fi

        # Learnings summary
        if [ -f "$AP_DIR/LEARNINGS_SUMMARY.md" ]; then
            AP_CONTEXT="${AP_CONTEXT}
#### Learnings Summary:
$(head -60 "$AP_DIR/LEARNINGS_SUMMARY.md")"
        fi
    done

    # Build dynamic pattern tracker list
    load_projects_with_keys
    TRACKER_LIST=""
    for SPEC in "${ALL_PROJECTS[@]}"; do
        IFS=: read -r _DIR _NAME KEY <<< "$SPEC"
        TRACKER_PATH="$CLAUDE_PROJECTS/$KEY/memory/patterns.md"
        if [ -f "$TRACKER_PATH" ]; then
            TRACKER_LIST="${TRACKER_LIST}
- ${TRACKER_PATH}"
        fi
    done

    DIGEST_PROMPT=$(cat << PROMPT
${AP_CONTEXT:+## Autopilot Intelligence Context
$AP_CONTEXT

---

}Read these files:
- ~/agent/memory/learnings.md (unified patterns + anti-patterns)${TRACKER_LIST}

Then:
1. Identify patterns in project trackers that appear in 2+ projects — promote to
   learnings.md under the appropriate section if not already there. Follow existing
   format. Mark source entries in project tracker as promoted.
2. Identify patterns at seen:2+ still at tier "observe" — escalate tier to "validate"
   and add to the project's docs/decisions.md if it exists.
3. Check learnings.md for entries that can be merged (semantic duplicates) — merge them.
4. Check for learnings.md entries with no matching pattern in any project tracker
   (orphaned globals) — add "(verify)" marker to the Confidence line.
5. Report what you changed (stdout) and what you left alone.
6. Check autopilot intelligence (above) for patterns not yet in any tracker or learnings.md.
   If a pattern appears in 3+ autopilot cycles (same "learning" theme), add it to
   the appropriate project's pattern tracker at tier "observe" with the cycle count
   as the "seen" value.
7. Check autopilot failed_attempts for recurring failure types. If a failure type
   appears 3+ times, add to learnings.md under the appropriate section.

Be concise — actionable findings only. If nothing needs changing, say so.
PROMPT
)

    DIGEST_LOG="$LOG_DIR/digest-claude-$DATE.log"
    echo "Invoking Claude CLI for pattern extraction..."
    if claude -p "$DIGEST_PROMPT" --allowedTools 'Edit,Read,Write,Bash' --max-turns 15 2>&1 | tee "$DIGEST_LOG"; then
        echo "Claude invocation succeeded. Output saved to: $DIGEST_LOG"
    else
        EXIT_CODE=$?
        echo "Claude invocation failed (exit $EXIT_CODE). Output saved to: $DIGEST_LOG"
        echo "Run manually: cd ~/agent && /project:digest"
    fi

    # Auto-commit changes to learnings.md (pattern trackers are in ~/.claude, persist without git)
    cd "$AGENT_DIR"
    if ! git diff --quiet memory/learnings.md 2>/dev/null; then
        git add memory/learnings.md
        git commit -m "auto: weekly digest — $DATE" --no-verify
        echo "Committed learnings.md changes"
    else
        echo "No changes to learnings.md"
    fi
fi

echo ""
echo "=== Digest Complete — $DATE ==="
