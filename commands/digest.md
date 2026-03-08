Cross-Project Learning Digest — Claude-powered pattern extraction.

## Steps

1. Read the current global learnings file: `~/agent/memory/learnings.md`

2. Read `~/agent/projects.conf` for the project list. For each project:
   - Read its knowledge file (check in order: `docs/decisions.md`, `.autopilot/LEARNINGS_SUMMARY.md`, `docs/learnings.md`)
   - Read its pattern tracker (derive Claude memory path from project directory)

3. For each project, identify patterns that meet ALL of these criteria:
   - Applies to MORE than just this specific project/codebase
   - Would prevent a real bug, crash, or wasted effort in a different project
   - Is NOT already captured in `learnings.md` (check for semantic duplicates, not just exact matches)
   - Is specific and actionable (not vague advice)

4. For each candidate pattern:
   - Classify: Architecture | Coding | Data | Frontend | Scraping | Product | Business | Agent System
   - Write in the established format: `SHORT_NAME: Concise actionable description.`
   - Explain briefly why it's universal (one sentence)

5. Present findings to the user:
   - Show each candidate pattern with its classification and reasoning
   - Note the current entry count vs the ~40 max target
   - Recommend which to add and which to skip
   - Wait for user approval before writing to learnings.md

6. If approved, append new entries to the appropriate section of `~/agent/memory/learnings.md`

## Rules
- Quality over quantity — better to find 0 new patterns than to add noise
- Semantic dedup: "always use try/catch in async handlers" and "ASYNC ERROR HANDLING" are the same pattern
- If learnings.md is at or near 40 entries, recommend which existing entry to remove before adding
- Never add project-specific implementation details (specific file names, specific API endpoints)
- The pattern should make sense to someone who has never seen the source project

## Effectiveness Check (run as part of digest)
For each existing learning in learnings.md:
- Has this learning been referenced in a pattern tracker's `applied` field?
- Has a pattern tracker entry with the same theme had its seen count increase?
- If a learning has existed for >2 months with no evidence of application, flag it as a prune candidate
- Merge candidates: two learnings that could be one clearer statement

## Cross-Project Correlation (run as part of digest)
After reading all project pattern trackers:
- Identify patterns that appear in multiple projects (even if named differently)
- These are strong candidates for global promotion to learnings.md
- Note: same type of mistake in different codebases = universal pattern
