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
git clone https://github.com/chyphenhype-cmd/claude-agent-memory.git agent-hub
cd agent-hub
bash setup.sh
```

The installer asks your name and install directory (default: `~/agent`), then:

1. Creates the directory structure and copies scripts
2. Generates brain files from templates (user profile, session bridge, learnings)
3. Installs a `CLAUDE.md` that configures Claude as a co-founder
4. Installs the self-improve skill into `~/.claude/`
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

### Self-improve skill (reactive intelligence)

| Skill | Trigger |
|-------|---------|
| `self-improve` | Fires after corrections, mistakes, feedback. Captures the pattern, not just the fix. |

The self-improvement pipeline is what separates Agent Hub from a static CLAUDE.md. Correct Claude once → pattern captured. Same mistake twice → hard rule. Three times → enforced across every project.

### Automation

| Script | Purpose |
|--------|---------|
| `capture-all-projects.sh` | Auto-captures context on session end (used by Stop hook) |
| `bootstrap-project.sh` | Wires a project into the brain (adds @imports, pattern tracker, docs scaffolding) |

---

## How it works

```
~/agent/                          <-- The brain (lives outside your projects)
  CLAUDE.md                       <-- Loaded by Claude Code, wires everything together
  memory/
    user-profile.md               <-- Your identity, preferences, working style
    session-bridge.md             <-- Recent sessions, active work, open questions
    learnings.md                  <-- Cross-project patterns (35 max, tiered)
  scripts/                        <-- Automation (capture, bootstrap)
  projects.conf                   <-- Registry of all connected projects

~/your-project/
  CLAUDE.md                       <-- Has @imports pointing to the brain files
  docs/decisions.md               <-- Project-specific decision log
  docs/evolution.md               <-- Project narrative (what was built and why)

~/.claude/
  skills/self-improve/            <-- Captures mistakes as patterns automatically
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
2. Registers the project in the hub's `CLAUDE.md` and `projects.conf`
3. Creates a pattern tracker at `~/.claude/projects/.../memory/patterns.md`
4. Scaffolds `docs/decisions.md` and `docs/evolution.md` if they don't exist

Your project needs a `CLAUDE.md` file before bootstrapping. If you don't have one, create a basic one describing the project.

---

## Daily workflow

**Morning:**
```
cd ~/agent && claude
```

Claude reads session bridge, checks recent git activity across your projects. You pick up where you left off.

**During work:**

Just build. Claude remembers your patterns, your architecture decisions, your preferences. When you make a mistake it's seen before, it catches it. When you correct it on something new, it captures the pattern for next time.

**End of session:**

The Stop hook fires automatically and captures session context. For significant sessions, Claude also updates the session bridge with what was done and what's next.

---

## Agent Hub Pro

The free version gives you persistent memory and self-improvement — the core loop that makes Claude actually useful across sessions.

**Pro adds the power features that make the system compound:**

- **3 additional skills** — memory-capture (proactive knowledge routing), product-lens (user + business perspective on every feature), new-project-playbook (tech stack + scaffolding guides)
- **4 slash commands** — `/briefing` (morning project status), `/digest` (cross-project pattern extraction), `/retro` (learning pipeline audit), `/health` (system integrity check)
- **5 playbooks** — Production-tested code patterns extracted from real projects: API resilience (circuit breakers, retry, rate limiting), SQLite (WAL, JSON columns, upserts, N+1 prevention), React frontend (React Query, SSE, optimistic updates), testing (offline scraper testing, event bus testing), web scraping (anti-bot, DOM vs API interception)
- **6 automation scripts** — System health check, project status snapshots, intelligence compiler, daily pulse, weekly digest, weekly retrospective
- **Customization Guide** — 2,500+ words on getting 10x more out of the system: writing effective profiles, session bridge practices, useful learnings vs noise, common mistakes
- **Email support** — Direct help getting set up

### Free vs Pro

| | Free | Pro ($49) |
|---|---|---|
| Brain files (profile, session bridge, learnings) | ✓ | ✓ |
| Self-improve skill | ✓ | ✓ |
| Stop hook + capture script | ✓ | ✓ |
| Bootstrap script | ✓ | ✓ |
| 3 additional skills | — | ✓ |
| 4 slash commands | — | ✓ |
| 5 production playbooks | — | ✓ |
| 6 automation scripts | — | ✓ |
| Customization Guide | — | ✓ |
| Email support | — | ✓ |

**Get Pro:** https://chyphenhype.gumroad.com/l/vmewkp

Pro buyers: download the zip, run `bash install-pro.sh` inside your existing Agent Hub installation.

---

## FAQ

**Do I need to use all of this?**

No. The core value comes from three files: `user-profile.md`, `session-bridge.md`, and `learnings.md`. The self-improve skill makes it compound automatically. Start there — it's everything you need.

**Does this work with any project / language?**

Yes. The brain files and memory system are language-agnostic. The playbooks (Pro) contain language-specific code (JavaScript, Python) but they're reference material, not dependencies.

**How is this different from just putting instructions in CLAUDE.md?**

A single CLAUDE.md is project-local and static. Agent Hub gives you cross-project memory (a pattern from your API project helps your CLI tool), persistent session history (Claude knows what you did yesterday), and a self-improving knowledge pipeline (mistakes get captured, validated, and enforced automatically). The architecture is what matters -- not any single file.

**Will this slow down Claude Code?**

The brain files total a few hundred lines. Claude Code loads them as context alongside your project's CLAUDE.md. The overhead is minimal and the context is highly relevant -- Claude spends less time asking questions and more time building.

**Does this work with Claude Pro / Team / API?**

Agent Hub works with Claude Code on any plan — Pro, Team, or Enterprise. It uses CLAUDE.md files and the Claude Code skill/command system, so it works regardless of how you're authenticated.

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
