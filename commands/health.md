Run the agent system health check and interpret the results.

## Steps

1. Run: `~/agent/scripts/system-health.sh`

2. Analyze the output and flag any issues:
   - Session bridge older than 3 days → suggest updating
   - Learnings over 40 entries → suggest pruning
   - Any project missing brain file imports → flag and offer to fix
   - Pattern trackers with 0 entries → the self-improve pipeline isn't firing
   - Any pattern at seen: 3+ still at tier "observe" → should be escalated
   - Learning pipeline: stale patterns or promotion candidates → suggest running /project:retro
   - Project hooks: any project missing PostToolUse or PreToolUse → flag the gap

3. Present a brief summary: what's healthy, what needs attention, and recommended actions.
   If learning pipeline issues found, recommend `/project:retro` for deeper analysis.
