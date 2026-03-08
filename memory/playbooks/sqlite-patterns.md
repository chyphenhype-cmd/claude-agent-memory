---

# SQLite Patterns Playbook
Source: Production Node (better-sqlite3) + Python (sqlite3) apps
Last extracted: 2026-03-07

---

## Patterns

### 1. WAL Mode + Foreign Keys On Connection

**When to use:** Every SQLite project. Set once at connection time, not per-query.

**Node (better-sqlite3):**
```js
export function getDb() {
  if (!_db) {
    _db = new Database(DB_PATH);
    _db.pragma('journal_mode = WAL');
    _db.pragma('foreign_keys = ON');
    const schema = readFileSync(SCHEMA_PATH, 'utf-8');
    _db.exec(schema);
    runMigrations(_db);
  }
  return _db;
}
```

**Python (sqlite3):**
```python
def get_connection():
    conn = sqlite3.connect(get_db_path())
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn
```

**Key gotchas:**
- `better-sqlite3` is synchronous and singleton-friendly (one `_db` instance reused). Python `sqlite3` opens/closes per operation.
- WAL mode persists on the database file — setting it once is technically enough, but setting it every connection is defensive and costs nothing.
- `foreign_keys=ON` does NOT persist — it must be set on every new connection.

---

### 2. JSON Column Auto-Serialization / Deserialization

**When to use:** When storing structured objects (arrays, nested data) in SQLite TEXT columns. Declare which fields are JSON once, and the DAL handles the rest.

**Node (better-sqlite3):**
```js
const JSON_FIELDS = {
  companies: ['research', 'outreach', 'relationshipIntel'],
  jobs: ['candidates', 'fee'],
  leads: ['signals', 'scoreBreakdown', 'feeEstimation', 'outreach', 'research'],
  prospect_queue: [
    'signals', 'scoreBreakdown', 'research', 'feeEstimation', 'decisionMaker',
    'buyingCommittee', 'battleCard', 'outreachCadence', 'accountStrategy',
    'outreach', 'engagementModel', 'companyProfile', 'painAnalysis', 'actions', 'reasoning',
  ],
  contacts: ['tags'],
  // ... 20+ tables registered
};

function serializeRow(table, row) {
  if (!row) return row;
  const jsonFields = JSON_FIELDS[table] || [];
  const out = {};
  for (const [k, v] of Object.entries(row)) {
    if (!SAFE_COL_RE.test(k)) continue;  // SQL injection guard
    out[k] = v;
  }
  for (const field of jsonFields) {
    if (out[field] !== undefined && out[field] !== null && typeof out[field] !== 'string') {
      out[field] = JSON.stringify(out[field]);
    }
  }
  // Convert booleans to integers for SQLite
  for (const [k, v] of Object.entries(out)) {
    if (typeof v === 'boolean') out[k] = v ? 1 : 0;
    if (typeof v === 'object' && v !== null) out[k] = JSON.stringify(v);
  }
  return out;
}

function deserializeRow(table, row) {
  if (!row) return row;
  const jsonFields = JSON_FIELDS[table] || [];
  const out = { ...row };
  for (const field of jsonFields) {
    if (typeof out[field] === 'string') {
      try { out[field] = JSON.parse(out[field]); } catch { /* leave as string */ }
    }
  }
  return out;
}
```

**Key gotchas:**
- Every table using JSON columns MUST be registered in `JSON_FIELDS`, even if the array is empty — otherwise the DAL won't know to serialize/deserialize.
- Raw SQL queries (bypass the DAL) won't auto-deserialize. You must manually `JSON.parse()` in those cases.
- Boolean values must be converted to 0/1 for SQLite — the serializer handles this.
- The catch-all `typeof v === 'object'` at the end handles any object fields NOT in JSON_FIELDS that accidentally made it through.

---

### 3. SQL Injection Prevention via Column Name Validation

**When to use:** Whenever building dynamic SQL from object keys (which could come from user input via `req.body`).

**Node (Express):**
```js
const SAFE_COL_RE = /^[a-zA-Z_][a-zA-Z0-9_]*$/;

function serializeRow(table, row) {
  const out = {};
  for (const [k, v] of Object.entries(row)) {
    if (!SAFE_COL_RE.test(k)) continue;  // Reject anything that could inject SQL
    out[k] = v;
  }
  // ...
}
```

**Key gotchas:**
- This protects against prototype pollution where `req.body` contains keys like `"id; DROP TABLE companies--"`.
- The regex silently drops bad keys rather than throwing — intentional design so malicious keys are ignored, not surfaced.
- This is NOT a substitute for parameterized queries (values are always `?` placeholders) — it protects the column name positions where parameterization doesn't work.

---

### 4. Table Name Validation (Collection Mapping)

**When to use:** When API routes accept a collection/entity name and you need to map it to a real table name.

**Node (Express):**
```js
const TABLE_MAP = {
  companies: 'companies',
  jobs: 'jobs',
  prospectQueue: 'prospect_queue',
  autopilotRuns: 'autopilot_runs',
  candidateJobs: 'candidate_jobs',
  // ... 26 mappings
};

function tableName(collection) {
  const table = TABLE_MAP[collection];
  if (!table) throw new Error(`Unknown collection: ${collection}`);
  return table;
}
```

**Key gotchas:**
- This also doubles as a camelCase-to-snake_case translator for API consumers.
- Without this, `req.params.collection` could be injected directly into SQL.
- Throws hard on unknown collections — fail loudly, don't silently pass through.

---

### 5. Generic CRUD with Targeted DAL Calls

**When to use:** Every entity. The old anti-pattern was `loadDb()` (read ALL tables) -> mutate in memory -> `saveDb()` (rewrite ALL tables). Targeted calls are the replacement.

**Node (better-sqlite3):**
```js
export function insertRecord(collection, record) {
  const table = tableName(collection);
  const db = getDb();
  const serialized = serializeRow(table, record);
  const cols = Object.keys(serialized);
  const placeholders = cols.map(() => '?').join(', ');
  const values = cols.map(c => serialized[c]);
  const quotedCols = cols.map(c => `"${c}"`).join(', ');
  db.prepare(`INSERT OR REPLACE INTO ${table} (${quotedCols}) VALUES (${placeholders})`).run(...values);
  return record;
}

export function updateRecord(collection, id, data) {
  const table = tableName(collection);
  const db = getDb();
  const withTimestamp = HAS_UPDATED_AT.has(table) && !data.updatedAt
    ? { ...data, updatedAt: new Date().toISOString() }
    : data;
  const serialized = serializeRow(table, withTimestamp);
  const cols = Object.keys(serialized).filter(c => c !== 'id');
  if (cols.length === 0) return getById(collection, id);
  const sets = cols.map(c => `"${c}" = ?`).join(', ');
  const values = [...cols.map(c => serialized[c]), id];
  db.prepare(`UPDATE ${table} SET ${sets} WHERE id = ?`).run(...values);
  return getById(collection, id);
}

export function deleteRecord(collection, id) {
  const table = tableName(collection);
  const db = getDb();
  db.prepare(`DELETE FROM ${table} WHERE id = ?`).run(id);
}
```

**Key gotchas:**
- `INSERT OR REPLACE` is used — this means if the `id` already exists, it replaces the entire row. Use `updateRecord` for partial updates.
- `updateRecord` auto-sets `updatedAt` for tables in the `HAS_UPDATED_AT` set (unless caller explicitly provides it).
- Column names are quoted with `"` to handle reserved words safely.
- Empty update (no columns to set) is a no-op that returns the existing record.

---

### 6. Upsert with Enrichment Preservation

**When to use:** When re-scraping or re-importing data that may overwrite previously enriched fields.

**Python (sqlite3):**
```python
def upsert_listing(listing: dict) -> int:
    validated = Listing(**listing)  # Pydantic validation
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute(
        "SELECT id FROM listings WHERE source = ? AND source_id = ?",
        (validated.source, validated.source_id),
    )
    existing = cursor.fetchone()

    if existing:
        listing_id = existing["id"]
        # Only update fields the scraper explicitly provided (exclude_unset=True)
        # This prevents re-scrapes from wiping enrichment data
        update_data = validated.model_dump(exclude_unset=True)
        fields = []
        values = []
        for key, value in update_data.items():
            if key not in ("source", "source_id", "id", "first_seen") and value is not None:
                fields.append(f"{key} = ?")
                values.append(value)
        fields.append("last_seen = ?")
        values.append(utc_now())
        fields.append("last_updated = ?")
        values.append(utc_now())
        values.append(listing_id)
        cursor.execute(
            f"UPDATE listings SET {', '.join(fields)} WHERE id = ?", values,
        )
    else:
        full_data = validated.model_dump(exclude_none=False)
        columns = list(full_data.keys())
        placeholders = ", ".join(["?"] * len(columns))
        values = [full_data[col] for col in columns]
        cursor.execute(
            f"INSERT INTO listings ({', '.join(columns)}) VALUES ({placeholders})", values,
        )
        listing_id = cursor.lastrowid
```

**Key gotchas:**
- `exclude_unset=True` (Pydantic) is critical — it distinguishes "scraper didn't provide this field" from "scraper explicitly set it to None."
- Protected fields (`source`, `source_id`, `id`, `first_seen`) are never overwritten on update.
- `value is not None` check prevents overwriting enrichment data with null from a less-complete scraper.
- Always updates `last_seen` and `last_updated` timestamps to track freshness.

---

### 7. SQLite ON CONFLICT Upsert

**When to use:** When you have a UNIQUE constraint and want to insert-or-update atomically.

**Python (sqlite3):**
```python
def upsert_commute_cache(listing_id: int, dest_name: str, commute_minutes: float,
                         distance_meters: int = None):
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute(
        """INSERT INTO commute_cache (listing_id, dest_name, commute_minutes, distance_meters)
           VALUES (?, ?, ?, ?)
           ON CONFLICT(listing_id, dest_name)
           DO UPDATE SET commute_minutes = excluded.commute_minutes,
                         distance_meters = excluded.distance_meters,
                         fetched_at = CURRENT_TIMESTAMP""",
        (listing_id, dest_name, commute_minutes, distance_meters),
    )
    conn.commit()
    conn.close()
```

**Schema (the UNIQUE constraint that makes this work):**
```sql
CREATE TABLE IF NOT EXISTS commute_cache (
    -- ...
    UNIQUE(listing_id, dest_name)
);
```

**Also used for duplicate-safe inserts with `INSERT OR IGNORE`:**
```python
def add_review(listing_id: int, review: dict):
    cursor.execute(
        f"INSERT OR IGNORE INTO reviews ({', '.join(columns)}) VALUES ({placeholders})",
        values,
    )
```

**Key gotchas:**
- `ON CONFLICT ... DO UPDATE` requires a named UNIQUE constraint or UNIQUE index.
- `excluded.column_name` refers to the values that would have been inserted.
- `INSERT OR IGNORE` silently drops duplicates — use when you don't care about updating existing data.
- `INSERT OR REPLACE` deletes and re-inserts (can trigger ON DELETE CASCADE). Use `ON CONFLICT DO UPDATE` instead when you have foreign key relationships.

---

### 8. Transactions for Multi-Statement Operations

**When to use:** Any operation that touches multiple rows/tables and must be atomic.

**Node (better-sqlite3):**
```js
export function replaceCollection(collection, records) {
  const table = tableName(collection);
  const db = getDb();
  const tx = db.transaction(() => {
    db.prepare(`DELETE FROM ${table}`).run();
    for (const record of records) {
      insertRecord(collection, record);
    }
  });
  tx();
  return listCollection(collection);
}

export function runTransaction(fn) {
  const db = getDb();
  const tx = db.transaction(fn);
  return tx();
}
```

**Node — Data migration in a transaction:**
```js
function migrateContactsFromActivities(db) {
  const tx = db.transaction(() => {
    for (const pair of pairs) {
      const id = randomUUID();
      insertContact.run(id, pair.name, title, email, phone, ...);
      updateActivity.run(id, pair.company, pair.name);
    }
  });
  tx();
}
```

**Key gotchas:**
- `better-sqlite3` transactions are synchronous — the callback runs entirely within one SQLite transaction.
- If any statement inside the transaction throws, everything rolls back automatically.
- For Python sqlite3, use `conn.commit()` at the end, and wrap in try/except with `conn.rollback()` on failure.
- `runTransaction` is exposed as a public API so route handlers can compose multi-table operations.

---

### 9. Migrations: Adding Columns Safely

**When to use:** Evolving a schema without dropping/recreating tables. SQLite has no `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`.

**Node (better-sqlite3):**
```js
function runMigrations(db) {
  const cols = db.prepare("PRAGMA table_info(companies)").all().map(c => c.name);
  if (!cols.includes('nextActionDate')) {
    db.exec("ALTER TABLE companies ADD COLUMN nextActionDate TEXT");
    db.exec("ALTER TABLE companies ADD COLUMN nextActionType TEXT");
    db.exec("ALTER TABLE companies ADD COLUMN nextActionNote TEXT");
  }
  db.exec("CREATE INDEX IF NOT EXISTS idx_companies_next_action ON companies(nextActionDate)");
}
```

**Python (sqlite3):**
```python
def _migrate_add_column(cursor, table: str, column: str, col_type: str):
    """Add a column to a table if it doesn't exist."""
    cursor.execute(f"PRAGMA table_info({table})")
    columns = [row[1] for row in cursor.fetchall()]
    if column not in columns:
        cursor.execute(f"ALTER TABLE {table} ADD COLUMN {column} {col_type}")
        print(f"  Migration: added {column} to {table}")

# Usage:
_migrate_add_column(cursor, "listings", "status", "TEXT DEFAULT 'new'")
_migrate_add_column(cursor, "listings", "tour_date", "TEXT")
_migrate_add_column(cursor, "listings", "floor_plan", "TEXT")
_migrate_add_column(cursor, "listings", "move_in_special", "TEXT")
_migrate_add_column(cursor, "listings", "special_value", "REAL")
_migrate_add_column(cursor, "listings", "parking_fee", "REAL")
```

**Key gotchas:**
- `PRAGMA table_info(tablename)` returns column metadata — check `.name` (index 1 in Python tuples, `.name` property in better-sqlite3).
- Indexes can use `CREATE INDEX IF NOT EXISTS` — no need for manual checking.
- Always run migrations at connection/init time, before any reads.
- Group related columns in a single migration check (check one column, then add all related columns in the same block).
- The Python version extracts a reusable helper `_migrate_add_column` — the Node version inlines it.

---

### 10. Paginated List with Count

**When to use:** Any API endpoint that lists entities. Never load all rows and paginate in JS.

**Node (better-sqlite3):**
```js
export function paginatedList(collection, { page = 1, limit = 50, where = '', params = [], orderBy = '' } = {}) {
  const table = tableName(collection);
  const db = getDb();
  const countRow = db.prepare(`SELECT COUNT(*) as total FROM ${table} ${where}`).get(...params);
  const total = countRow.total;
  const offset = (page - 1) * limit;
  const order = orderBy || 'ORDER BY rowid';
  const rows = db.prepare(`SELECT * FROM ${table} ${where} ${order} LIMIT ? OFFSET ?`).all(...params, limit, offset);
  return {
    data: rows.map(r => deserializeRow(table, r)),
    total,
    page,
    limit,
    totalPages: Math.ceil(total / limit),
  };
}
```

**Key gotchas:**
- Two queries: one for count, one for data. The count query uses the same `where` clause.
- Default sort is `ORDER BY rowid` (insertion order) — callers can override.
- Returns pagination metadata (`total`, `page`, `limit`, `totalPages`) alongside the data.
- `LIMIT ? OFFSET ?` params are appended after the WHERE params.

---

### 11. Batch Loading (N+1 Prevention)

**When to use:** When the scoring engine or dashboard needs related data for every listing. One query replaces N individual lookups.

**Python (sqlite3):**
```python
def get_all_reviews_batch() -> dict:
    """Batch-load all reviews, keyed by listing_id. One query instead of N."""
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM reviews ORDER BY listing_id, review_date DESC")
    result = {}
    for row in cursor.fetchall():
        result.setdefault(row["listing_id"], []).append(dict(row))
    conn.close()
    return result

def get_all_commute_cache_batch(max_age_days: int = 7) -> dict:
    """Batch-load all fresh commute cache entries.
    Returns a nested dict: {listing_id: {dest_name: commute_minutes}}.
    """
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute(
        """SELECT listing_id, dest_name, commute_minutes FROM commute_cache
           WHERE datetime(fetched_at) >= datetime('now', ?)""",
        (f'-{max_age_days} days',),
    )
    result = {}
    for row in cursor.fetchall():
        result.setdefault(row["listing_id"], {})[row["dest_name"]] = row["commute_minutes"]
    conn.close()
    return result
```

**Key gotchas:**
- This turned scoring from 2,900 individual queries to 2 batch queries. Massive performance win.
- Use `dict.setdefault()` to build nested structures from flat query results.
- The commute cache version includes a freshness filter (`max_age_days`) so stale data is excluded.

---

### 12. Change-Only Snapshots (Price History / Special History)

**When to use:** When you want to track changes over time without bloating the table with duplicate records on every scrape.

**Python (sqlite3):**
```python
def record_price_snapshot(cursor, listing_id: int, price_min, price_max):
    if price_min is None and price_max is None:
        return

    cursor.execute(
        """SELECT price_min, price_max FROM price_history
           WHERE listing_id = ? ORDER BY id DESC LIMIT 1""",
        (listing_id,),
    )
    last = cursor.fetchone()

    if last is None:
        # First snapshot
        cursor.execute(
            "INSERT INTO price_history (listing_id, price_min, price_max) VALUES (?, ?, ?)",
            (listing_id, price_min, price_max),
        )
    else:
        # Only record if price actually changed
        if last["price_min"] != price_min or last["price_max"] != price_max:
            cursor.execute(
                "INSERT INTO price_history (listing_id, price_min, price_max) VALUES (?, ?, ?)",
                (listing_id, price_min, price_max),
            )
```

**Key gotchas:**
- Compare against the most recent snapshot before inserting. Prevents one row per scrape run.
- Called from within `upsert_listing()` — automatically records price changes during re-scrapes.
- Companion function `seed_price_history()` backfills existing listings when the feature is first added.
- The special history variant handles the additional complexity of NULL meaning "no special" vs. empty string.

---

### 13. Cross-Source Deduplication (Fuzzy Matching)

**When to use:** When the same entity appears from multiple sources with slightly different names/addresses.

**Python (sqlite3):**
```python
def _normalize_address_for_dedup(addr):
    if not addr:
        return ""
    addr = addr.lower().strip()
    addr = re.sub(r'^\|\s*', '', addr)                          # Strip Redfin pipe prefix
    addr = re.sub(r'\s+(?:apt|unit|ste|suite|#)\s*\S+', '', addr)  # Strip unit suffixes
    # Normalize street abbreviations
    _STREET_ABBREVS = [
        (r'\bst\b', 'street'), (r'\bln\b', 'lane'), (r'\brd\b', 'road'),
        (r'\bdr\b', 'drive'), (r'\bblvd\b', 'boulevard'), (r'\bave\b', 'avenue'),
    ]
    for pattern, replacement in _STREET_ABBREVS:
        addr = re.sub(pattern, replacement, addr)
    addr = re.sub(r'[,.]', '', addr)
    addr = re.sub(r'\s+', ' ', addr).strip()
    return addr

def _normalize_name_for_dedup(name):
    if not name:
        return ""
    name = name.lower().strip()
    name = re.sub(r'\b(?:apartments?|the|at)\b', '', name)
    name = re.sub(r'[^a-z0-9 ]', '', name)
    name = re.sub(r'\s+', ' ', name).strip()
    return name
```

**The dedup merge logic (three-tier field merging):**
```python
# Text fields: copy if keeper is NULL or empty
for field in text_fields:
    if not keeper.get(field) and dupe.get(field):
        updates.append(f"{field} = ?")
        values.append(dupe[field])

# Numeric fields: copy if keeper is NULL or 0
for field in numeric_fields:
    if (keeper.get(field) is None or keeper.get(field) == 0) and \
       dupe.get(field) and dupe[field] != 0:
        updates.append(f"{field} = ?")
        values.append(dupe[field])

# Boolean fields: only copy if keeper is NULL (0 means "no", not missing)
for field in bool_fields:
    if keeper.get(field) is None and dupe.get(field) is not None:
        updates.append(f"{field} = ?")
        values.append(dupe[field])
```

**Key gotchas:**
- Two-pass approach: normalized address first, then name+zip for anything not caught.
- Name normalization requires minimum length (8 chars after stripping filler) to prevent false matches.
- The three-tier merge is critical: text overwrites NULL/empty, numeric overwrites NULL/0, boolean overwrites NULL only. Zero is NOT the same as unknown for booleans.
- Reassign child records (reviews, photos) to the keeper before hiding the duplicate.

---

### 14. UTC Timestamps Everywhere

**When to use:** All database writes. Local time only for display/UX.

**Python (sqlite3):**
```python
def utc_now() -> str:
    """UTC timestamp in ISO 8601 format. Use for all DB storage."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def utc_ago(**kwargs) -> str:
    """UTC timestamp N hours/days ago. Use for DB query cutoffs."""
    return (datetime.now(timezone.utc) - timedelta(**kwargs)).strftime("%Y-%m-%dT%H:%M:%SZ")
```

**Node (in schema.sql):**
```sql
createdAt TEXT DEFAULT (datetime('now')),
updatedAt TEXT DEFAULT (datetime('now'))
```

**Key gotchas:**
- SQLite's `datetime('now')` returns UTC. The Python helper explicitly uses `timezone.utc`.
- `utc_ago()` is a utility for "find records older/newer than N hours/days" queries.
- `datetime.now()` without a timezone is a code smell in data paths — the helper makes this obvious.
- Handle both `T` and space separators when parsing (some sources use one, some the other).

---

### 15. Auto-Updated Timestamps

**When to use:** Tables with `updatedAt` columns that should automatically refresh on any update.

**Node (better-sqlite3):**
```js
const HAS_UPDATED_AT = new Set([
  'companies', 'jobs', 'candidates', 'candidate_jobs', 'templates', 'placements',
  'sequence_executions', 'bullhorn_companies', 'bullhorn_contacts', 'contacts',
]);

export function updateRecord(collection, id, data) {
  const withTimestamp = HAS_UPDATED_AT.has(table) && !data.updatedAt
    ? { ...data, updatedAt: new Date().toISOString() }
    : data;
  // ... rest of update logic
}
```

**Key gotchas:**
- Only auto-sets if the caller didn't explicitly provide `updatedAt` — allows overriding for imports/migrations.
- Registered in a Set, not derived from schema introspection — explicit is better than magic.

---

### 16. Domain Query Functions (Push Filtering to SQL)

**When to use:** Instead of `listCollection('activities').filter(a => a.company === name)` in JS — push the WHERE clause to SQL.

**Node (better-sqlite3):**
```js
export function getActivitiesByCompany(companyName) {
  return queryCollection('activities',
    'WHERE company = ? COLLATE NOCASE ORDER BY date DESC, createdAt DESC',
    [companyName]);
}

export function getStaleCompanies(dayThreshold = 14) {
  const db = getDb();
  return db.prepare(`
    SELECT c.name, c.stage, MAX(a.date) as lastActivity
    FROM companies c
    LEFT JOIN activities a ON LOWER(a.company) = LOWER(c.name)
    WHERE c.stage NOT IN ('Established Client', 'Lost', 'No Response')
    GROUP BY c.id
    HAVING lastActivity IS NULL OR lastActivity < date('now', ?)
    ORDER BY lastActivity ASC
    LIMIT 10
  `).all(`-${dayThreshold} days`);
}
```

**Key gotchas:**
- `COLLATE NOCASE` for case-insensitive matching on text fields.
- `queryCollection` is a thin wrapper that adds deserialization — for complex JOINs, use `db.prepare()` directly.
- The `getStaleCompanies` example shows a real domain query: LEFT JOIN + GROUP BY + HAVING with relative date math.

---

### 17. Schema Conventions

**Node schema patterns:**
```sql
-- TEXT primary keys (UUIDs), not INTEGER AUTOINCREMENT
id TEXT PRIMARY KEY,

-- Defaults for every text field (prevents NULL surprises)
name TEXT NOT NULL DEFAULT '',
stage TEXT DEFAULT 'No Response',

-- JSON columns are TEXT with comment markers
research TEXT, -- JSON blob
signals TEXT,  -- JSON blob

-- Timestamps with SQLite functions
createdAt TEXT DEFAULT (datetime('now')),
updatedAt TEXT DEFAULT (datetime('now'))

-- Composite UNIQUE constraints
UNIQUE(candidateId, jobId)

-- Foreign keys with cascade
FOREIGN KEY (candidateId) REFERENCES candidates(id) ON DELETE CASCADE
```

**Python schema patterns:**
```sql
-- INTEGER AUTOINCREMENT primary keys (scraper-assigned IDs)
id INTEGER PRIMARY KEY AUTOINCREMENT,

-- Natural UNIQUE key for upsert
UNIQUE(source, source_id)

-- Boolean as INTEGER with defaults
has_garage INTEGER DEFAULT 0,
allows_dogs INTEGER DEFAULT 0,
```

**Index conventions:**
```sql
-- Single-column indexes for common filters
CREATE INDEX IF NOT EXISTS idx_companies_stage ON companies(stage);

-- Composite indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_prospect_queue_status_score ON prospect_queue(status, score DESC);
CREATE INDEX IF NOT EXISTS idx_activities_date_company ON activities(date, company);
CREATE INDEX IF NOT EXISTS idx_seq_exec_status_next ON sequence_executions(status, nextActionDate);

-- Composite for covering queries
CREATE INDEX IF NOT EXISTS idx_price_history_listing ON price_history(listing_id, recorded_at DESC);
```

**Key gotchas:**
- The Node app uses TEXT UUIDs (`randomUUID()`) as PKs — good for distributed generation, bad for index locality.
- The Python scraper uses INTEGER AUTOINCREMENT — better for range scans and index performance.
- `DEFAULT ''` on text fields prevents NULL checks everywhere in application code.
- `IF NOT EXISTS` on all CREATE TABLE and CREATE INDEX statements makes schema idempotent.

---

### 18. Find-or-Create Pattern

**When to use:** When you need an entity to exist but don't know if it does yet (e.g., contacts from activity logs).

**Node (better-sqlite3):**
```js
export function findOrCreateContact(name, companyName, companyId) {
  const db = getDb();
  const existing = db.prepare(
    "SELECT * FROM contacts WHERE LOWER(TRIM(name)) = LOWER(TRIM(?)) AND LOWER(TRIM(companyName)) = LOWER(TRIM(?))"
  ).get(name, companyName);
  if (existing) return deserializeRow('contacts', existing);
  const id = randomUUID();
  db.prepare(
    "INSERT INTO contacts (id, name, companyId, companyName, source, createdAt, updatedAt) VALUES (?, ?, ?, ?, 'manual', datetime('now'), datetime('now'))"
  ).run(id, name, companyId || null, companyName);
  return { id, name, companyId, companyName, source: 'manual', activityCount: 0 };
}
```

**Key gotchas:**
- `LOWER(TRIM(...))` on both sides for case-insensitive, whitespace-tolerant matching.
- Returns the same shape whether it found or created — callers don't need to know which happened.
- Not atomic without a transaction — in theory, two concurrent calls could create duplicates. Acceptable for this use case since better-sqlite3 is synchronous and single-connection.

---

## Mistakes We Already Made

**1. loadDb() / saveDb() anti-pattern (fixed in production)**
The original design read ALL 6 tables into memory, mutated in JS, then rewrote ALL tables. This was the #1 performance and data integrity issue. A concurrent write from another service could be overwritten. Fixed by replacing with targeted DAL calls.

**2. Re-scraping wiped enrichment data (fixed in production)**
Running scrapers again would overwrite fields that had been enriched by detail-page crawlers (amenities, pet info, year_built). Fixed with `exclude_unset=True` in the upsert — only overwrite fields the scraper explicitly provided with non-None values.

**3. Prototype pollution via req.body spread (fixed in production)**
`...req.body` was spread directly into database operations, allowing arbitrary field injection. Fixed with the `SAFE_COL_RE` regex that drops any key not matching `^[a-zA-Z_][a-zA-Z0-9_]*$`.

**4. NULL vs 0 confusion in boolean/optional fields (fixed in production)**
Boolean fields like `has_garage` were defaulted to 0 when the data was unknown. But 0 means "confirmed no garage" and penalized the listing in scoring. Fixed: use NULL for unknown, 0 for confirmed no. The three-tier merge respects this: booleans overwrite WHERE NULL only.

**5. Missing JSON_FIELDS registration (ongoing)**
New tables with JSON columns must be added to the `JSON_FIELDS` map. Forgetting this means objects get `[object Object]` stored as a string. Every table is now registered, even if the array is empty.

**6. Raw SQL bypassing DAL deserialization (ongoing)**
Complex JOIN queries use `db.prepare()` directly and don't go through `deserializeRow`. The `getNextActionCompanies()` function manually parses research JSON as a workaround:
```js
return rows.map(r => {
  if (typeof r.research === 'string') {
    try { r.research = JSON.parse(r.research); } catch { /* leave as string */ }
  }
  return r;
});
```

**7. AI response structure crashes (fixed in production)**
`content[0].text` fails when AI response has unexpected structure. Not a SQLite issue directly, but the crash took down the server and left database connections open because there was no graceful shutdown. Fixed: safe extraction helpers + process error handlers + `closeDb()` on shutdown.

---

## Key Files (Source of Truth)

- `db/index.js` — Node DAL (production Express app): 1,227 lines, 70+ exported functions, WAL setup, JSON auto-serialization, CRUD, pagination, domain queries, sequence management, transactions
- `db/schema.sql` — 574 lines, 24 tables, 50+ indexes, migration-safe with `IF NOT EXISTS`
- `database.py` — Python DAL (production Python scraper): 1,153 lines, WAL setup, Pydantic validation, upsert with enrichment preservation, cross-source dedup, batch loading, price/special history tracking, commute cache
