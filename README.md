# Agent Hub

### Cross-project intelligence for Claude Code.

Claude Code forgets everything when a session ends. You explain the same architecture twice, re-discover the same bugs, lose decisions made last Tuesday. Multiply that across 2-3 projects and you're spending more time re-explaining than building.

Agent Hub fixes this. It gives Claude persistent memory across sessions and across projects — your preferences, your decisions, your patterns, your project status. Claude starts every session already knowing what happened, what's next, and what mistakes to avoid.

---

## What it does

- **Persistent memory**: Claude remembers who you are, how you work, what you've built, and what you decided. Across every session. Across every project.
- **Cross-project intelligence**: A pattern learned in one project (e.g., "always validate AI response structure before accessing fields") automatically applies to all your other projects.
- **Self-improving**: When you correct Claude, it captures the pattern with a severity counter. Fix the same mistake twice and it escalates to a hard rule. Three times and it's enforced everywhere.
- **Co-founder mode**: Claude shows up prepared — reads what happened last session, checks project status, gives you a briefing, has opinions on what to build next.

---

## Before and after

**Without Agent Hub:**

```
You: Let's keep working on the API.
Claude: I don't have context on what API you're referring to.
        Could you tell me about your project?
You: [spends 10 minutes re-explaining architecture, recent changes,
      what's broken, what was decided last time]
Claude: Got it. What would you like to work on?
You: [screams internally]
```

**With Agent Hub:**

```
You: Let's keep working on the API.
Claude: Welcome back. Last session we refactored the auth middleware
        and decided to switch from JWT to session tokens (see decisions.md).
        The migration is half-done — 3 of 7 routes updated.
        I'd recommend finishing the remaining 4 routes before adding
        the refresh token logic, since the old JWT paths will break
        once we deploy. Want to start with the /users endpoint?
```

---

## Install

```bash
git clone [REPO_URL] agent-hub
cd agent-hub
bash setup.sh
```

The installer asks your name and install directory (default: `~/agent`), then:

1. Creates the directory structure and copies all scripts
2. Generates brain files from templates (user profile, session bridge, learnings)
3. Installs a `CLAUDE.md` that configures Claude as a co-founder
4. Installs 4 skills and 4 slash commands into `~/.claude/`
5. Configures a Stop hook that auto-captures context when sessions end
6. Initializes a git repo to track your memory over time

Takes about 60 seconds. No dependencies beyond bash and git.

---

## What's included

### Brain files (the memory layer)

| File | Purpose |
|------|---------|
| `memory/user-profile.md` | Who you are, how you work, what you value. Claude reads this every session. |
| `memory/session-bridge.md` | What happened last session, what's active, what's next. The #1 file for continuity. |
| `memory/learnings.md` | Cross-project patterns and anti-patterns. Capped at ~35, pruned quarterly. |

### Skills (reactive intelligence)

| Skill | Trigger |
|-------|---------|
| `self-improve` | Fires after corrections, mistakes, feedback. Captures the pattern, not just the fix. |
| `memory-capture` | Fires after decisions, insights, milestones. Routes knowledge to the right file. |
| `product-lens` | Activates during feature design. Thinks from the user's perspective. |
| `new-project-playbook` | Guides tech stack, scaffolding, and architecture for new projects. |

### Slash commands (on-demand tools)

| Command | What it does |
|---------|--------------|
| `/briefing` | Morning briefing — project status, what changed, what needs attention. |
| `/digest` | Extracts patterns from recent work across all projects into learnings. |
| `/retro` | Audits the learning pipeline — stale patterns, missing validations, promotion candidates. |
| `/health` | Runs system health check — file integrity, wiring, learning pipeline status. |

### Playbooks (production-tested code patterns)

Five playbooks extracted from real production systems. Each contains working code, not abstract advice:

- **API Resilience** — Circuit breakers, retry with exponential backoff, rate limit pacing, CLI fallback
- **SQLite Patterns** — WAL mode, JSON columns, upserts, migrations, N+1 prevention, cross-source dedup
- **React Frontend** — React Query integration, SSE streams, optimistic updates, command palette
- **Testing** — Offline scraper testing, optional imports, event bus testing, pure function extraction
- **Web Scraping** — Anti-bot layering, DOM vs API interception, enrichment preservation

### Automation scripts

| Script | Purpose |
|--------|---------|
| `bootstrap-project.sh` | Wires a project into the brain (adds @imports, pattern tracker, docs scaffolding, hooks) |
| `system-health.sh` | Validates file integrity, wiring, learning pipeline, script syntax |
| `snapshot-status.sh` | Generates verified project status from git/filesystem (no stale data) |
| `knowledge-compile.sh` | Compiles intelligence briefing from all projects |
| `daily-pulse.sh` | Daily activity snapshot across all projects |
| `weekly-digest.sh` | Extracts cross-project learnings from the week |
| `weekly-retro.sh` | Audits the learning pipeline for staleness |
| `capture-all-projects.sh` | Auto-captures context on session end (used by Stop hook) |

---

## How it works

```
~/agent/                          <-- The brain (lives outside your projects)
  CLAUDE.md                       <-- Loaded by Claude Code, wires everything together
  memory/
    user-profile.md               <-- Your identity, preferences, working style
    session-bridge.md             <-- Recent sessions, active work, open questions
    learnings.md                  <-- Cross-project patterns (35 max, tiered)
    playbooks/                    <-- Deep reference implementations
  scripts/                        <-- Automation (health, status, compile, bootstrap)
  projects.conf                   <-- Registry of all connected projects

~/your-project/
  CLAUDE.md                       <-- Has @imports pointing to the brain files
  docs/decisions.md               <-- Project-specific decision log
  docs/evolution.md               <-- Project narrative (what was built and why)

~/.claude/
  skills/                         <-- Self-improve, memory-capture, product-lens
  commands/                       <-- /briefing, /digest, /retro, /health
  settings.json                   <-- Stop hook for auto-capture
```

Every project's `CLAUDE.md` uses `@import` directives to pull in the brain files. When you open Claude Code in any project, it automatically reads your profile, recent session history, cross-project learnings, and project-specific context. When the session ends, the Stop hook captures what happened.

Patterns flow through a three-tier pipeline:
1. **Observe** (seen once) -- captured in the project's pattern tracker
2. **Validate** (seen 2+) -- promoted to project decisions or global learnings
3. **Enforce** (seen 3+) -- written into CLAUDE.md rules or automated hooks

---

## Adding a project

```bash
bash ~/agent/scripts/bootstrap-project.sh ~/your-project
```

The script:
1. Appends `@import` directives to your project's `CLAUDE.md` (pointing to the brain)
2. Asks what kind of project (web app, scraper, CLI, bot) and adds relevant playbook imports
3. Registers the project in the hub's `CLAUDE.md` and `projects.conf`
4. Creates a pattern tracker at `~/.claude/projects/.../memory/patterns.md`
5. Scaffolds `docs/decisions.md` and `docs/evolution.md` if they don't exist
6. Creates `.claude/settings.local.json` with safety hooks (blocks destructive commands, auto-lints on save)

Your project needs a `CLAUDE.md` file before bootstrapping. If you don't have one, create a basic one describing the project.

---

## Daily workflow

**Morning:**
```
cd ~/agent && claude
> /briefing
```

Claude reads all project status, recent sessions, and overnight activity. Gives you a briefing: what changed, what's blocked, what to work on.

**During work:**

Just build. Claude remembers your patterns, your architecture decisions, your preferences. When you make a mistake it's seen before, it catches it. When you correct it on something new, it captures the pattern for next time.

**End of session:**

The Stop hook fires automatically and captures session context. For significant sessions, Claude also updates the session bridge with what was done and what's next.

**Weekly:**
```
> /digest
> /retro
```

`/digest` pulls patterns from the week's work across all projects and promotes recurring ones to global learnings. `/retro` audits the pipeline — flags stale patterns, suggests promotions, identifies gaps.

---

## Commands reference

### /briefing

Generates project status from git and filesystem (not stale docs), compiles intelligence from all projects, and presents a briefing: recent sessions, active work, blockers, and recommendations.

### /digest

Reads autopilot logs, recent commits, and pattern trackers across all projects. Extracts new patterns, validates existing ones against evidence, and promotes recurring patterns to `learnings.md`.

### /retro

Audits the learning pipeline: which patterns are stale (not validated recently), which should be promoted to higher tiers, which should be pruned. Keeps the knowledge base healthy.

### /health

Runs `system-health.sh` and interprets results. Checks: brain file existence, project wiring (@imports present), script syntax, learning pipeline state, doc staleness.

---

## FAQ

**Do I need to use all of this?**

No. The core value comes from three files: `user-profile.md`, `session-bridge.md`, and `learnings.md`. The skills, commands, and automation scripts compound the value over time but aren't required on day one. Start with the brain files, add the rest as you feel the need.

**Does this work with any project / language?**

Yes. The brain files and memory system are language-agnostic. The playbooks contain language-specific code (JavaScript, Python) but they're reference material, not dependencies. The bootstrap script detects your project language and wires up appropriate playbooks.

**How is this different from just putting instructions in CLAUDE.md?**

A single CLAUDE.md is project-local and static. Agent Hub gives you cross-project memory (a pattern from your API project helps your CLI tool), persistent session history (Claude knows what you did yesterday), and a self-improving knowledge pipeline (mistakes get captured, validated, and enforced automatically). The architecture is what matters -- not any single file.

**Will this slow down Claude Code?**

The brain files total a few hundred lines. Claude Code loads them as context alongside your project's CLAUDE.md. The overhead is minimal and the context is highly relevant -- Claude spends less time asking questions and more time building.

---

## Requirements

- Claude Code (any plan)
- macOS or Linux
- bash, git

---

## License

MIT

---

Built by extracting the intelligence system from 4 production projects and 400+ commits. This is not a template someone imagined would be useful -- it's the system that actually runs.

[GUMROAD_LINK]
