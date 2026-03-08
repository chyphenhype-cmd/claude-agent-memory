# Launch Posts — Copy-Paste Ready

Created: 2026-03-08

---

## Twitter/X Thread

**Tweet 1 (hook):**

Claude Code forgets everything between sessions.

I built a system that makes it remember — patterns, decisions, project status — across every project, forever.

Open source. One-command setup. Here's how it works:

**Tweet 2 (the pain):**

The problem: every time you start a Claude Code session, you're starting from scratch.

Re-explain your architecture. Re-discover bugs you already fixed. Lose the decision you made Tuesday.

Now multiply that across 3 projects.

**Tweet 3 (the fix):**

Agent Hub gives Claude persistent memory through 3 files:

- user-profile.md — who you are, how you work
- session-bridge.md — what happened last session, what's next
- learnings.md — cross-project patterns (self-improving)

Claude reads them every session. Automatically.

**Tweet 4 (before/after):**

Before:
"Let's work on the API."
"I don't have context. Could you tell me about your project?"

After:
"Welcome back. Last session we refactored auth middleware. 3 of 7 routes updated. I'd start with /users next."

**Tweet 5 (the architecture):**

It also includes:

- 4 skills (self-improve captures mistakes automatically)
- 5 playbooks with real production code
- 9 automation scripts
- Stop hook that auto-captures context when sessions end

Extracted from 4 production projects and 400+ commits. Not theoretical.

**Tweet 6 (CTA):**

One command to install:

git clone https://github.com/chyphenhype-cmd/claude-agent-memory.git
cd claude-agent-memory
bash setup.sh

MIT licensed. Star it if it's useful.

https://github.com/chyphenhype-cmd/claude-agent-memory

---

## Reddit Post (r/ClaudeAI)

**Title:** I built a cross-project memory system for Claude Code — open source

**Body:**

I've been using Claude Code across 4 projects for the past few weeks and the biggest pain point was obvious: it forgets everything between sessions.

Every new conversation starts from zero. Re-explain the architecture, re-discover the same bugs, lose decisions from yesterday. Across multiple projects it's brutal.

So I built Agent Hub — a persistent memory layer that sits outside your projects and gets loaded into every Claude Code session automatically.

**What it does:**

- 3 brain files (your profile, session history, cross-project learnings) get @imported into every project's CLAUDE.md
- When you correct Claude, a self-improve skill captures the pattern with a severity counter. Same mistake twice = hard rule. Three times = enforced everywhere.
- A Stop hook auto-captures context when sessions end
- Patterns learned in one project automatically apply to all your other projects
- Slash commands for daily briefings, weekly digests, health checks
- 5 playbooks with real production code (API resilience, SQLite, React, testing, web scraping)

**The result:** Claude starts every session already knowing what happened, what's next, and what mistakes not to repeat. It actually gets smarter over time instead of resetting to zero.

**Install:**
```
git clone https://github.com/chyphenhype-cmd/claude-agent-memory.git
cd claude-agent-memory
bash setup.sh
```

Takes 60 seconds. No dependencies beyond bash and git. MIT licensed.

This isn't a template I thought would be useful — it's the actual system I run daily across 4 production projects with 400+ commits. I extracted and anonymized it so anyone can use it.

Repo: https://github.com/chyphenhype-cmd/claude-agent-memory

Happy to answer questions about the architecture or how the self-improvement pipeline works.

---

## Hacker News

**Title:** Show HN: Agent Hub – persistent cross-project memory for Claude Code

**URL:** https://github.com/chyphenhype-cmd/claude-agent-memory

HN prefers you link directly to the repo — the README does the selling. If it gets traction, comment with context about why you built it. Post during weekday morning EST for best visibility.

---

## Account Setup Priorities

1. **Twitter/X** — fastest feedback loop, tech audience is there, threads get shared
2. **Reddit (r/ClaudeAI)** — 200k+ subscribers, high intent audience
3. **Hacker News** — highest ceiling but hardest to get traction
