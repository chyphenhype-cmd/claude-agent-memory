---
name: self-improve
description: >
  Invoke after any correction, mistake identification, user feedback,
  or when the user says "remember this", "don't do that again", or similar.
  Also invoke when the same type of error is seen twice in one session, or when
  an autopilot cycle fails and then succeeds. Captures ALL types of patterns —
  technical, product, business, and personal working style — to prevent
  recurring mistakes and compound intelligence across sessions.
---

## When to Invoke

### Capture Events (something went wrong or was learned)
- User corrects a mistake (code, product decision, business reasoning, communication style)
- User says "remember this", "don't do that again", or gives explicit feedback
- An autopilot iteration fails and then succeeds (capture the fix)
- A debugging session reveals a non-obvious root cause
- The SAME type of error appears twice in one session (auto-detect escalation)
- A product or business insight emerges during conversation
- the user pushes back on a recommendation (capture WHY he disagreed)
- A fix that reverts a previous fix (regression indicator — needs a rule)
- An approach was tried and abandoned (anti-pattern — capture why it failed)

### Application Events (a learning was used)
- You read learnings.md and one of the entries influenced your decision
- You avoided a mistake because of a known pattern
- A pattern from one project informed a decision in another project
When this happens:
1. Note it in the pattern tracker entry's `applied` field with date and context
2. The weekly retro validates learnings against git commit evidence automatically — no manual tracking needed

## What to Capture — NOT Just Code

### Technical Patterns
- Coding mistakes, architecture decisions, debugging insights

### Product Patterns
- UX insights: "users would find this confusing because..."
- Feature decisions: "we built X instead of Y because..."
- What made a feature feel good or bad to use

### Business Patterns
- Market insights: "recruiters pay $X for this type of tool"
- Pricing decisions: "freemium works better than paywall for..."
- Monetization angles discovered during building

### Working Style Patterns
- How the user prefers to be communicated with
- What level of detail he wants in different contexts
- Decision-making preferences revealed through corrections
- When he wants autonomy vs when he wants to be consulted

### Anti-Patterns (NEW — things that FAILED)
- Approaches that were tried and didn't work, with WHY
- These prevent future sessions from re-attempting dead ends
- Format: `type: anti-pattern` in the pattern tracker
- Example: "Tried DOM scraping on Apartments.com — Akamai WAF blocks all automated access"

## Project Detection — CRITICAL

Detect the current project dynamically from the working directory. Do NOT assume a fixed list.

### Step 1: Identify the project root
Walk up from the current working directory until you find a directory containing `CLAUDE.md`.
That directory is the **project root**. Extract the project name from the directory name.

### Step 2: Derive the Claude memory path
Claude Code stores project memory at `~/.claude/projects/` using the absolute path with
slashes replaced by dashes. For example:
- `~/my-app` -> `~/.claude/projects/-Users-yourname-my-app/memory/`
- `~/Projects/side-project` -> `~/.claude/projects/-Users-yourname-Projects-side-project/memory/`

Construct the path by taking the project root's absolute path and replacing `/` with `-`.

### Step 3: Find or create the project pattern tracker
Look for `patterns.md` in the project's Claude memory directory (from Step 2).
If it doesn't exist, **create it** with the template:
```
# Pattern Tracker — [ProjectName]

Tracks recurring patterns with seen counters for automatic escalation.
- Tier 1 (seen: 1) -> captured here only
- Tier 2 (seen: 2+) -> also in project decisions/learnings
- Tier 3 (seen: 3+) -> also in CLAUDE.md or enforced via hook

---
```

### Step 4: Find the project's knowledge file
Check in order (use the first one found):
- `docs/decisions.md`
- `.autopilot/LEARNINGS_SUMMARY.md`
- `docs/learnings.md`
If none exist, skip project-level knowledge file writes (pattern tracker is sufficient).

### Special case: ~/agent/
If working directly in `~/agent/`, write only to global files.

**Global files (ALWAYS available, regardless of project):**
- Global learnings: `~/agent/memory/learnings.md`
- the user profile (for working style patterns): `~/agent/memory/user-profile.md`

## The Three-Tier Learning Pipeline

### Tier 1: OBSERVE — Capture the Pattern
1. **Identify what happened**: What was the mistake, insight, or learning?
2. **Classify it**:
   - `technical` — code, architecture, tooling
   - `product` — UX, feature design, user experience
   - `business` — market, pricing, monetization, strategy
   - `style` — how the user works, communicates, makes decisions
   - `gotcha` — specific trap that catches you once
   - `rule` — must always/never do (critical correctness)
   - `anti-pattern` — approach that was tried and failed (capture why)
3. **Determine scope**:
   - `project` — specific to this codebase
   - `global` — applies to any project
4. **Check the project's pattern tracker**
   - If this pattern already exists, increment its `seen` counter and update `last` date
   - If new, add it with `seen: 1`
5. **Cross-project correlation check** (NEW):
   - Read the OTHER project's pattern tracker
   - If a similar pattern exists there, this is evidence for global scope
   - Note the correlation in both trackers

### Tier 2: VALIDATE — Track Recurrence
- `seen: 1` -> First occurrence. Pattern tracker only.
- `seen: 2` -> Recurring. Also write to project decisions/learnings file.
- `seen: 3+` -> Battle-tested. Promote to project CLAUDE.md Gotchas section.

### Auto-Escalation Triggers (skip tiers when evidence is strong):
- **Security/safety pattern** -> immediately promote to enforce tier, regardless of seen count
- **Pattern found in BOTH projects** -> immediately promote to global learnings
- **Pattern caused data loss or crash** -> immediately promote to enforce tier
- **the user explicitly says "always" or "never"** -> immediately promote to enforce tier

### Tier 3: ENFORCE — Promote to Deterministic Rules
When a pattern reaches `seen: 3+` AND is critical to correctness:
- Technical rules: consider a hook (PostToolUse/PreToolUse) and describe what it would do
- Product rules: add to product-lens skill
- Business rules: add to learnings.md Business section
- Style rules: add to user-profile.md

## Write Routing

### ALWAYS write to the project's pattern tracker
Every pattern gets recorded in the current project's patterns.md.

### ALSO write to global when scope is "global"
Technical/product/business patterns that apply universally:
- Append to `~/agent/memory/learnings.md` under the right section
- Format: `SHORT_NAME (YYYY-MM): Concise actionable description.`
- Check for duplicates first — semantic, not just exact match

Working style patterns:
- Update `~/agent/memory/user-profile.md` under the relevant section
- These are about WHO the user is, not what we learned about code

### The Correction Protocol (for when the user pushes back)
1. Note the correction
2. Form a hypothesis: "I think you pushed back because [reason]"
3. Ask the user: "Am I reading that right?"
4. Store the UNDERSTANDING, not just the correction
5. If it reveals a working style pattern, update user-profile.md

## Pattern Tracker Entry Format
```
### [SHORT_NAME]
- seen: N
- type: technical|product|business|style|gotcha|rule|anti-pattern
- scope: project|global
- tier: observe|validate|enforce
- rule: [Concise, actionable description]
- first: YYYY-MM-DD
- last: YYYY-MM-DD
- applied: [optional — dates and contexts where this learning prevented a mistake]
- related: [optional — names of related patterns in this or other project trackers]
```

## Learning Effectiveness Protocol (NEW)

When you notice you're APPLYING a known learning (not just capturing a new one):

1. Identify which learning or pattern influenced the decision
2. Update the pattern tracker entry: add to its `applied` field
3. If the learning is in learnings.md, this confirms its value — note it mentally for retro
4. If a learning is being applied cross-project, that's strong signal for global promotion

This creates a feedback loop: learnings that are frequently applied are confirmed valuable.
Learnings that are never applied may need rewording or pruning.

### Confirm to User
Tell the user:
- What pattern was captured and WHY it matters
- Where it was written (project tracker + global if applicable)
- Current tier (observe/validate/enforce)
- Whether escalation is recommended
- If cross-project correlations were found, mention them

## Self-Evolution
If this improvement process itself missed something, update this SKILL.md.
