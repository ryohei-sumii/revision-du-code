# Round 2 — テストフィクスチャ(仕込みバグ差分)/ Fixtures

Opus が作成し Sonnet が独立検証した「バグ入り差分＋無害トラップ」。**評価の正解データ**です。

## 作成されたフィクスチャ(author)

### domain: API gateway / HTTP middleware — per-tenant request rate limiting for a Go web service  (Go)
**planted bugs:**
- `bug-1` [critical/race] @ internal/ratelimit/ratelimit.go, Allow(): the line `t.limiters[tenantID] = lim` inside the `if !ok` block (added ~line 40) — Allow() takes only a read lock (t.mu.RLock / defer RUnlock) but then MUTATES the shared map on the cold-miss path: `t.limiters[tenantID] = lim`. sync.RWMutex permits many goroutines to hold the read lock simultaneously, so concurrent first-requests execute the map assignment with no mutual exclusion.
  - なぜ本物: Two goroutines both call Allow for tenants not yet in the map (e.g. two concurrent first requests, whether for the same new tenant or two different new tenants). Both acquire RLock concurrently, both see ok==false, and both perform a map write at the same instant. The Go runtime's built-in concurrent-map-access detector fires `fatal error: concurrent map writes`, which is NOT a recoverable panic — it terminates the entire process, dropping every in-flight connection. Because tenant buckets are created lazily, this triggers precisely during traffic ramp-up / cold start when many new tenants appear at once — the worst possible time. Correct code must take the write lock (Lock) around the create-and-store, typically with a double-check after upgrading.
**benign traps(誤検出を誘う無害な変更・拾ってはいけない):**
- @ internal/ratelimit/ratelimit.go, SetRate() (added ~lines 52-60) — SetRate reassigns the entire map with `t.limiters = make(map[string]*rate.Limiter)`, throwing away every existing tenant bucket while other goroutines are actively reading the map in Allow.  (なぜOK: SetRate holds the exclusive write lock (t.mu.Lock / defer Unlock) for the whole operation, and every reader in Allow accesses the map under t.mu.RLock. RWMutex guarantees Lock cannot overlap any RLock, so the map swap is fully serialized against readers — no data race. Dropping the buckets is the documented, intentional behavior (new rate takes effect immediately); the transient reset of token counts is a deliberate design tradeoff, not a correctness bug. A hasty reviewer may flag 'replacing a shared map used by concurrent readers,' but it is correct here.)
- @ internal/ratelimit/ratelimit.go, Middleware() (added ~line 66): `w.Header().Set("Retry-After", "1")` immediately before `http.Error(...)` — Setting a response header right before calling http.Error, which writes the status line and body — looks like the header is set 'too late' and will be silently dropped.  (なぜOK: http.Error internally calls w.WriteHeader(code) only when it runs; headers added to w.Header() BEFORE the first WriteHeader/Write are flushed as part of the response. Since the Set precedes http.Error, Retry-After is correctly emitted on the 429 response. The ordering is valid Go net/http usage; a reviewer who claims 'headers after http.Error don't work' is misreading the sequence.)

<details><summary>diff</summary>

```diff
diff --git a/internal/ratelimit/ratelimit.go b/internal/ratelimit/ratelimit.go
index 5c1a9f0..b2e7d34 100644
--- a/internal/ratelimit/ratelimit.go
+++ b/internal/ratelimit/ratelimit.go
@@ -1,38 +1,74 @@
 package ratelimit
 
 import (
 	"net/http"
+	"sync"
 
 	"golang.org/x/time/rate"
 )
 
-// Limiter enforces a single global request rate shared across all callers.
-type Limiter struct {
-	lim *rate.Limiter
+// TenantLimiter enforces a per-tenant request rate. Each tenant is given its
+// own token bucket, created lazily on the tenant's first request so we don't
+// have to know the full tenant set up front.
+type TenantLimiter struct {
+	mu       sync.RWMutex
+	limiters map[string]*rate.Limiter
+	rps      rate.Limit
+	burst    int
 }
 
-func New(rps rate.Limit, burst int) *Limiter {
-	return &Limiter{lim: rate.NewLimiter(rps, burst)}
+func New(rps rate.Limit, burst int) *TenantLimiter {
+	return &TenantLimiter{
+		limiters: make(map[string]*rate.Limiter),
+		rps:      rps,
+		burst:    burst,
+	}
 }
 
-func (l *Limiter) Allow() bool {
-	return l.lim.Allow()
+// Allow reports whether a request from the given tenant may proceed. The
+// tenant's bucket is created on first use.
+func (t *TenantLimiter) Allow(tenantID string) bool {
+	t.mu.RLock()
+	defer t.mu.RUnlock()
+
+	lim, ok := t.limiters[tenantID]
+	if !ok {
+		lim = rate.NewLimiter(t.rps, t.burst)
+		t.limiters[tenantID] = lim
+	}
+	return lim.Allow()
 }
 
-// Middleware rejects requests that exceed the configured global rate.
-func (l *Limiter) Middleware(next http.Handler) http.Handler {
+// SetRate updates the limit applied to newly created tenant buckets. Existing
+// buckets are dropped so the new rate takes effect on the next request rather
+// than waiting for old buckets to refill.
+func (t *TenantLimiter) SetRate(rps rate.Limit, burst int) {
+	t.mu.Lock()
+	defer t.mu.Unlock()
+
+	t.rps = rps
+	t.burst = burst
+	t.limiters = make(map[string]*rate.Limiter)
+}
+
+// Middleware rejects requests from tenants that exceed their configured rate.
+func (t *TenantLimiter) Middleware(next http.Handler) http.Handler {
 	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
-		if !l.Allow() {
+		tenant := r.Header.Get("X-Tenant-ID")
+		if tenant == "" {
+			tenant = "anonymous"
+		}
+		if !t.Allow(tenant) {
+			w.Header().Set("Retry-After", "1")
 			http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
 			return
 		}
 		next.ServeHTTP(w, r)
 	})
 }
```
</details>

### domain: Backend data-retention batch job (audit-log purge) with an Alembic schema migration and APScheduler registration  (Python (SQLAlchemy Core + Alembic))
**planted bugs:**
- `BUG-1` [critical/data-loss] @ app/jobs/audit_retention.py, the DELETE statement (added line: "OR legal_hold = false", ~line +38) — The DELETE's WHERE clause mixes AND and OR without parentheses: "WHERE org_id = :org_id AND created_at < :cutoff OR legal_hold = false". SQL binds AND tighter than OR, so it parses as (org_id = :org_id AND created_at < :cutoff) OR (legal_hold = false). The org/age scoping is confined to the left side; the trailing OR makes the statement delete EVERY audit_logs row whose legal_hold is false, across ALL organizations, ignoring org_id and cutoff entirely.
  - なぜ本物: On the very first loop iteration, conn.execute deletes essentially the entire audit_logs table (every row not on legal hold — the overwhelming majority), regardless of organization or retention window. It runs inside engine.begin(), so it commits. The clause that was written to PROTECT legal-hold rows is exactly what triggers global, irreversible deletion of all non-hold audit history. A correct version needs parentheses around the OR term and, since legal_hold rows must be EXEMPT, the condition should be AND legal_hold = false (or AND NOT legal_hold), not OR.
**benign traps(誤検出を誘う無害な変更・拾ってはいけない):**
- @ migrations/versions/7f3a9c2b1e04_add_audit_log_retention.py, op.execute UPDATE (~line +31) — A bare-looking "UPDATE organizations SET retention_days = 365" that appears to rewrite every organization row.  (なぜOK: It is scoped by "WHERE retention_days IS NULL" and runs immediately after the column is added as nullable, so every row is NULL at that point. This is a standard one-time default backfill for a newly added column, not a destructive mass overwrite of existing configured values.)
- @ migrations/versions/7f3a9c2b1e04_add_audit_log_retention.py, op.alter_column(... nullable=False) (~line +34) — Tightening retention_days to NOT NULL looks like it will fail or reject existing rows that have no value.  (なぜOK: The preceding op.execute backfill populates retention_days for every NULL row within the same migration (same transaction), so no NULLs remain when the NOT NULL constraint is applied. The ordering (add nullable -> backfill -> set NOT NULL) is the correct, safe pattern.)
- @ migrations/versions/7f3a9c2b1e04_add_audit_log_retention.py, downgrade() op.drop_column calls (~lines +38-39) — downgrade() drops columns (legal_hold, retention_days), which pattern-matches the 'migration drops a column still read elsewhere' hazard.  (なぜOK: These drops are in downgrade() and remove exactly the two columns this same migration's upgrade() added; reverting the revision correctly reverses its own schema changes. No other code path depends on these columns existing after a downgrade of this specific revision.)

<details><summary>diff</summary>

```diff
diff --git a/app/jobs/audit_retention.py b/app/jobs/audit_retention.py
new file mode 100644
index 0000000..a1b2c3d
--- /dev/null
+++ b/app/jobs/audit_retention.py
@@ -0,0 +1,46 @@
+import logging
+from datetime import datetime, timedelta
+
+from sqlalchemy import text
+
+from app.db import engine
+
+log = logging.getLogger(__name__)
+
+DEFAULT_RETENTION_DAYS = 365
+
+
+def _orgs_with_retention(conn):
+    rows = conn.execute(
+        text(
+            "SELECT id, retention_days FROM organizations "
+            "WHERE deleted_at IS NULL"
+        )
+    ).fetchall()
+    return rows
+
+
+def purge_expired_audit_logs():
+    """Delete audit logs older than each org's retention window.
+
+    Logs flagged with legal_hold are exempt and must never be purged.
+    """
+    total_deleted = 0
+    with engine.begin() as conn:
+        for org in _orgs_with_retention(conn):
+            retention = org.retention_days or DEFAULT_RETENTION_DAYS
+            cutoff = datetime.utcnow() - timedelta(days=retention)
+            result = conn.execute(
+                text(
+                    "DELETE FROM audit_logs "
+                    "WHERE org_id = :org_id "
+                    "AND created_at < :cutoff "
+                    "OR legal_hold = false"
+                ),
+                {"org_id": org.id, "cutoff": cutoff},
+            )
+            total_deleted += result.rowcount
+            log.info(
+                "purged %s audit logs for org %s", result.rowcount, org.id
+            )
+    return total_deleted
diff --git a/migrations/versions/7f3a9c2b1e04_add_audit_log_retention.py b/migrations/versions/7f3a9c2b1e04_add_audit_log_retention.py
new file mode 100644
index 0000000..d4e5f60
--- /dev/null
+++ b/migrations/versions/7f3a9c2b1e04_add_audit_log_retention.py
@@ -0,0 +1,39 @@
+"""add audit log retention settings
+
+Revision ID: 7f3a9c2b1e04
+Revises: 2c1d5e8a9b30
+Create Date: 2026-06-28 09:14:22.108431
+"""
+from alembic import op
+import sqlalchemy as sa
+
+revision = "7f3a9c2b1e04"
+down_revision = "2c1d5e8a9b30"
+branch_labels = None
+depends_on = None
+
+
+def upgrade():
+    op.add_column(
+        "organizations",
+        sa.Column("retention_days", sa.Integer(), nullable=True),
+    )
+    op.add_column(
+        "audit_logs",
+        sa.Column(
+            "legal_hold",
+            sa.Boolean(),
+            server_default=sa.false(),
+            nullable=False,
+        ),
+    )
+    op.execute(
+        "UPDATE organizations SET retention_days = 365 "
+        "WHERE retention_days IS NULL"
+    )
+    op.alter_column("organizations", "retention_days", nullable=False)
+
+
+def downgrade():
+    op.drop_column("audit_logs", "legal_hold")
+    op.drop_column("organizations", "retention_days")
diff --git a/app/scheduler.py b/app/scheduler.py
index 3a1f8b2..9c7e410 100644
--- a/app/scheduler.py
+++ b/app/scheduler.py
@@ -3,6 +3,7 @@ import logging
 from apscheduler.schedulers.background import BackgroundScheduler
 
 from app.jobs.session_cleanup import purge_stale_sessions
+from app.jobs.audit_retention import purge_expired_audit_logs
 
 log = logging.getLogger(__name__)
 
@@ -10,3 +11,6 @@ log = logging.getLogger(__name__)
 def register_jobs(scheduler: BackgroundScheduler) -> None:
     scheduler.add_job(purge_stale_sessions, "cron", hour=2, id="session_cleanup")
+    scheduler.add_job(
+        purge_expired_audit_logs, "cron", hour=3, id="audit_retention"
+    )
```
</details>

### domain: Backend API rate limiting (HTTP service + batch worker sharing a token-bucket limiter)  (TypeScript)
**planted bugs:**
- `bug-1-contract-break` [critical/contract] @ src/gateway.ts, handleBatchJob — context line `const allowed = await consumeToken(job.userId)` and `if (!allowed)` (around @@ +18..+22, unchanged by the diff but now broken) — consumeToken's return type changed from Promise<boolean> to Promise<RateLimitResult> (an object). handleApiRequest was migrated to read result.allowed, but the existing handleBatchJob caller still treats the return value as a boolean: `const allowed = await consumeToken(...)` followed by `if (!allowed)`. `allowed` is now always a truthy object, so `!allowed` is always false.
  - なぜ本物: Every batch job now skips the throttle branch entirely: ThrottledError is never thrown and the warn log never fires, so runBatch(job) always executes regardless of the user's remaining quota. A user (or a runaway loop) submitting thousands of batch jobs bypasses rate limiting completely, overwhelming downstream systems / incurring unbounded cost. It compiles cleanly because `!object` is valid TypeScript, so tsc gives no warning and it is easy to miss in review.
- `bug-2-retry-after-units` [high/contract] @ src/gateway.ts, handleApiRequest — added line `res.setHeader('Retry-After', String(result.resetMs))` (@@ +11) — resetMs is in milliseconds (WINDOW_MS = 60_000). The HTTP Retry-After header, when given as a delta, must be an integer number of seconds. It is set directly to the millisecond value without dividing by 1000.
  - なぜ本物: On a 429, the server tells clients Retry-After: 60000, i.e. wait 60000 seconds (~16.6 hours) instead of 60 seconds. Well-behaved clients and SDKs that honor Retry-After will back off for hours, effectively taking the user offline after a single rate-limit hit. The correct value is Math.ceil(result.resetMs / 1000) — and note the adjacent X-RateLimit-Reset line does exactly that conversion, making the omission here the real defect.
**benign traps(誤検出を誘う無害な変更・拾ってはいけない):**
- @ src/gateway.ts, handleApiRequest — `res.setHeader('X-RateLimit-Reset', String(Math.ceil(result.resetMs / 1000)))` (@@ +10) — The /1000 division looks suspicious next to the Retry-After line that uses resetMs raw — a hasty reviewer may flag one of them as an inconsistent/double conversion and 'fix' this line to remove the /1000.  (なぜOK: resetMs is milliseconds; X-RateLimit-Reset is conventionally expressed as seconds-until-reset, so Math.ceil(resetMs / 1000) is the correct conversion. This is the CORRECT line — the bug is the other header (Retry-After) which is missing the same division. Flagging this line is a false positive.)
- @ src/rateLimiter.ts — `return { allowed: false, remaining: 0, resetMs: WINDOW_MS - elapsed }` and the refill calc `Math.floor((elapsed / WINDOW_MS) * CAPACITY)` / `Math.min(CAPACITY, bucket.tokens + refill)` (@@ +19..+23) — `WINDOW_MS - elapsed` looks like it could go negative if a lot of time has elapsed, and the refill expression looks like it could overflow CAPACITY or lose units — tempting to flag as a negative Retry-After / capacity-overflow bug.  (なぜOK: Stored tokens are always >= 0 (remaining = tokens - 1 with tokens >= 1). The tokens<=0 branch is only reachable when bucket.tokens == 0 AND refill == 0, which requires elapsed < WINDOW_MS/CAPACITY (600ms); in that branch WINDOW_MS - elapsed is always in (59400, 60000], never negative. Even under clock skew (elapsed < 0) the result only grows larger, staying positive. Separately, Math.min(CAPACITY, ...) hard-caps the refilled bucket, and (elapsed/WINDOW_MS)*CAPACITY is dimensionally correct (fraction-of-window * capacity = tokens). Nothing here is a real bug.)

<details><summary>diff</summary>

```diff
diff --git a/src/rateLimiter.ts b/src/rateLimiter.ts
index 1a2b3c4..5d6e7f8 100644
--- a/src/rateLimiter.ts
+++ b/src/rateLimiter.ts
@@ -1,18 +1,29 @@
 import { redis } from './redis'
 
 const CAPACITY = 100
 const WINDOW_MS = 60_000
 
-export async function consumeToken(userId: string): Promise<boolean> {
+export interface RateLimitResult {
+  allowed: boolean
+  remaining: number
+  resetMs: number
+}
+
+export async function consumeToken(userId: string): Promise<RateLimitResult> {
   const key = `rl:${userId}`
   const raw = await redis.get(key)
   const bucket = raw ? JSON.parse(raw) : { tokens: CAPACITY, updatedAt: Date.now() }
 
-  if (bucket.tokens <= 0) {
-    return false
+  const now = Date.now()
+  const elapsed = now - bucket.updatedAt
+  const refill = Math.floor((elapsed / WINDOW_MS) * CAPACITY)
+  const tokens = Math.min(CAPACITY, bucket.tokens + refill)
+
+  if (tokens <= 0) {
+    return { allowed: false, remaining: 0, resetMs: WINDOW_MS - elapsed }
   }
 
-  const remaining = bucket.tokens - 1
-  await redis.set(key, JSON.stringify({ tokens: remaining, updatedAt: Date.now() }), 'PX', WINDOW_MS)
-  return true
+  const remaining = tokens - 1
+  await redis.set(key, JSON.stringify({ tokens: remaining, updatedAt: now }), 'PX', WINDOW_MS)
+  return { allowed: true, remaining, resetMs: WINDOW_MS }
 }
diff --git a/src/gateway.ts b/src/gateway.ts
index 2b3c4d5..6e7f8a9 100644
--- a/src/gateway.ts
+++ b/src/gateway.ts
@@ -6,18 +6,21 @@ import { ThrottledError } from './errors'
 export async function handleApiRequest(req: Request, res: Response) {
   const userId = req.user.id
-  const allowed = await consumeToken(userId)
-  if (!allowed) {
+  const result = await consumeToken(userId)
+  res.setHeader('X-RateLimit-Remaining', String(result.remaining))
+  res.setHeader('X-RateLimit-Reset', String(Math.ceil(result.resetMs / 1000)))
+  if (!result.allowed) {
+    res.setHeader('Retry-After', String(result.resetMs))
     res.status(429).json({ error: 'rate_limited' })
     return
   }
   res.status(200).json(await processRequest(req))
 }
 
 export async function handleBatchJob(job: BatchJob) {
   const allowed = await consumeToken(job.userId)
   if (!allowed) {
-    logger.warn('batch job throttled', { userId: job.userId })
+    logger.warn('batch job throttled', { userId: job.userId, jobId: job.id })
     throw new ThrottledError(job.id)
   }
   await runBatch(job)
 }
```
</details>

### domain: web backend / e-commerce orders REST API (Flask + SQLite)  (Python)
**planted bugs:**
- `BUG-1` [critical/sqli] @ app/api/orders.py, list_orders — added line `status = request.args.get("status", "shipped")` feeding `orders_by_status(db, status)` — The new ?status query parameter is passed straight into the pre-existing orders_by_status() helper, which builds its WHERE clause with `"... status = '%s'" % status` (unparameterized string interpolation). Before this PR the only caller invoked orders_by_status(db, "shipped") with a hard-coded constant, so the injectable sink was dormant/unreachable by external input; the diff wires request-controlled input into it, turning it into a live SQL injection.
  - なぜ本物: Request `GET /api/orders?status=' UNION SELECT id, password_hash, email, 1 FROM users --` produces the query `SELECT id, customer_id, total, status FROM orders WHERE status = '' UNION SELECT id, password_hash, email, 1 FROM users --'`, exfiltrating every user's password hash and email into the JSON response. `?status=' OR '1'='1` dumps all orders regardless of status. The value is never validated against the known status set nor bound as a parameter, and the sink itself is unchanged, so the injection is fully reachable by any unauthenticated caller of the endpoint.
**benign traps(誤検出を誘う無害な変更・拾ってはいけない):**
- @ app/reports/queries.py, recent_orders_by_customer — `f"ORDER BY created_at {direction} LIMIT ?"` — An f-string interpolates `direction` directly into the SQL text, which pattern-matches the classic ORDER BY injection and looks alarming next to a real SQLi in the same PR.  (なぜOK: `direction` is derived via `_SORT_DIRECTIONS.get(sort, "DESC")`, a strict allow-list whose values are only ever the literals "ASC" or "DESC". Any unknown/malicious `sort` (including injection payloads) misses the dict and falls back to "DESC", so no attacker-controlled text can ever reach the SQL string. This is a correct whitelisting pattern, not a vulnerability.)
- @ app/api/orders.py, customer_orders — `<int:customer_id>` converter, `limit = int(request.args.get("limit", 20))`, and the `?`-parameterized query — Both `customer_id` and `limit` are user-controlled values that end up in a database query, which a hasty reviewer may flag as untrusted input reaching SQL.  (なぜOK: `customer_id` comes through Flask's `<int:...>` route converter (non-integer paths 404 before the handler runs), `limit` is coerced with `int(...)`, and both are passed as bound parameters (`WHERE customer_id = ?`, `LIMIT ?`) in recent_orders_by_customer — never string-concatenated. No injection is possible. (At worst a non-numeric ?limit raises ValueError -> HTTP 500, a minor robustness nit, not a security bug.))
- @ app/reports/queries.py, recent_orders_by_customer — SQL that mixes an f-string with `?` placeholders — Seeing an f-string and `?` bind parameters combined in one SQL literal can look like an inconsistent/half-parameterized query worth flagging.  (なぜOK: The f-string only injects the already-whitelisted `direction` literal; all genuinely user-controlled data (customer_id, limit) uses bound `?` parameters. Combining a static whitelisted keyword via f-string with bound parameters for values is safe and idiomatic.)

<details><summary>diff</summary>

```diff
From 4c1a9f0e2b7d5a3f8e1c6b2d9a4f0e13 Mon Sep 17 00:00:00 2001
From: Dana Okoro <dana@shop.example>
Date: Mon, 6 Jul 2026 09:14:22 +0000
Subject: [PATCH] orders API: allow filtering by status and add per-customer
 order history

Previously GET /api/orders was hard-wired to the "shipped" dashboard. This
lets the frontend pass ?status= to reuse the same endpoint for the other
tabs (pending/paid/cancelled), and adds a per-customer order history route
for the new account page.

---
 app/api/orders.py       | 18 +++++++++++++++---
 app/reports/queries.py  | 15 +++++++++++++++
 2 files changed, 30 insertions(+), 3 deletions(-)

diff --git a/app/reports/queries.py b/app/reports/queries.py
index 1a2b3c4..5d6e7f8 100644
--- a/app/reports/queries.py
+++ b/app/reports/queries.py
@@ -1,9 +1,24 @@
 """Read helpers for order reporting."""
 
 
+_SORT_DIRECTIONS = {"asc": "ASC", "desc": "DESC"}
+
+
 def orders_by_status(db, status):
     sql = (
         "SELECT id, customer_id, total, status "
         "FROM orders WHERE status = '%s'" % status
     )
     return db.execute(sql).fetchall()
+
+
+def recent_orders_by_customer(db, customer_id, limit=20, sort="desc"):
+    direction = _SORT_DIRECTIONS.get(sort, "DESC")
+    sql = (
+        "SELECT id, total, status, created_at FROM orders "
+        "WHERE customer_id = ? "
+        f"ORDER BY created_at {direction} LIMIT ?"
+    )
+    return db.execute(sql, (customer_id, limit)).fetchall()
diff --git a/app/api/orders.py b/app/api/orders.py
index 9f8e7d6..2b3c4d5 100644
--- a/app/api/orders.py
+++ b/app/api/orders.py
@@ -1,15 +1,25 @@
 """Orders API endpoints."""
 
-from flask import Blueprint, jsonify
+from flask import Blueprint, jsonify, request
 
 from app.db import get_db
-from app.reports.queries import orders_by_status
+from app.reports.queries import orders_by_status, recent_orders_by_customer
 
 bp = Blueprint("orders", __name__)
 
 
 @bp.route("/api/orders")
 def list_orders():
     db = get_db()
-    rows = orders_by_status(db, "shipped")
+    status = request.args.get("status", "shipped")
+    rows = orders_by_status(db, status)
     return jsonify([dict(r) for r in rows])
+
+
+@bp.route("/api/customers/<int:customer_id>/orders")
+def customer_orders(customer_id):
+    db = get_db()
+    limit = int(request.args.get("limit", 20))
+    sort = request.args.get("sort", "desc")
+    rows = recent_orders_by_customer(db, customer_id, limit=limit, sort=sort)
+    return jsonify([dict(r) for r in rows])
```
</details>

## 独立検証で確定した正解(verify / ground truth)

### verify #1  (usable=True)
- notes: The diff is coherent and self-contained (single file, clean before/after transformation from a global limiter to a per-tenant limiter). I verified the primary claimed bug by tracing the exact code: Allow() takes t.mu.RLock() (a shared/read lock) and defer t.mu.RUnlock(), then on a cache miss executes t.limiters[tenantID] = lim, a map write, while only holding the read lock. Multiple goroutines can hold RLock concurrently, so two concurrent first-requests (even for two different new tenants, since it's a single shared map) can execute concurrent map writes with no synchronization, which is undefined behavior in Go and commonly manifests as 'fatal error: concurrent map writes', a fatal, non-recoverable runtime crash (not merely a benign data race). This is correctly classified as critical/race and the location is accurate.\n\nI additionally found a real bug the author's list omitted: the per-tenant map key (tenantID) is taken directly from the client-controlled request header X-Tenant-ID with no validation, allow-list, or bound on cardinality, and t.limiters only ever grows (SetRate is the only place it's cleared, which is an operator-triggered config change, not a cleanup mechanism). An attacker can send requests with a large number of distinct X-Tenant-ID values to make the server allocate an unbounded number of rate.Limiter entries that are never evicted, causing unbounded memory growth (resource-exhaustion / memory-leak DoS). This is a real behavioral regression introduced by this diff (the prior version had a single fixed limiter, immune to this) and is directly on the changed lines (map keyed by header value in Allow/Middleware). I rate it medium severity since it requires sustained/malicious traffic to matter, unlike the critical, immediately-crashing race bug.\n\nBoth benign traps check out under close reading of Go's RWMutex and net/http semantics: the SetRate map-swap is properly serialized against Allow's RLock-protected reads, and the header-before-http.Error ordering is correct standard-library usage that does emit the header.\n\nNo other issues found (e.g., rate.Limiter.Allow() itself is internally synchronized so calling it under only RLock is fine independent of the map-write bug; the 'anonymous' fallback bucket for missing tenant header is an intentional, non-buggy design choice).
- 確定 planted bugs:
  - `bug-1` [critical/race] @ internal/ratelimit/ratelimit.go, Allow(): `t.limiters[tenantID] = lim` executed while only t.mu.RLock() is held (added ~line 40) — Allow() acquires only a read lock (t.mu.RLock/defer RUnlock) but on a cache miss writes to the shared map (t.limiters[tenantID] = lim). Since RWMutex allows many concurrent RLock holders, two goroutines hitting a cold tenant simultaneously (e.g., during traffic ramp-up when many new tenants first appear) can both execute the map write concurrently with no mutual exclusion, which is undefined behavior in Go and typically crashes the process with 'fatal error: concurrent map writes', taking down the whole server. Fix: take the exclusive Lock (ideally with double-checked locking: RLock to check, then Lock+recheck to create-and-store) around the create-and-store path.
  - `bug-2` [medium/resource-exhaustion] @ internal/ratelimit/ratelimit.go, Allow()/Middleware(): tenant key taken from unvalidated client header `X-Tenant-ID` and stored permanently in t.limiters (added ~lines 33-43, 66-68) — The tenant ID used as the map key comes directly from a client-controlled request header with no validation or allow-list, and every distinct value seen creates a new permanent entry in t.limiters (only cleared by an operator calling SetRate, not by any eviction policy). A client that sends many requests with distinct X-Tenant-ID values can force the server to allocate an unbounded number of rate.Limiter objects that are never freed, causing unbounded memory growth over time (a memory-leak/DoS vector). This is a regression versus the prior single global limiter, which had no such attacker-controlled state growth. Fix: validate/allow-list tenant IDs against known tenants, or bound the map with an LRU/TTL eviction policy.

### verify #2  (usable=True)
- notes: The diff is coherent and reviewable. The single planted bug (BUG-1) is real and severe: verified via standard SQL operator precedence (AND binds tighter than OR), the WHERE clause `org_id = :org_id AND created_at < :cutoff OR legal_hold = false` parses as `(org_id = :org_id AND created_at < :cutoff) OR (legal_hold = false)`. Since legal_hold defaults to false for essentially all rows, the first loop iteration deletes nearly the entire audit_logs table across all organizations, inside a committing transaction (engine.begin()), directly contradicting the function's own docstring guarantee that legal-hold rows must never be purged (ironically the exemption clause is what causes global deletion of everything NOT on hold). This matches the author's claim; I kept it as critical data-loss.\n\nAll three benign traps check out as genuinely safe on inspection of the migration's operation ordering (add nullable column -> backfill NULLs -> enforce NOT NULL; downgrade reverses only this revision's own additions).\n\nI found one additional, lower-severity real bug the author missed: `retention = org.retention_days or DEFAULT_RETENTION_DAYS` in app/jobs/audit_retention.py treats a legitimately configured `retention_days = 0` as falsy and silently substitutes the 365-day default, meaning an org that explicitly configured a 0-day (or effectively minimal) retention window would have its audit logs retained far longer than configured. This is a real logic bug (should use `if org.retention_days is not None else DEFAULT_RETENTION_DAYS`), though its practical impact is smaller and more speculative than BUG-1 since it depends on 0 being a meaningful/used configuration value; I've included it as a medium-severity additional finding rather than critical.\n\nNo other correctness issues found in scheduler.py wiring or the migration's column definitions.
- 確定 planted bugs:
  - `BUG-1` [critical/data-loss] @ app/jobs/audit_retention.py, DELETE statement in purge_expired_audit_logs (added line "OR legal_hold = false", ~line +38) — The WHERE clause `org_id = :org_id AND created_at < :cutoff OR legal_hold = false` lacks parentheses; SQL operator precedence makes AND bind tighter than OR, so it evaluates as `(org_id = :org_id AND created_at < :cutoff) OR (legal_hold = false)`. Since legal_hold defaults to false (server_default=sa.false()) for essentially every existing row, the very first loop iteration deletes almost all rows in audit_logs across every organization, ignoring org_id and the retention cutoff entirely, and the transaction commits via engine.begin(). This is the exact opposite of the stated intent (legal-hold rows are supposed to be exempt/protected) and destroys audit history irreversibly.
  - `BUG-2` [medium/logic-error] @ app/jobs/audit_retention.py, purge_expired_audit_logs (line: `retention = org.retention_days or DEFAULT_RETENTION_DAYS`) — Using `or` to apply the fallback treats a legitimately configured `retention_days = 0` the same as NULL/missing, silently overriding it to 365 days. An org that explicitly set a 0 (or otherwise falsy) retention value would have logs retained far longer than configured, silently diverging from admin intent/compliance configuration. Should check `is None` instead of relying on truthiness.

### verify #3  (usable=True)
- notes: Verified by tracing data flow. Before the diff, orders_by_status(db, status) was only ever invoked with the hard-coded literal \"shipped\" in list_orders; the SQL it builds (\"... status = '%s'\" % status) was always unparameterized string interpolation, but the sink was unreachable by external input. The diff adds `status = request.args.get(\"status\", \"shipped\")` and threads it straight into that same unchanged, unparameterized sink, making it a live, unauthenticated SQL injection (e.g. ?status=' UNION SELECT id, password_hash, email, 1 FROM users -- exfiltrates the users table; ?status=' OR '1'='1 dumps all orders). This is a real, critical, in-diff bug — confirmed as described by the author, with the caveat that the vulnerable line/sink itself lives in app/reports/queries.py (orders_by_status) even though the newly-attacker-controlled input originates in app/api/orders.py; both files/lines are relevant to the finding.\n\nThe second new function, recent_orders_by_customer, is properly defended: customer_id/limit are bound as `?` parameters and sort is passed through a strict allow-list dict before being embedded via f-string, so it cannot be abused. I did not find any additional planted/incidental bugs worth adding as blocking findings. Two very minor, non-blocking observations (not added as findings because they are not real defects worthy of a planted-bug slot): (1) a non-numeric `?limit` value raises an unhandled ValueError producing a 500 rather than a graceful 400; (2) neither endpoint shows any authorization check restricting which caller may view a given customer's order history, but since list_orders (unchanged in this regard) and the rest of the file also show no auth layer, this looks like an existing architectural pattern (auth handled elsewhere, e.g. middleware) rather than a regression introduced by this diff, so I did not treat it as a planted bug.\n\nAll three benign traps are correctly benign as described. The diff is coherent and self-contained; fixture is usable.
- 確定 planted bugs:
  - `BUG-1` [critical/sqli] @ app/api/orders.py:list_orders (status = request.args.get("status", "shipped")) flowing into app/reports/queries.py:orders_by_status ("... status = '%s'" % status) — The new ?status query parameter on GET /api/orders is passed unvalidated into orders_by_status(), which builds its WHERE clause via unparameterized % string interpolation. Prior to this diff the function was only ever called with the hard-coded constant "shipped", so the injectable sink was dormant; the diff makes it reachable by any unauthenticated caller. A request like GET /api/orders?status=' UNION SELECT id, password_hash, email, 1 FROM users -- lets an attacker exfiltrate arbitrary table data (e.g. user password hashes) through the JSON response, and ?status=' OR '1'='1 dumps all orders regardless of status.

