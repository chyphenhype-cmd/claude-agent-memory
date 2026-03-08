---

# API Resilience Playbook
Source: Production Node/Express app
Last extracted: 2026-03-07

---

## Patterns

### 1. Circuit Breaker — Fail Fast After Repeated Failures

**When to use:** Wrapping any external API where consecutive failures indicate the service is down. Prevents queuing long retry cycles when the upstream is clearly unavailable.

**Code (from a production Express app's AI service module):**

```js
const circuitBreaker = {
  failures: 0,
  lastFailure: 0,
  openUntil: 0,
  THRESHOLD: 3,          // consecutive failures to trip
  WINDOW_MS: 300_000,    // 5 min window for counting failures
  COOLDOWN_MS: 600_000,  // 10 min cooldown when tripped
};

function checkCircuitBreaker() {
  if (Date.now() < circuitBreaker.openUntil) {
    const remainSec = Math.round((circuitBreaker.openUntil - Date.now()) / 1000);
    throw new Error(`Circuit breaker open — API unavailable. Retry in ${remainSec}s.`);
  }
  // Reset if window expired
  if (Date.now() - circuitBreaker.lastFailure > circuitBreaker.WINDOW_MS) {
    circuitBreaker.failures = 0;
  }
}

function recordSuccess() {
  circuitBreaker.failures = 0;
}

function recordFailure() {
  circuitBreaker.failures++;
  circuitBreaker.lastFailure = Date.now();
  if (circuitBreaker.failures >= circuitBreaker.THRESHOLD) {
    circuitBreaker.openUntil = Date.now() + circuitBreaker.COOLDOWN_MS;
    log.error({ failures: circuitBreaker.failures, cooldownMin: circuitBreaker.COOLDOWN_MS / 60000 }, 'Circuit breaker tripped');
  }
}
```

**Key gotchas:**
- Circuit breaker is checked BEFORE the retry loop starts (`checkCircuitBreaker()` is the first call in `callAnthropicWithRetry`).
- Failure window auto-resets if enough time passes without failures — no manual reset needed.
- Only `recordFailure()` is called when retries are exhausted; rate-limit retries do NOT count as failures.

---

### 2. Retry with Exponential Backoff + Graceful Fallback

**When to use:** Any rate-limited API call. The exponential backoff prevents hammering, and the CLI fallback demonstrates the pattern of having a secondary path when the primary is exhausted.

**Code (from a production Express app's AI service module):**

```js
export async function callAnthropicWithRetry(params, maxRetries = 4) {
  checkCircuitBreaker();
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      const result = await anthropic.messages.create({ ...params, timeout: 120000 });
      recordSuccess();
      return result;
    } catch (err) {
      // Fall back to Claude CLI if API usage limits are hit
      if (err.status === 400 && err.message?.includes('usage limits')) {
        _apiLimitHit = true;
        log.info({ model: params.model }, 'API limit reached — falling back to Claude CLI (Max subscription)');
        return callClaudeCLIFallback(params);
      }

      const is429 = err.status === 429 || (err.message && err.message.includes('rate_limit'));
      if (is429 && attempt < maxRetries) {
        const backoff = Math.min(90000 * Math.pow(2, attempt), 720000) + Math.random() * 10000;
        log.warn({ attempt: attempt + 1, maxRetries, backoffSec: Math.round(backoff / 1000), model: params.model }, 'Rate limited, retrying');
        await new Promise(r => setTimeout(r, backoff));
        continue;
      }
      recordFailure();
      throw err;
    }
  }
}
```

**Key gotchas:**
- Backoff schedule: 90s -> 180s -> 360s -> 720s (capped), plus random jitter of 0-10s to prevent thundering herd.
- The `timeout: 120000` on the API call itself is separate from the retry backoff — it prevents hanging on a single request.
- The CLI fallback (`callClaudeCLIFallback`) spawns a child process with `ANTHROPIC_API_KEY` deleted from env, forcing it to use Max subscription auth instead of the exhausted API key. This is a clever undocumented pattern.
- Only 429 errors trigger retry. A 400 "usage limits" error triggers the fallback path immediately — no retries wasted.

---

### 3. Rate Limit Pacing with Promise Chain

**When to use:** When you have an org-level token budget (e.g., 30k tokens/min) shared across all callers. Prevents concurrent callers from racing past the limit.

**Code (from a production Express app's AI service module):**

```js
const API_PACE_MS = 90000;
let lastApiCall = 0;
let _paceChain = Promise.resolve();
let _apiLimitHit = false;

export function isApiLimitHit() { return _apiLimitHit; }

export async function paceApiCall() {
  if (_apiLimitHit) {
    log.debug('Skipping pace — API limits hit, using CLI fallback');
    return;
  }
  _paceChain = _paceChain.then(() => new Promise(resolve => {
    const elapsed = Date.now() - lastApiCall;
    const wait = (elapsed < API_PACE_MS && lastApiCall > 0) ? API_PACE_MS - elapsed : 0;
    if (wait > 0) log.debug({ waitSec: Math.round(wait / 1000) }, 'Pacing API call');
    setTimeout(() => { lastApiCall = Date.now(); resolve(); }, wait);
  }));
  return _paceChain;
}
```

**Key gotchas:**
- The promise chain (`_paceChain`) serializes concurrent callers — each waits for the previous one to clear. Without this, two concurrent route handlers would both see "90s elapsed" and fire simultaneously.
- Once API limits are hit (`_apiLimitHit = true`), pacing is skipped entirely because the CLI fallback uses a separate rate pool (Max subscription).
- Call `await paceApiCall()` BEFORE every `callAnthropicWithRetry()` that uses `web_search` (those are the expensive calls).

---

### 4. CLI Fallback — Secondary Execution Path

**When to use:** When your primary API has hard spending/rate limits but you have an alternative execution path (e.g., a subscription-based CLI, a secondary API key, a different provider).

**Code (from a production Express app's AI service module):**

```js
async function callClaudeCLIFallback(params) {
  const systemPrompt = params.system || '';
  const userMsg = params.messages?.find(m => m.role === 'user')?.content;
  const userPrompt = typeof userMsg === 'string'
    ? userMsg
    : Array.isArray(userMsg)
      ? userMsg.filter(b => b.type === 'text').map(b => b.text).join('\n')
      : '';

  const model = params.model?.includes('haiku') ? 'haiku' : 'sonnet';
  const needsWebSearch = params.tools?.some(t =>
    t.type?.includes('web_search') || t.name?.includes('web_search')
  );

  const args = ['-p', userPrompt, '--output-format', 'text', '--model', model];
  if (systemPrompt) args.push('--system-prompt', systemPrompt);
  if (needsWebSearch) args.push('--allowedTools', 'WebSearch,WebFetch');

  // Remove env vars that interfere with CLI fallback
  const env = { ...process.env };
  delete env.CLAUDECODE;
  delete env.ANTHROPIC_API_KEY;

  // Sonnet with web_search can take 4-5 min for deep research
  const TIMEOUT_MS = model === 'sonnet' && needsWebSearch ? 360000 : 180000;

  return new Promise((resolve, reject) => {
    const child = spawn('claude', args, {
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });

    const timer = setTimeout(() => {
      child.kill('SIGTERM');
      reject(new Error(`Claude CLI timed out after ${TIMEOUT_MS / 1000}s`));
    }, TIMEOUT_MS);

    child.on('close', (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        reject(new Error(`Claude CLI exited with code ${code}: ${(stderr || stdout).substring(0, 200)}`));
        return;
      }
      resolve({
        content: [{ type: 'text', text: stdout.trim() }],
        model: params.model,
        stop_reason: 'end_turn',
      });
    });

    child.on('error', (err) => {
      clearTimeout(timer);
      reject(new Error(`Claude CLI spawn failed: ${err.message}`));
    });
  });
}
```

**Key gotchas:**
- `stdio: ['ignore', 'pipe', 'pipe']` — stdin is closed to prevent the child process from hanging waiting for input.
- `delete env.ANTHROPIC_API_KEY` — forces the CLI to authenticate via Max subscription instead of the exhausted API key. Without this, the fallback hits the same limit.
- `delete env.CLAUDECODE` — prevents nested session detection which would change CLI behavior.
- Timeout is model-aware: 6 minutes for Sonnet+web_search, 3 minutes otherwise.
- The response is normalized to match the Anthropic SDK response shape (`{ content: [{ type: 'text', text }] }`) so callers don't need to know which path was used.

---

### 5. Safe JSON Extraction from AI Responses

**When to use:** Every time you parse structured data from an LLM response. AI responses can have markdown wrapping, trailing commas, missing content blocks, or unexpected structure.

**Code (from a production Express app's AI service module):**

```js
export function extractJson(text, type = 'object') {
  if (!text) return { data: null, error: 'Empty response' };

  // Strip markdown code blocks first (CLI fallback wraps JSON in ```json...```)
  const stripped = text.replace(/```(?:json)?\s*\n?/g, '');

  const open = type === 'array' ? '[' : '{';
  const close = type === 'array' ? ']' : '}';

  // Find the balanced JSON by counting brackets
  const startIdx = stripped.indexOf(open);
  if (startIdx === -1) return { data: null, error: 'No JSON found in response' };

  let depth = 0;
  let inString = false;
  let escape = false;
  for (let i = startIdx; i < stripped.length; i++) {
    const ch = stripped[i];
    if (escape) { escape = false; continue; }
    if (ch === '\\' && inString) { escape = true; continue; }
    if (ch === '"') { inString = !inString; continue; }
    if (inString) continue;
    if (ch === open) depth++;
    else if (ch === close) {
      depth--;
      if (depth === 0) {
        const candidate = stripped.substring(startIdx, i + 1);
        try {
          return { data: JSON.parse(candidate), error: null };
        } catch (err) {
          try {
            // Fix trailing commas (common AI mistake)
            const cleaned = candidate.replace(/,\s*([}\]])/g, '$1');
            return { data: JSON.parse(cleaned), error: null };
          } catch {
            return { data: null, error: `JSON parse failed: ${err.message}` };
          }
        }
      }
    }
  }

  return { data: null, error: 'No complete JSON found (unbalanced brackets)' };
}
```

**Key gotchas:**
- Returns `{ data, error }` tuple — callers always check both. Never throws.
- Strips markdown code fences first because the CLI fallback wraps JSON in ``` blocks.
- Uses bracket-depth counting instead of regex to find balanced JSON — handles nested objects correctly.
- Auto-fixes trailing commas (`/,\s*([}\]])/g`) which LLMs frequently produce.
- Supports both `'object'` and `'array'` types via the `type` parameter.
- NEVER use `msg.content[0].text` directly — content blocks can be missing or have unexpected types.

---

### 6. TTL Cache with Express Middleware + Invalidation Key Maps

**When to use:** Caching expensive computed endpoints (analytics, aggregations) where the data changes only on writes, not reads.

**Cache core (from a production Express app's cache service):**

```js
const store = new Map();

export function cacheGet(key) {
  const entry = store.get(key);
  if (!entry) return null;
  if (Date.now() > entry.expiresAt) {
    store.delete(key);
    return null;
  }
  return entry.value;
}

export function cacheSet(key, value, ttlMs) {
  store.set(key, { value, expiresAt: Date.now() + ttlMs });
}

export function cacheInvalidate(pattern) {
  if (typeof pattern === 'string') {
    for (const key of store.keys()) {
      if (key === pattern || key.startsWith(pattern + ':')) {
        store.delete(key);
      }
    }
  } else {
    store.clear();
  }
}

// Express middleware: cache GET responses with TTL
export function cached(key, ttlMs) {
  return (_req, res, next) => {
    const hit = cacheGet(key);
    if (hit) return res.json(hit);
    const originalJson = res.json.bind(res);
    res.json = (data) => {
      cacheSet(key, data, ttlMs);
      return originalJson(data);
    };
    next();
  };
}
```

**Usage — middleware on route:**

```js
router.get('/kpi-stats', cached('kpi-stats', 30_000), (_req, res) => { ... });
router.get('/follow-up-queue', cached('follow-up-queue', 60_000), (_req, res) => { ... });
router.get('/relationship-scores', cached('relationship-scores', 120_000), (_req, res) => { ... });
```

**Invalidation key map (from the CRUD route module):**

```js
const CACHE_INVALIDATION = {
  companies: ['kpi-stats', 'follow-up-queue', 'revenue-forecast', 'relationship-scores',
    'activity-insights', 'win-loss-analytics', 'market-pulse', 'weekly-report', 'notifications',
    'territory-map', 'revenue-goals', 'velocity-alerts', 'next-action-queue'],
  activities: ['kpi-stats', 'follow-up-queue', 'conversion-funnel', 'relationship-scores',
    'activity-insights', 'streak', 'activity-summary', 'market-pulse', 'weekly-report',
    'notifications', 'outreach-effectiveness', 'channel-attribution', 'next-action-queue'],
  jobs: ['kpi-stats', 'revenue-forecast', 'weekly-report', 'revenue-goals', 'velocity-alerts'],
  leads: ['kpi-stats', 'weekly-report'],
};
```

**Invalidation call on mutation:**

```js
(CACHE_INVALIDATION[col] || []).forEach(k => cacheInvalidate(k));
```

**Key gotchas:**
- The `cached()` middleware monkey-patches `res.json` to intercept the response — it caches the data transparently without the route handler knowing.
- Activities affect 13 cached endpoints. Missing even one key means stale data on that endpoint until TTL expires.
- Each route module that creates activities has its own `ACTIVITY_CACHES` constant that must stay in sync with the CRUD invalidation map.
- TTL tuning: 30s for fast-changing data (kpi-stats, streak), 60s for moderate (follow-up-queue, activity-insights), 120s for slow-changing (relationship-scores, revenue-forecast).

---

### 7. Event Bus for Decoupled Chain Reactions

**When to use:** When one mutation triggers side effects across multiple modules (cache invalidation, sequence advancement, auto-research, notifications). Keeps modules decoupled.

**Event bus (from a production Express app's event service):**

```js
import { EventEmitter } from 'events';
import { createLogger } from './logger.js';

const log = createLogger('Events');

class AppEventBus extends EventEmitter {
  emit(event, ...args) {
    log.debug({ event, listenerCount: this.listenerCount(event) }, 'Event emitted');
    return super.emit(event, ...args);
  }
}

const bus = new AppEventBus();

// Prevent unhandled listener errors from crashing the process
bus.on('error', (err) => {
  log.error({ err }, 'Event listener error');
});

export const EVENTS = {
  ACTIVITY_CREATED: 'activity:created',
  COMPANY_UPDATED: 'company:updated',
  COMPANY_STAGE_CHANGED: 'company:stage_changed',
  JOB_CREATED: 'job:created',
  JOB_UPDATED: 'job:updated',
  LEAD_CREATED: 'lead:created',
  PROSPECT_CREATED: 'prospect:created',
  PROSPECT_UPDATED: 'prospect:updated',
  PROSPECT_ACTIONED: 'prospect:actioned',
  SIGNALS_INGESTED: 'signals:ingested',
  LEADGEN_RUN_STARTED: 'leadgen:run_started',
  LEADGEN_RUN_COMPLETED: 'leadgen:run_completed',
  CONTACT_ENRICHED: 'contact:enriched',
  JOB_ACTIVATED: 'job:activated',
  BROWSER_AUTH_EXPIRED: 'browser:auth_expired',
  SEQUENCE_ADVANCED: 'sequence:advanced',
};

export default bus;
```

**Chain reaction example — Activity Created triggers sequence auto-advance:**

```js
// Event listener: auto-advance sequence on activity creation
bus.on(EVENTS.ACTIVITY_CREATED, (activity) => {
  try {
    if (!activity.company || !activity.type) return;
    const actTypes = new Set(['call', 'email', 'linkedin']);
    if (!actTypes.has(activity.type)) return;

    // ... find matching sequence, advance it ...
    const advanced = advanceSequence(seq.id, nextActionDate);
    SEQUENCE_CACHES.forEach(k => cacheInvalidate(k));
    scheduleDbJsonBackup();
    bus.emit(EVENTS.SEQUENCE_ADVANCED, { sequence: advanced, activity, companyId: company.id });
  } catch (err) {
    log.error({ err }, 'Failed to auto-advance sequence on activity event');
  }
});
```

**Chain reaction example — Prospect Created triggers event-driven deep research:**

```js
bus.on(EVENTS.PROSPECT_CREATED, async (prospect) => {
  try {
    const hasHighValueSignal = (prospect.signals || []).some(s => HIGH_VALUE_SIGNALS.has(s.type));
    // ... triggers immediate deep research for high-value signals ...
```

**Chain reaction example — Prospect Created re-activates nurture sequences:**

```js
bus.on(EVENTS.PROSPECT_CREATED, (prospect) => {
  try {
    if (!prospect.company) return;
    const nurtureSeqs = getNurtureSequencesByCompanyName(prospect.company);
    // ... re-activates paused nurture sequences when new signals arrive ...
```

**Key gotchas:**
- The `bus.on('error')` handler is critical — without it, a listener error propagates as an unhandled exception and crashes the process.
- Every listener MUST have its own try/catch. The error handler on the bus only catches errors from `emit` itself, not from async listener callbacks.
- Events can cascade: `ACTIVITY_CREATED` -> handler advances sequence -> emits `SEQUENCE_ADVANCED`. Be careful of infinite loops.
- The `emit` override logs listener count per event — useful for debugging when listeners are missing or duplicated.
- Multiple modules can listen to the same event (e.g., `PROSPECT_CREATED` has listeners in both `autopilot.js` and `sequences.js`).

---

### 8. Field Whitelisting Against Prototype Pollution

**When to use:** Every create/update endpoint that accepts user input and writes to a database.

**Code (from the CRUD route module):**

```js
const ALLOWED_FIELDS = {
  companies: new Set(['name', 'industry', 'contact', 'title', 'email', 'phone', 'stage', 'value',
    'location', 'notes', 'source', 'research', 'outreach', 'lastContactDate', 'lastResearchedAt',
    'nextActionDate', 'nextActionType', 'nextActionNote']),
  jobs: new Set(['title', 'company', 'status', 'type', 'location', 'salary', 'notes', 'fee', 'candidates', 'bullhornId']),
  activities: new Set(['company', 'type', 'notes', 'date', 'contact', 'gotResponse', 'outcome', 'source',
    'outreachStyle', 'subjectLine', 'durationMinutes']),
  // ...
};
```

**Key gotcha:** Never `...req.body` into DB operations. Always pick explicitly: `Object.fromEntries(Object.entries(req.body).filter(([k]) => ALLOWED_FIELDS[col].has(k)))`.

---

## Mistakes We Already Made

### 1. `content[0].text` — The Server Crasher
AI responses can have missing content blocks or unexpected types. Directly accessing `msg.content[0].text` crashed the server across 9 route handlers. Fixed by building `extractJson()` and replacing every direct access. (decisions.md: "SAFE AI TEXT EXTRACTION", evolution.md: "Hardening & Automation")

### 2. Prototype Pollution via `req.body` Spread
`req.body` was being spread directly into database operations (`{...req.body}`). Any request could inject arbitrary fields like `__proto__` or overwrite internal fields. Fixed with explicit field whitelisting per collection. (decisions.md: "PROTOTYPE POLLUTION")

### 3. SSE Streams Crash on Client Disconnect
Long-running AI research uses Server-Sent Events. When clients disconnect mid-stream, `res.write()` throws and crashes the process. Fixed by wrapping every `res.write()` in try/catch and clearing intervals on error. (decisions.md: "SSE STREAMS", evolution.md)

### 4. Express 5 Async Rejections
Express 5 does NOT auto-catch async rejections in all cases. Unhandled rejections crashed the process. Every async route handler now needs a top-level try/catch. (decisions.md: "ASYNC ROUTE HANDLERS")

### 5. No Graceful Shutdown
Server died on SIGTERM, leaving database connections open. Fixed by adding proper cleanup: close server, clear timers, close DB. (evolution.md: "Hardening & Automation")

### 6. Shared Rate Limits Between Interactive and Autopilot
Running Claude Code interactively while autopilot runs = both hit the 30k tokens/min org-level limit and fail. Solution: autopilot runs at 5 AM, never concurrent with interactive sessions. (decisions.md: "RATE LIMITING" gotcha)

### 7. SQL Injection via Malicious Object Keys
The DAL accepted arbitrary table names. Added table name validation. (evolution.md: "Hardening & Automation")

### 8. Cache Invalidation: One Missed Key = Stale Data
Activities affect 13 cached endpoints. Forgetting to invalidate even one means the dashboard shows stale data until TTL expires. The `CACHE_INVALIDATION` map in `crud.js` and `ACTIVITY_CACHES` in `outreach.js` must stay in sync manually — there is no automated check. (decisions.md: "CACHE INVALIDATION")

---

## Key Files (Source of Truth)

| File | What It Contains |
|------|-----------------|
| `services/ai.js` | Circuit breaker, retry with backoff, paceApiCall(), CLI fallback, extractJson() |
| `services/cache.js` | TTL cache, Express middleware, invalidation |
| `services/events.js` | Event bus, event name constants |
| `routes/crud.js` | CACHE_INVALIDATION key map, ALLOWED_FIELDS whitelist, event emission on mutations |
| `routes/sequences.js` | Event listeners for ACTIVITY_CREATED and PROSPECT_CREATED chain reactions |
| `routes/autopilot.js` | Event-triggered deep research on PROSPECT_CREATED |
| `routes/outreach.js` | ACTIVITY_CACHES constant (must stay in sync with crud.js) |
| `routes/analytics.js` | `cached()` middleware usage with TTL values per endpoint |
| `docs/decisions.md` | Decision log with retrospectives |
| `docs/evolution.md` | Project narrative with hardening history |
