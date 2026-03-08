Learning Pipeline Retrospective — audit what the system has learned and what needs attention.

Run this weekly or after intensive work sessions to keep the learning pipeline healthy.

## Steps

1. Read `~/agent/projects.conf` for the project list. For each project, read its pattern tracker
   (derive Claude memory path from project directory — replace / with -).

2. Read global learnings: `~/agent/memory/learnings.md`

3. For each pattern tracker, analyze:

### Stale Patterns (seen: 1 for >7 days)
- Identify patterns that were captured once and never seen again
- Recommend: keep (valuable even if rare), reword (too narrow), or prune (noise)

### Promotion Candidates (seen: 2+ still at observe/validate)
- Patterns with enough evidence to advance to the next tier
- Recommend specific promotions: which file to write to, what wording

### Cluster Analysis
- Group related patterns under themes (e.g., "defensive coding", "data integrity", "scraper resilience")
- Identify if a cluster suggests a higher-level principle that should be a single learning

### Cross-Project Correlations
- Compare patterns across all projects
- Find patterns that appear in multiple projects (even with different names)
- These are strong candidates for global learnings.md

### Anti-Patterns (things that failed)
- Check git history for reverted commits or fix-after-fix patterns
- These reveal mistakes that should be captured but might not have been

4. Read learnings.md and analyze:

### Effectiveness Assessment
- For each learning, ask: "Has this actually prevented a mistake recently?"
- Flag learnings that may be too vague to be actionable
- Flag learnings that overlap or could be merged

### Staleness Check
- Entries from >3 months ago that haven't been referenced or updated
- Technology-specific entries that may be outdated (library versions, API behavior)

### Capacity Check
- Current count vs ~40 target
- If near capacity, recommend which entries to merge or prune

5. Present a structured report:

### Learning Pipeline Health
- Total patterns across all projects
- Tier distribution (observe / validate / enforce)
- Patterns promoted since last retro
- New patterns since last retro

### Action Items
- Patterns to promote (with specific destinations)
- Patterns to prune (with reasoning)
- Learnings to merge or reword
- Gaps: types of mistakes that keep happening without a learning

### Cross-Project Intelligence
- Correlations found between projects
- New global learnings to propose

6. Wait for user approval before making any changes.

## Rules
- Quality over quantity — removing noise is as valuable as adding signal
- A learning that's never applied might need rewording, not deletion
- Merge before splitting — 2 similar entries are worse than 1 clear one
- The goal is a lean, high-signal knowledge base, not an exhaustive encyclopedia
