#!/bin/bash
#############################################
# Bootstrap a new project into the agent system
#
# Wires up a project directory so it connects to the global brain:
# 1. Appends @imports to CLAUDE.md (if not already present)
# 2. Asks project type and adds relevant playbook @imports
# 3. Registers project in ~/agent/CLAUDE.md
# 4. Creates Claude memory directory with pattern tracker
# 5. Scaffolds docs/decisions.md and docs/evolution.md
# 6. Creates .claude/settings.local.json with standard hooks
#
# Usage: ./bootstrap-project.sh <project-dir> [knowledge-file]
#   project-dir: absolute or relative path to project
#   knowledge-file: path within project for learnings (default: docs/decisions.md)
#
# Example: ./bootstrap-project.sh ~/Projects/new-app docs/decisions.md
#############################################

set -euo pipefail

source "$(dirname "$0")/_common.sh"

PROJECT_DIR="${1:?Usage: ./bootstrap-project.sh <project-dir> [knowledge-file]}"
KNOWLEDGE_FILE="${2:-docs/decisions.md}"

# Resolve to absolute path
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)
PROJECT_NAME=$(basename "$PROJECT_DIR")

AGENT_CLAUDE="$AGENT_DIR/CLAUDE.md"
PLAYBOOKS_DIR="$AGENT_DIR/memory/playbooks"

# Derive Claude memory path
MEMORY_KEY=$(echo "$PROJECT_DIR" | sed 's|/|-|g')
CLAUDE_MEMORY_DIR="$HOME/.claude/projects/$MEMORY_KEY/memory"

echo "Bootstrapping: $PROJECT_NAME"
echo "  Path: $PROJECT_DIR"
echo "  Knowledge file: $KNOWLEDGE_FILE"
echo "  Claude memory: $CLAUDE_MEMORY_DIR"
echo ""

# 1. Check CLAUDE.md exists
if [ ! -f "$PROJECT_DIR/CLAUDE.md" ]; then
    echo "WARNING: No CLAUDE.md found in $PROJECT_DIR"
    echo "  Create one first, then re-run this script."
    exit 1
fi

# 2. Ask project type for playbook selection
echo "What kind of project? (Enter number)"
echo "  1) Web app (React + Express API)"
echo "  2) Scraper / Data pipeline (Python + Playwright)"
echo "  3) CLI tool / Script"
echo "  4) Bot (Telegram, Discord, etc.)"
echo "  5) Other / Skip playbooks"
read -r -p "> " PROJECT_TYPE

# Map project type to relevant playbooks
PLAYBOOK_IMPORTS=""
case "$PROJECT_TYPE" in
    1)
        PLAYBOOK_IMPORTS="@~/agent/memory/playbooks/api-resilience.md — API retry, caching, rate limiting patterns
@~/agent/memory/playbooks/sqlite-patterns.md — DAL, WAL mode, JSON columns, transactions
@~/agent/memory/playbooks/react-frontend.md — React Query, SSE, command palette, dark theme
@~/agent/memory/playbooks/testing-patterns.md — offline testing, optional imports, event bus testing"
        ;;
    2)
        PLAYBOOK_IMPORTS="@~/agent/memory/playbooks/web-scraping.md — anti-bot, DOM vs API, dedup, enrichment
@~/agent/memory/playbooks/sqlite-patterns.md — DAL, WAL mode, dedup normalization
@~/agent/memory/playbooks/testing-patterns.md — offline scraper testing, pure function extraction"
        ;;
    3)
        PLAYBOOK_IMPORTS="@~/agent/memory/playbooks/sqlite-patterns.md — DAL, WAL mode (if using SQLite)
@~/agent/memory/playbooks/testing-patterns.md — testing patterns"
        ;;
    4)
        PLAYBOOK_IMPORTS="@~/agent/memory/playbooks/api-resilience.md — API retry, rate limiting
@~/agent/memory/playbooks/sqlite-patterns.md — DAL, WAL mode"
        ;;
    5|*)
        echo "  Skipping playbook imports."
        ;;
esac

# 3. Append @imports if not already present
if ! grep -q "agent/memory/learnings.md" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    echo "Adding @imports to CLAUDE.md..."
    cat >> "$PROJECT_DIR/CLAUDE.md" << 'IMPORTS'

## Global Brain
@~/agent/memory/user-profile.md — who you are, preferences, how we work together
@~/agent/memory/learnings.md — cross-project patterns (technical, product, business)
@~/agent/memory/session-bridge.md — where we left off across all projects
@~/agent/memory/intelligence-briefing.md — pre-session intelligence (computed daily)
IMPORTS
    echo "  Done."
else
    echo "  @imports already present in CLAUDE.md, skipping."
fi

# 4. Add playbook imports if selected
if [ -n "$PLAYBOOK_IMPORTS" ]; then
    if ! grep -q "playbooks/" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
        echo "Adding playbook @imports..."
        {
            echo ""
            echo "## Playbooks (deep knowledge from proven projects)"
            echo "$PLAYBOOK_IMPORTS"
        } >> "$PROJECT_DIR/CLAUDE.md"
        echo "  Done."
    else
        echo "  Playbook imports already present, skipping."
    fi
fi

# 5. Add Self-Improvement section if not present
if ! grep -q "Self-Improvement" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    echo "Adding Self-Improvement section..."
    cat >> "$PROJECT_DIR/CLAUDE.md" << 'SELFIMPROVE'

## Self-Improvement
When I correct a mistake, invoke the self-improve skill to capture the pattern.
After fixing any bug, ask: "Is the root cause a pattern that should be in patterns.md?" If yes, update it.
SELFIMPROVE
    echo "  Done."
fi

# 6. Register in ~/agent/CLAUDE.md if not already there
if ! grep -q "$PROJECT_DIR" "$AGENT_CLAUDE" 2>/dev/null; then
    echo "Registering in agent hub..."
    # Find the last @~ project line number and insert after it
    LAST_PROJECT_LINE=$(grep -n "^- @~.*CLAUDE.md" "$AGENT_CLAUDE" | tail -1 | cut -d: -f1)
    if [ -n "$LAST_PROJECT_LINE" ]; then
        sed -i '' "${LAST_PROJECT_LINE}a\\
- @${PROJECT_DIR}/CLAUDE.md — ${PROJECT_NAME}
" "$AGENT_CLAUDE"
    fi
    echo "  Done."
else
    echo "  Already registered in agent hub, skipping."
fi

# 6b. Register in projects.conf if not already there
PROJ_REL="${PROJECT_DIR/#$HOME/\~}"
if [ -f "$PROJECTS_CONF" ] && ! grep -q "$PROJ_REL:" "$PROJECTS_CONF" 2>/dev/null; then
    echo "Registering in projects.conf..."
    echo "${PROJ_REL}:${PROJECT_NAME}" >> "$PROJECTS_CONF"
    echo "  Done."
elif [ -f "$PROJECTS_CONF" ]; then
    echo "  Already in projects.conf, skipping."
fi

# 7. Create Claude memory directory and pattern tracker
if [ ! -d "$CLAUDE_MEMORY_DIR" ]; then
    echo "Creating Claude memory directory..."
    mkdir -p "$CLAUDE_MEMORY_DIR"
fi

if [ ! -f "$CLAUDE_MEMORY_DIR/patterns.md" ]; then
    echo "Creating pattern tracker..."
    cat > "$CLAUDE_MEMORY_DIR/patterns.md" << TRACKER
# Pattern Tracker — $PROJECT_NAME

Tracks recurring patterns with seen counters for automatic escalation.
Updated by the self-improve skill.
- Tier 1 (seen: 1) -> captured here only
- Tier 2 (seen: 2+) -> also in project decisions/learnings
- Tier 3 (seen: 3+) -> also in CLAUDE.md or enforced via hook

---
TRACKER
    echo "  Done."
else
    echo "  Pattern tracker already exists, skipping."
fi

# 8. Scaffold docs/ if not present
mkdir -p "$PROJECT_DIR/docs"

if [ ! -f "$PROJECT_DIR/docs/decisions.md" ]; then
    echo "Creating docs/decisions.md..."
    cat > "$PROJECT_DIR/docs/decisions.md" << DECISIONS
# Decision Log — $PROJECT_NAME

Record architectural decisions, learnings, and gotchas here.
Each entry should help future sessions avoid repeating mistakes.

Format: \`[YYYY-MM-DD] CATEGORY: Description\`

---
DECISIONS
    echo "  Done."
fi

if [ ! -f "$PROJECT_DIR/docs/evolution.md" ]; then
    echo "Creating docs/evolution.md..."
    cat > "$PROJECT_DIR/docs/evolution.md" << EVOLUTION
# $PROJECT_NAME — Evolution

The story of what we built, what problems we solved, and where we're heading.
Updated at the end of every session.

---

## Where It Started ($(date '+%B %Y'))

[Describe the problem this project solves, who it's for, and why it matters.]

EVOLUTION
    echo "  Done."
fi

# 9. Create .claude/settings.local.json with standard hooks if not present
SETTINGS_FILE="$PROJECT_DIR/.claude/settings.local.json"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "Creating .claude/settings.local.json with standard hooks..."
    mkdir -p "$PROJECT_DIR/.claude"

    # Detect language for auto-lint hook
    if ls "$PROJECT_DIR"/*.py "$PROJECT_DIR"/**/*.py 2>/dev/null | head -1 > /dev/null 2>&1; then
        LINT_CMD='filepath="$CLAUDE_FILE_PATH"; if [ -n "$filepath" ] && echo "$filepath" | grep -qE '"'"'\\.py$'"'"'; then python3 -m py_compile "$filepath" 2>&1 || true; fi'
        LINT_MSG="Checking Python syntax..."
    elif ls "$PROJECT_DIR"/*.js "$PROJECT_DIR"/*.jsx "$PROJECT_DIR"/**/*.js 2>/dev/null | head -1 > /dev/null 2>&1; then
        LINT_CMD="filepath=\"\$CLAUDE_FILE_PATH\"; if [ -n \"\$filepath\" ] && echo \"\$filepath\" | grep -qE '\\\\.jsx?\$'; then cd $PROJECT_DIR && npx eslint --no-warn-ignored \"\$filepath\" --fix 2>/dev/null || true; fi"
        LINT_MSG="Auto-linting..."
    else
        LINT_CMD=""
    fi

    cat > "$SETTINGS_FILE" << SETTINGS
{
  "permissions": {
    "allow": [
      "WebSearch"
    ]
  },
  "hooks": {
    "PostToolUse": [
$(if [ -n "$LINT_CMD" ]; then
cat << POSTHOOK
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "$LINT_CMD",
            "statusMessage": "$LINT_MSG"
          }
        ]
      }
POSTHOOK
fi)
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "if echo \"\$CLAUDE_BASH_COMMAND\" | grep -qE 'git\\\\s+push|git\\\\s+reset\\\\s+--hard|rm\\\\s+-rf\\\\s+/|DROP\\\\s+TABLE'; then echo 'BLOCKED: Destructive command requires explicit approval' >&2; exit 2; fi"
          }
        ]
      }
    ]
  }
}
SETTINGS
    echo "  Done."
else
    echo "  settings.local.json already exists, skipping."
fi

echo ""
echo "Bootstrap complete for $PROJECT_NAME."
echo ""
echo "Next steps:"
echo "  1. Review CLAUDE.md — ensure @imports and playbooks look right"
echo "  2. Fill in docs/evolution.md with the project story"
echo "  3. Start building!"
