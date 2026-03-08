#!/bin/bash
#############################################
# Agent Hub — Setup Script
#
# Sets up the cross-project intelligence system for Claude Code.
# Run once. Takes ~30 seconds.
#
# Usage: bash setup.sh [install-dir]
#   install-dir: where to install (default: ~/agent)
#############################################

set -euo pipefail

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Agent Hub — Cross-Project Intelligence"
echo "  for Claude Code"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# --- 1. Get user info ---

read -r -p "Your name (used in session files): " USER_NAME
if [ -z "$USER_NAME" ]; then
    echo "Name is required."
    exit 1
fi

INSTALL_DIR="${1:-$HOME/agent}"
read -r -p "Install directory [$INSTALL_DIR]: " CUSTOM_DIR
INSTALL_DIR="${CUSTOM_DIR:-$INSTALL_DIR}"

# Expand ~ manually
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"

echo ""
echo "Setting up Agent Hub for $USER_NAME at $INSTALL_DIR"
echo ""

# --- 2. Determine source directory (where setup.sh lives) ---

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- 3. Create directory structure ---

echo "Creating directories..."
mkdir -p "$INSTALL_DIR/memory"
mkdir -p "$INSTALL_DIR/scripts"
mkdir -p "$INSTALL_DIR/docs"
mkdir -p "$INSTALL_DIR/logs"
echo "  Done."

# --- 4. Copy free-tier scripts ---

echo "Installing scripts..."
for script in _common.sh capture-all-projects.sh bootstrap-project.sh; do
    if [ -f "$SOURCE_DIR/scripts/$script" ]; then
        cp "$SOURCE_DIR/scripts/$script" "$INSTALL_DIR/scripts/$script"
        chmod +x "$INSTALL_DIR/scripts/$script"
    fi
done
echo "  Done."

# --- 5. Detect and install Pro scripts (if present) ---

PRO_DETECTED=false
PRO_SCRIPTS=(system-health.sh knowledge-compile.sh daily-pulse.sh weekly-retro.sh weekly-digest.sh snapshot-status.sh)
for script in "${PRO_SCRIPTS[@]}"; do
    if [ -f "$SOURCE_DIR/scripts/$script" ]; then
        PRO_DETECTED=true
        cp "$SOURCE_DIR/scripts/$script" "$INSTALL_DIR/scripts/$script"
        chmod +x "$INSTALL_DIR/scripts/$script"
    fi
done

if $PRO_DETECTED; then
    echo "  Pro scripts detected and installed."
fi

# --- 6. Detect and install Pro playbooks (if present) ---

if [ -d "$SOURCE_DIR/memory/playbooks" ] && ls "$SOURCE_DIR"/memory/playbooks/*.md &>/dev/null; then
    echo "Installing playbooks..."
    mkdir -p "$INSTALL_DIR/memory/playbooks"
    for playbook in "$SOURCE_DIR"/memory/playbooks/*.md; do
        [ -f "$playbook" ] || continue
        cp "$playbook" "$INSTALL_DIR/memory/playbooks/$(basename "$playbook")"
    done
    echo "  Pro playbooks installed."
fi

# --- 7. Generate brain files from templates ---

DATE=$(date '+%Y-%m-%d')

echo "Generating brain files..."

# User profile
if [ ! -f "$INSTALL_DIR/memory/user-profile.md" ]; then
    sed "s/{{USER_NAME}}/$USER_NAME/g" "$SOURCE_DIR/memory/user-profile.md.template" \
        > "$INSTALL_DIR/memory/user-profile.md"
    echo "  Created user-profile.md"
else
    echo "  user-profile.md already exists, skipping."
fi

# Session bridge
if [ ! -f "$INSTALL_DIR/memory/session-bridge.md" ]; then
    sed "s/{{DATE}}/$DATE/g" "$SOURCE_DIR/memory/session-bridge.md.template" \
        > "$INSTALL_DIR/memory/session-bridge.md"
    echo "  Created session-bridge.md"
else
    echo "  session-bridge.md already exists, skipping."
fi

# Learnings
if [ ! -f "$INSTALL_DIR/memory/learnings.md" ]; then
    sed "s/{{DATE}}/$DATE/g" "$SOURCE_DIR/memory/learnings.md.template" \
        > "$INSTALL_DIR/memory/learnings.md"
    echo "  Created learnings.md"
else
    echo "  learnings.md already exists, skipping."
fi

echo "  Done."

# --- 8. Generate CLAUDE.md ---

if [ ! -f "$INSTALL_DIR/CLAUDE.md" ]; then
    echo "Generating CLAUDE.md..."
    cp "$SOURCE_DIR/CLAUDE.md.template" "$INSTALL_DIR/CLAUDE.md"
    echo "  Done."
else
    echo "  CLAUDE.md already exists, skipping."
fi

# --- 9. Create projects.conf ---

if [ ! -f "$INSTALL_DIR/projects.conf" ]; then
    echo "Creating projects.conf..."
    cp "$SOURCE_DIR/projects.conf.example" "$INSTALL_DIR/projects.conf"
    echo "  Done."
else
    echo "  projects.conf already exists, skipping."
fi

# --- 10. Set up Claude Code global settings ---

CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
mkdir -p "$CLAUDE_DIR"

echo "Configuring Claude Code..."

if [ ! -f "$SETTINGS_FILE" ]; then
    cat > "$SETTINGS_FILE" << SETTINGS
{
  "permissions": {
    "allow": [
      "Bash(*)",
      "Edit(*)",
      "Write(*)",
      "Read(*)"
    ],
    "deny": [
      "Bash(rm -rf *)",
      "Bash(git push --force*)",
      "Bash(git push -f *)",
      "Bash(git reset --hard*)",
      "Bash(git clean -f*)"
    ]
  },
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$INSTALL_DIR/scripts/capture-all-projects.sh",
            "timeout": 10000
          }
        ]
      }
    ]
  }
}
SETTINGS
    echo "  Created settings.json with Stop hook."
else
    # Check if Stop hook already exists
    if grep -q "capture-all-projects" "$SETTINGS_FILE" 2>/dev/null; then
        echo "  Stop hook already configured."
    else
        echo ""
        echo "  ⚠️  settings.json already exists but doesn't have the Stop hook."
        echo "  Add this to your hooks section manually:"
        echo ""
        echo '    "Stop": [{'
        echo '      "hooks": [{'
        echo '        "type": "command",'
        echo "        \"command\": \"$INSTALL_DIR/scripts/capture-all-projects.sh\","
        echo '        "timeout": 10000'
        echo '      }]'
        echo '    }]'
        echo ""
    fi
fi

# --- 11. Install self-improve skill ---

SKILLS_DIR="$CLAUDE_DIR/skills"
echo "Installing skills..."

# Always install self-improve (free tier)
if [ -d "$SOURCE_DIR/skills/self-improve" ]; then
    mkdir -p "$SKILLS_DIR/self-improve"
    cp "$SOURCE_DIR/skills/self-improve/SKILL.md" "$SKILLS_DIR/self-improve/SKILL.md"
    echo "  Installed skill: self-improve"
fi

# Install Pro skills if present
for skill_name in memory-capture product-lens new-project-playbook; do
    if [ -d "$SOURCE_DIR/skills/$skill_name" ]; then
        mkdir -p "$SKILLS_DIR/$skill_name"
        cp "$SOURCE_DIR/skills/$skill_name/SKILL.md" "$SKILLS_DIR/$skill_name/SKILL.md"
        echo "  Installed Pro skill: $skill_name"
    fi
done

echo "  Done."

# --- 12. Install Pro slash commands (if present) ---

COMMANDS_DIR="$CLAUDE_DIR/commands"
if [ -d "$SOURCE_DIR/commands" ] && ls "$SOURCE_DIR"/commands/*.md &>/dev/null; then
    echo "Installing Pro slash commands..."
    mkdir -p "$COMMANDS_DIR"
    for cmd in "$SOURCE_DIR"/commands/*.md; do
        [ -f "$cmd" ] || continue
        cp "$cmd" "$COMMANDS_DIR/$(basename "$cmd")"
        echo "  Installed command: /$(basename "$cmd" .md)"
    done
    echo "  Done."
fi

# --- 13. Initialize git repo ---

if [ ! -d "$INSTALL_DIR/.git" ]; then
    echo "Initializing git repository..."
    cd "$INSTALL_DIR"
    git init -q
    # Create .gitignore
    cat > .gitignore << 'GITIGNORE'
# Computed files (regenerated by scripts)
memory/project-status.md
memory/intelligence-briefing.md
memory/project-pulse.md

# Logs
logs/

# OS files
.DS_Store
GITIGNORE
    git add -A
    git commit -q -m "Initial agent hub setup"
    echo "  Done."
fi

# --- Done! ---

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Getting Started:"
echo ""
echo "  1. Edit your profile:"
echo "     $INSTALL_DIR/memory/user-profile.md"
echo ""
echo "  2. Add your first project:"
echo "     bash $INSTALL_DIR/scripts/bootstrap-project.sh ~/your-project"
echo ""
echo "  3. Open Claude Code in your project and start working."
echo "     The Stop hook will auto-capture context when sessions end."
echo ""

if ! $PRO_DETECTED; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Want playbooks, slash commands, and"
    echo "  automation scripts? Get Agent Hub Pro:"
    echo "  [GUMROAD_LINK]"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
fi
