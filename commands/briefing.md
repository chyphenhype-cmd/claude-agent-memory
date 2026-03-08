Morning briefing — read system state and surface what needs attention.

## Steps

0. Generate fresh project status numbers:
   `bash ~/agent/scripts/snapshot-status.sh`

1. Read the project pulse (pre-generated daily snapshot):
   `~/agent/memory/project-pulse.md`
   If it exists and was generated today, use it as the primary data source.
   If it's stale or missing, regenerate: `bash ~/agent/scripts/daily-pulse.sh`

2. Read the session bridge: `~/agent/memory/session-bridge.md`

3. Read the computed project status: `~/agent/memory/project-status.md`
   Use THIS for all page/route/service/DB counts — never session-bridge.md.

4. If the pulse file is stale (>24h), supplement with live git checks per project.
   Read `~/agent/projects.conf` for the project list, then for each project:
   - `cd <project-dir> && git log --oneline --since="7 days ago" | head -10`

5. Check learning pipeline health across all projects:
   - Read each project's pattern tracker (derive path from projects.conf)
   - Count: total patterns, tier distribution (observe/validate/enforce), any new since last briefing
   - Flag: patterns at seen: 2+ still at observe tier (ready for promotion)
   - Flag: patterns at seen: 1 older than 7 days (stale — may be noise)
   - Check learnings.md entry count vs ~40 target

6. Present a briefing with these sections:

### Where We Left Off
Summarize session-bridge.md Recent Sessions — what was the last thing we worked on in each project.

### Project Pulse
Show the activity table from project-pulse.md. Highlight anything significant.

### Project Status
Show key numbers from project-status.md (computed, not stored).

### Brain Health
From pulse file: digest/retro status, learnings count, session bridge freshness, flags.

### Learning Pipeline
- Pattern count per project and tier distribution
- Any patterns ready for promotion (seen 2+ but not yet escalated)
- Any stale patterns (seen 1, older than 7 days)
- learnings.md capacity (current / 40 target)
- Cross-project correlations spotted

### What's Next
Based on session-bridge priorities and recent momentum, recommend what to work on today. Have an opinion — don't just list options.

### Open Questions
Surface any unresolved questions from session-bridge or ideas that need discussion.

Keep it concise. This should take 30 seconds to read, not 5 minutes.
