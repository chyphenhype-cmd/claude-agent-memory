---

# React Frontend Playbook
Source: Production React 19 + Vite 7 + Tailwind 4 app
Last extracted: 2026-03-07

---

## Pattern 1: API Client (Legacy/Simple CRUD)

**When to use:** Quick one-off CRUD operations in components that don't need cache invalidation or optimistic updates. Being phased out in favor of React Query hooks.

**File:** `src/utils/storage.js` (from a production React app)

```js
import { toast } from 'sonner';

const API = '/api';

const api = {
  async list(collection, params = {}) {
    try {
      const qs = Object.keys(params).length > 0 ? '?' + new URLSearchParams(params).toString() : '';
      const res = await fetch(`${API}/${collection}${qs}`);
      if (!res.ok) { toast.error(`Failed to load ${collection}`); return []; }
      return await res.json();
    } catch {
      toast.error(`Failed to load ${collection}`);
      return [];
    }
  },

  async create(collection, item) {
    try {
      const res = await fetch(`${API}/${collection}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(item),
      });
      if (!res.ok) { toast.error(`Failed to create ${collection} record`); return null; }
      return await res.json();
    } catch {
      toast.error(`Failed to create ${collection} record`);
      return null;
    }
  },

  async update(collection, id, data) { /* same pattern: fetch + toast.error on failure */ },
  async remove(collection, id) { /* DELETE + toast.error */ },
  async replace(collection, items) { /* PUT full collection + toast.error */ },
};

export default api;
```

**Key gotchas:**
- Returns empty array `[]` or `null` on failure instead of throwing -- callers must check for falsy returns.
- Error toasts are baked in; you get double toasts if you also toast in the calling component.
- No cache invalidation -- if another component rendered the same data via React Query, it will be stale after a `storage.create()` call.

---

## Pattern 2: React Query Collection Hooks (useQuery)

**When to use:** All server state reads. This is the standard. 72 hooks migrated to this pattern.

**File:** `src/hooks/useApi.js` (from a production React app)

### 2a: Basic Collection with Server-Side Pagination

```js
function buildCollectionUrl(collection, { page, limit, sort, order } = {}) {
  const params = new URLSearchParams();
  if (page) { params.set('page', page); params.set('limit', limit || 50); }
  if (sort) { params.set('sort', sort); params.set('order', order || 'desc'); }
  const qs = params.toString();
  return qs ? `${API}/${collection}?${qs}` : `${API}/${collection}`;
}

export function useCompanies({ page, limit, sort, order, ...options } = {}) {
  const pagination = page ? { page, limit, sort, order } : undefined;
  return useQuery({
    queryKey: pagination ? ['companies', pagination] : ['companies'],
    queryFn: () => fetchJson(buildCollectionUrl('companies', { page, limit, sort, order })),
    ...options,
  });
}
```

**Key gotchas:**
- `queryKey` changes shape depending on whether pagination is passed. Without `page`, key is `['companies']`; with page, it's `['companies', { page, limit, sort, order }]`. This means `invalidateQueries({ queryKey: ['companies'] })` invalidates ALL pages (prefix matching).
- The `...options` spread lets callers pass `enabled`, `staleTime`, `refetchInterval` etc.

### 2b: Filtered Collection with Search/Filter Params

```js
export function useContacts({ page = 1, limit = 50, search, companyId, sort, order, ...options } = {}) {
  return useQuery({
    queryKey: ['contacts', { page, limit, search, companyId, sort, order }],
    queryFn: () => {
      const params = new URLSearchParams({ page, limit });
      if (search) params.set('search', search);
      if (companyId) params.set('companyId', companyId);
      if (sort) params.set('sort', sort);
      if (order) params.set('order', order);
      return fetchJson(`${API}/contacts?${params}`);
    },
    ...options,
  });
}
```

### 2c: Detail Query with `enabled` Guard

```js
export function useCompanyDetail(id) {
  return useQuery({
    queryKey: ['company-detail', id],
    queryFn: () => fetchJson(`${API}/company-detail/${id}`),
    enabled: !!id,
    staleTime: 2 * 60_000,
  });
}
```

**Key gotchas:**
- `enabled: !!id` prevents the query from firing when `id` is null/undefined (e.g., before a route param resolves).
- `staleTime: 2 * 60_000` (2 minutes) -- detail pages use this to avoid refetching on every mount.

### 2d: Search Query with Minimum Length Guard

```js
export function useContactSearch(query) {
  return useQuery({
    queryKey: ['contact-search', query],
    queryFn: () => fetchJson(`${API}/contacts/search?q=${encodeURIComponent(query)}`),
    enabled: !!query && query.length >= 2,
  });
}
```

### 2e: Polling Query (Auto-Refresh)

```js
export function useKpiStats() {
  return useQuery({
    queryKey: ['kpi-stats'],
    queryFn: () => fetchJson(`${API}/kpi-stats`),
    refetchInterval: 15_000,
  });
}

export function useSidebarStats() {
  return useQuery({
    queryKey: ['sidebar-stats'],
    queryFn: async () => {
      const [notifications, companies, jobs, queue] = await Promise.all([
        fetchJson(`${API}/notifications`).catch(() => ({ total: 0 })),
        fetchJson(`${API}/companies`).catch(() => []),
        fetchJson(`${API}/jobs`).catch(() => []),
        fetchJson(`${API}/prospect-queue?status=new`).catch(() => ({ summary: {} })),
      ]);
      return {
        notificationCount: notifications.total || 0,
        pipelineCount: companies.length,
        openJobsCount: jobs.filter(j => !['Placed', 'Closed'].includes(j.status)).length,
        prospectQueueCount: queue.summary?.new || 0,
      };
    },
    refetchInterval: 60_000,
    refetchIntervalInBackground: false,
  });
}
```

**Key gotchas:**
- `refetchIntervalInBackground: false` on sidebar stats -- stops polling when the tab is not focused (saves API calls).
- The `queryFn` aggregates 4 endpoints with `Promise.all` + `.catch()` fallbacks. Each sub-request fails independently without killing the whole query.
- Polling intervals: KPI = 15s (dashboard-critical), sidebar = 60s, prospect queue = 15s. Tune per use case.

### 2f: Conditionally-Enabled Polling (Toggle On/Off)

```js
export function useIntelligenceStatus(enabled = false) {
  return useQuery({
    queryKey: ['intelligence-status'],
    queryFn: () => fetchJson(`${API}/intelligence-status`).catch(() => null),
    enabled,
    refetchInterval: enabled ? 3000 : false,
  });
}
```

**When to use:** Progress indicators for long-running jobs. Poll fast (3s) only while the operation is in progress.

---

## Pattern 3: React Query Mutations (useMutation)

### 3a: Simple Mutation with Cache Invalidation

```js
export function useCreateContact() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (data) => postJson(`${API}/contacts`, data),
    onSuccess: (_, variables) => {
      qc.invalidateQueries({ queryKey: ['contacts'] });
      if (variables?.companyId) {
        qc.invalidateQueries({ queryKey: ['company-detail', variables.companyId] });
      }
    },
  });
}
```

**Key gotchas:**
- Invalidation is by queryKey prefix. `['contacts']` invalidates all contact-related queries (list, search, by-company, etc.).
- Conditionally invalidate related entities when the mutation payload includes foreign keys (e.g., `companyId`).

### 3b: Update Mutation (Destructure id from Payload)

```js
export function useUpdateContact() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...data }) => putJson(`${API}/contacts/${id}`, data),
    onSuccess: (_, vars) => {
      qc.invalidateQueries({ queryKey: ['contacts'] });
      qc.invalidateQueries({ queryKey: ['contact', vars.id] });
    },
  });
}
```

**Convention:** `{ id, ...data }` pattern -- caller passes `{ id: 123, name: 'foo', email: 'bar' }`. The `id` goes into the URL, the rest goes into the body.

### 3c: Optimistic Update (Full Pattern)

```js
export function useCreateActivity() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (activity) => postJson(`${API}/activities`, activity),
    onMutate: async (activity) => {
      await qc.cancelQueries({ queryKey: ['activities'] });
      const previous = qc.getQueryData(['activities']);
      const optimistic = {
        ...activity,
        id: activity.id || crypto.randomUUID(),
        createdAt: new Date().toISOString(),
      };
      qc.setQueryData(['activities'], old => old ? [optimistic, ...old] : [optimistic]);
      return { previous };
    },
    onError: (_err, _vars, ctx) => {
      if (ctx?.previous) qc.setQueryData(['activities'], ctx.previous);
    },
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ['activities'] });
      qc.invalidateQueries({ queryKey: ['kpi'] });
    },
  });
}
```

**When to use:** High-frequency user actions (logging an activity, "Did it" clicks) where UI lag would feel broken.

**Key gotchas:**
- `onMutate`: cancel in-flight queries first, snapshot previous data, insert the optimistic item.
- `onError`: rollback to snapshot.
- `onSettled`: always invalidate (runs after both success and error) to sync with server truth.
- `crypto.randomUUID()` for temp ID -- gets replaced by the real ID after refetch.

### 3d: Wide Invalidation (Mutation Touches Many Queries)

```js
export function useQuickLog() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (data) => postJson(`${API}/quick-log`, data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['activities'] });
      qc.invalidateQueries({ queryKey: ['kpi-stats'] });
      qc.invalidateQueries({ queryKey: ['follow-up-queue'] });
      qc.invalidateQueries({ queryKey: ['next-action-queue'] });
      qc.invalidateQueries({ queryKey: ['streak'] });
      qc.invalidateQueries({ queryKey: ['activity-insights'] });
      qc.invalidateQueries({ queryKey: ['company'] });
      qc.invalidateQueries({ queryKey: ['contact'] });
      qc.invalidateQueries({ queryKey: ['sidebar-stats'] });
    },
  });
}
```

**Key gotchas:**
- Activity creation touches 9 different query keys. Miss one and some part of the UI goes stale. This maps to the backend's `CACHE INVALIDATION` decision: "Activities affect 10+ cached endpoints."
- This is why each mutation hook lists invalidations explicitly rather than using a generic "invalidate everything" approach.

### 3e: Mutation with Custom Response Handling (409 Conflict)

```js
export function useRunIntelligence() {
  return useMutation({
    mutationFn: async (data) => {
      const res = await fetch(`${API}/run-intelligence`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
      });
      if (res.status === 409) return { alreadyRunning: true };
      if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
      return res.json();
    },
  });
}
```

**When to use:** When certain HTTP status codes are expected/non-fatal (e.g., "job already running").

### 3f: Mutation with Direct Cache Write (Skip Refetch)

```js
export function useGenerateBriefing() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => postJson(`${API}/briefing/generate`, {}),
    onSuccess: (data) => {
      if (data) qc.setQueryData(['briefing'], data);
    },
  });
}
```

**When to use:** When the mutation response IS the new data. Write directly to cache instead of invalidating + refetching.

### 3g: Delayed Invalidation (Long-Running Backend Job)

```js
export function useRunAutopilotNow() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => postJson(`${API}/autopilot/run-now`, {}),
    onSuccess: () => {
      setTimeout(() => {
        qc.invalidateQueries({ queryKey: ['prospect-queue'] });
        qc.invalidateQueries({ queryKey: ['autopilot-status'] });
        qc.invalidateQueries({ queryKey: ['autopilot-history'] });
      }, 3000);
    },
  });
}
```

**When to use:** Backend starts an async job. Data won't be ready immediately. Delay invalidation by 3 seconds to give the job time to produce results.

---

## Pattern 4: Fetch Primitives

**File:** `src/hooks/useApi.js` (from a production React app) (lines 1-35)

```js
const API = '/api';

async function fetchJson(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

async function postJson(url, body) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

async function putJson(url, body) { /* same shape as postJson with method: 'PUT' */ }

async function deleteJson(url) {
  const res = await fetch(url, { method: 'DELETE' });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.ok;
}
```

**Key gotchas:**
- These are NOT exported. They're internal to useApi.js. Components never call `fetchJson` directly.
- `deleteJson` returns `res.ok` (boolean), not parsed JSON. The delete response body is ignored.
- All throw on non-2xx -- React Query catches these and surfaces them via `error` state.

---

## Pattern 5: App Shell (Layout + Sidebar + Command Palette)

**File:** `src/layouts/AppLayout.jsx` (from a production React app)

### 5a: Nav Structure (Grouped, Collapsible, Drag-Reorderable)

```js
const navGroups = [
  {
    label: 'Intelligence',
    items: [
      { to: '/', label: 'Today', icon: LayoutDashboard },
      { to: '/prospect-hq', label: 'Prospect Engine', icon: Zap },
      { to: '/sequences', label: 'Sequences', icon: Play },
    ],
  },
  {
    label: 'CRM',
    items: [
      { to: '/pipeline', label: 'Companies', icon: Building2 },
      { to: '/contacts', label: 'Contacts', icon: Contact },
      // ...
    ],
  },
  { label: 'Tools', items: [ /* ... */ ] },
];
```

**Active link styling:**
```jsx
<NavLink
  to={item.to}
  end={item.to === '/'}
  className={({ isActive }) =>
    `group relative flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium transition-all duration-200 ${
      isActive
        ? 'bg-indigo-600/15 text-indigo-400 shadow-sm shadow-indigo-500/10'
        : 'text-gray-400 hover:bg-dark-700/70 hover:text-gray-200 hover:pl-4'
    }`
  }
>
```

**Key gotchas:**
- `end={item.to === '/'}` is required on the root route or it matches every page.
- Nav order is persisted to `localStorage` under a namespaced key.

### 5b: Sidebar Badge Counts (Polling via React Query)

```js
const { data: stats } = useSidebarStats();
const notificationCount = stats?.notificationCount || 0;
// ...
{badge !== null && (
  <span className={`text-[9px] font-bold min-w-[18px] text-center px-1 py-0.5 rounded-full ${
    item.to === '/' ? 'bg-amber-500/20 text-amber-400' :
    item.to === '/prospect-hq' ? 'bg-emerald-500/20 text-emerald-400' :
    'bg-dark-600 text-gray-500'
  }`}>{badge}</span>
)}
```

### 5c: Command Palette (Cmd+K)

**Architecture:** Dual-mode search -- regular text = entity search, `>` prefix = command mode.

```js
const isCommandMode = searchQuery.startsWith('>');
```

**Keyboard shortcut registration:**
```js
useEffect(() => {
  const handler = (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') { e.preventDefault(); setSearchOpen(prev => !prev); }
    if ((e.metaKey || e.ctrlKey) && e.key === 'l') { e.preventDefault(); setQuickLogOpen(prev => !prev); }
    if ((e.metaKey || e.ctrlKey) && e.key === 'j') { e.preventDefault(); setQuickProspectOpen(prev => !prev); }
    if (e.altKey && e.key === 't') { e.preventDefault(); setNotifOpen(prev => !prev); }
    if (e.key === '?' && !e.metaKey && !e.ctrlKey && !(e.target instanceof HTMLInputElement) && !(e.target instanceof HTMLTextAreaElement)) {
      e.preventDefault(); setShortcutsOpen(prev => !prev);
    }
    if (e.key === 'Escape') { /* close all modals */ }
  };
  window.addEventListener('keydown', handler);
  return () => window.removeEventListener('keydown', handler);
}, [searchOpen, quickLogOpen, quickProspectOpen, shortcutsOpen, notifOpen]);
```

**Key gotchas:**
- `?` shortcut guard: skip when focus is in an input/textarea to avoid triggering while typing.
- Escape closes all modals in priority order.
- Search data fetched lazily via `enabled: searchOpen` on the React Query hooks -- zero cost when palette is closed.

### 5d: Toast System

```jsx
// In AppLayout's JSX:
<Toaster richColors position="bottom-right" />

// Usage anywhere in the app:
import { toast } from 'sonner';
toast.success('Activity logged');
toast.error('Failed to save');
```

---

## Mistakes We Already Made

### Prototype Pollution
**What happened:** `req.body` was spread directly into DB operations. Any request could inject arbitrary fields.
**Fix:** Whitelist allowed fields explicitly in every create/update handler. Never `...req.body` into a DB call.

### Unsafe AI Response Access
**What happened:** `msg.content[0].text` crashes when content blocks are missing or have unexpected types.
**Fix:** Use safe extraction helpers. Never access AI response content directly.

### Invisible Hover States
**What happened:** `hover:border-border` on dark theme -- resting border color equals hover color. Hover effect is invisible.
**Fix:** Use `hover:border-dark-500 transition-colors` for interactive cards.

### SSE Stream Crashes
**What happened:** Client disconnects mid-stream, `res.write()` throws, server crashes.
**Fix:** Wrap `res.write()` in try/catch. Clear intervals on disconnect/error.

### Async Route Handler Crashes
**What happened:** Express 5 doesn't auto-catch async rejections in all cases. Uncaught promise rejection kills the process.
**Fix:** Every async route handler needs a top-level try/catch.

### Custom Toast Divs
**What happened:** Pages created their own `fixed bottom-6 right-6` toast elements instead of using the global Sonner `<Toaster>`.
**Fix:** Use `toast.success()` / `toast.error()` from `sonner`. AppLayout already mounts `<Toaster>`.

### CSS Variable Tokens vs Raw Tokens
**What happened:** Mixed usage of `text-muted-foreground`, `bg-secondary` (CSS variable tokens from shadcn) and `text-gray-500`, `bg-dark-700` (raw Tailwind tokens).
**Fix:** All new code uses raw `dark-*` / `gray-*` tokens exclusively. Do NOT use the CSS variable tokens.

### Cache Staleness After Mutations
**What happened:** Mutations that create activities didn't invalidate all the query keys that depend on activity data (KPI stats, follow-up queue, conversion funnel, etc.).
**Fix:** Each mutation hook explicitly lists every query key it affects. There are up to 9 keys per activity mutation.

---

## Visual Design Conventions

| Element | Classes |
|---|---|
| Card wrapper | `py-0 border-border bg-card` |
| Card content | `<CardContent className="p-4">` |
| Interactive card hover | `hover:border-dark-500 transition-colors` |
| Clickable card lift | `hover:-translate-y-0.5 hover:shadow-xl transition-all duration-200` |
| Page subtitle | `text-sm text-gray-500 mt-1` |
| Section heading | `text-sm font-semibold text-gray-400 uppercase tracking-wider` |
| Filter chip | `rounded-full text-xs px-3 py-1 font-medium cursor-pointer` |
| Badge (small count) | `text-[9px] font-bold min-w-[18px] text-center px-1 py-0.5 rounded-full` |
| Root background | `bg-dark-900 text-gray-100` |
| Sidebar | `bg-dark-800 border-r border-dark-600` |
| Active nav link | `bg-indigo-600/15 text-indigo-400` |
| Inactive nav link | `text-gray-400 hover:bg-dark-700/70 hover:text-gray-200` |

---

## staleTime Reference

| Data Type | staleTime | refetchInterval | Rationale |
|---|---|---|---|
| KPI stats | default (0) | 15s | Dashboard-critical, always fresh |
| Sidebar stats | default | 60s | Background counts, low priority |
| Prospect queue | default | 15s | Active working queue |
| Today's actions | default | 60s | Daily checklist |
| Sequences | default | 60s | Active cadences |
| Company/Job detail | 2 min | none | Doesn't change while viewing |
| Revenue/conversion analytics | 5 min | none | Slow-moving data |
| Briefing | 5 min | none | Generated once per day |
| Territory map | 2 min | none | Geo data, rarely changes |

---

## Key Files (Source of Truth)

| File | Purpose |
|---|---|
| `src/hooks/useApi.js` | All React Query hooks (72+). THE source of truth for data fetching patterns. |
| `src/utils/storage.js` | Legacy CRUD API client with built-in toast errors. Being superseded by useApi.js hooks. |
| `src/layouts/AppLayout.jsx` | App shell: sidebar nav, command palette (Cmd+K), quick logger (Cmd+L), quick prospect (Cmd+J), notification center (Alt+T), keyboard shortcuts (?), Sonner toaster mount. |
| `docs/decisions.md` | Decision log with retro annotations. Visual design conventions, architecture decisions, gotchas. |
| `src/components/ui/sonner.jsx` | Sonner toast wrapper (shadcn). |
| `src/components/QuickLogger.jsx` | Quick activity logging modal. |
| `src/components/QuickProspect.jsx` | Quick JD paste/prospect creation modal. |
