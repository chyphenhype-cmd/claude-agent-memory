---

# Web Scraping Playbook
Source: Production Python scraper (Playwright)
Last extracted: 2026-03-07

---

## Patterns

### 1. BaseScraper — Anti-Detection Browser Management
**When to use:** Any project that needs Playwright for scraping. Every scraper inherits this.

**Pattern:** Centralize browser launch, page creation, and anti-detection in a base class. Each new page gets a randomized fingerprint (user agent + viewport). Stealth library handles the hard stuff (webdriver flag removal, WebGL fingerprint, etc.), with a manual fallback.

```python
# scrapers/base.py

try:
    from playwright_stealth import Stealth
    _stealth = Stealth()
except ImportError:
    _stealth = None

USER_AGENTS = [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:123.0) Gecko/20100101 Firefox/123.0",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2.1 Safari/605.1.15",
    # ... 15 total across Chrome/Firefox/Safari/Edge on macOS/Windows/Linux
]

VIEWPORTS = [
    {"width": 1920, "height": 1080},
    {"width": 1536, "height": 864},
    {"width": 1440, "height": 900},
    {"width": 1366, "height": 768},
    {"width": 2560, "height": 1440},
    {"width": 1680, "height": 1050},
    {"width": 1280, "height": 800},
]

class BaseScraper:
    async def start_browser(self):
        self.playwright = await async_playwright().start()
        self.browser = await self.playwright.chromium.launch(
            headless=self.headless,
            args=[
                "--disable-blink-features=AutomationControlled",
                "--no-sandbox",
            ],
        )

    async def new_page(self) -> Page:
        ua = random.choice(USER_AGENTS)
        viewport = random.choice(VIEWPORTS)
        context = await self.browser.new_context(
            viewport=viewport,
            user_agent=ua,
            locale="en-US",
            timezone_id="America/Chicago",
        )
        page = await context.new_page()
        if _stealth:
            await _stealth.apply_stealth_async(page)
        else:
            await page.add_init_script("""
                Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
            """)
        return page
```

**Key gotchas:**
- Always `try/except` the `playwright` and `playwright_stealth` imports so tests run without heavy deps installed.
- Set `locale` and `timezone_id` to match your target geography; mismatches are a detection signal.
- `--disable-blink-features=AutomationControlled` removes Chrome's automation indicator in the `navigator` object.

---

### 2. Safe Navigation with Exponential Backoff
**When to use:** Every `page.goto()` call. Network errors and timeouts are common; you need retry logic that does not retry non-transient failures (403, DNS errors).

```python
# scrapers/base.py

def backoff_delay(attempt, base=2.0, max_delay=30.0):
    delay = min(base ** attempt, max_delay)
    jitter = random.uniform(0, 1.0)
    return delay + jitter

async def safe_goto(self, page, url, retries=3,
                    wait_until="domcontentloaded", timeout=30000):
    for attempt in range(retries):
        try:
            response = await page.goto(url, wait_until=wait_until, timeout=timeout)
            if response and response.status == 403:
                print(f"    403 Forbidden: {url[:80]}")
                return False
            return True
        except Exception as e:
            err_str = str(e).lower()
            if "net::err_aborted" in err_str or "net::err_name_not_resolved" in err_str:
                return False  # Don't retry DNS or abort errors
            if attempt < retries - 1:
                delay = backoff_delay(attempt)
                await asyncio.sleep(delay)
            else:
                return False
    return False
```

**Key gotchas:**
- 403 = blocked, stop immediately. Do not retry.
- DNS resolution failures and `ERR_ABORTED` are permanent; retrying wastes time.
- Always add jitter to backoff to avoid thundering herd if multiple scrapers retry simultaneously.

---

### 3. curl_cffi for TLS-Fingerprint-Protected Sites (Akamai/Cloudflare)
**When to use:** Sites like Apartments.com that use Akamai bot detection. Playwright gets blocked because its TLS fingerprint is detectable. `curl_cffi` impersonates a real browser's TLS stack at the network level.

```python
# scrapers/apartments_com.py

try:
    from curl_cffi import requests as cffi_requests
except ImportError:
    cffi_requests = None

class ApartmentsComScraper(BaseScraper):
    HEADERS = {
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Accept-Encoding": "gzip, deflate, br",
        "Connection": "keep-alive",
        "Cache-Control": "max-age=0",
    }

    def _init_session(self):
        """Initialize session with Safari TLS impersonation + cookie warmup."""
        self.session = cffi_requests.Session(impersonate="safari")
        self.session.headers.update(self.HEADERS)

        # Visit homepage first to get tracking cookies (looks human)
        try:
            resp = self.session.get(self.BASE_URL, timeout=15)
            time.sleep(random.uniform(2, 4))
        except Exception:
            pass

    def _fetch_page(self, url):
        if not cffi_requests:
            return None
        if not hasattr(self, "session") or not self.session:
            self._init_session()
        try:
            resp = self.session.get(url, timeout=20)
            if resp.status_code == 200:
                text = resp.text
                if "access denied" in text[:500].lower():
                    return None  # Blocked by Akamai
                if len(text) < 2000:
                    return None  # Suspiciously short = probably a captcha page
                return text
            return None
        except Exception:
            return None
```

**Key gotchas:**
- The homepage warmup is critical: visit the base URL first to collect cookies, then make search requests. Without this, Akamai blocks you immediately.
- Check for "access denied" in the first 500 chars of the response body; Akamai returns 200 OK with a block page, not a 403.
- Check response length: a page under 2000 chars is almost certainly a captcha or block page, not real content.
- Conservative pacing between requests (5-10s random delay) prevents IP flagging:

```python
# Rate limiting between search pages
if i < len(search_urls) - 1:
    delay = random.uniform(5, 10)
    time.sleep(delay)
```

- Track blocked count and bail early:

```python
blocked_count = 0
for i, url in enumerate(search_urls):
    html = self._fetch_page(url)
    if not html:
        blocked_count += 1
        if blocked_count >= 3:
            print("    Too many blocks — stopping")
            break
```

---

### 4. API Interception (Zillow Pattern)
**When to use:** Sites with internal APIs (Zillow, Redfin, etc.). More reliable than DOM parsing because the API response is structured JSON. Set up a response listener before navigating, then extract data from intercepted API calls.

```python
# scrapers/zillow.py

class ZillowScraper(BaseScraper):
    def __init__(self, headless=True):
        super().__init__(headless=headless)
        self.api_listings = []
        self.api_photos = {}  # source_id -> [photo_urls]

    async def _setup_interception(self, page):
        """Intercept Zillow API responses to capture listing data."""
        async def handle_response(response):
            url = response.url
            if any(pat in url for pat in [
                "search-page-state",
                "async-create-search",
                "GetSearchPageState",
            ]):
                try:
                    data = await response.json()
                    self._extract_from_api(data)
                except Exception:
                    pass
        page.on("response", handle_response)

    def _extract_from_api(self, data):
        """Navigate Zillow's nested JSON structure."""
        cat1 = data.get("cat1", {})
        search_results = cat1.get("searchResults", {})
        list_results = search_results.get("listResults", [])
        map_results = search_results.get("mapResults", [])
        for result in list_results + map_results:
            listing = self._parse_api_result(result)
            if listing:
                self.api_listings.append(listing)

    async def scrape_search_page(self, page, url):
        # Set up interception BEFORE navigating
        await self._setup_interception(page)

        await self.safe_goto(page, url, wait_until="networkidle", timeout=45000)
        await self.random_delay(3, 5)

        # Scroll to trigger lazy loading
        await page.evaluate("window.scrollBy(0, 500)")
        await self.random_delay(1, 2)

        # Check API-intercepted data first
        if self.api_listings:
            listings = list(self.api_listings)
            self.api_listings.clear()
            return listings

        # Fallback: try __NEXT_DATA__ script tag
        next_data_el = await page.query_selector("script#__NEXT_DATA__")
        if next_data_el:
            content = await next_data_el.inner_text()
            data = json.loads(content)
            # ... extract from Next.js page data
```

**The key enrichment pattern** -- extract nested data greedily from API responses to avoid detail-page visits:

```python
def _enrich_from_home_info(self, listing, info):
    """Extract enrichment from Zillow's hdpData.homeInfo."""
    yr = info.get("yearBuilt")
    if yr and isinstance(yr, int) and 1900 < yr <= 2027:
        listing["year_built"] = yr

    pet_policy = info.get("petPolicy")
    if isinstance(pet_policy, dict):
        if pet_policy.get("dogs") or pet_policy.get("largeDogsAllowed"):
            listing["allows_dogs"] = 1
        weight = pet_policy.get("maxPetWeight") or pet_policy.get("dogWeightLimit")
        if weight:
            listing["dog_weight_limit"] = int(weight)
    elif isinstance(pet_policy, str) and pet_policy:
        pet_lower = pet_policy.lower()
        if "no pet" in pet_lower:
            listing["allows_dogs"] = 0
        elif "dog" in pet_lower:
            listing["allows_dogs"] = 1

    # Derive boolean flags from amenity text
    amenity_lower = amenity_text.lower()
    if "garage" in amenity_lower:
        listing["has_garage"] = 1
    if any(x in amenity_lower for x in ["in-unit", "in unit", "washer/dryer in"]):
        listing["has_in_unit_wd"] = 1
```

**Key gotchas:**
- Use `wait_until="networkidle"` (not `domcontentloaded`) so the API call completes before you check for data.
- The interception listener must be attached BEFORE `page.goto()`.
- Always have a DOM fallback -- API interception can fail silently.
- Zillow's `__NEXT_DATA__` script tag is a second fallback containing the same data in a different structure.
- Filter rental prices: `if price > 10000: return None` -- Zillow mixes sale and rental listings.
- Build search URLs using Zillow's `searchQueryState` JSON parameter encoded in the URL -- not traditional query params.

---

### 5. DOM Card Extraction with Parent Walk-Up (Zumper Pattern)
**When to use:** React/SPA sites where listing cards are rendered dynamically. Find stable anchor elements (links with known href patterns), then walk up the DOM tree to find the containing card with all the data.

```python
# scrapers/zumper.py — JS executed in browser context

raw_cards = await page.evaluate('''() => {
    const results = [];
    const links = document.querySelectorAll('a[href*="/apartment-buildings/"]');
    const seen = new Set();

    for (const link of links) {
        const href = link.href;
        if (seen.has(href)) continue;
        seen.add(href);

        // Walk up DOM to find card container with price + address
        let card = link;
        for (let i = 0; i < 15; i++) {
            card = card.parentElement;
            if (!card) break;
            const text = card.innerText || '';
            if (text.includes('$') && text.length > 80) break;
        }

        if (!card) continue;
        const text = card.innerText || '';
        if (!text.includes('$')) continue;

        let imgSrc = '';
        const imgs = card.querySelectorAll('img');
        for (const img of imgs) {
            const src = img.src || img.dataset?.src || '';
            if (src && src.startsWith('http') && !src.includes('logo') && !src.includes('icon')) {
                imgSrc = src;
                break;
            }
        }

        results.push({
            href: href,
            text: text.substring(0, 800),
            imgSrc: imgSrc,
        });
    }
    return results;
}''')
```

Then parse the text on the Python side with regex:

```python
def _parse_card_text(self, text, url):
    lines = [l.strip() for l in re.split(r'[\n|]', text) if l.strip()]

    # Filter noise tokens
    noise = {"Quick look", "View all fees", "Current Item", "Must-see", ""}
    lines = [l for l in lines if l not in noise and not re.match(r'^\d$', l)]

    for line in lines:
        # Price: $X,XXX or $X,XXX-$X,XXX
        price_match = re.findall(r"\$([\d,]+)", line)
        if price_match and not price_min:
            prices = [int(p.replace(",", "")) for p in price_match]
            prices = [p for p in prices if 500 < p < 15000]  # Sanity filter

        # Address: require "TX" and a 5-digit zip
        zip_match = re.search(r"TX\s+(\d{5})\b", line)

        # Bed/bath with flexible abbreviations
        bed_match = re.search(r"(\d+)\s*(?:bed|bd|br)", line, re.IGNORECASE)
        bath_match = re.search(r"(\d+\.?\d*)\s*(?:bath|ba)", line, re.IGNORECASE)

        # Amenity keywords from card badges
        amenity_kws = ["in-unit laundry", "garage parking", "swimming pool",
                       "fitness center", "pet friendly", "dog park"]
        for kw in amenity_kws:
            if kw.lower() in line.lower():
                amenities.append(kw)
```

**Key gotchas:**
- Href patterns (`/apartment-buildings/`) are stable; CSS class names change constantly on SPAs.
- The walk-up stops when it finds a container with `$` and 80+ chars -- this prevents grabbing just the link text vs the full card.
- Use `page.evaluate()` to run the extraction in browser context (not Playwright selectors), because React hydrates elements dynamically.
- Scroll aggressively before extraction to trigger lazy loading:

```python
for _ in range(8):
    await page.evaluate("window.scrollBy(0, 800)")
    await self.random_delay(1, 2)
```

- Always have inline JSON fallback for when DOM parsing gets few results:

```python
if len(listings) < 5:
    inline = await self._extract_inline_data(page)
```

---

### 6. Multi-Method HTML Parsing (JSON-LD + Card Selectors)
**When to use:** Sites that embed structured data. Try JSON-LD first (most reliable), then fall back to HTML card parsing.

```python
# scrapers/apartments_com.py

def _parse_html(self, html):
    listings = []
    soup = BeautifulSoup(html, "html.parser")

    # Method 1: JSON-LD structured data
    ld_scripts = soup.find_all("script", type="application/ld+json")
    for script in ld_scripts:
        try:
            data = json.loads(script.string)
            items = data if isinstance(data, list) else [data]
            for item in items:
                listing = self._parse_ld_json(item)
                if listing:
                    listings.append(listing)
        except (json.JSONDecodeError, TypeError):
            continue

    # Method 2: HTML cards (multiple selector fallbacks)
    cards = soup.select("[data-listingid]")
    if not cards:
        for sel in ["li.mortar-wrapper", "article.placard"]:
            cards = soup.select(sel)
            if cards:
                break

    for card in cards:
        listing = self._parse_html_card(card)
        if listing:
            listings.append(listing)

    return listings
```

**Key gotchas:**
- JSON-LD uses standard schema types (`ApartmentComplex`, `Apartment`, `Residence`) -- check the `@type` field.
- Have multiple CSS selector fallbacks for cards; sites A/B test their markup.
- Images require checking multiple attributes (`src`, `data-src`, `data-lazy-src`, `srcset`) and filtering out logos/icons/sprites:

```python
for img in card.select("img"):
    for attr in ("src", "data-src", "data-lazy-src", "srcset"):
        val = img.get(attr, "") or ""
        if attr == "srcset":
            val = val.split(",")[0].strip().split(" ")[0] if val else ""
        if val.startswith("http") and val not in all_photo_urls:
            if not any(skip in val.lower() for skip in ("logo", "icon", "sprite", "1x1", "pixel", ".svg")):
                all_photo_urls.append(val)
```

---

### 7. Cross-Source Deduplication (Address Normalization + Name+Zip Fuzzy Match)
**When to use:** Any time you scrape from multiple sources. The same property will appear with different names, abbreviations, and formatting.

**Two-pass approach:**

```python
# database.py

def _normalize_address_for_dedup(addr):
    if not addr:
        return ""
    addr = addr.lower().strip()
    # Strip Redfin pipe prefix: "| 505 W 8th St"
    addr = re.sub(r'^\|\s*', '', addr)
    # Strip unit/apt suffixes: "APT 305", "#719", "Unit 2B"
    addr = re.sub(r'\s+(?:apt|unit|ste|suite|#)\s*\S+', '', addr)
    # Remove property name prefix before street number
    m = re.match(r'^[a-z\s]+?(\d+\s)', addr)
    if m and m.start(1) > 5:
        addr = addr[m.start(1):]
    # Normalize street abbreviations
    _STREET_ABBREVS = [
        (r'\bst\b', 'street'), (r'\bln\b', 'lane'), (r'\brd\b', 'road'),
        (r'\bdr\b', 'drive'), (r'\bblvd\b', 'boulevard'), (r'\bave\b', 'avenue'),
        (r'\bct\b', 'court'), (r'\bpl\b', 'place'), (r'\bpkwy\b', 'parkway'),
    ]
    for pattern, replacement in _STREET_ABBREVS:
        addr = re.sub(pattern, replacement, addr)
    # Normalize directional abbreviations
    for pattern, replacement in [(r'\bn\.?\b', 'north'), (r'\bs\.?\b', 'south'),
                                  (r'\be\.?\b', 'east'), (r'\bw\.?\b', 'west')]:
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

def deduplicate_listings():
    # Pass 1: Group by normalized address
    addr_groups = defaultdict(list)
    for row in all_listings:
        norm = _normalize_address_for_dedup(row["address"])
        if norm:
            addr_groups[norm].append(row["id"])

    # Pass 2: Group by normalized name + zip (only ungrouped listings)
    name_zip_groups = defaultdict(list)
    for row in all_listings:
        if row["id"] in grouped_ids:
            continue
        norm_name = _normalize_name_for_dedup(row["name"])
        if norm_name and len(norm_name) >= 8 and row["zip_code"]:
            key = f"{norm_name}|{row['zip_code']}"
            name_zip_groups[key].append(row["id"])
```

**Three-tier merge logic for the keeper:**

```python
# Text fields: copy if keeper is NULL or empty
for field in ["amenities_raw", "description", "management_company", "image_url"]:
    if not keeper.get(field) and dupe.get(field):
        updates.append(f"{field} = ?")

# Numeric fields: copy if keeper is NULL or 0
for field in ["sqft", "year_built", "dog_weight_limit"]:
    if (keeper.get(field) is None or keeper.get(field) == 0) and dupe.get(field):
        updates.append(f"{field} = ?")

# Boolean fields: only copy if keeper is NULL (0 means "confirmed no", not missing)
for field in ["has_garage", "has_in_unit_wd", "allows_dogs"]:
    if keeper.get(field) is None and dupe.get(field) is not None:
        updates.append(f"{field} = ?")
```

**Key gotchas:**
- Name match requires minimum 8 chars after normalization to avoid false positives (short names like "The Vue" match too broadly).
- NEVER overwrite boolean fields that are 0. Zero means "confirmed no" (e.g., no dogs allowed). NULL means "unknown." This distinction is critical for scoring.
- Reassign reviews and photos from dupes to the keeper before hiding.
- Pick the keeper by highest score first, then most populated fields -- not just the oldest or first-seen.

---

### 8. Upsert with Enrichment Preservation
**When to use:** Every time you save scraped data. Re-scraping must NOT wipe out data enriched by detail-page visits or other scrapers.

```python
# database.py

def upsert_listing(listing):
    existing = cursor.execute(
        "SELECT id FROM listings WHERE source = ? AND source_id = ?",
        (validated.source, validated.source_id),
    ).fetchone()

    if existing:
        listing_id = existing["id"]
        # Only update fields the scraper explicitly provided (exclude_unset=True)
        update_data = validated.model_dump(exclude_unset=True)
        fields = []
        values = []
        for key, value in update_data.items():
            if key not in ("source", "source_id", "id", "first_seen") and value is not None:
                fields.append(f"{key} = ?")
                values.append(value)
        fields.append("last_seen = ?")
        values.append(utc_now())
        # ...
```

**Key gotchas:**
- `exclude_unset=True` is the magic: only fields the scraper explicitly set get updated. If the scraper did not provide `amenities_raw`, it stays untouched.
- `value is not None` prevents a scraper that returns `None` for a field from wiping out previously enriched data.
- Always update `last_seen` on every upsert so you know the listing is still active.
- Price snapshots should only be recorded when price actually changed:

```python
def record_price_snapshot(cursor, listing_id, price_min, price_max):
    last = cursor.execute(
        "SELECT price_min, price_max FROM price_history WHERE listing_id = ? ORDER BY id DESC LIMIT 1",
        (listing_id,),
    ).fetchone()
    if last is None:
        # First snapshot
        cursor.execute("INSERT INTO price_history ...")
    elif last["price_min"] != price_min or last["price_max"] != price_max:
        # Price changed
        cursor.execute("INSERT INTO price_history ...")
```

---

### 9. Optional Imports for Testability
**When to use:** Always. Heavy dependencies like Playwright should not prevent tests from running.

```python
# scrapers/base.py
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

```python
# scrapers/apartments_com.py
try:
    from curl_cffi import requests as cffi_requests
except ImportError:
    cffi_requests = None
```

**Key gotchas:**
- Provide fallback types (`Browser = object`) so type hints do not break.
- Check availability at runtime before use: `if not cffi_requests: return None`.
- This pattern enabled 1,078+ tests to run without Playwright installed.

---

### 10. UTC Timestamps Everywhere
**When to use:** All database storage. Local time only for display.

```python
# database.py

def utc_now() -> str:
    """UTC timestamp in ISO 8601 format."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def utc_ago(**kwargs) -> str:
    """UTC timestamp N hours/days ago. Use for DB query cutoffs."""
    return (datetime.now(timezone.utc) - timedelta(**kwargs)).strftime("%Y-%m-%dT%H:%M:%SZ")
```

**Key gotchas:**
- `datetime.now()` (no timezone) in data paths is a code smell -- always use `utc_now()`.
- Use the `Z` suffix (ISO 8601) for consistency.
- SQLite's `datetime()` function handles both space and T separators, so queries like `WHERE datetime(recorded_at) >= datetime(?)` work.

---

### 11. Detail Page Enrichment Pattern
**When to use:** After initial search-page scraping, visit individual listing pages to extract amenities, pet policy, year built, descriptions, etc.

```python
# scrapers/zumper.py

async def scrape_detail_page(self, page, url):
    await self.safe_goto(page, url, retries=2, timeout=20000)
    await self.random_delay(2, 4)

    # Scroll to load lazy content
    for _ in range(3):
        await page.evaluate("window.scrollBy(0, 800)")
        await self.random_delay(0.3, 0.6)

    body = await page.inner_text("body")
    body_lower = body.lower()

    enrichment = {}

    # Amenities: keyword scan of full page body
    for kw in ["garage", "pool", "fitness center", "gym", "in-unit laundry",
                "washer", "dishwasher", "balcony", "patio", "hardwood",
                "stainless steel", "granite", "ev charging", "dog park"]:
        if kw in body_lower:
            amenity_keywords.append(kw)

    # Pet policy: look for positive/negative signals
    if any(x in body_lower for x in ["dog", "pet friendly", "pets allowed"]):
        if "no dog" in body_lower or "no pet" in body_lower:
            enrichment["allows_dogs"] = 0
        else:
            enrichment["allows_dogs"] = 1

    # Weight limit regex
    weight_match = re.search(
        r'(\d+)\s*(?:lb|pound)s?\s*(?:max|limit|weight)', body_lower
    )

    # Year built regex
    year_match = re.search(
        r"(?:built in|year built|constructed in?)[:\s]*(\d{4})", body_lower
    )
    if year_match:
        yr = int(year_match.group(1))
        if 1900 < yr <= 2027:
            enrichment["year_built"] = yr
```

The enrichment update uses the three-tier merge:

```python
# Text: update if current is NULL or empty
for f in ("amenities_raw", "description", "management_company"):
    if f in data and data[f] and not existing.get(f):
        sets.append(f"{f} = ?")

# Numeric: update if current is NULL or 0
for f in ("year_built", "dog_weight_limit"):
    if f in data and data[f] and not existing.get(f):
        sets.append(f"{f} = ?")

# Boolean: update only if current is NULL
for f in ("has_garage", "has_in_unit_wd", "allows_dogs"):
    if f in data and existing.get(f) is None:
        sets.append(f"{f} = ?")
```

**Key gotchas:**
- Open a new browser context per detail page to avoid cookie/state leakage between listings.
- Close the context after each detail page: `await detail_page.context.close()`.
- Limit detail page visits: `detail_limit=20` -- you do not need to enrich every listing.
- Photos from detail pages: filter by bounding box width > 100px to skip icons and avatars.

---

### 12. Move-In Special Detection
**When to use:** Extracting promotional pricing from listing text (both card text and detail pages).

```python
# Used in both apartments_com.py and zumper.py

special_match = re.search(
    r"(\d+\s+(?:weeks?|months?)\s+free(?:\s+rent)?)"
    r"|(\$[\d,]+\s+off)"
    r"|(first\s+month\s+free)"
    r"|(look\s+and\s+lease)"
    r"|(up\s+to\s+\$[\d,]+\s+off)"
    r"|(\$[\d,]+\s+(?:concession|move[- ]?in\s+special))"
    r"|(limited[- ]time\s+(?:offer|pricing|rates?))"
    r"|(reduced\s+(?:rates?|pricing))"
    r"|(rent\s+special)"
    r"|(specials?\s+available)",
    card_text, re.IGNORECASE,
)
```

And the value estimator for financial comparison:

```python
# database.py

def estimate_special_value(special_text, monthly_rent=0):
    text = special_text.lower().strip()

    # "$X,XXX off" — direct dollar amount
    m = re.search(r'\$\s*([\d,]+)', text)
    if m:
        return float(m.group(1).replace(',', ''))

    # "X months free"
    m = re.search(r'(\d+)\s*months?\s*free', text)
    if m and monthly_rent > 0:
        return float(int(m.group(1))) * monthly_rent

    # "X weeks free"
    m = re.search(r'(\d+)\s*weeks?\s*free', text)
    if m and monthly_rent > 0:
        return int(m.group(1)) * (monthly_rent / 4.33)

    return 0.0
```

---

## Mistakes We Already Made

These are real bugs and architectural mistakes discovered during development, extracted from `docs/evolution.md` and `database.py`:

1. **Re-scraping wiped enrichment data.** The original upsert logic overwrote all fields on update, destroying amenity data, pet info, and descriptions that had been populated by detail-page enrichers. Fix: use `exclude_unset=True` on the Pydantic model dump so only explicitly-provided fields get updated.

2. **Same apartment appearing 3+ times across sources.** "Camden Belmont" vs "Camden Belmont Apartments" vs a slightly different address format. Without address normalization and name+zip fuzzy matching, duplicates flooded the rankings. Fix: two-pass dedup with `_normalize_address_for_dedup()` and `_normalize_name_for_dedup()`.

3. **Missing data scored as "average" instead of "neutral."** When 40%+ of scoring weight came from categories with no data (e.g., no commute time), the score clustered around the middle. Listings with no data looked the same as listings with genuinely average data. Fix: adaptive weight redistribution -- redistribute weight from missing-data categories to informed categories.

4. **Bedroom filter missing from dealbreaker checks.** Listings that should have been eliminated were ranking in the top 15 because the bedroom count was never checked as a dealbreaker. A separate bug: geo boundary check broke on listings with null coordinates. Fix: add null guards to every dealbreaker check.

5. **Boolean defaults of 0 treated as "confirmed no" when data was actually unknown.** `has_garage INTEGER DEFAULT 0` means every listing starts as "no garage" even when we simply have not checked. This penalized listings in scoring. Fix: use NULL for unknown, 0 for confirmed no. Only overwrite boolean fields during merge if the existing value is NULL.

6. **Zillow listings had unreliable data (estimated rents, missing floor plans) but dominated rankings.** Fix: Zillow confidence discount in the scoring engine.

7. **23 DFW zip codes were missing from the lookup table.** 28 listings had no location or commute scores at all because their zip was unknown. Fix: audit the zip code list against actual scraped data.

8. **Anti-bot escalation.** Sites started blocking Playwright scrapers after initial success. Adding user-agent rotation alone was not enough. Fix: layered defenses -- UA rotation + viewport randomization + random delays + playwright-stealth. For TLS fingerprinting (Akamai), switch to curl_cffi with browser impersonation. Conservative pacing (5-10s between requests) prevents IP flagging.

9. **Review scraper grinding through broken pages.** The original scraper tried every listing's reviews even when Google Maps was returning errors. Fix: bail early on consecutive failures instead of grinding through the entire list. Skip listings that already have recent reviews.

10. **`content[0].text` crashes on unexpected AI response structures.** (From a production Express app but applies universally.) Never assume response arrays have elements or that elements have the expected type. Use safe extraction helpers.

---

## Key Files (Source of Truth)

- `scrapers/base.py` -- BaseScraper with anti-detection, backoff, safe navigation
- `scrapers/apartments_com.py` -- curl_cffi/Safari TLS impersonation for Akamai-protected sites
- `scrapers/zillow.py` -- API interception pattern + nested JSON extraction
- `scrapers/zumper.py` -- DOM parent walk-up + inline JSON fallback + detail page enrichment
- `config.py` -- Search criteria, scoring weights, target zips, dealbreakers, anti-bot settings
- `database.py` -- Upsert with enrichment preservation, cross-source dedup, three-tier merge, price/special tracking
- `docs/evolution.md` -- Project narrative with all mistakes documented in context
