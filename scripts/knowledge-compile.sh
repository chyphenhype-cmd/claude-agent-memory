#!/bin/bash
#############################################
# Knowledge Compiler — Intelligence Briefing
#
# Reads ALL intelligence sources across projects and produces
# ~/agent/memory/intelligence-briefing.md
#
# Sources: autopilot intelligence, pattern trackers, learnings.md,
#          failed attempts, git history, playbooks
#
# No network calls. No Claude CLI. Pure bash + jq.
# Target: < 5 seconds execution.
#############################################

set -euo pipefail

source "$(dirname "$0")/_common.sh"

OUTPUT_FILE="$AGENT_DIR/memory/intelligence-briefing.md"
LEARNINGS_FILE="$AGENT_DIR/memory/learnings.md"
PLAYBOOKS_DIR="$AGENT_DIR/memory/playbooks"
LOG_DIR="$AGENT_DIR/logs"
DATE=$(date '+%Y-%m-%d %H:%M')
NOW_EPOCH=$(date +%s)
SEVEN_DAYS_AGO_EPOCH=$((NOW_EPOCH - 7 * 86400))

mkdir -p "$LOG_DIR"
echo "compile: $(date)" >> "$LOG_DIR/compile-heartbeat.log"

# Load projects from conf
load_autopilot_projects
load_projects_with_keys

# --- Helper functions ---

# Safe grep — returns empty string instead of failing with set -e
sgrep() {
    grep "$@" 2>/dev/null || true
}

# Parse a YYYY-MM-DD date string to epoch (macOS)
date_to_epoch() {
    local datestr="$1"
    # Validate date format first
    if [[ ! "$datestr" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "$NOW_EPOCH"
        return
    fi
    date -j -f "%Y-%m-%d" "$datestr" +%s 2>/dev/null || echo "$NOW_EPOCH"
}

# Days between epoch and now
days_ago() {
    local epoch="$1"
    echo $(( (NOW_EPOCH - epoch) / 86400 ))
}

# Extract SHORT_NAMEs from a pattern tracker file
extract_pattern_names() {
    local file="$1"
    [ ! -f "$file" ] && return 0
    sgrep '^### ' "$file" | sed 's/^### //'
}

# Extract a field value for a given pattern name from a tracker file
extract_pattern_field() {
    local file="$1" name="$2" field="$3"
    [ ! -f "$file" ] && return 0
    awk -v name="### $name" -v field="- ${field}:" '
        $0 == name { found=1; next }
        found && /^### / { found=0 }
        found && index($0, field) == 1 { sub(field " ?", ""); print; exit }
    ' "$file" 2>/dev/null || true
}

# Get last N intelligence entries with non-empty learnings (from JSONL)
get_intelligence_entries() {
    local file="$1" count="$2" since_epoch="$3"
    [ ! -f "$file" ] && return 0

    local result
    # Try entries from last 7 days with learnings first
    result=$(jq -r --arg since "$since_epoch" '
        select(.timestamp != null)
        | select((.timestamp | sub("Z$";"") | sub("T";" ") | strptime("%Y-%m-%d %H:%M:%S") | mktime) >= ($since | tonumber))
        | select(.learning != null and .learning != "")
        | "- Cycle \(.cycle) [\(.mode)] \(.result): \(.summary | .[0:80])...\n  Learning: \(.learning | .[0:120])"
    ' "$file" 2>/dev/null | head -n "$((count * 2))" || true)

    if [ -z "$result" ]; then
        # Fall back to last N entries with learnings overall
        result=$(tail -20 "$file" | jq -r '
            select(.learning != null and .learning != "")
            | "- Cycle \(.cycle) [\(.mode)] \(.result): \(.summary | .[0:80])...\n  Learning: \(.learning | .[0:120])"
        ' 2>/dev/null | tail -n "$((count * 2))" || true)
    fi

    echo "$result"
}

# Count cycles by result type from JSONL (last 7 days)
count_cycle_results() {
    local file="$1"
    [ ! -f "$file" ] && { echo "0:0:0:0"; return 0; }

    # Parse all results in one jq pass for efficiency
    local results
    results=$(jq -r --arg since "$SEVEN_DAYS_AGO_EPOCH" '
        select(.timestamp != null)
        | select((.timestamp | sub("Z$";"") | sub("T";" ") | strptime("%Y-%m-%d %H:%M:%S") | mktime) >= ($since | tonumber))
        | .result
    ' "$file" 2>/dev/null || true)

    local total success failed idle
    total=$(echo "$results" | sgrep -c '.' || true)
    success=$(echo "$results" | sgrep -c '^success$' || true)
    failed=$(echo "$results" | sgrep -c '^failure$' || true)
    idle=$(echo "$results" | sgrep -cE '^(idle|rate_limited)$' || true)

    echo "${total:-0}:${success:-0}:${failed:-0}:${idle:-0}"
}

# Extract failed attempts from failed_attempts.md (last 5)
# Handles both formats:
#   Format A: "## Cycle N — MODE — DATE" headers
#   AptFinder: "- Cycle N [MODE] DATE — reason" lines
get_failed_attempts() {
    local file="$1" project="$2"
    [ ! -f "$file" ] && return 0

    local lines
    # Try "- Cycle" format first (Format B)
    lines=$(sgrep '^- Cycle' "$file")
    if [ -n "$lines" ]; then
        echo "$lines" | tail -5 | while IFS= read -r line; do
            echo "- [$project] ${line#- }"
        done
        return 0
    fi

    # Try "## Cycle" format (Format A) — extract cycle header + reason
    lines=$(sgrep '^## Cycle' "$file")
    if [ -n "$lines" ]; then
        # Also grab the Reason line for each cycle
        echo "$lines" | tail -5 | while IFS= read -r line; do
            # "## Cycle 1 — EXPLORE — 2026-03-06 01:06"
            local cycle mode datestr reason
            cycle=$(echo "$line" | sgrep -oE 'Cycle [0-9]+' | head -1)
            # Mode is between first and second em-dash
            mode=$(echo "$line" | awk -F' — ' '{print $2}')
            datestr=$(echo "$line" | sgrep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
            # Try to get the Reason line from the file
            reason=$(sgrep -A4 "^${line}$" "$file" | sgrep '^\- \*\*Reason:\*\*' | sed 's/.*Reason:\*\* //' | head -1)
            if [ -n "$reason" ]; then
                echo "- [$project] ${cycle:-unknown} [${mode:-unknown}] ${datestr:-unknown} — ${reason}"
            else
                echo "- [$project] ${cycle:-unknown} [${mode:-unknown}] ${datestr:-unknown}"
            fi
        done
        return 0
    fi
}

# Collect recent autopilot areas for playbook recommendations
get_recent_areas() {
    local file="$1"
    [ ! -f "$file" ] && return 0
    tail -20 "$file" | jq -r '.area // empty' 2>/dev/null | sort -u || true
}

# Map area keyword to playbook filename
map_area_to_playbook() {
    local area="$1"
    case "$area" in
        security|api|routes|route|audit)
            echo "api-resilience.md" ;;
        react|frontend|component|ui|ux)
            echo "react-frontend.md" ;;
        database|sql|schema|db|data)
            echo "sqlite-patterns.md" ;;
        test|tests|testing)
            echo "testing-patterns.md" ;;
        scraper|scraping|dom|web)
            echo "web-scraping.md" ;;
        infrastructure)
            echo "testing-patterns.md" ;;
        *)
            echo "" ;;
    esac
}

# --- Section 1: Autopilot Intelligence ---

AUTOPILOT_SECTION=""

for SPEC in "${AUTOPILOT_PROJECTS[@]}"; do
    DIR="${SPEC%%:*}"
    NAME="${SPEC#*:}"
    INTEL_FILE="$DIR/.autopilot/intelligence.jsonl"

    if [ ! -f "$INTEL_FILE" ]; then continue; fi

    COUNTS=$(count_cycle_results "$INTEL_FILE")
    TOTAL=$(echo "$COUNTS" | cut -d: -f1)
    SUCCESS=$(echo "$COUNTS" | cut -d: -f2)
    FAILED=$(echo "$COUNTS" | cut -d: -f3)
    IDLE=$(echo "$COUNTS" | cut -d: -f4)

    ENTRIES=$(get_intelligence_entries "$INTEL_FILE" 5 "$SEVEN_DAYS_AGO_EPOCH")

    AUTOPILOT_SECTION="${AUTOPILOT_SECTION}
### ${NAME} (${TOTAL} cycles: ${SUCCESS} success, ${FAILED} failed, ${IDLE} idle)
${ENTRIES:-No entries with learnings found.}
"
done

# --- Section 2: Anti-Patterns ---

ANTIPATTERN_SECTION=""
for SPEC in "${AUTOPILOT_PROJECTS[@]}"; do
    DIR="${SPEC%%:*}"
    NAME="${SPEC#*:}"
    FAILED_FILE="$DIR/.autopilot/failed_attempts.md"

    ATTEMPTS=$(get_failed_attempts "$FAILED_FILE" "$NAME")
    if [ -n "$ATTEMPTS" ]; then
        ANTIPATTERN_SECTION="${ANTIPATTERN_SECTION}${ATTEMPTS}
"
    fi
done

# --- Section 3: Cross-Project Pattern Candidates ---

# Collect all pattern names per project into temp files (avoids associative array issues)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

for SPEC in "${ALL_PROJECTS[@]}"; do
    IFS=: read -r DIR NAME KEY <<< "$SPEC"
    TRACKER="$CLAUDE_PROJECTS/$KEY/memory/patterns.md"
    [ ! -f "$TRACKER" ] && continue

    while IFS= read -r PNAME; do
        [ -z "$PNAME" ] && continue
        echo "$NAME" >> "$TEMP_DIR/pattern_${PNAME}"
    done < <(extract_pattern_names "$TRACKER")
done

CROSS_PROJECT_SECTION=""
for pfile in "$TEMP_DIR"/pattern_*; do
    [ ! -f "$pfile" ] && continue
    PNAME=$(basename "$pfile" | sed 's/^pattern_//')
    PROJECT_COUNT=$(wc -l < "$pfile" | tr -d ' ')
    if [ "$PROJECT_COUNT" -ge 2 ]; then
        PROJECTS_LIST=$(paste -sd', ' "$pfile")
        # Check if already in learnings.md
        if ! sgrep -q "$PNAME" "$LEARNINGS_FILE"; then
            CROSS_PROJECT_SECTION="${CROSS_PROJECT_SECTION}- ${PNAME}: seen in ${PROJECTS_LIST}, not yet in learnings.md
"
        fi
    fi
done

# --- Section 4: Promotion Candidates ---

PROMOTION_SECTION=""
for SPEC in "${ALL_PROJECTS[@]}"; do
    IFS=: read -r DIR NAME KEY <<< "$SPEC"
    TRACKER="$CLAUDE_PROJECTS/$KEY/memory/patterns.md"
    [ ! -f "$TRACKER" ] && continue

    while IFS= read -r PNAME; do
        [ -z "$PNAME" ] && continue
        TIER=$(extract_pattern_field "$TRACKER" "$PNAME" "tier")
        SEEN=$(extract_pattern_field "$TRACKER" "$PNAME" "seen")

        # Promotion candidate: observe tier with seen >= 2
        if [ "$TIER" = "observe" ] && [ -n "$SEEN" ] && [ "$SEEN" -ge 2 ] 2>/dev/null; then
            PROMOTION_SECTION="${PROMOTION_SECTION}- ${NAME}/${PNAME} (seen: ${SEEN}, tier: observe) — ready for validate
"
        fi
    done < <(extract_pattern_names "$TRACKER")
done

# --- Section 5: Effectiveness Report ---

EFFECTIVENESS_ROWS=""

for SPEC in "${ALL_PROJECTS[@]}"; do
    IFS=: read -r DIR NAME KEY <<< "$SPEC"
    TRACKER="$CLAUDE_PROJECTS/$KEY/memory/patterns.md"
    [ ! -f "$TRACKER" ] && continue

    while IFS= read -r PNAME; do
        [ -z "$PNAME" ] && continue
        TIER=$(extract_pattern_field "$TRACKER" "$PNAME" "tier")
        [ "$TIER" != "enforce" ] && continue

        LAST_DATE=$(extract_pattern_field "$TRACKER" "$PNAME" "last")
        [ -z "$LAST_DATE" ] && LAST_DATE="unknown"

        # Convert pattern name to first keyword for git search
        FIRST_KEYWORD=$(echo "$PNAME" | tr '_' '\n' | tr '[:upper:]' '[:lower:]' | head -1)

        # Search git log across all project repos for keyword
        EVIDENCE_COUNT=0
        for PROJ_SPEC in "${ALL_PROJECTS[@]}"; do
            PROJ_DIR=$(echo "$PROJ_SPEC" | cut -d: -f1)
            if [ -d "$PROJ_DIR/.git" ]; then
                HITS=$(git -C "$PROJ_DIR" log --oneline --since='7 days ago' --grep="$FIRST_KEYWORD" -i 2>/dev/null | wc -l | tr -d ' ' || true)
                EVIDENCE_COUNT=$((EVIDENCE_COUNT + HITS))
            fi
        done

        if [ "$EVIDENCE_COUNT" -gt 0 ]; then
            STATUS="active ($EVIDENCE_COUNT commits)"
        else
            STATUS="untested"
        fi

        EFFECTIVENESS_ROWS="${EFFECTIVENESS_ROWS}| ${PNAME} | ${TIER} | ${LAST_DATE} | ${EVIDENCE_COUNT} commits (7d) | ${STATUS} |
"
    done < <(extract_pattern_names "$TRACKER")
done

if [ -n "$EFFECTIVENESS_ROWS" ]; then
    EFFECTIVENESS_SECTION="| Pattern | Tier | Last Validated | Evidence | Status |
|---------|------|----------------|----------|--------|
${EFFECTIVENESS_ROWS}"
else
    EFFECTIVENESS_SECTION="No enforce-tier patterns found."
fi

# --- Section 6: Stale Knowledge ---

STALE_SECTION=""
while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Extract the validated date
    VALIDATED_DATE=$(echo "$line" | sgrep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1)
    [ -z "$VALIDATED_DATE" ] && continue

    VALIDATED_EPOCH=$(date_to_epoch "$VALIDATED_DATE")
    DAYS=$(days_ago "$VALIDATED_EPOCH")

    # Find the associated pattern name (look backward from this line in learnings.md)
    PATTERN_LINE=$(sgrep -B5 "$VALIDATED_DATE" "$LEARNINGS_FILE" | sgrep -E '^[A-Z][A-Z _]+' | tail -1 | sed 's/ (.*//')
    [ -z "$PATTERN_LINE" ] && continue

    if [ "$DAYS" -gt 60 ]; then
        STALE_SECTION="${STALE_SECTION}- ${PATTERN_LINE} (validated: ${VALIDATED_DATE}, ${DAYS} days ago) — prune candidate
"
    elif [ "$DAYS" -gt 30 ]; then
        STALE_SECTION="${STALE_SECTION}- ${PATTERN_LINE} (validated: ${VALIDATED_DATE}, ${DAYS} days ago) — decaying
"
    fi
done < <(sgrep 'Validated:' "$LEARNINGS_FILE")

# --- Section 7: Learning Velocity ---

# Count new patterns (first: date in last 7 days)
NEW_PATTERNS_7D=0
for SPEC in "${ALL_PROJECTS[@]}"; do
    IFS=: read -r DIR NAME KEY <<< "$SPEC"
    TRACKER="$CLAUDE_PROJECTS/$KEY/memory/patterns.md"
    [ ! -f "$TRACKER" ] && continue

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        FIRST_DATE=$(echo "$line" | sed 's/- first: //')
        [ -z "$FIRST_DATE" ] && continue
        FIRST_EPOCH=$(date_to_epoch "$FIRST_DATE")
        if [ "$FIRST_EPOCH" -ge "$SEVEN_DAYS_AGO_EPOCH" ]; then
            NEW_PATTERNS_7D=$((NEW_PATTERNS_7D + 1))
        fi
    done < <(sgrep '^- first:' "$TRACKER")
done

# Count promotions (tier = promoted with last date in 7 days)
PROMOTIONS_7D=0
for SPEC in "${ALL_PROJECTS[@]}"; do
    IFS=: read -r DIR NAME KEY <<< "$SPEC"
    TRACKER="$CLAUDE_PROJECTS/$KEY/memory/patterns.md"
    [ ! -f "$TRACKER" ] && continue

    while IFS= read -r PNAME; do
        [ -z "$PNAME" ] && continue
        TIER=$(extract_pattern_field "$TRACKER" "$PNAME" "tier")
        LAST=$(extract_pattern_field "$TRACKER" "$PNAME" "last")
        [ -z "$LAST" ] && continue
        LAST_EPOCH=$(date_to_epoch "$LAST")
        if [ "$LAST_EPOCH" -ge "$SEVEN_DAYS_AGO_EPOCH" ] && [ "$TIER" = "promoted" ]; then
            PROMOTIONS_7D=$((PROMOTIONS_7D + 1))
        fi
    done < <(extract_pattern_names "$TRACKER")
done

# Learnings capacity
LEARNINGS_COUNT=$(sgrep -cE '^[A-Z][A-Z _]+' "$LEARNINGS_FILE" | tr -d '[:space:]')
LEARNINGS_COUNT=${LEARNINGS_COUNT:-0}
LEARNINGS_REMAINING=$((40 - LEARNINGS_COUNT))

# --- Section 8: Recommended Reading ---

# Collect all recent areas from autopilot
ALL_AREAS=""
for SPEC in "${AUTOPILOT_PROJECTS[@]}"; do
    DIR="${SPEC%%:*}"
    INTEL_FILE="$DIR/.autopilot/intelligence.jsonl"
    AREAS=$(get_recent_areas "$INTEL_FILE")
    if [ -n "$AREAS" ]; then
        ALL_AREAS="${ALL_AREAS}
${AREAS}"
    fi
done

# Build recommendations (deduplicate playbooks)
RECOMMENDED=""
SEEN_PLAYBOOKS=""

while IFS= read -r area; do
    [ -z "$area" ] && continue
    PLAYBOOK=$(map_area_to_playbook "$area")
    [ -z "$PLAYBOOK" ] && continue
    # Check if already seen
    if [[ "$SEEN_PLAYBOOKS" != *"$PLAYBOOK"* ]]; then
        SEEN_PLAYBOOKS="${SEEN_PLAYBOOKS}:${PLAYBOOK}"
        if [ -f "$PLAYBOOKS_DIR/$PLAYBOOK" ]; then
            RECOMMENDED="${RECOMMENDED}- ${PLAYBOOK} — relevant to recent \`${area}\` work
"
        fi
    fi
done <<< "$ALL_AREAS"

# --- Write the briefing ---

cat > "$OUTPUT_FILE" << BRIEFING_EOF
# Intelligence Briefing
Generated: ${DATE} | Compiler v1

## Autopilot Intelligence (Last 7 Days)
${AUTOPILOT_SECTION:-No autopilot projects with intelligence data found.}

## Anti-Patterns (From Failures)
${ANTIPATTERN_SECTION:-No failed attempts recorded.}

## Cross-Project Pattern Candidates
${CROSS_PROJECT_SECTION:-No cross-project patterns found outside learnings.md.}

## Promotion Candidates
${PROMOTION_SECTION:-No patterns ready for promotion (need seen >= 2 at observe tier).}

## Effectiveness Report
${EFFECTIVENESS_SECTION}

## Stale Knowledge
${STALE_SECTION:-All learnings validated within 30 days — knowledge is fresh.}

## Learning Velocity
- New patterns (7d): ${NEW_PATTERNS_7D}
- Promotions (7d): ${PROMOTIONS_7D}
- Capacity: ${LEARNINGS_COUNT}/40 (${LEARNINGS_REMAINING} slots remaining)

## Recommended Reading
${RECOMMENDED:-No recent autopilot areas matched to playbooks.}
BRIEFING_EOF

echo "Intelligence briefing compiled: $OUTPUT_FILE"
