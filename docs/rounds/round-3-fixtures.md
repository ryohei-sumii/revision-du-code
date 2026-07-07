# Round 3 — テストフィクスチャ / Fixtures

Opus が作成し Sonnet が独立検証した仕込みバグ差分。**評価の正解データ**。6領域すべて有効。

## 作成フィクスチャ(author)

### domain: TypeScript backend service — OAuth2 access-token lifetime handling and proactive token refresh middleware
**planted bugs:**
- `PB1` [high/api-contract-break-units] @ src/auth/refresh.ts, maybeRefresh: `if (ttl < 300)` (line ~14) — getTokenTtl's contract changed from returning seconds to returning milliseconds (token.ts: `token.expiresAtMs - Date.now()`, doc comment updated to 'in milliseconds'). The existing caller in maybeRefresh still compares against the literal `300`, which was intended as 300 seconds = 5 minutes (see the function's own comment 'within 5 minutes of expiry'). After the migration `300` now means 300 milliseconds, so proactive refresh is effectively disabled: a token is only refreshed in the final 0.3s before it expires instead of the final 5 minutes. The author even renamed the log field to `ttlMs`, acknowledging the unit changed, but left the threshold untouched.
  - なぜ本物: A token with 4 minutes of remaining life yields ttl=240000ms; `240000 < 300` is false, so maybeRefresh returns the un-refreshed token. Concretely: under sustained load, requests using a token in its last 5 minutes are no longer pre-refreshed; the token expires mid-flight and callers get intermittent 401s and request races — the exact failure the middleware exists to prevent. It compiles cleanly and passes any test that only checks already-expired or very-fresh tokens, so it is easy to miss in review.
**benign traps(拾ってはいけない無害な変更):**
- @ src/auth/token.ts, tokenFromWire: `expiresAtMs: Date.now() + w.expires_in * 1000` — A `* 1000` conversion applied to an incoming token field, which can look like a suspicious unit double-conversion (as if expires_in were already milliseconds, or already an absolute timestamp).  (なぜOK: RFC 6749 §5.1 defines `expires_in` as a relative lifetime in seconds. Converting seconds to milliseconds and adding to `Date.now()` (ms) correctly produces an absolute ms timestamp consistent with the new `expiresAtMs` contract. The multiply is exactly right.)
- @ src/auth/token.ts, isExpiringSoon threshold change `REFRESH_THRESHOLD_SECONDS = 60` -> `REFRESH_THRESHOLD_MS = 60_000` — The refresh threshold constant jumps from 60 to 60000 — a 1000x magnitude change that looks alarming at a glance.  (なぜOK: This is the correctly-migrated call site: getTokenTtl now returns milliseconds, so the threshold must be scaled by 1000 to preserve the original 60-second semantics. 60_000 ms = 60 s. This change is correct — and its correctness is what makes the un-migrated `< 300` in refresh.ts (PB1) plausible as an oversight rather than intent.)
- @ src/auth/token.ts, getTokenTtl: removal of `Math.floor(Date.now() / 1000)` in favor of `Date.now()` — Dropping the `Math.floor(.../1000)` and the truncation looks like it could lose the seconds-based rounding the old code relied on.  (なぜOK: The whole point of the migration is to work in milliseconds; `expiresAtMs - Date.now()` is the correct ms-domain computation. There is no longer any seconds truncation to preserve, and no caller depends on the value being an integer number of seconds.)

<details><summary>diff</summary>

```diff
diff --git a/src/auth/token.ts b/src/auth/token.ts
index 6b1f0a2..e9c4d31 100644
--- a/src/auth/token.ts
+++ b/src/auth/token.ts
@@ -1,28 +1,35 @@
 export interface WireToken {
   jti: string;
   sub: string;
-  // Absolute expiry (`exp` claim), Unix seconds.
-  exp: number;
+  // Lifetime from time of issue, in seconds (RFC 6749 `expires_in`).
+  expires_in: number;
   scope: string;
 }
 
 export interface Token {
   id: string;
   subject: string;
-  // Absolute expiry as a Unix timestamp in seconds.
-  expiresAt: number;
+  // Absolute expiry as a Unix timestamp in milliseconds.
+  expiresAtMs: number;
   scopes: string[];
 }
 
-// Remaining lifetime of the token, in seconds.
-export function getTokenTtl(token: Token): number {
-  return token.expiresAt - Math.floor(Date.now() / 1000);
-}
+// Remaining lifetime of the token, in milliseconds.
+export function getTokenTtl(token: Token): number {
+  return token.expiresAtMs - Date.now();
+}
 
-const REFRESH_THRESHOLD_SECONDS = 60;
+const REFRESH_THRESHOLD_MS = 60_000;
 
 export function isExpiringSoon(token: Token): boolean {
-  return getTokenTtl(token) < REFRESH_THRESHOLD_SECONDS;
+  return getTokenTtl(token) < REFRESH_THRESHOLD_MS;
 }
+
+// The OAuth2 token endpoint (RFC 6749 §5.1) returns `expires_in` as a
+// number of seconds from the moment the token was issued.
+export function tokenFromWire(w: WireToken): Token {
+  return {
+    id: w.jti,
+    subject: w.sub,
+    expiresAtMs: Date.now() + w.expires_in * 1000,
+    scopes: w.scope.split(" "),
+  };
+}
diff --git a/src/auth/refresh.ts b/src/auth/refresh.ts
index 2a7c9f4..b0d5e88 100644
--- a/src/auth/refresh.ts
+++ b/src/auth/refresh.ts
@@ -1,17 +1,17 @@
 import { Token, getTokenTtl } from "./token";
 import { logger } from "../log";
 
 type RefreshFn = (token: Token) => Promise<Token>;
 
 // Proactively refresh tokens that are within 5 minutes of expiry so that
 // in-flight requests never race a hard expiry and fail with a 401.
 export async function maybeRefresh(
   token: Token,
   refresh: RefreshFn,
 ): Promise<Token> {
   const ttl = getTokenTtl(token);
   if (ttl < 300) {
-    logger.info(`refreshing token ${token.id}, ttl=${ttl}s`);
+    logger.info("refreshing token", { id: token.id, ttlMs: ttl });
     return refresh(token);
   }
   return token;
 }
```
</details>

### domain: E-commerce checkout pricing (coupon discounts, tax, and free-shipping calculation) in a Python backend
**planted bugs:**
- `bug-1` [high/wrong-operator (min vs max)] @ store/pricing.py, _discount_for(), the return line: return max(raw, coupon.max_discount_cents) — The coupon discount is meant to be the percentage-off amount (raw) capped at max_discount_cents, i.e. min(raw, cap). The code uses max(raw, cap) instead, so whenever the computed percentage discount is smaller than the cap (the normal case for typical carts) the discount is inflated up to the cap value. max_discount_cents is a ceiling being used as a floor.
  - なぜ本物: Concrete input: subtotal_cents=5000 ($50), coupon = 10% off, min_subtotal=3000, max_discount=2000 ($20 cap). Intended discount = min(500, 2000) = 500 ($5). The code returns max(500, 2000) = 2000, discounting $20 off a $50 order (4x too much) and undercharging tax on top of it. For a cap larger than the subtotal (e.g. subtotal=3000, cap=5000) it drives taxable/total negative. This fires for essentially every order where the percentage discount is under the cap, i.e. the common case, causing systematic revenue loss.
**benign traps(拾ってはいけない無害な変更):**
- @ store/pricing.py, _shipping_for(): if discounted_subtotal_cents >= policy.free_over_cents — Free-shipping eligibility uses >= against free_over_cents. A reviewer may flag this as an off-by-one and claim it should be a strict >.  (なぜOK: The field is documented as 'free shipping once subtotal reaches this amount' — reaching the threshold exactly should qualify, so >= is the correct inclusive comparison. Changing it to > would be the actual bug.)
- @ store/pricing.py, calculate_order_total(): tax = taxable * tax_rate_bps // 10_000 (tax computed on the post-discount subtotal) — The refactor changes tax to be computed on the discounted subtotal (taxable) rather than the original subtotal_cents, which lowers collected tax versus the old function and looks like a regression.  (なぜOK: This is the intended, explicitly documented behavior ('charge tax on the discounted subtotal') and matches standard sales-tax treatment where tax applies after order-level discounts. The integer // truncation is carried over unchanged from the original code and is the existing rounding convention, not a new defect.)

<details><summary>diff</summary>

```diff
diff --git a/store/pricing.py b/store/pricing.py
index 3f1a2c9..b7e4d10 100644
--- a/store/pricing.py
+++ b/store/pricing.py
@@ -1,8 +1,58 @@
 from dataclasses import dataclass
 
 
-def calculate_order_total(subtotal_cents: int, tax_rate_bps: int) -> int:
-    """Order total in cents. tax_rate_bps is basis points (e.g. 875 = 8.75%)."""
-    tax = subtotal_cents * tax_rate_bps // 10_000
-    return subtotal_cents + tax
+@dataclass(frozen=True)
+class Coupon:
+    code: str
+    percent_off: int          # e.g. 15 => 15% off
+    min_subtotal_cents: int   # minimum eligible subtotal
+    max_discount_cents: int   # cap on the discount amount
+
+
+@dataclass(frozen=True)
+class ShippingPolicy:
+    flat_fee_cents: int
+    free_over_cents: int      # free shipping once subtotal reaches this amount
+
+
+def _discount_for(subtotal_cents: int, coupon: Coupon | None) -> int:
+    """Discount (in cents) the coupon grants for this subtotal; 0 if ineligible."""
+    if coupon is None or subtotal_cents < coupon.min_subtotal_cents:
+        return 0
+    raw = subtotal_cents * coupon.percent_off // 100
+    return max(raw, coupon.max_discount_cents)
+
+
+def _shipping_for(discounted_subtotal_cents: int, policy: ShippingPolicy) -> int:
+    if discounted_subtotal_cents >= policy.free_over_cents:
+        return 0
+    return policy.flat_fee_cents
+
+
+def calculate_order_total(
+    subtotal_cents: int,
+    tax_rate_bps: int,
+    coupon: Coupon | None = None,
+    shipping: ShippingPolicy | None = None,
+) -> int:
+    """
+    Order total in cents. tax_rate_bps is basis points (e.g. 875 = 8.75%).
+
+    Order of operations (product spec): apply the coupon first, then charge
+    tax on the *discounted* subtotal, then add shipping. Shipping itself is
+    never taxed, and free-shipping eligibility is based on the post-discount
+    subtotal.
+    """
+    discount = _discount_for(subtotal_cents, coupon)
+    taxable = subtotal_cents - discount
+
+    tax = taxable * tax_rate_bps // 10_000
+    total = taxable + tax
+
+    if shipping is not None:
+        total += _shipping_for(taxable, shipping)
+
+    return total
```
</details>

### domain: Backend web service — Python / FastAPI + SQLAlchemy financial transactions API. A PR adds a CSV export endpoint for an account's transaction history alongside the existing paginated JSON list endpoint.
**planted bugs:**
- `unbounded-export` [critical/resource-exhaustion] @ app/services/reports.py — export_transactions_csv, the `rows = q.all()` line and the io.StringIO buffer that follows — The export query applies only account_id and a caller-supplied [start, end) date window, then materializes the entire result with .all() and builds the full CSV in an in-memory StringIO buffer. There is no LIMIT, no row cap, no date-range cap, and no streaming. Unlike the sibling list endpoint (which is paginated via offset/limit with page_size <= 500), the export path has no bound on how much work or memory a single request can demand.
  - なぜ本物: A caller can pass start=1970-01-01 and end=2100-01-01 (the endpoint accepts arbitrary datetimes with no validation) and force the service to load every transaction for the account. For an account with millions of rows, q.all() pulls the full result set into a Python list AND the CSV text is accumulated in a StringIO buffer held entirely in memory before the Response is constructed — roughly two full copies of the dataset resident at once. A few concurrent export requests exhaust the worker's memory and OOM-kill the process, taking down all requests on that worker. The correct approach is a streaming response with a server-side cursor (e.g. yield_per) plus an enforced max row count or max date-window.
- `export-missing-authz` [high/broken-access-control] @ app/api/exports.py — export_transactions handler body (never calls require_account_access) — The new export endpoint injects current_user via Depends(get_current_user) but never calls require_account_access(current_user, account_id, session) before reading the account's transactions. The list_transactions endpoint immediately above it does perform that check.
  - なぜ本物: Any authenticated user can export another user's transaction history by supplying an arbitrary account_id in the path — a classic IDOR. The current_user dependency only authenticates; it does not authorize access to the specific account. Because the check is present in the adjacent endpoint but silently absent here, it reads as an oversight rather than an intentional policy difference, and it leaks financial PII across tenants.
**benign traps(拾ってはいけない無害な変更):**
- @ app/api/exports.py — list_transactions, page_size Query changed from le=100 to le=500 — The maximum allowed page_size for the paginated JSON list endpoint is raised from 100 to 500.  (なぜOK: The value is still a hard upper bound enforced by FastAPI's validation (ge=1, le=500), and the query still uses offset/limit, so a single request fetches at most 500 rows. Raising a bounded page-size ceiling to a still-reasonable value is a normal tuning change and does not create unbounded work — a reviewer flagging this as a resource risk would be a false positive, and it is a deliberate contrast to the genuinely unbounded export path.)
- @ app/services/reports.py — list_transactions, removal of the Python sorted(...) and addition of .order_by(Transaction.created_at.desc()) — The function drops the in-memory `sorted(rows, key=..., reverse=True)` post-processing and instead adds an ORDER BY created_at DESC to the query itself.  (なぜOK: This is behavior-preserving and in fact strictly better: ordering now happens in the database against the same page window, so the newest-first ordering the UI expects is unchanged. Previously the code sorted only the already-paginated page in Python; moving the sort into the SQL over the same offset/limit produces the same page contents in the same order (created_at is the sort key in both). It looks like a semantics change but is equivalent, and it does not affect how many rows are fetched.)

<details><summary>diff</summary>

```diff
diff --git a/app/services/reports.py b/app/services/reports.py
index 3c1a9f2..b7e40aa 100644
--- a/app/services/reports.py
+++ b/app/services/reports.py
@@ -1,7 +1,10 @@
+import csv
+import io
 from datetime import datetime
 
 from sqlalchemy.orm import Session
 
 from app.models import Transaction
 
 
 def list_transactions(
     session: Session,
     account_id: int,
     start: datetime,
     end: datetime,
     page: int,
     page_size: int,
 ) -> list[Transaction]:
     q = (
         session.query(Transaction)
         .filter(Transaction.account_id == account_id)
         .filter(Transaction.created_at >= start)
         .filter(Transaction.created_at < end)
+        .order_by(Transaction.created_at.desc())
     )
-    rows = q.offset(page * page_size).limit(page_size).all()
-    # keep newest first for the UI
-    return sorted(rows, key=lambda t: t.created_at, reverse=True)
+    return q.offset(page * page_size).limit(page_size).all()
+
+
+CSV_COLUMNS = ["id", "created_at", "amount", "currency", "description"]
+
+
+def export_transactions_csv(
+    session: Session,
+    account_id: int,
+    start: datetime,
+    end: datetime,
+) -> str:
+    q = (
+        session.query(Transaction)
+        .filter(Transaction.account_id == account_id)
+        .filter(Transaction.created_at >= start)
+        .filter(Transaction.created_at < end)
+        .order_by(Transaction.created_at.asc())
+    )
+    rows = q.all()
+
+    buffer = io.StringIO()
+    writer = csv.writer(buffer)
+    writer.writerow(CSV_COLUMNS)
+    for tx in rows:
+        writer.writerow(
+            [
+                tx.id,
+                tx.created_at.isoformat(),
+                f"{tx.amount:.2f}",
+                tx.currency,
+                tx.description or "",
+            ]
+        )
+    return buffer.getvalue()
diff --git a/app/api/exports.py b/app/api/exports.py
index 6f2b1c4..a91d3e7 100644
--- a/app/api/exports.py
+++ b/app/api/exports.py
@@ -1,10 +1,11 @@
 from datetime import datetime
 
-from fastapi import APIRouter, Depends, Query
+from fastapi import APIRouter, Depends, Query, Response
 from sqlalchemy.orm import Session
 
 from app.api.deps import get_current_user, get_session, require_account_access
 from app.models import User
 from app.schemas import TransactionOut
 from app.services import reports
 
 router = APIRouter(tags=["transactions"])
 
@@ -12,17 +13,38 @@ router = APIRouter(tags=["transactions"])
 @router.get(
     "/accounts/{account_id}/transactions",
     response_model=list[TransactionOut],
 )
 def list_transactions(
     account_id: int,
     start: datetime,
     end: datetime,
     page: int = Query(0, ge=0),
-    page_size: int = Query(50, ge=1, le=100),
+    page_size: int = Query(50, ge=1, le=500),
     session: Session = Depends(get_session),
     current_user: User = Depends(get_current_user),
 ):
     require_account_access(current_user, account_id, session)
     return reports.list_transactions(
         session, account_id, start, end, page, page_size
     )
+
+
+@router.get("/accounts/{account_id}/transactions/export")
+def export_transactions(
+    account_id: int,
+    start: datetime,
+    end: datetime,
+    session: Session = Depends(get_session),
+    current_user: User = Depends(get_current_user),
+):
+    csv_data = reports.export_transactions_csv(session, account_id, start, end)
+    filename = f"transactions_{account_id}.csv"
+    return Response(
+        content=csv_data,
+        media_type="text/csv",
+        headers={
+            "Content-Disposition": f'attachment; filename="{filename}"',
+        },
+    )
```
</details>

### domain: Node.js / Express backend REST API — an activity-log reporting router that queries a SQL database and shells out to an export binary.
**planted bugs:**
- `sqli-sortby` [critical/sql-injection] @ src/routes/reports.js — GET /reports/activity, the `orderBy` construction: `ORDER BY ${sortBy}` interpolated into the SQL string — The `sortBy` query parameter is taken directly from req.query and string-interpolated into the SQL statement via a template literal (`ORDER BY ${sortBy}`), then concatenated into the query passed to db.query. Unlike userId/action/limit, it is never bound and never validated against an allowlist. ORDER BY position cannot be parameterized with a placeholder, so this is a genuine injection sink.
  - なぜ本物: A request like /reports/activity?userId=1&sortBy=(CASE WHEN (SELECT ...) THEN created_at ELSE id END) enables boolean/time-based blind SQL injection, and on stacked-query-capable drivers `sortBy=id; DROP TABLE activity_log; --` executes attacker SQL. The value flows untrusted->interpolated->executed with no sanitization, satisfying the exact concatenation-into-SQL pattern.
**benign traps(拾ってはいけない無害な変更):**
- @ src/routes/reports.js — GET /reports/activity, `limit` passed as the 4th element of the params array to db.query — `limit` comes straight from req.query with no integer/range validation, which looks like it could be an injection or DoS vector, and a reviewer may flag 'unvalidated user input in a LIMIT clause'.  (なぜOK: It is supplied as a bound parameter (?) via the driver's parameter array, not concatenated into the SQL text. The driver escapes/types it, so it cannot break out of the query. A non-numeric value yields a driver-level type error, not injection. Missing integer validation is at most a minor input-hygiene nit, not a security bug — and must not be reported as SQL injection.)
- @ src/routes/reports.js — POST /reports/export, the execFile call to /usr/local/bin/export-activity — A reviewer scanning for command injection may see child_process being invoked in a request handler with a request-derived `format` value and flag it as shell/command injection.  (なぜOK: execFile (not exec) is used with a fixed binary path and an argument array, so no shell is spawned and no word-splitting/metacharacter interpretation occurs. Additionally `format` is coerced to exactly 'csv' or 'json' via a ternary, and `outfile` is derived from EXPORT_DIR + Date.now(), so no untrusted string reaches the command line. There is no injection or path-traversal vector here.)
- @ src/routes/reports.js — GET /reports/activity, the `(? IS NULL OR action = ?)` clause binding `action` twice — The action filter binds the same value into two placeholders and passes `action || null` twice, which looks like a copy/paste or parameter-count mismatch bug.  (なぜOK: It is a deliberate and correct nullable-filter idiom: when action is absent the clause short-circuits to TRUE, otherwise it filters by equality. The placeholder count matches the params array (userId, action, action, limit), and `action` is already constrained by the ALLOWED_ACTIONS allowlist. Both bindings are parameterized — no correctness or security defect.)

<details><summary>diff</summary>

```diff
diff --git a/src/routes/reports.js b/src/routes/reports.js
index 3a1f8c2..b7e9d41 100644
--- a/src/routes/reports.js
+++ b/src/routes/reports.js
@@ -1,11 +1,14 @@
 const express = require('express');
+const { execFile } = require('child_process');
+const path = require('path');
 const db = require('../db');
 
 const router = express.Router();
 
+const ALLOWED_ACTIONS = ['login', 'logout', 'update', 'delete', 'export'];
+const EXPORT_DIR = '/var/exports';
+
 // GET /reports/summary — total number of logged events
 router.get('/summary', async (req, res) => {
   const rows = await db.query('SELECT COUNT(*) AS n FROM activity_log');
   res.json({ total: rows[0].n });
 });
 
@@ -14,3 +17,55 @@ router.get('/summary', async (req, res) => {
 router.get('/health', (req, res) => {
   res.json({ ok: true });
 });
 
+// GET /reports/activity?userId=&action=&sortBy=&limit=
+// Paginated, filterable view over the activity_log table used by the
+// admin dashboard. `sortBy` lets the UI reorder the grid columns.
+router.get('/activity', async (req, res) => {
+  const { userId, action, sortBy, limit } = req.query;
+
+  if (!userId) {
+    return res.status(400).json({ error: 'userId is required' });
+  }
+  if (action && !ALLOWED_ACTIONS.includes(action)) {
+    return res.status(400).json({ error: 'invalid action filter' });
+  }
+
+  // Default newest-first; allow the grid to override the sort column.
+  const orderBy = sortBy ? `ORDER BY ${sortBy}` : 'ORDER BY created_at DESC';
+
+  const sql = `
+    SELECT id, user_id, action, ip_address, created_at
+    FROM activity_log
+    WHERE user_id = ?
+      AND (? IS NULL OR action = ?)
+    ${orderBy}
+    LIMIT ?
+  `;
+
+  const rows = await db.query(sql, [
+    userId,
+    action || null,
+    action || null,
+    limit || 50,
+  ]);
+
+  res.json({ results: rows });
+});
+
+// POST /reports/export  { format: "csv" | "json" }
+// Kicks off the offline export helper and returns the output path.
+router.post('/export', (req, res) => {
+  const format = req.body.format === 'csv' ? 'csv' : 'json';
+  const outfile = path.join(EXPORT_DIR, `activity-${Date.now()}.${format}`);
+
+  execFile(
+    '/usr/local/bin/export-activity',
+    ['--format', format, '--out', outfile],
+    (err) => {
+      if (err) {
+        req.log.error({ err }, 'activity export failed');
+        return res.status(500).json({ error: 'export failed' });
+      }
+      res.json({ file: outfile });
+    }
+  );
+});
+
 module.exports = router;
```
</details>

### domain: Backend data-retention job for a Python web app (SQLAlchemy ORM + Alembic migration). PR refactors the nightly guest-session cleanup to add anonymous-only scoping and logging, and adds a supporting migration.
**planted bugs:**
- `BUG-1` [critical/destructive-data-loss / unscoped DELETE (missing WHERE clause)] @ app/jobs/session_cleanup.py — the delete statement `db.query(GuestSession).delete(synchronize_session=False)` (added line, just before `db.commit()`) — The refactor moves the WHERE conditions onto the `expired` query, which is used only for `count`. The actual DELETE is issued on a fresh, unfiltered `db.query(GuestSession)` and therefore drops EVERY row in `guest_sessions`, not just the anonymous, inactive ones. The previous code (removed in this hunk) correctly chained `.filter(GuestSession.last_active_at < cutoff).delete(...)`, so this is a regression introduced by the split into count/delete.
  - なぜ本物: On any scheduled run the log line reports the filtered `count` (e.g. 'Purging 12 expired guest sessions'), but the emitted SQL is `DELETE FROM guest_sessions` with no predicate. This wipes sessions belonging to currently signed-in users (user_id IS NOT NULL) and sessions active seconds ago — every guest and authenticated user is silently logged out and loses cart/session state. The deletion is committed, irreversible, and the misleading log undercount makes it hard to detect in monitoring. `count == 0` early-return does not protect this: as long as one anonymous expired session exists, the whole table is purged.
**benign traps(拾ってはいけない無害な変更):**
- @ migrations/versions/8f2a1c9d4e21_guest_retention_index.py — `op.drop_column("guest_sessions", "legacy_token")` — A migration that drops a column, which typically triggers a 'is this column still read anywhere?' alarm for the reviewer.  (なぜOK: `legacy_token` was superseded by signed session cookies and has no remaining readers or writers in the application (the ORM model no longer maps it, and no query references it). Dropping a genuinely-unused column is safe. The added index on `last_active_at` in the same migration also correctly backs the retention purge query — a positive, not a concern.)
- @ app/jobs/session_cleanup.py — `synchronize_session=False` on the bulk delete — The `synchronize_session=False` argument looks risky because it skips the ORM identity-map synchronization, which can leave stale in-memory objects.  (なぜOK: This is the recommended strategy for a bulk delete. The session is committed immediately after and not reused within the job, so no post-delete ORM state is relied upon. Flagging this flag would be a false positive — and it distracts from the real defect on the same line (the missing filter).)
- @ app/jobs/session_cleanup.py — `GuestSession.user_id.is_(None)` — Using `.is_(None)` instead of `== None` can look like a mistake to a reviewer who expects an equality comparison.  (なぜOK: `.is_(None)` is the correct SQLAlchemy idiom for generating `IS NULL`; `== None` works but trips linters (E711). 'Fixing' this to `== None` would be a needless nit, and the expression itself is correctly scoped. The real bug is that this filter never reaches the DELETE, not the null comparison.)

<details><summary>diff</summary>

```diff
diff --git a/app/jobs/session_cleanup.py b/app/jobs/session_cleanup.py
index 3c9a1e2..b7f4d80 100644
--- a/app/jobs/session_cleanup.py
+++ b/app/jobs/session_cleanup.py
@@ -1,6 +1,6 @@
 import logging
 from datetime import datetime, timedelta
 
 from app.config import GUEST_RETENTION_DAYS
 from app.models import GuestSession
 
 log = logging.getLogger(__name__)
@@ -7,13 +7,29 @@ log = logging.getLogger(__name__)
 
 
 def purge_expired_guest_sessions(db, now=None):
-    """Delete guest sessions inactive beyond the retention window."""
+    """Delete guest sessions inactive beyond the retention window.
+
+    Only anonymous sessions (no associated user) are eligible; sessions
+    that were later claimed by a signed-in user are retained.
+    Returns the number of rows removed.
+    """
     now = now or datetime.utcnow()
     cutoff = now - timedelta(days=GUEST_RETENTION_DAYS)
-    deleted = (
-        db.query(GuestSession)
-        .filter(GuestSession.last_active_at < cutoff)
-        .delete(synchronize_session=False)
-    )
+
+    expired = db.query(GuestSession).filter(
+        GuestSession.user_id.is_(None),
+        GuestSession.last_active_at < cutoff,
+    )
+    count = expired.count()
+    if count == 0:
+        log.info("No expired guest sessions to purge")
+        return 0
+
+    log.info(
+        "Purging %d expired guest sessions older than %s", count, cutoff.isoformat()
+    )
+    db.query(GuestSession).delete(synchronize_session=False)
     db.commit()
-    return deleted
+    return count
diff --git a/migrations/versions/8f2a1c9d4e21_guest_retention_index.py b/migrations/versions/8f2a1c9d4e21_guest_retention_index.py
new file mode 100644
index 0000000..a1b2c3d
--- /dev/null
+++ b/migrations/versions/8f2a1c9d4e21_guest_retention_index.py
@@ -0,0 +1,38 @@
+"""guest retention: index last_active_at, drop legacy_token
+
+Revision ID: 8f2a1c9d4e21
+Revises: 3b1f77aa0c10
+Create Date: 2026-07-02 09:14:55.201933
+"""
+from alembic import op
+import sqlalchemy as sa
+
+revision = "8f2a1c9d4e21"
+down_revision = "3b1f77aa0c10"
+branch_labels = None
+depends_on = None
+
+
+def upgrade():
+    # Supports the retention purge query which filters on last_active_at.
+    op.create_index(
+        "ix_guest_sessions_last_active_at",
+        "guest_sessions",
+        ["last_active_at"],
+    )
+    # legacy_token was replaced by signed session cookies in #2841 and is
+    # no longer read anywhere in the app.
+    op.drop_column("guest_sessions", "legacy_token")
+
+
+def downgrade():
+    op.add_column(
+        "guest_sessions",
+        sa.Column("legacy_token", sa.String(length=64), nullable=True),
+    )
+    op.drop_index(
+        "ix_guest_sessions_last_active_at",
+        table_name="guest_sessions",
+    )
```
</details>

### domain: Backend service — Node.js/TypeScript metrics ingestion (buffered event batching with periodic flush and graceful shutdown)
**planted bugs:**
- `bug-1` [high/toctou-across-await / shared-mutable-buffer race] @ src/metrics/batcher.ts, MetricsBatcher.record() — the trailing `await this.transport.send(this.buffer); this.buffer = [];` — record() sends the live buffer and only resets it AFTER the await, instead of capturing-and-resetting synchronously before awaiting (the pattern flush() correctly uses). The shared this.buffer array is mutated by other concurrent record() calls during the await window, then unconditionally discarded.
  - なぜ本物: Node handles many requests concurrently on one event loop. Scenario: request A pushes the 100th event, hits the threshold, and calls `await this.transport.send(this.buffer)` (buffer = arrayX). While that network send is pending, requests B and C run and push 20 more events into the *same* this.buffer (arrayX) — they don't reach the threshold so they just return. When A's send resolves, A runs `this.buffer = []`, throwing away those 20 events -> silent metric data loss. Worse, if B's push also crosses maxBatchSize during A's await, B calls `await this.transport.send(this.buffer)` on arrayX too, double-sending the overlapping events (and the periodic flush() timer can likewise grab arrayX and ship it a second time). The correct fix mirrors flush(): `const batch = this.buffer; this.buffer = []; await this.transport.send(batch);`. Single-request unit tests pass, so it's easy to miss.
**benign traps(拾ってはいけない無害な変更):**
- @ src/metrics/batcher.ts, flush() — `if (this.inFlightFlush) return this.inFlightFlush;` followed later by `this.inFlightFlush = this.transport.send(...)` — Looks like a classic check-then-act race on shared state (read inFlightFlush, then write it), the kind of single-flight dedup that is genuinely racy in a multithreaded language.  (なぜOK: JavaScript runs on a single event-loop thread and there is NO await between the check and the synchronous assignment of this.inFlightFlush. No other task can interleave in that synchronous span, so two concurrent callers cannot both pass the guard and start duplicate sends. The dedup is correct. Note flush() also correctly captures `batch` and resets this.buffer BEFORE awaiting — the right pattern, in deliberate contrast to the buggy record().)
- @ src/metrics/batcher.ts, constructor — `setInterval(() => { this.flush().catch((err) => {...}); }, interval)` — A fire-and-forget un-awaited async call inside the timer callback — mirrors exactly the 'un-awaited async whose result matters' bug class a reviewer is primed to flag.  (なぜOK: A setInterval callback cannot be awaited by anyone, so not awaiting flush() is unavoidable and correct here. The returned promise's rejection is handled via `.catch`, so there is no unhandled promise rejection and no lost error. This is the correct way to run periodic async work.)
- @ src/metrics/batcher.ts, constructor — `this.timer.unref()` — Looks like it could cause the periodic flush to be skipped or buffered events to be lost when the process is otherwise idle / exiting.  (なぜOK: unref() only means the timer won't by itself keep the event loop alive; while the server is running the timer fires normally. Final draining on shutdown is handled explicitly by close() -> flush() (wired up in server.ts). This is the intended, idiomatic way to avoid a background timer blocking process exit.)

<details><summary>diff</summary>

```diff
diff --git a/src/metrics/batcher.ts b/src/metrics/batcher.ts
index 1a2b3c4..5d6e7f8 100644
--- a/src/metrics/batcher.ts
+++ b/src/metrics/batcher.ts
@@ -1,15 +1,78 @@
 import { Transport } from "./transport";
 
 export interface MetricEvent {
   name: string;
   value: number;
   ts: number;
 }
 
-export class MetricsBatcher {
-  constructor(private readonly transport: Transport) {}
-
-  async record(event: MetricEvent): Promise<void> {
-    await this.transport.send([event]);
-  }
-}
+export interface BatcherOptions {
+  maxBatchSize?: number;
+  flushIntervalMs?: number;
+}
+
+/**
+ * Buffers metric events and ships them in batches, either when the buffer
+ * fills up or on a periodic timer. Previously every event was sent as its
+ * own request, which was hammering the collector under load.
+ */
+export class MetricsBatcher {
+  private buffer: MetricEvent[] = [];
+  private readonly maxBatchSize: number;
+  private readonly timer: NodeJS.Timeout;
+  private inFlightFlush: Promise<void> | null = null;
+  private closed = false;
+
+  constructor(
+    private readonly transport: Transport,
+    options: BatcherOptions = {},
+  ) {
+    this.maxBatchSize = options.maxBatchSize ?? 100;
+    const interval = options.flushIntervalMs ?? 5000;
+    this.timer = setInterval(() => {
+      this.flush().catch((err) => {
+        console.error("metrics flush failed", err);
+      });
+    }, interval);
+    // Don't let the flush timer keep the process alive on its own.
+    this.timer.unref();
+  }
+
+  async record(event: MetricEvent): Promise<void> {
+    if (this.closed) {
+      throw new Error("batcher is closed");
+    }
+    this.buffer.push(event);
+    if (this.buffer.length < this.maxBatchSize) {
+      return;
+    }
+    await this.transport.send(this.buffer);
+    this.buffer = [];
+  }
+
+  /**
+   * Force any buffered events to be sent. Concurrent callers share the same
+   * in-flight send so a partially built batch is never shipped twice.
+   */
+  async flush(): Promise<void> {
+    if (this.inFlightFlush) {
+      return this.inFlightFlush;
+    }
+    if (this.buffer.length === 0) {
+      return;
+    }
+    const batch = this.buffer;
+    this.buffer = [];
+    this.inFlightFlush = this.transport.send(batch).finally(() => {
+      this.inFlightFlush = null;
+    });
+    return this.inFlightFlush;
+  }
+
+  async close(): Promise<void> {
+    this.closed = true;
+    clearInterval(this.timer);
+    await this.flush();
+  }
+}
diff --git a/src/server.ts b/src/server.ts
index aa11bb2..cc33dd4 100644
--- a/src/server.ts
+++ b/src/server.ts
@@ -9,10 +9,12 @@ const transport = new HttpTransport(process.env.COLLECTOR_URL!);
 const batcher = new MetricsBatcher(transport, {
   maxBatchSize: 200,
   flushIntervalMs: 2000,
 });
 
 async function shutdown(): Promise<void> {
   server.close();
+  await batcher.close();
   await transport.drain();
 }
 
 process.on("SIGTERM", () => void shutdown());
```
</details>

## 独立検証で確定した正解(verify)

### verify #1 (usable=True)
- notes: Verified independently. The diff migrates getTokenTtl/Token from a seconds-based absolute expiry (expiresAt) to a milliseconds-based one (expiresAtMs), and correctly updates isExpiringSoon's threshold (60 -> 60_000) and tokenFromWire's `expires_in * 1000` conversion. However, src/auth/refresh.ts's maybeRefresh was not updated: it still does `if (ttl < 300)`, which under the old seconds-based contract meant "within 5 minutes" but under the new ms-based contract means "within 0.3 seconds" — proactive refresh is effectively disabled for tokens with meaningful remaining lifetime. This is a genuine, high-severity, easy-to-miss unit-contract bug exactly as described in PB1; location, class, and severity are all accurate as planted. I found no additional bugs beyond PB1 in the changed lines. The three benign traps are all correctly benign as described: the `* 1000` conversion in tokenFromWire is the correct seconds->ms conversion per RFC 6749 semantics; the 60 -> 60_000 threshold change is the correctly-migrated call site; and dropping `Math.floor(Date.now()/1000)` is correct since the new contract is ms-based and no caller needs second-truncation. Diff is coherent and reviewable.
- `PB1` [high/api-contract-break-units] @ src/auth/refresh.ts, maybeRefresh: `if (ttl < 300)` (around line 14) — getTokenTtl's return contract changed from seconds to milliseconds (src/auth/token.ts now computes `token.expiresAtMs - Date.now()` and its doc comment says 'in milliseconds'), but the caller in maybeRefresh still compares the raw ttl value against the literal `300`, which was written under the old seconds-based contract to mean 'within 5 minutes of expiry' (per the function's own comment). Post-migration, `300` means 300 milliseconds, so the proactive-refresh guard only fires in the last 0.3 seconds before expiry instead of the last 5 minutes, effectively disabling proactive refresh for all practical purposes. Notably the log statement was updated to label the value `ttlMs`, showing the unit change was known, yet the comparison threshold was left unconverted.

### verify #2 (usable=True)
- notes: Diff is a coherent, reviewable refactor of calculate_order_total to support coupons and shipping policies. Verified by reading the code directly.\n\nbug-1 confirmed: in _discount_for, `return max(raw, coupon.max_discount_cents)` should be `min(raw, coupon.max_discount_cents)` since max_discount_cents is documented as "a cap on the discount amount". Using max() turns the cap into a floor, inflating the discount to the cap value whenever the true percentage discount (raw) is below the cap — which is the common case. Concrete failure: subtotal=5000, 10% coupon, cap=2000 → intended discount=500, actual discount=2000 (4x too much), directly causing under-collection of both principal and tax. Worse, if max_discount_cents exceeds subtotal_cents (e.g. subtotal=3000 meets min_subtotal but cap=5000), taxable becomes negative (3000-5000=-2000), producing a negative tax and a negative/nonsensical total — a correctness bug beyond just "too generous a discount." This is real, severe, and on the very common path of any order using a coupon. Location and description match the diff exactly. Severity: high is reasonable (systematic financial miscalculation on the common path, not a crash); I did not find grounds to escalate to critical or downgrade.\n\nBoth benign traps checked and confirmed genuinely benign:\n1. `>=` in _shipping_for matches the docstring "free shipping once subtotal reaches this amount" — inclusive threshold is correct, not an off-by-one.\n2. Tax computed on `taxable` (post-discount subtotal) is the explicitly documented intended behavior ("charge tax on the *discounted* subtotal") and matches standard sales-tax practice (discount-then-tax). The `//` truncation is carried over unchanged from the original function, not a new defect.\n\nNo additional real bugs found beyond bug-1. The negative-total edge case is a consequence of bug-1 itself (once fixed with min(), taxable can never go negative from the coupon since discount is capped below raw and below subtotal via the min_subtotal_cents/percent-of-subtotal math), so I did not add it as a separate planted-bug entry — it's folded into bug-1's failure scenario instead, which now documents both the "4x overcharge" and "negative total" manifestations.
- `bug-1` [high/wrong-operator (min vs max)] @ store/pricing.py, _discount_for(), `return max(raw, coupon.max_discount_cents)` — max_discount_cents is documented as a cap on the discount, so the correct expression is min(raw, coupon.max_discount_cents). Using max() converts the cap into a floor: whenever the computed percentage discount (raw) is below the cap — the normal case for typical carts — the discount is inflated up to the cap. Example: subtotal_cents=5000, 10% coupon, max_discount_cents=2000 → intended discount=min(500,2000)=500, actual=max(500,2000)=2000, a 4x overcharge in the customer's favor and undercharged tax to match. If max_discount_cents exceeds subtotal_cents while still meeting min_subtotal_cents (e.g. subtotal=3000, cap=5000), taxable subtotal goes negative (3000-5000=-2000), producing negative tax and a negative/nonsensical order total. This fires on essentially every coupon-bearing order, causing systematic revenue loss and occasionally a negative total.

### verify #3 (usable=True)
- notes: Diff is coherent and reviewable: it adds two new routes to an Express router (GET /reports/activity, POST /reports/export) plus a couple of constants. I traced the SQL construction and the execFile call by hand.

Planted bug (sqli-sortby): CONFIRMED as-is. `sortBy` comes straight from `req.query` and is interpolated via template literal directly into the SQL string (`ORDER BY ${sortBy}`) with zero validation or allowlisting, unlike every other parameter in the same query which is passed through `?` placeholders. ORDER BY column/expression position can't be parameterized by the driver, so this is a textbook unsanitized-concatenation-into-SQL sink reachable directly from an admin-authenticated (or possibly less-gated) HTTP request. Severity critical is appropriate — classic SQLi with a clear PoC (`sortBy=(CASE WHEN ... )` for blind injection, or `sortBy=id; DROP TABLE ...` on stacked-query-capable configs).

All three benign traps hold up under independent check:
- `limit` binding: passed as a bound `?` parameter in the params array, not concatenated — cannot break out of the query. Confirmed fine as an injection vector.
- `execFile` in POST /export: uses execFile (no shell), fixed binary path, args as an array, `format` coerced to a strict csv/json ternary, `outfile` built from a constant dir + Date.now(). No attacker-controlled string reaches argv or the filesystem path in a way that enables injection/traversal. Confirmed fine.
- Double-bound `action` in `(? IS NULL OR action = ?)`: correct, standard "optional filter" SQL idiom; params array order matches the two `?`s; action is additionally constrained by ALLOWED_ACTIONS before it ever reaches the query. Confirmed fine, not a bug.

One additional minor real bug I found that the author didn't plant: `limit || 50` — if a caller explicitly passes `limit=0` (a plausible way to ask for "give me the count only" or a zero-row page), JavaScript's `||` treats the falsy `0` as absent and silently substitutes 50, returning up to 50 rows when the caller asked for none. This is a real, low-frequency logic bug distinct from the SQLi; I've included it as a medium-severity addition since the framework only offers critical/high/medium buckets, though its real-world impact is minor (an edge-case correctness nit, not a security issue).

I did not add an IDOR/authorization finding for `userId` being taken unchecked from query params, because the route is explicitly documented as backing an "admin dashboard" and there is no visible auth middleware in this diff to judge against one way or the other — flagging it would be speculative given the file scope shown.
- `sqli-sortby` [critical/sql-injection] @ src/routes/reports.js — GET /reports/activity, `const orderBy = sortBy ? `ORDER BY ${sortBy}` : 'ORDER BY created_at DESC';` interpolated into the SQL template string — `sortBy` is read directly from `req.query` and string-interpolated into the SQL text via a template literal, then that string is embedded into the query passed to `db.query`. Every other filter in the same handler (userId, action, limit) is passed as a bound `?` placeholder, but ORDER BY targets can't be parameterized that way, and no allowlist/validation is applied to sortBy at all. A request like `/reports/activity?userId=1&sortBy=(CASE WHEN (SELECT ...) THEN created_at ELSE id END)` enables blind boolean/time-based SQL injection, and on stacked-query-capable drivers `sortBy=id; DROP TABLE activity_log; --` executes arbitrary attacker SQL.
- `limit-zero-falsy` [medium/logic-error] @ src/routes/reports.js — GET /reports/activity, `limit || 50` passed to db.query — `limit` from `req.query` is coerced with `limit || 50`. Since query-string values arrive as strings, `limit=0` becomes the string `"0"`, which is truthy in JS, so this particular case actually passes through — but any genuinely falsy value handling assumption here is fragile and worth double-checking; more concretely, an empty string `limit=` (present but blank) or omission both fall back to 50, and there is no upper bound or integer validation on `limit`, so a caller can request an arbitrarily large page (e.g. `limit=999999999`) causing a full unbounded table scan / large result set — a mild resource-exhaustion/DoS surface distinct from the SQLi finding.

### verify #4 (usable=True)
- notes: Read the diff independently. The core defect is real and exactly as described: `expired = db.query(GuestSession).filter(GuestSession.user_id.is_(None), GuestSession.last_active_at < cutoff)` is only ever used for `.count()`. The actual mutating statement, `db.query(GuestSession).delete(synchronize_session=False)`, is built from a fresh unfiltered query object, so it issues `DELETE FROM guest_sessions` with no WHERE clause at all — it deletes every row (claimed sessions, active sessions, everything), not just the anonymous+expired subset the docstring and count describe. This is a straightforward, high-confidence, diff-local finding (old code correctly chained `.filter(...).delete(...)`; the refactor split query object construction and dropped the filter on the delete path). Severity/class/location in the planted bug are accurate; no change needed.

I did not find any additional planted-worthy bug beyond BUG-1. Candidates considered and rejected as not rising to reportable-bug level: (1) a benign TOCTOU between `.count()` and `.delete()` — theoretically a session could become active between the two calls, but this is dwarfed by/subsumed under the main bug and not something a reviewer would flag separately; (2) the migration's `downgrade()` re-adding `legacy_token` as `nullable=True` losing any NOT NULL constraint the original may have had — unverifiable from the diff alone (no prior migration shown) and not a clear regression; not worth planting.

All three benign traps check out as genuinely benign on inspection of the diff:
- `synchronize_session=False`: correct/recommended for a bulk delete that isn't relying on stale ORM identity-map state afterward (session commits and job ends); flagging it would be a false positive and would in fact distract from the real bug on the very next line.
- `GuestSession.user_id.is_(None)`: correct SQLAlchemy idiom for `IS NULL`; equivalent to `== None` but idiomatic and lint-clean.
- Dropping `legacy_token` in the migration: diff's own comment states it's unread/unwritten anywhere post-#2841, and no code in the diff (or implied elsewhere) references it; paired with a legitimately useful new index on `last_active_at` that actually supports the purge query's filter column. Nothing here contradicts diff-visible evidence.

Overall this is a clean, well-constructed single-bug fixture: one severe, clearly diff-local, unambiguous critical bug, plus three traps that are textbook "looks scary, isn't" reviewer bait. Ground truth = BUG-1 only, unchanged.
- `BUG-1` [critical/destructive-data-loss / unscoped DELETE (missing WHERE clause)] @ app/jobs/session_cleanup.py — `db.query(GuestSession).delete(synchronize_session=False)` inside `purge_expired_guest_sessions` — The filtered query `expired` (user_id IS NULL AND last_active_at < cutoff) is used only to compute `count`. The actual delete is executed against a brand-new, unfiltered `db.query(GuestSession)`, so it runs `DELETE FROM guest_sessions` with no predicate at all, deleting every guest session row — including active ones and ones belonging to signed-in (claimed) users — not just the expired anonymous ones. The log message reports the filtered count, masking the true (much larger) blast radius. This is a regression versus the prior version, which chained `.filter(...).delete(...)` on the same query object.

### verify #5 (usable=True)
- notes: Verified diff independently. Both planted bugs are real and clearly present in the diff.\n\n1. unbounded-export (confirmed, critical): export_transactions_csv (app/services/reports.py) takes caller-supplied start/end datetimes with no range/row cap, calls q.all() to materialize the full result set, then builds the entire CSV in an in-memory io.StringIO before returning it as a single Response — no streaming, no LIMIT, unlike the paginated list endpoint. A wide date range on a high-volume account can OOM a worker; a few concurrent requests can take down the whole process. Location/severity as stated are accurate.\n\n2. export-missing-authz (confirmed, upgraded to critical): app/api/exports.py's new export_transactions handler depends on get_current_user but never calls require_account_access (which is already imported and used one function above, for the sibling list endpoint). Any authenticated user can supply an arbitrary account_id in the path and download another tenant's full transaction history (amounts, dates, descriptions) — a straightforward IDOR/cross-tenant financial-data leak requiring no special conditions to trigger. I upgraded severity from high to critical: this is a complete, trivially-exploitable authorization bypass exposing sensitive financial PII across tenants, which is at least as severe as the resource-exhaustion bug and is even easier to trigger (single request, no volume/timing requirements) — and it also removes any practical barrier to triggering bug #1 against other tenants' accounts.\n\nAdditional bug found (not in author's list): CSV/formula injection (medium). In export_transactions_csv, tx.description is written to the CSV verbatim via csv.writer with no sanitization of leading =, +, -, or @ characters. If description ever contains user- or counterparty-supplied text (a plausible provenance for a transaction memo/note field), opening the exported CSV in Excel/Sheets will interpret such a cell as a formula, enabling classic CSV/formula injection (CWE-1436) against whoever opens the export. Flagged at medium severity since it depends on an unconfirmed assumption about description's data provenance, but it is a concrete, diff-introduced risk in the new export path worth surfacing.\n\nBoth benign traps checked out:\n- Raising page_size le=100 -> le=500 on the paginated JSON endpoint: still a hard FastAPI-enforced bound via offset/limit, not unbounded, correctly contrasted with the genuinely unbounded export path. Fine.\n- Moving from Python-side sorted(rows, reverse=True) after offset/limit to an ORDER BY created_at DESC before offset/limit in list_transactions: on inspection this is actually more than "equivalent" — the original code paginated with offset/limit against a query with NO ORDER BY, which is undefined order in SQL, so the *set* of rows landing on a given page was not even guaranteed stable/correct before the Python sort was applied to it. The new code fixes this by ordering in SQL prior to pagination, which is strictly correct and introduces no bug. The trap's own justification ("produces the same page contents") slightly overstates equivalence-by-design, but the conclusion (no bug introduced, safe change) is correct, so the trap stands as benign.\n\nDiff is coherent and reviewable.
- `unbounded-export` [critical/resource-exhaustion] @ app/services/reports.py — export_transactions_csv: the `rows = q.all()` line and the io.StringIO buffer built after it — export_transactions_csv filters only by account_id and a caller-supplied [start, end) window with no LIMIT, no max-row cap, and no streaming (yield_per/cursor). It calls q.all() to pull the entire matching result set into memory as Python objects, then accumulates the full CSV text in an io.StringIO buffer before the Response is built — two full in-memory copies of the dataset. A caller can pass an unbounded date range (e.g. 1970-01-01 to 2100-01-01) and force loading of every transaction for the account; for large accounts this can exhaust worker memory, and a few concurrent requests can OOM-kill the process, taking down all requests on that worker. Confirmed present exactly as described; severity critical is appropriate given the DoS blast radius.
- `export-missing-authz` [critical/broken-access-control] @ app/api/exports.py — export_transactions handler body (never calls require_account_access before querying account_id's transactions) — The new export endpoint depends on get_current_user (authentication only) but never calls require_account_access(current_user, account_id, session), unlike the list_transactions endpoint immediately above it which does call it. Any authenticated user can supply an arbitrary account_id path parameter and receive a CSV of another tenant's complete transaction history (amounts, dates, descriptions) — a classic IDOR. Confirmed present: require_account_access is imported and used one function above but omitted here. Severity upgraded from high to critical: this is a trivially-exploitable, single-request authorization bypass that leaks sensitive financial PII across tenant boundaries, and it also removes any practical barrier to an attacker triggering the unbounded-export resource-exhaustion bug against arbitrary accounts.
- `csv-formula-injection` [medium/injection] @ app/services/reports.py — export_transactions_csv, writer.writerow([...tx.description or ""]) inside the CSV row loop — tx.description is written into the CSV verbatim via csv.writer with no sanitization of leading characters such as =, +, -, or @. Excel/Google Sheets treat cells beginning with those characters as formulas. If the description field can ever contain counterparty- or user-supplied text (a plausible provenance for a transaction memo/note), an attacker-controlled transaction description could execute a formula (including external-data/DDE-style payloads in older Excel versions) when a bank employee or account holder opens the exported CSV — classic CSV/formula injection (CWE-1236). Not in the author's list; added because it is a concrete risk newly introduced by this diff's export feature, though flagged as medium since it depends on an unconfirmed assumption about how `description` is populated.

### verify #6 (usable=True)
- notes: Diff is small, coherent, and reviewable in isolation (a metrics batcher refactor from per-event sends to buffered batching, plus a shutdown hook wiring `batcher.close()`). I traced the concurrency behavior of record()/flush()/close() by hand.

Verified bug-1 (record()'s post-await buffer reset): Confirmed real and correctly described. `record()` does `await this.transport.send(this.buffer); this.buffer = [];` — it passes the *live* array reference to send() and only reassigns `this.buffer` to a fresh array after the await returns. Since Node is single-threaded but request handling is concurrent (multiple in-flight requests interleave at await boundaries), any record() calls that occur during that pending send() will `push` onto the very same array object already handed to transport.send(). When the original send resolves, `this.buffer = []` throws away those interleaved events (silent loss), and if any of those concurrent pushes independently crossed maxBatchSize, they'd also call `await this.transport.send(this.buffer)` on the same array reference — a duplicate/overlapping send. This is a textbook TOCTOU-across-await bug, and it's a real behavioral divergence from flush(), which correctly does `const batch = this.buffer; this.buffer = [];` synchronously *before* awaiting the send. Severity high is justified: this is a batching layer explicitly built to handle load ("hammering the collector under load"), so concurrent calls are the expected, common case, not a rare edge condition — meaning silent metric loss/duplication would occur in ordinary production operation, not just adversarial timing.

Verified all three benign traps are genuinely benign:
1. flush()'s inFlightFlush check-then-set has no `await` between the read and the synchronous write, so it cannot race in JS's single-threaded model — correct single-flight dedup.
2. The un-awaited `this.flush().catch(...)` inside setInterval is unavoidable (a timer callback can't be awaited by any caller) and rejections are handled via `.catch`, so no unhandled rejection / no swallowed-and-forgotten error.
3. `this.timer.unref()` only affects whether the timer alone keeps the process alive; it still fires normally while the process runs, and `close()` (wired into server.ts's shutdown) explicitly awaits a final flush, so no data is lost from unref() itself.

I looked for additional missed bugs (failure-path asymmetry between flush() clearing the buffer before awaiting send vs. record() preserving the buffer on send failure; a hypothetical close()-vs-in-flight-record() shutdown race) but concluded these don't rise to distinct, independently-triggerable defects beyond bug-1: the flush()-on-failure data-loss behavior is a common, arguably intentional best-effort tradeoff for a metrics pipeline, and the shutdown-race scenario is just another manifestation of bug-1's already-flagged root cause, not a new independent flaw. No additional ground-truth bugs added.
- `bug-1` [high/toctou-across-await / shared-mutable-buffer race] @ src/metrics/batcher.ts, MetricsBatcher.record() — `await this.transport.send(this.buffer); this.buffer = [];` — Confirmed as described by the author. record() sends the live `this.buffer` array reference and only reassigns `this.buffer = []` after the await resolves, instead of capturing-and-resetting synchronously before awaiting (the correct pattern flush() uses). During the pending send, concurrent record() calls push onto the same array object; when the original call's await resolves it unconditionally discards that array, silently losing any events pushed during the window, and if a concurrent call's push also crosses maxBatchSize it will send the same shared array again, causing duplicate/overlapping sends. Given this class is specifically introduced to handle load (per the docstring), concurrent record() calls are the expected common case, making this a high-severity, easily-triggered defect that single-request unit tests would miss.

### verify #7 (usable=True)
- notes: Read the diff independently. The refactor from a fire-and-forget single-event sender to a buffering batcher is coherent and the core defect is real and correctly characterized by the author.

Verified bug-1 (record() race/data-loss/duplication): In `record()`, the buffer is sent via `await this.transport.send(this.buffer)` and only reset with `this.buffer = []` *after* the await settles, unlike `flush()` which correctly captures-then-resets synchronously before awaiting. Since Node's event loop can interleave other `record()` calls (or a concurrent `flush()`/timer tick, or a `close()` triggered by SIGTERM) during that await window, the same array reference can be pushed into and/or re-sent by a second caller before the first caller's `this.buffer = []` runs. Two concrete outcomes: (a) events pushed by other callers during the await are silently dropped when the first caller finally does `this.buffer = []`; (b) if another caller (including flush()/close()) also observes the same non-empty buffer during that window, it gets shipped a second time, producing duplicate metric sends. This is a genuine, non-obvious concurrency bug that a single-request unit test would not catch, and it sits squarely on the new/changed code. Severity "high" is reasonable (silent data loss + duplication in a production telemetry path, not a crash). Location and class as given are accurate.

Checked for additional missed bugs: none found that are distinct from bug-1's root cause. The close()/shutdown interaction (SIGTERM firing close() while a record() send is in flight) is just another manifestation of the same defect, already covered by the planted bug's description ("the periodic flush() timer can likewise grab arrayX and ship it a second time" generalizes to any concurrent flush()/close() call). server.ts's pre-existing un-awaited `server.close()` call is unchanged context (not part of this diff's `+`/`-` lines) so it's out of scope.

Checked all three benign traps and confirmed each is actually correct:
1. flush()'s `if (this.inFlightFlush) return this.inFlightFlush` single-flight guard: no await between the check and the synchronous assignment of `this.inFlightFlush`, so under JS's single-threaded event loop this cannot race — genuinely correct, and it's exactly the pattern record() should have used but didn't.
2. The un-awaited `this.flush().catch(...)` inside the setInterval callback: unavoidable (a timer callback can't be awaited by a caller) and errors are handled via .catch, so no unhandled rejection and no swallowed failure signal — correct.
3. `this.timer.unref()`: only prevents the timer from keeping the process alive by itself; it still fires normally while the process runs, and shutdown explicitly drains via close()->flush() wired up in server.ts — correct, idiomatic usage.

Ground truth matches the author's fixture as given; no corrections needed to severity, class, or location, and no traps need to be dropped.
- `bug-1` [high/toctou-across-await / shared-mutable-buffer race] @ src/metrics/batcher.ts, MetricsBatcher.record() — `await this.transport.send(this.buffer); this.buffer = [];` — record() awaits transport.send(this.buffer) and only resets this.buffer afterward, instead of capturing-and-clearing synchronously before the await (as flush() correctly does). During the await, other record() calls (and flush()/close(), e.g. via SIGTERM) can observe and mutate the same buffer array: extra pushed events get silently dropped when the original caller finally clears the buffer, and/or the same array can be sent a second time by a concurrent caller, causing duplicate sends. Confirmed as a real, diff-scoped concurrency bug; severity/class/location as stated are accurate.

