#!/bin/bash
#############################################
# Weekly Retro — Decision Feedback Loop
#
# Pulls the last 7 days of activity across all projects, identifies
# decisions made this week, and asks Claude to evaluate whether
# each decision was validated or contradicted by subsequent work.
#
# Appends a "Week in Review" block to ~/agent/memory/learnings.md.
#
# Usage: weekly-retro.sh [--dry-run]
# Cron: 0 11 * * 0 ~/agent/scripts/weekly-retro.sh >> ~/agent/logs/weekly-retro.log 2>&1
#############################################

set -euo pipefail

export PATH="/opt/homebrew/bin:/opt/homebrew/opt/node@22/bin:/usr/local/bin:$PATH"

source "$(dirname "$0")/_common.sh"

LEARNINGS="$AGENT_DIR/memory/learnings.md"
BRIDGE="$AGENT_DIR/memory/session-bridge.md"
LOG_DIR="$AGENT_DIR/logs"
DATE=$(date '+%Y-%m-%d')
WEEK_AGO=$(date -v-7d '+%Y-%m-%d' 2>/dev/null || date -d "7 days ago" '+%Y-%m-%d' 2>/dev/null || echo "2000-01-01")
DRY_RUN=false
RETRO_FILE="$LOG_DIR/retro-$DATE.md"

if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
fi

mkdir -p "$LOG_DIR"

# Heartbeat — proves the script was invoked (even if Claude fails later)
echo "heartbeat: $(date)" >> "$LOG_DIR/retro-heartbeat.log"

echo "=== Weekly Retro — $DATE (since $WEEK_AGO) ==="
echo ""

# --- 1. Gather git activity across all projects ---

load_projects

ALL_COMMITS=""
for SPEC in "${PROJECTS[@]}"; do
    DIR="${SPEC%%:*}"
    NAME="${SPEC#*:}"

    if [ ! -d "$DIR/.git" ]; then
        continue
    fi

    COMMITS=$(cd "$DIR" && git log --oneline --since="$WEEK_AGO" 2>/dev/null || true)
    if [ -n "$COMMITS" ]; then
        COUNT=$(echo "$COMMITS" | wc -l | tr -d ' ')
        ALL_COMMITS="${ALL_COMMITS}

### $NAME ($COUNT commits)
$COMMITS"
        echo "$NAME: $COUNT commits this week"
    else
        echo "$NAME: no commits this week"
    fi
done

echo ""

# --- 2. Extract session bridge history for the week ---

SESSION_HISTORY=""
if [ -f "$BRIDGE" ]; then
    # Extract recent session entries (lines starting with [2026-03-...])
    SESSION_HISTORY=$(grep -A5 "^\[" "$BRIDGE" | head -60 || true)
fi

# --- 3. Find decisions made this week ---

DECISIONS_THIS_WEEK=""
for SPEC in "${PROJECTS[@]}"; do
    DIR="${SPEC%%:*}"
    NAME="${SPEC#*:}"
    DECISIONS_FILE="$DIR/docs/decisions.md"

    if [ ! -f "$DECISIONS_FILE" ]; then
        continue
    fi

    # Find entries with dates from this week
    WEEK_DECISIONS=$(grep -E "^\[2026-" "$DECISIONS_FILE" | while read -r line; do
        ENTRY_DATE=$(echo "$line" | grep -oE '^\[([0-9-]+)\]' | tr -d '[]')
        if [ -n "$ENTRY_DATE" ] && [ "$ENTRY_DATE" \> "$WEEK_AGO" ] || [ "$ENTRY_DATE" = "$WEEK_AGO" ]; then
            echo "$NAME: $line"
        fi
    done || true)

    if [ -n "$WEEK_DECISIONS" ]; then
        DECISIONS_THIS_WEEK="${DECISIONS_THIS_WEEK}
$WEEK_DECISIONS"
    fi
done

echo "Decisions found this week:"
if [ -n "$DECISIONS_THIS_WEEK" ]; then
    echo "$DECISIONS_THIS_WEEK" | head -20
else
    echo "  (none with dates in range)"
fi
echo ""

# --- 4. Build context file for Claude ---

{
    cat << 'HEADER'
# Weekly Retro Context

Analyze the following week of activity and produce a Week in Review.
HEADER

    echo ""
    echo "## Git Commits (last 7 days)"
    echo "$ALL_COMMITS"

    echo ""
    echo "## Session Notes"
    if [ -n "$SESSION_HISTORY" ]; then
        echo "$SESSION_HISTORY"
    else
        echo "(no session history found)"
    fi

    echo ""
    echo "## Decisions Made This Week"
    if [ -n "$DECISIONS_THIS_WEEK" ]; then
        echo "$DECISIONS_THIS_WEEK"
    else
        echo "(no new decisions logged)"
    fi

    echo ""
    echo "## Current Learnings"
    if [ -f "$LEARNINGS" ]; then
        cat "$LEARNINGS"
    fi
} > "$RETRO_FILE"

echo "Context file: $RETRO_FILE ($(wc -l < "$RETRO_FILE" | tr -d ' ') lines)"
echo ""

# --- 5. Ask Claude to evaluate ---

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would invoke claude -p for retro analysis."
    echo "Context saved to: $RETRO_FILE"
    echo "Run without --dry-run to execute."
else
    echo "=== Claude Retro Analysis ==="
    echo ""

    if ! command -v claude &> /dev/null; then
        echo "ERROR: claude CLI not found. PATH=$PATH"
        exit 1
    fi

    cd "$AGENT_DIR"

    RETRO_LOG="$LOG_DIR/retro-claude-$DATE.log"
    RETRO_PROMPT_FILE="$LOG_DIR/.retro-prompt-$DATE.txt"

    # Write prompt to temp file — heredoc inside $() breaks on apostrophes/em-dashes
    cat > "$RETRO_PROMPT_FILE" << 'RETROPROMPT'
You are reviewing the past week of development work across all projects.

Read the retro context file provided. Then:

1. Produce a "Week in Review" analysis (print to stdout) with these sections:
   - Validated Learnings: entries CONFIRMED by this weeks work (LEARNING_NAME -- evidence)
   - Challenged Learnings: entries CONTRADICTED or needing updates (LEARNING_NAME -- challenge)
   - New Pattern Candidates: 0-3 patterns not yet in learnings.md (PATTERN_NAME -- observed, frequency: one-off or recurring)
   - Surprise: one thing no existing learning predicted (or "No surprises")
   - Decision Health: for each decision this week, was it validated?

2. For any "Challenged Learnings" -- find the entry in ~/agent/memory/learnings.md
   and append a retro note on the Confidence line: "| Retro (DATE): [challenge description]"

3. For any "New Pattern Candidates" with frequency "recurring" -- add a new entry
   to ~/agent/memory/learnings.md under the appropriate section. Follow the existing
   format: SHORT_NAME (YYYY-MM): Description. Add Confidence: Medium and Validated date.
   Add the Validated date on the next line.

4. For learnings not touched by ANY commit this week across ALL projects
   (check commit messages and changed files for keyword overlap with the
   learning topic), AND that have not been validated in the last 2 retros,
   add "(stale?)" to the Confidence line.

5. Update the "Last retro:" date in the learnings.md header to todays date.

6. If learnings.md is at 38+ entries, prune the weakest "prune candidate" entries
   to stay under 40.

Be ruthlessly concise in your stdout output. No filler. Only items with real evidence.
RETROPROMPT

    FULL_PROMPT="Read the file at $RETRO_FILE, then follow these instructions: $(cat "$RETRO_PROMPT_FILE")"

    echo "Invoking Claude CLI for retro analysis..."
    if claude -p "$FULL_PROMPT" --allowedTools 'Edit,Read,Write,Bash' --max-turns 15 2>&1 | tee "$RETRO_LOG"; then
        echo "Claude invocation succeeded. Output saved to: $RETRO_LOG"
    else
        EXIT_CODE=$?
        echo "Claude invocation failed (exit $EXIT_CODE). Context saved at: $RETRO_FILE"
        echo "Run manually: cd ~/agent && /project:retro"
    fi

    rm -f "$RETRO_PROMPT_FILE"

    # Auto-commit any changes to learnings.md
    cd "$AGENT_DIR"
    if ! git diff --quiet memory/learnings.md 2>/dev/null; then
        git add memory/learnings.md
        git commit -m "auto: weekly retro — $DATE" --no-verify
        echo "Committed learnings.md changes"
    fi

    echo ""
    echo "Full Claude output saved to: $LOG_DIR/retro-claude-$DATE.log"
fi

echo ""
echo "=== Weekly Retro Complete — $DATE ==="
