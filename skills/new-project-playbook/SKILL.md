---
name: new-project-playbook
description: >
  Load when starting a new project from scratch, choosing a tech stack,
  scaffolding initial architecture, or running bootstrap-project.sh.
  Contains proven patterns, startup checklists, and stack
  decision guides based on real experience across multiple projects.
  Also load when the user says "new project", "start something new",
  "I have an idea for", or "what stack should I use".
---

## Before Writing Any Code

### 1. Define the Product (10 minutes, saves 10 hours)
- What problem does this solve? For who?
- Would you (or someone like you) pay for this? How much?
- What's the absolute minimum version that proves the idea works?
- Write a 3-sentence pitch before touching code

### 2. Choose the Stack (proven patterns)

**Web App with API**:
- Frontend: React + Vite + Tailwind CSS + shadcn components
- Backend: Express (ESM) with modular routes/ and services/
- Database: SQLite (better-sqlite3, WAL mode) — scales further than people think
- AI: Anthropic SDK with callAnthropicWithRetry() wrapper
- Why: Proven stack, fast to build, easy to deploy, Claude knows it deeply

**Scraper/Data Pipeline**:
- Python 3.9+ with venv
- Scraping: Playwright for JS-heavy sites, requests for APIs
- Database: SQLite with WAL mode
- Dashboard: Streamlit (fast to build) or React (if it'll become a product)
- Why: Python ecosystem is best for scraping/data. Streamlit is fast for personal tools.

**Trading Bot / Autonomous Tool**:
- Python for strategy logic and exchange APIs
- SQLite for trade history and state
- Separate monitoring dashboard
- Safety: paper trading first, graduated trust, hard position limits
- Why: Python has the best exchange API libraries. Safety is non-negotiable.

**CLI Tool / Script**:
- Python or Node depending on the ecosystem
- Keep it simple — single file until it needs to grow
- Why: don't over-architect things that might stay small

### 3. Scaffold Right From Day One

**Every project gets these immediately:**
```
project/
  CLAUDE.md          # Concise: stack, commands, standards, gotchas, @imports brain
  .claude/
    settings.local.json  # Hooks: auto-lint, destructive command blocking
  docs/
    decisions.md     # Architecture decisions and learnings (curated)
  .gitignore
  README.md
```

**Wire into the brain:**
```bash
~/agent/scripts/bootstrap-project.sh <project-dir>
```
This connects the project to the global intelligence system automatically.
The bootstrap script will:
- Ask what kind of project and inject relevant playbook @imports
- Create docs/decisions.md and docs/evolution.md with template headers
- Create .claude/settings.local.json with auto-lint and destructive command blocking
- Wire @imports to brain files, create pattern tracker

**Playbooks** (deep knowledge extracted from existing projects):
- `~/agent/memory/playbooks/api-resilience.md` — retry, caching, rate limiting, circuit breaker
- `~/agent/memory/playbooks/web-scraping.md` — anti-bot, DOM vs API, dedup, enrichment
- `~/agent/memory/playbooks/sqlite-patterns.md` — DAL, WAL, JSON columns, transactions, dedup
- `~/agent/memory/playbooks/react-frontend.md` — React Query, SSE, command palette, dark theme
- `~/agent/memory/playbooks/testing-patterns.md` — offline testing, optional imports
Load playbooks on-demand for the project type — they contain real code from proven projects.

## Day One Patterns (apply to EVERY project)

### Database
- SQLite WAL mode from the start (one line, prevents future headaches)
- DAL layer: typed CRUD functions, never raw SQL in route handlers
- Field whitelisting on all write operations from day one
- NULL means unknown, 0 means confirmed no, 1 means confirmed yes

### Error Handling
- Top-level try/catch in every async handler from the first endpoint
- Process-level exception handlers (uncaughtException, unhandledRejection)
- Graceful shutdown handler (close DB, clear timers, close server)

### AI Integration (if applicable)
- Retry wrapper with exponential backoff from the first API call
- Rate limit awareness — know your limits before you hit them
- Safe response extraction — never trust AI output structure directly
- Circuit breaker pattern if making frequent calls

### Security (always, no exceptions)
- Field whitelisting on inputs
- No raw SQL with user data — parameterized queries only
- No secrets in code — .env files, gitignored
- Block destructive commands in hooks

### Git
- Initialize immediately, commit early and often
- Feature branches for experimental work
- Conventional commit messages for readable history

## Product Checklist (for projects that might become products)
- [ ] Can someone unfamiliar understand what this does in 10 seconds?
- [ ] Is there a clear "aha moment" in the first 2 minutes of using it?
- [ ] What would the landing page headline be?
- [ ] What's the pricing: free, freemium, or paid? Why?
- [ ] Who are 3 specific people/companies who would buy this?

## After Scaffolding
- Update ~/agent/memory/session-bridge.md with the new project
- Start a decisions.md log from the first architectural choice
- Set up auto-lint hooks immediately (don't "add them later")
- Write the first test alongside the first feature, not after
