---
name: memory-capture
description: >
  Proactive knowledge capture for decisions, insights, and session milestones.
  Fire when: an architectural decision is made, a product insight emerges,
  a cross-project connection is spotted, a session produces significant work,
  or a new approach is validated. Complements self-improve (which handles
  mistakes/corrections). This skill handles things that went RIGHT.
---

## When to Fire

### Decision Capture
- "Let's use X instead of Y" — an architectural or technology choice was made
- "We should build X before Y" — a prioritization decision
- "This UX works because..." — a product design decision
- The user says "yes, do it that way" — confirmed direction

### Insight Capture
- A cross-project pattern is spotted: "The approach from Project A would work here"
- A product insight: "Users would want X because..."
- A business insight: "This could be monetized by..."
- A working style discovery: the user prefers X over Y (not a correction, just a preference)

### Session Milestone Capture
- Significant feature completed or milestone reached
- Project status changed meaningfully (e.g., "scoring engine is done")
- A blocker was resolved and the resolution matters for future sessions

### Validation Capture
- A prior learning from learnings.md actively prevented a mistake
- An approach from one project successfully applied in another
- A pattern tracker entry proven correct by real-world use

## Where to Write

### Route by type:

**Architectural decision** → Project's `docs/decisions.md`
- Format: `[YYYY-MM-DD] CATEGORY: Description`
- Only if the decision would confuse a future session that doesn't know about it

**Product/business insight** → Project's MEMORY.md (auto-memory)
- Only if it changes how we BUILD, not just what we KNOW
- Ask: "Will this change behavior in the next session?" If no, don't write it.

**Cross-project pattern** → `~/agent/memory/learnings.md`
- Must apply to MORE than one project
- Must be specific and actionable (not vague advice)
- Check for semantic duplicates first — don't add if already captured
- Format: `SHORT_NAME (YYYY-MM): Concise actionable description.`

**Session state** → `~/agent/memory/session-bridge.md`
- Update "Last Session" section with what was accomplished
- Update "Project Status" section if status changed meaningfully
- Keep under 40 lines total

**Working style discovery** → `~/agent/memory/user-profile.md`
- Only for durable preferences, not one-time instructions
- Must be something that should apply to ALL future sessions

**Learning validation** → Project's pattern tracker
- Add to the `applied` field: `YYYY-MM-DD, context: [brief description]`
- This confirms the learning is valuable and should not be pruned

## The Signal vs Noise Test

Before writing ANYTHING, ask these three questions:
1. **Will this change behavior?** If a future session reads this, will it do something differently?
2. **Is this durable?** Will this still be true in a month? (If not, it's session context, not memory)
3. **Is this already captured?** Check the destination file for semantic duplicates first.

If any answer is NO, don't write it.

## What to NEVER Capture
- Changelogs ("added feature X") — git log handles this
- Temporary debugging context — dies with the session
- Information already in the codebase (README, config, comments)
- Vague observations that don't lead to action ("the code is complex")
- Transient state ("currently working on X") unless updating session-bridge

## Integration with Self-Improve

These two skills are complementary:
- **self-improve**: Something went WRONG. Capture the mistake so it never happens again.
- **memory-capture**: Something went RIGHT. Capture the decision/insight so it persists.

Both skills write to the same files. Neither should duplicate what the other captured.
If a correction reveals an architectural decision, self-improve handles the correction
and memory-capture handles the decision — but check that only ONE writes to each file.

## After Capture
Tell the user briefly:
- What was captured and where
- Why it matters for future sessions
- If it's a cross-project pattern, mention the connection
