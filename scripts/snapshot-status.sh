#!/bin/bash
# snapshot-status.sh — Generate verified project status as standalone file
# Outputs to ~/agent/memory/project-status.md (computed, never committed)
# Run: bash ~/agent/scripts/snapshot-status.sh
#
# Uses projects.conf for project list. Per-project custom blocks can be
# added as scripts/status.d/<project-name>.sh (optional).

set -euo pipefail

source "$(dirname "$0")/_common.sh"

OUTPUT="$AGENT_DIR/memory/project-status.md"
STATUS_PLUGINS="$(dirname "$0")/status.d"
NOW=$(date '+%Y-%m-%d %H:%M')

load_projects

{
echo "# Project Status"
echo "Generated: ${NOW} — Run \`bash ~/agent/scripts/snapshot-status.sh\` to refresh"
echo ""

for SPEC in "${PROJECTS[@]}"; do
  DIR="${SPEC%%:*}"
  NAME="${SPEC#*:}"

  [ -d "$DIR" ] || continue

  echo "## $NAME"

  # Check for a custom status plugin
  PLUGIN_NAME=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  PLUGIN="$STATUS_PLUGINS/${PLUGIN_NAME}.sh"
  if [ -f "$PLUGIN" ]; then
    # Run custom plugin — it handles project-specific details
    bash "$PLUGIN" "$DIR" "$NAME" 2>/dev/null || true
  else
    # Generic git-based status for any project
    if [ -d "$DIR/.git" ]; then
      last_commit=$(cd "$DIR" && git log --oneline -1 2>/dev/null || echo "unknown")
      modified=$(cd "$DIR" && git status --short 2>/dev/null | grep -c '^ M\|^M ' || true)
      untracked=$(cd "$DIR" && git status --short 2>/dev/null | grep -c '^??' || true)
      echo "- Git: ${last_commit}"
      echo "- Working dir: ${modified} modified, ${untracked} untracked"
    else
      echo "- Not a git repository"
    fi
  fi
  echo ""
done

# --- Doc Staleness Check ---
echo "## Doc Staleness"
echo ""
STALE_FOUND=0
for SPEC in "${PROJECTS[@]}"; do
  DIR="${SPEC%%:*}"
  NAME="${SPEC#*:}"
  [ -d "$DIR/.git" ] || continue

  for DOC in "docs/evolution.md" "docs/decisions.md"; do
    DOCPATH="$DIR/$DOC"
    DOCNAME=$(basename "$DOC")
    if [ ! -f "$DOCPATH" ]; then
      echo "- **${NAME}** — \`${DOCNAME}\` MISSING"
      STALE_FOUND=1
      continue
    fi
    LAST_DOC_HASH=$(cd "$DIR" && git log -1 --format="%H" -- "$DOC" 2>/dev/null)
    if [ -z "$LAST_DOC_HASH" ]; then
      echo "- **${NAME}** — \`${DOCNAME}\` never committed"
      STALE_FOUND=1
      continue
    fi
    COMMITS_SINCE=$(cd "$DIR" && git rev-list --count "${LAST_DOC_HASH}..HEAD" 2>/dev/null || echo 0)
    if [ "$COMMITS_SINCE" -gt 5 ]; then
      echo "- **${NAME}** — \`${DOCNAME}\` is ${COMMITS_SINCE} commits behind — UPDATE REQUIRED"
      STALE_FOUND=1
    fi
  done
done

if [ "$STALE_FOUND" -eq 0 ]; then
  echo "All docs current (within 5 commits)."
fi
echo ""

} > "$OUTPUT"

echo "Project status written to: $OUTPUT"
