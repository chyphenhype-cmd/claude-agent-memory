#!/bin/bash
#############################################
# Agent System Health Check
#
# One-command overview of the intelligence system's health.
# Reports: file freshness, entry counts, wiring status, staleness warnings.
#
# Usage: ./system-health.sh
#############################################

source "$(dirname "$0")/_common.sh"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Agent System Health Check"
echo "  $(date '+%Y-%m-%d %H:%M')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Brain file freshness
echo "📁 Brain Files"
for file in user-profile.md learnings.md session-bridge.md; do
    FULL="$AGENT_DIR/memory/$file"
    if [ -f "$FULL" ]; then
        MOD=$(stat -f "%Sm" -t "%Y-%m-%d" "$FULL")
        LINES=$(wc -l < "$FULL" | tr -d ' ')
        SIZE=$(wc -c < "$FULL" | tr -d ' ')
        echo "  $file: $LINES lines, ${SIZE}B, last modified $MOD"
    else
        echo "  $file: MISSING"
    fi
done
echo ""

# 2. Session bridge staleness
BRIDGE="$AGENT_DIR/memory/session-bridge.md"
if [ -f "$BRIDGE" ]; then
    LAST_UPDATE=$(grep "Last updated:" "$BRIDGE" | head -1 | sed 's/Last updated: //')
    if [ -n "$LAST_UPDATE" ]; then
        DAYS_OLD=$(( ($(date +%s) - $(date -j -f "%Y-%m-%d" "$LAST_UPDATE" +%s 2>/dev/null || echo $(date +%s))) / 86400 ))
        if [ $DAYS_OLD -gt 7 ]; then
            echo "⚠️  Session bridge is $DAYS_OLD days old — may be stale"
        elif [ $DAYS_OLD -gt 0 ]; then
            echo "📅 Session bridge last updated $DAYS_OLD day(s) ago"
        else
            echo "✅ Session bridge is current (today)"
        fi
    fi
fi
echo ""

# 3. Learnings count
LEARNINGS="$AGENT_DIR/memory/learnings.md"
if [ -f "$LEARNINGS" ]; then
    ENTRY_COUNT=$(grep -cE "^[A-Z][A-Z _]+" "$LEARNINGS" 2>/dev/null || echo "0")
    ENTRY_COUNT=$(echo "$ENTRY_COUNT" | tr -d '[:space:]')
    echo "📊 Learnings: $ENTRY_COUNT entries (target: ~40 max)"
    if [ "$ENTRY_COUNT" -gt 45 ]; then
        echo "  ⚠️  Over target — consider pruning"
    fi
fi
echo ""

# 4. Pattern tracker status
echo "🔍 Pattern Trackers"
load_projects

for SPEC in "${PROJECTS[@]}"; do
    DIR="${SPEC%%:*}"
    NAME="${SPEC#*:}"
    MEMORY_KEY=$(echo "$DIR" | sed 's|/|-|g')
    TRACKER="$CLAUDE_PROJECTS/$MEMORY_KEY/memory/patterns.md"

    if [ -f "$TRACKER" ]; then
        PATTERN_COUNT=$(grep -c "^### " "$TRACKER" 2>/dev/null; echo $?)
        PATTERN_COUNT=$(grep "^### " "$TRACKER" 2>/dev/null | wc -l | tr -d ' ')
        MAX_SEEN=$(grep "^- seen:" "$TRACKER" 2>/dev/null | sed 's/.*seen: //' | sort -rn | head -1 | tr -d '[:space:]')
        ENFORCED=$(grep "tier: enforce" "$TRACKER" 2>/dev/null | wc -l | tr -d ' ')
        echo "  $NAME: $PATTERN_COUNT patterns, $ENFORCED enforced, max seen: ${MAX_SEEN:-0}"
    else
        echo "  $NAME: NO PATTERN TRACKER"
    fi
done
echo ""

# 5. @import wiring check
echo "🔗 Project Wiring"
for SPEC in "${PROJECTS[@]}"; do
    DIR="${SPEC%%:*}"
    NAME="${SPEC#*:}"
    CLAUDE_FILE="$DIR/CLAUDE.md"

    if [ ! -f "$CLAUDE_FILE" ]; then
        echo "  $NAME: NO CLAUDE.md"
        continue
    fi

    IMPORTS=0
    for BRAIN in user-profile.md learnings.md session-bridge.md intelligence-briefing.md; do
        if grep -q "$BRAIN" "$CLAUDE_FILE" 2>/dev/null; then
            IMPORTS=$((IMPORTS + 1))
        fi
    done

    if [ $IMPORTS -eq 4 ]; then
        echo "  $NAME: ✅ All 4 brain files imported"
    else
        echo "  $NAME: ⚠️  Only $IMPORTS/4 brain files imported"
        for BRAIN in user-profile.md learnings.md session-bridge.md; do
            if ! grep -q "$BRAIN" "$CLAUDE_FILE" 2>/dev/null; then
                echo "    Missing: $BRAIN"
            fi
        done
    fi
done
echo ""

# 6. Learning Pipeline Health
echo "🧠 Learning Pipeline"
TOTAL_PATTERNS=0
TOTAL_OBSERVE=0
TOTAL_VALIDATE=0
TOTAL_ENFORCE=0
STALE_PATTERNS=0
PROMO_CANDIDATES=0

for SPEC in "${PROJECTS[@]}"; do
    DIR="${SPEC%%:*}"
    NAME="${SPEC#*:}"
    MEMORY_KEY=$(echo "$DIR" | sed 's|/|-|g')
    TRACKER="$CLAUDE_PROJECTS/$MEMORY_KEY/memory/patterns.md"

    if [ -f "$TRACKER" ]; then
        # Count patterns by tier
        P_COUNT=$(grep -c "^### " "$TRACKER" 2>/dev/null || true)
        P_OBSERVE=$(grep -c "tier: observe" "$TRACKER" 2>/dev/null || true)
        P_VALIDATE=$(grep -c "tier: validate" "$TRACKER" 2>/dev/null || true)
        P_ENFORCE=$(grep -c "tier: enforce" "$TRACKER" 2>/dev/null || true)
        TOTAL_PATTERNS=$((TOTAL_PATTERNS + P_COUNT))
        TOTAL_OBSERVE=$((TOTAL_OBSERVE + P_OBSERVE))
        TOTAL_VALIDATE=$((TOTAL_VALIDATE + P_VALIDATE))
        TOTAL_ENFORCE=$((TOTAL_ENFORCE + P_ENFORCE))

        # Check for stale patterns (seen: 1, last date > 7 days ago)
        SEVEN_DAYS_AGO=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d "7 days ago" +%Y-%m-%d 2>/dev/null || echo "2000-01-01")
        while IFS= read -r line; do
            PATTERN_NAME=$(echo "$line" | sed 's/^### //')
            # Get next few lines to check seen count and last date
            SEEN=$(grep -A5 "^### $PATTERN_NAME$" "$TRACKER" | grep "^- seen:" | sed 's/.*seen: //' | tr -d '[:space:]')
            TIER=$(grep -A5 "^### $PATTERN_NAME$" "$TRACKER" | grep "^- tier:" | sed 's/.*tier: //' | tr -d '[:space:]')
            LAST=$(grep -A8 "^### $PATTERN_NAME$" "$TRACKER" | grep "^- last:" | sed 's/.*last: //' | tr -d '[:space:]')

            if [ "$SEEN" = "1" ] && [ -n "$LAST" ] && [ "$LAST" \< "$SEVEN_DAYS_AGO" ]; then
                STALE_PATTERNS=$((STALE_PATTERNS + 1))
            fi
            if [ -n "$SEEN" ] && [ "$SEEN" -ge 2 ] 2>/dev/null && [ "$TIER" = "observe" ]; then
                PROMO_CANDIDATES=$((PROMO_CANDIDATES + 1))
            fi
        done < <(grep "^### " "$TRACKER" 2>/dev/null)
    fi
done

echo "  Total patterns: $TOTAL_PATTERNS (observe: $TOTAL_OBSERVE, validate: $TOTAL_VALIDATE, enforce: $TOTAL_ENFORCE)"
if [ $STALE_PATTERNS -gt 0 ]; then
    echo "  ⚠️  $STALE_PATTERNS stale pattern(s) (seen once, >7 days old) — review with /project:retro"
fi
if [ $PROMO_CANDIDATES -gt 0 ]; then
    echo "  ⚠️  $PROMO_CANDIDATES pattern(s) ready for promotion (seen 2+ but still at observe)"
fi
if [ $TOTAL_ENFORCE -gt 0 ]; then
    echo "  ✅ $TOTAL_ENFORCE pattern(s) at enforce tier"
fi
echo ""

# 7. Skills check
echo "🛠️ Skills"
SKILLS_DIR="$HOME/.claude/skills"
if [ -d "$SKILLS_DIR" ]; then
    SKILL_COUNT=$(ls -d "$SKILLS_DIR"/*/ 2>/dev/null | wc -l | tr -d ' ')
    echo "  $SKILL_COUNT skills installed:"
    for skill_dir in "$SKILLS_DIR"/*/; do
        skill_name=$(basename "$skill_dir")
        echo "    - $skill_name"
    done
else
    echo "  No skills directory found"
fi
echo ""

# 8. Hooks check
echo "🪝 Hooks"
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
    HOOK_COUNT=$(grep -c '"type"' "$SETTINGS" 2>/dev/null || echo 0)
    echo "  $HOOK_COUNT hook(s) configured in global settings"
    if grep -q "capture-all-projects\|capture-session-bridge" "$SETTINGS" 2>/dev/null; then
        echo "  ✅ Stop hook: session capture"
    else
        echo "  ⚠️  No session capture Stop hook"
    fi
else
    echo "  No global settings.json found"
fi
echo ""

# 9. Project Hooks Audit
echo "🔧 Project Hooks"
for SPEC in "${PROJECTS[@]}"; do
    DIR="${SPEC%%:*}"
    NAME="${SPEC#*:}"
    SETTINGS_FILE="$DIR/.claude/settings.local.json"

    if [ ! -f "$SETTINGS_FILE" ]; then
        echo "  $NAME: ⚠️  No settings.local.json (no project hooks)"
        continue
    fi

    HAS_POST=$(grep -c "PostToolUse" "$SETTINGS_FILE" 2>/dev/null || true)
    HAS_PRE=$(grep -c "PreToolUse" "$SETTINGS_FILE" 2>/dev/null || true)
    HAS_STOP=$(grep -c "Stop" "$SETTINGS_FILE" 2>/dev/null || true)

    STATUS=""
    [ "$HAS_POST" -gt 0 ] && STATUS="${STATUS}PostToolUse "
    [ "$HAS_PRE" -gt 0 ] && STATUS="${STATUS}PreToolUse "
    [ "$HAS_STOP" -gt 0 ] && STATUS="${STATUS}Stop "

    if [ -n "$STATUS" ]; then
        echo "  $NAME: ✅ Hooks: $STATUS"
    else
        echo "  $NAME: ⚠️  settings.local.json exists but no hooks configured"
    fi

    # Check for agents
    AGENTS_DIR="$DIR/.claude/agents"
    if [ -d "$AGENTS_DIR" ]; then
        AGENT_COUNT=$(ls -1 "$AGENTS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
        AGENT_NAMES=$(ls -1 "$AGENTS_DIR"/*.md 2>/dev/null | xargs -I{} basename {} .md | tr '\n' ', ' | sed 's/,$//')
        echo "  $NAME: ✅ $AGENT_COUNT agent(s): $AGENT_NAMES"
    fi
done
echo ""

# 10. Intelligence System
echo "🔬 Intelligence System"
BRIEFING="$AGENT_DIR/memory/intelligence-briefing.md"
if [ -f "$BRIEFING" ]; then
    BRIEFING_MOD=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$BRIEFING" 2>/dev/null || stat -c "%y" "$BRIEFING" 2>/dev/null | cut -d. -f1)
    BRIEFING_AGE=$(( ($(date +%s) - $(stat -f %m "$BRIEFING" 2>/dev/null || stat -c %Y "$BRIEFING" 2>/dev/null || echo 0)) / 3600 ))
    if [ "$BRIEFING_AGE" -lt 24 ]; then
        echo "  ✅ Intelligence briefing: current ($BRIEFING_MOD)"
    else
        echo "  ⚠️  Intelligence briefing: ${BRIEFING_AGE}h old — run knowledge-compile.sh"
    fi
else
    echo "  ⚠️  No intelligence briefing — run: bash ~/agent/scripts/knowledge-compile.sh"
fi

# Anti-patterns merged into learnings.md as of 2026-03-08
echo "  ✅ Unified learnings (patterns + anti-patterns in one file)"

if [ -x "$AGENT_DIR/scripts/knowledge-compile.sh" ]; then
    echo "  ✅ Knowledge compiler: installed"
else
    echo "  ⚠️  Knowledge compiler: missing or not executable"
fi

# Validate weekly scripts parse correctly
SCRIPT_ERRORS=0
for SCRIPT in weekly-digest.sh weekly-retro.sh; do
    if [ -f "$AGENT_DIR/scripts/$SCRIPT" ]; then
        if ! bash -n "$AGENT_DIR/scripts/$SCRIPT" 2>/dev/null; then
            echo "  ❌ $SCRIPT has syntax errors — will fail when launchd runs it"
            SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
        fi
    fi
done
[ "$SCRIPT_ERRORS" -eq 0 ] && echo "  ✅ Weekly scripts: syntax valid"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Health check complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
