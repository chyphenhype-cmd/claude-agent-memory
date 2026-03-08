---

# Testing Patterns Playbook
Source: Production Python scraper (pytest) + Production Express app (no project-level tests)
Last extracted: 2026-03-07

---

## Pattern 1: Pure Function Extraction (Offline Scraper Testing)

**When to use:** Testing scraper logic without launching a browser. Extract parsing/regex/normalization into pure functions and test those directly.

**Three variants observed:**

### 1a. Mock `__init__` to avoid Playwright

Used when the scraper class has methods you want to test, but `__init__` would launch a browser.

```python
# From a production Python scraper's test suite

from unittest.mock import patch
from scrapers.apartments_com import ApartmentsComScraper

def make_scraper():
    """Return a scraper instance without starting Playwright."""
    with patch.object(ApartmentsComScraper, "__init__", lambda self, headless=True: None):
        s = ApartmentsComScraper.__new__(ApartmentsComScraper)
        s.browser = None
        s.scraper = None
    return s
```

**Gotcha:** You must manually set any instance attributes the methods depend on (like `s.browser = None`, `s.BASE_URL = "..."`) because `__init__` never ran.

### 1b. Safe `__init__` -- instantiate directly

Used when the scraper's `__init__` does NOT launch a browser (just sets config).

```python
# From a production Python scraper's test suite

from scrapers.zumper import ZumperScraper

# Module-level scraper instance — __init__ is safe (no browser launched)
_scraper = ZumperScraper()

def parse(text, url="https://www.zumper.com/apartments-for-rent/dallas-tx/p123456/main-st"):
    return _scraper._parse_card_text(text, url)
```

### 1c. Replicate the pure logic in the test file

Used when the scraper class cannot be imported at all without heavy dependencies. Copy the pure function into the test file and test the replica.

```python
# From a production Python scraper's test suite

# We can't import ZillowScraper directly (needs Playwright/BaseScraper).
# Instead, replicate the pure parsing logic for testing.

def _enrich_from_home_info(listing: dict, info: dict):
    """Replica of ZillowScraper._enrich_from_home_info for unit testing."""
    yr = info.get("yearBuilt")
    if yr and isinstance(yr, int) and 1900 < yr <= 2027:
        listing["year_built"] = yr
    # ... rest of logic copied from source
```

**Gotcha:** The replica must be kept in sync with the source. If the real function changes and the test replica doesn't, tests pass but coverage is illusory. Consider refactoring the real code to extract these as standalone functions instead.

### 1d. Replicate block-detection or regex logic

For helper functions embedded in methods that can't be imported, replicate just the logic.

```python
# From a production Python scraper's test suite

def _is_blocked_response(text: str, status_code: int) -> bool:
    """Replicate the block-detection logic from _fetch_page_cloudscraper."""
    if status_code != 200:
        return True
    if "access denied" in text.lower()[:500]:
        return True
    if "reference #" in text.lower()[:500]:
        return True
    if len(text) < 1000:
        return True
    return False
```

---

## Pattern 2: Optional Imports (try/except)

**When to use:** Source modules depend on heavy/optional packages (Playwright, pandas, etc.). Wrap imports so tests can import the module without installing those deps.

```python
# From a production Python scraper's base module

try:
    from playwright.async_api import async_playwright, Browser, Page
except ImportError:
    async_playwright = None
    Browser = object
    Page = object

try:
    from playwright_stealth import Stealth
    _stealth = Stealth()
except ImportError:
    _stealth = None
```

**Key gotchas:**
- Set fallback values that won't cause `NameError` at import time (`= None` or `= object`)
- Any code that uses the optional dep must check `if async_playwright is None` before calling
- This pattern fixed 13 test collection errors in a production scraper (tests couldn't even load modules without Playwright installed)

---

## Pattern 3: Database Isolation with tmp_path + monkeypatch

**When to use:** Testing functions that hit SQLite. Redirect all DB operations to a temp file so tests don't corrupt real data.

```python
# From a production Python scraper's test suite

import database

@pytest.fixture(autouse=True)
def tmp_db(monkeypatch, tmp_path):
    """Redirect all database operations to a temporary file."""
    db_file = str(tmp_path / "test.db")
    monkeypatch.setattr(database, "get_db_path", lambda: db_file)
    database.init_db()
    return db_file
```

**Key gotchas:**
- Use `autouse=True` so every test in the file gets a fresh DB automatically
- Call `database.init_db()` after patching to create the schema in the temp DB
- Some tables (like `photos`) may not be created by `init_db()` -- create them manually in the fixture if needed
- Return the `db_file` path so tests can open raw `sqlite3` connections for assertions that bypass the DAL

---

## Pattern 4: Factory Helpers (_make_listing, _make_card)

**When to use:** Tests need realistic data structures. Create a helper that returns defaults with override capability.

```python
# From a production Python scraper's test suite

def _make_listing(**overrides):
    """Helper to build a valid listing dict with sensible defaults."""
    defaults = {
        "source": "test",
        "source_id": "abc-123",
        "name": "Test Apartment",
        "address": "100 Main St, Dallas, TX 75206",
        "city": "Dallas",
        "state": "TX",
        "zip_code": "75206",
        "price_min": 2800.0,
        "price_max": 3200.0,
        "bedrooms": 2,
        "bathrooms": 2.0,
        "sqft": 1100,
    }
    defaults.update(overrides)
    return defaults
```

**Why this matters:** Tests only specify the fields they care about. A test about price doesn't need to set address, zip, etc. Reduces noise and makes test intent obvious.

---

## Pattern 5: Scoring Without Live Data (Pure Function Testing)

**When to use:** Testing scoring engines that normally read from DB or APIs. Import the pure scoring functions and pass synthetic data.

```python
# From a production Python scraper's test suite

from research.scoring import (
    score_price, score_sqft, score_location, score_commute,
    score_amenities, score_style, score_pet,
    calculate_total_score, calculate_adaptive_score,
    _has_component_data,
)

class TestScorePrice:
    def test_no_price_returns_neutral(self):
        assert score_price({}) == 0.5
        assert score_price({"price_min": 0}) == 0.5

    def test_in_range(self):
        assert score_price({"price_min": 2800}) == 0.9

    def test_way_over_budget_zero(self):
        assert score_price({"price_min": 5000}) == 0
```

**For adaptive scoring with DB dependencies, use monkeypatch:**

```python
# From a production Python scraper's test suite

class TestHasComponentData:
    def test_full_data_listing(self, monkeypatch):
        listing = {
            "id": 999, "price_min": 2800, "sqft": 1400,
            "lat": 32.83, "lon": -96.77,
            "amenities_raw": "pool garage balcony",
            "allows_dogs": 1, "year_built": 2022,
        }
        # Mock the DB call that checks for reviews
        monkeypatch.setattr("research.scoring.get_listing_reviews",
                            lambda lid: [{"rating": 4.5}])
        scores = {"review_score": 0.85, "style_score": 0.85}
        result = _has_component_data(listing, scores)
        assert all(result.values())
```

**Key gotcha:** `monkeypatch.setattr` uses the dotted path where the function is *looked up*, not where it's *defined*. If `scoring.py` imports `get_listing_reviews` from `database`, patch `"research.scoring.get_listing_reviews"`, not `"database.get_listing_reviews"`.

---

## Pattern 6: Regex Pattern Testing (Reviews, Parsing)

**When to use:** Testing regex patterns used for HTML/text parsing. Define the compiled patterns in the test file (mirroring the source) and test against known inputs.

```python
# From a production Python scraper's test suite

import re

GOOGLE_RATING_PATTERN = re.compile(
    r"(\d\.\d)\s*(?:out of 5|stars?|\([\d,]+ (?:review|rating))",
    re.IGNORECASE,
)

class TestGoogleRatingRegex:
    def test_matches_out_of_5(self):
        m = GOOGLE_RATING_PATTERN.search("4.2 out of 5")
        assert m and float(m.group(1)) == 4.2

    def test_no_match_for_plain_decimal(self):
        m = GOOGLE_RATING_PATTERN.search("4.2 is our apartment unit number")
        assert m is None
```

**Key gotchas:**
- Always test negative cases (what should NOT match) alongside positive cases
- Test edge cases: case sensitivity, embedded in longer text, boundary values
- Test that the pattern doesn't capture false positives from similar-looking text

---

## Pattern 7: External API Mocking (Google Places, Config)

**When to use:** Testing code that calls external APIs. Use `@patch` to mock the network call and config values.

```python
# From a production Python scraper's test suite

from unittest.mock import patch, MagicMock

def _mock_places_response(rating=4.3, count=156, display_name="Katy Trail Uptown"):
    """Build a mock Places API JSON response."""
    body = json.dumps({
        "places": [{
            "rating": rating,
            "userRatingCount": count,
            "displayName": {"text": display_name},
        }]
    }).encode()
    resp = MagicMock()
    resp.read.return_value = body
    resp.__enter__ = lambda s: s
    resp.__exit__ = MagicMock(return_value=False)
    return resp

class TestFetchPlacesRating:
    @patch("research.reviews.GOOGLE_MAPS", {"api_key": "test-key"})
    @patch("research.reviews.urllib.request.urlopen")
    def test_extracts_rating_and_count(self, mock_urlopen):
        mock_urlopen.return_value = _mock_places_response(4.3, 156)
        result = fetch_places_rating("Katy Trail Uptown")
        assert result["rating"] == 4.3
        assert result["review_count"] == 156

    @patch("research.reviews.GOOGLE_MAPS", {"api_key": "test-key"})
    @patch("research.reviews.urllib.request.urlopen")
    def test_handles_network_error(self, mock_urlopen):
        mock_urlopen.side_effect = Exception("Connection refused")
        result = fetch_places_rating("Katy Trail Uptown")
        assert result["rating"] == 0
```

**Key gotchas:**
- Mock the context manager protocol (`__enter__`/`__exit__`) for `urllib.request.urlopen`
- Always test the error path (network failure, empty response, malformed JSON)
- Patch config values alongside the network call to control API key presence

---

## Pattern 8: Anti-Bot Config Integrity Testing

**When to use:** Validating that anti-detection pools (user agents, viewports) stay realistic and diverse.

```python
# From a production Python scraper's test suite

from scrapers.base import USER_AGENTS, VIEWPORTS, pick_user_agent, pick_viewport, backoff_delay

class TestUserAgents:
    def test_pool_has_at_least_10_entries(self):
        assert len(USER_AGENTS) >= 10

    def test_all_contain_mozilla(self):
        for ua in USER_AGENTS:
            assert ua.startswith("Mozilla/5.0")

    def test_no_duplicates(self):
        assert len(USER_AGENTS) == len(set(USER_AGENTS))

    def test_contains_modern_chrome_versions(self):
        modern = [ua for ua in USER_AGENTS if "Chrome/12" in ua]
        assert len(modern) >= 5

class TestPickUserAgent:
    def test_randomness(self):
        """Multiple calls should produce at least 2 distinct UAs."""
        random.seed(42)
        results = {pick_user_agent() for _ in range(50)}
        assert len(results) >= 2
```

---

## Pattern 9: Three-Tier Merge Testing (NULL vs Zero vs Confirmed)

**When to use:** Testing deduplication or enrichment that merges data from multiple sources. The key invariant: NULL = unknown (overwrite), 0 = confirmed no (preserve), value = confirmed (preserve).

```python
# From a production Python scraper's test suite

class TestDataMerging:
    def test_merges_boolean_only_from_null(self, tmp_db):
        lid1 = database.upsert_listing(_make_listing(
            source="zumper", source_id="z1",
            address="100 Main St, Dallas, TX 75206",
            has_garage=None, allows_dogs=None,
        ))
        lid2 = database.upsert_listing(_make_listing(
            source="rent.com", source_id="r1",
            address="100 Main St, Dallas, TX 75206",
            has_garage=1, allows_dogs=0,
        ))
        _add_score(lid1, 0.9)
        _add_score(lid2, 0.5)
        database.deduplicate_listings()
        kept = _get_listing(tmp_db, lid1)
        assert kept["has_garage"] == 1
        assert kept["allows_dogs"] == 0

    def test_does_not_overwrite_boolean_zero(self, tmp_db):
        """0 means 'no', not 'unknown' — should NOT be overwritten."""
        lid1 = database.upsert_listing(_make_listing(
            source="zumper", source_id="z1",
            address="100 Main St, Dallas, TX 75206",
            has_garage=0,
        ))
        lid2 = database.upsert_listing(_make_listing(
            source="rent.com", source_id="r1",
            address="100 Main St, Dallas, TX 75206",
            has_garage=1,
        ))
        _add_score(lid1, 0.9)
        _add_score(lid2, 0.5)
        database.deduplicate_listings()
        kept = _get_listing(tmp_db, lid1)
        assert kept["has_garage"] == 0  # 0 preserved, not overwritten with 1
```

**This is a critical invariant.** Defaulting boolean/optional fields to 0 when unknown penalizes in scoring. Use NULL for unknown, 0 for confirmed no.

---

## Pattern 10: Idempotency Testing

**When to use:** Any operation that might run multiple times (dedup, enrichment, scoring). Verify that running it twice produces the same result.

```python
# From a production Python scraper's test suite

class TestIdempotency:
    def test_running_twice_produces_same_result(self, tmp_db):
        database.upsert_listing(_make_listing(
            source="zumper", source_id="z1",
            address="100 Main St, Dallas, TX 75206",
        ))
        database.upsert_listing(_make_listing(
            source="rent.com", source_id="r1",
            address="100 Main St, Dallas, TX 75206",
        ))
        first_run = database.deduplicate_listings()
        second_run = database.deduplicate_listings()
        assert first_run == 1
        assert second_run == 0  # Already deduped
        assert _count_visible(tmp_db) == 1
```

---

## Mistakes We Already Made

**From evolution.md and pattern trackers:**

1. **`content[0].text` crash (Express app):** AI response content blocks can be missing or unexpected types. Always use safe extraction helpers. Fixed across 9 route handlers.

2. **Bedroom filter missing from dealbreakers (Python scraper):** Listings that should have been eliminated were ranking in the top 15. Critical scoring bug.

3. **Geo boundary check broke on null coordinates (Python scraper):** Dealbreaker check crashed on listings with `lat=None`. Always guard against null coords.

4. **NULL vs 0 confusion (Python scraper):** Boolean fields defaulted to 0 instead of NULL. Zero means "confirmed no" and penalizes in scoring. NULL means "unknown" and should be neutral.

5. **Re-scraping wiped enriched data (Python scraper):** Upsert logic overwrote detail-page-enriched fields with empty values from list-page scrapes. Fixed to only overwrite when new data is actually better.

6. **13 test collection errors (Python scraper):** Tests couldn't even load because Playwright wasn't installed in the test environment. Fixed with try/except optional imports (Pattern 2).

7. **Prototype pollution (Express app):** `req.body` spread directly into DB operations. Fixed with field whitelisting on every create/update endpoint.

8. **SSE stream crashes on disconnect (Express app):** `res.write()` after client disconnect crashed the server. Fixed with try/catch guards and interval cleanup.

---

## Express App Testing Gap

The production Express app has **zero project-level tests**. All test files found were in `node_modules/`. The event bus (`services/events.js`) is a clean 41-line EventEmitter wrapper with named event constants -- testable but untested. The project documentation references "full test coverage" for the event bus, but no test files exist in the repository.

---

## Key Files (Source of Truth)

**Python Scraper Tests:**
- `tests/conftest.py` -- pytest config (adds project root to path)
- `tests/test_scoring.py` -- 880+ lines, scoring engine tests (Patterns 5, 10)
- `tests/test_zillow_extraction.py` -- 421 lines, logic replica pattern (Pattern 1c)
- `tests/test_apartments_com.py` -- 585 lines, mock __init__ pattern (Pattern 1a)
- `tests/test_zumper.py` -- 599 lines, safe __init__ pattern (Pattern 1b)
- `tests/test_deduplication.py` -- 830 lines, DB isolation + merge + idempotency (Patterns 3, 9, 10)
- `tests/test_reviews.py` -- 612 lines, regex + API mock patterns (Patterns 6, 7)
- `tests/test_base_scraper.py` -- 193 lines, anti-bot pool integrity (Pattern 8)
- `tests/test_detail_enricher.py` -- DB isolation with extra table setup (Pattern 3)

**Source Code (Optional Import Pattern):**
- `scrapers/base.py` -- try/except for Playwright + playwright_stealth (Pattern 2)

**Express App (No Tests):**
- `services/events.js` -- 41-line event bus, testable but untested
