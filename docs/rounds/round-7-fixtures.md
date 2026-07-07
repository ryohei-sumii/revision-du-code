# Round 7 — テストフィクスチャ / Fixtures

R6回帰×2＋広域(素correctness/エラー処理/クリーン/nit のみ/混在)。

## 作成フィクスチャ

### domain: Go backend — latency metrics / observability service (nearest-rank percentile over a rolling window)
**planted bugs:**
- `BUG1` [high/off-by-one] @ internal/metrics/percentile.go, line 22 — `return sorted[rank]` where `rank := int(math.Ceil(p / 100 * float64(len(sorted))))` — Nearest-rank percentile computes a 1-based rank but indexes the 0-based slice with it directly. The result is the (rank+1)-th smallest value instead of the rank-th, and when `p/100 * N` lands on an integer (which includes p=100 for any N, and p=95 whenever N is a multiple of 20) `rank == len(sorted)` and `sorted[rank]` panics with index out of range.
- `BUG2` [high/empty-case-panic] @ internal/metrics/percentile.go, line 22 — `sorted[rank]` when `len(samples) == 0` — Percentile does not handle an empty sample set. With no samples, len(sorted)=0, rank = ceil(0)=0, and `sorted[0]` panics with index out of range on an empty slice.
**benign traps:**
- @ internal/metrics/window.go — `Snapshot()` returns `append([]float64(nil), w.samples...)` under the mutex — A reviewer may claim Snapshot leaks a reference to the internal `w.samples` slice, creating a data race with Add()'s reslicing/append and with the handler reading it lock-free. (なぜOK: `append([]float64(nil), w.samples...)` allocates a brand-new backing array and copies the elements while the lock is held, so the returned slice shares no storage with w.samples. Callers (P95, the handler) operate only on this private copy; there is no aliasing and no race.)
- @ internal/metrics/percentile.go — `make([]float64, len(samples))` + `copy` before `sort.Float64s` — A reviewer may flag the defensive copy as needless allocation/inefficiency, or worry that sorting mutates the caller's data. (なぜOK: The copy is intentional and correct: it prevents Percentile from mutating (reordering) the caller's slice, which matters because Snapshot's copy is already owned but future callers might pass a shared slice. The allocation is O(N) and bounded by the window limit — appropriate, not a defect.)

<details><summary>diff</summary>

```diff
diff --git a/internal/metrics/percentile.go b/internal/metrics/percentile.go
new file mode 100644
index 0000000..b3a1f27
--- /dev/null
+++ b/internal/metrics/percentile.go
@@ -0,0 +1,24 @@
+package metrics
+
+import (
+	"math"
+	"sort"
+)
+
+// Percentile returns the p-th percentile (p in the range 0..100) of the given
+// samples using the nearest-rank method. The input slice does not need to be
+// pre-sorted; a defensive copy is sorted internally so the caller's slice is
+// left untouched.
+//
+// Example: Percentile(latencies, 95) yields the p95 latency.
+func Percentile(samples []float64, p float64) float64 {
+	sorted := make([]float64, len(samples))
+	copy(sorted, samples)
+	sort.Float64s(sorted)
+
+	// Nearest-rank: the smallest value whose rank is >= ceil(p/100 * N).
+	rank := int(math.Ceil(p / 100 * float64(len(sorted))))
+	return sorted[rank]
+}
diff --git a/internal/metrics/window.go b/internal/metrics/window.go
index 4c1d9a2..e7f0b56 100644
--- a/internal/metrics/window.go
+++ b/internal/metrics/window.go
@@ -1,6 +1,9 @@
 package metrics
 
-import "sync"
+import (
+	"sync"
+	"time"
+)
 
 // RollingWindow accumulates latency samples (in seconds) for a single route.
 // It keeps at most `limit` of the most recent samples.
@@ -30,3 +33,31 @@ func (w *RollingWindow) Add(v float64) {
 		w.samples = w.samples[len(w.samples)-w.limit:]
 	}
 }
+
+// Observe records the elapsed time since start as a latency sample.
+func (w *RollingWindow) Observe(start time.Time) {
+	w.Add(time.Since(start).Seconds())
+}
+
+// Snapshot returns a copy of the current samples that is safe for the caller
+// to read and retain after the lock is released.
+func (w *RollingWindow) Snapshot() []float64 {
+	w.mu.Lock()
+	defer w.mu.Unlock()
+	return append([]float64(nil), w.samples...)
+}
+
+// Count returns the number of samples currently held in the window.
+func (w *RollingWindow) Count() int {
+	w.mu.Lock()
+	defer w.mu.Unlock()
+	return len(w.samples)
+}
+
+// P95 reports the 95th-percentile latency (in seconds) across the samples
+// currently in the window. It is used by the /metrics scrape handler.
+func (w *RollingWindow) P95() float64 {
+	return Percentile(w.Snapshot(), 95)
+}
diff --git a/internal/metrics/handler.go b/internal/metrics/handler.go
index 9a2b7c1..d5e6f8b 100644
--- a/internal/metrics/handler.go
+++ b/internal/metrics/handler.go
@@ -18,10 +18,13 @@ func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
 	h.mu.RLock()
 	defer h.mu.RUnlock()
 
 	enc := newPromEncoder(w)
 	for route, win := range h.windows {
 		enc.gauge("http_request_latency_seconds_sum", route, sum(win.Snapshot()))
+		// p95 latency per route, exported for the dashboard alerting rules.
+		enc.gauge("http_request_latency_seconds_p95", route, win.P95())
 	}
 }
```
</details>

### domain: Go HTTP client library — request configuration and retry logic (backend infrastructure)
**planted bugs:**
- `PB1` [critical/zero-value-default / fail-closed regression] @ internal/client/config.go LoadConfig (RequestTimeout left unset when API_REQUEST_TIMEOUT env var is absent) consumed at internal/client/client.go Do → context.WithTimeout(ctx, c.cfg.RequestTimeout) — The new RequestTimeout field is only assigned when the API_REQUEST_TIMEOUT environment variable is set. When it is unset (the default in most deployments), RequestTimeout keeps its zero value (0). Do() unconditionally wraps the caller context with context.WithTimeout(ctx, 0). No non-zero fallback/default is applied anywhere.
**benign traps:**
- @ internal/client/client.go Do — loop condition `attempt <= c.cfg.MaxRetries` and message `c.cfg.MaxRetries+1` — The loop runs from attempt 0 while attempt <= MaxRetries, i.e. MaxRetries+1 iterations, and the failure message reports MaxRetries+1 attempts. This reads like a classic off-by-one where one extra request is issued. (なぜOK: The field is documented as 'the number of retries attempted after the initial call.' MaxRetries retries plus 1 initial attempt is exactly MaxRetries+1 total executions, so the loop bound is correct and the '+1' in the message is consistent with that definition. No off-by-one.)
- @ internal/client/config.go LoadConfig — shadowed err in the ParseDuration block — `d, err := time.ParseDuration(v)` introduces err inside the if-block, which can look like it shadows/ignores an outer error variable. (なぜOK: There is no outer err in scope at that point (cfg is built with a struct literal), so the := correctly declares a new local, the error is checked and returned, and nothing is shadowed or dropped.)

<details><summary>diff</summary>

```diff
diff --git a/internal/client/config.go b/internal/client/config.go
index 3a1f2c9..b7e4a10 100644
--- a/internal/client/config.go
+++ b/internal/client/config.go
@@ -1,6 +1,7 @@
 package client
 
 import (
+	"fmt"
 	"os"
 	"strconv"
 	"time"
@@ -14,6 +15,11 @@ type Config struct {
 	// MaxRetries is the number of retries attempted after the initial call.
 	MaxRetries int
 
+	// RequestTimeout bounds the total wall-clock time for a single Do call,
+	// including connection, TLS handshake, and response body read. It is
+	// enforced by wrapping the caller's context with a deadline.
+	RequestTimeout time.Duration
+
 	// UserAgent is sent on every outbound request.
 	UserAgent string
 }
@@ -33,6 +39,14 @@ func LoadConfig() (*Config, error) {
 		UserAgent:  getEnv("API_USER_AGENT", "svc-gateway/1.0"),
 	}
 
+	if v := os.Getenv("API_REQUEST_TIMEOUT"); v != "" {
+		d, err := time.ParseDuration(v)
+		if err != nil {
+			return nil, fmt.Errorf("invalid API_REQUEST_TIMEOUT %q: %w", v, err)
+		}
+		cfg.RequestTimeout = d
+	}
+
 	return cfg, nil
 }
 
diff --git a/internal/client/client.go b/internal/client/client.go
index 5d8c1e0..2f0aa31 100644
--- a/internal/client/client.go
+++ b/internal/client/client.go
@@ -2,6 +2,7 @@ package client
 
 import (
 	"context"
+	"fmt"
 	"time"
 )
 
@@ -24,15 +25,20 @@ func New(cfg *Config) *Client {
 // Do executes req, retrying transient failures up to cfg.MaxRetries times.
 // The supplied ctx governs cancellation across all attempts.
 func (c *Client) Do(ctx context.Context, req *Request) (*Response, error) {
+	ctx, cancel := context.WithTimeout(ctx, c.cfg.RequestTimeout)
+	defer cancel()
+
 	var lastErr error
 	for attempt := 0; attempt <= c.cfg.MaxRetries; attempt++ {
 		resp, err := c.doOnce(ctx, req)
 		if err == nil {
 			return resp, nil
 		}
+		if ctx.Err() != nil {
+			return nil, ctx.Err()
+		}
 		lastErr = err
 		time.Sleep(backoff(attempt))
 	}
-	return nil, lastErr
+	return nil, fmt.Errorf("request failed after %d attempts: %w", c.cfg.MaxRetries+1, lastErr)
 }
```
</details>

### domain: Payroll / wage calculation (Java backend service)
**planted bugs:**
- `overtime-negative-hours` [high/wrong-operator / missing lower-bound clamp (everyday correctness)] @ WeeklyPayCalculator.computeGrossPay — line `double overtimeHours = hoursWorked - OVERTIME_THRESHOLD;` — overtimeHours is computed as hoursWorked - 40 without clamping to zero. The regularHours line uses Math.min(hoursWorked, 40) to cap the regular portion, but the overtime line has no matching Math.max(0, ...) floor. For any week under 40 hours, overtimeHours is negative and produces a negative overtimePay that is added to (i.e. subtracts from) regularPay.
**benign traps:**
- @ WeeklyPayCalculator.computeGrossPay — `BigDecimal.valueOf(regularHours)` / `BigDecimal.valueOf(overtimeHours)` converting a double into BigDecimal — A reviewer primed on 'never use double for money' may flag that hours are held as double and converted via BigDecimal.valueOf, claiming floating-point error will corrupt the monetary result. (なぜOK: The doubles here are hours (a count of time), not currency. BigDecimal.valueOf(double) routes through Double.toString, giving the clean decimal value (e.g. 37.5), the arithmetic is done in BigDecimal, and the final result is rounded once with setScale(2, HALF_UP). No monetary precision is lost. This is standard, correct usage — not a defect.)
- @ WeeklyPayCalculator.computeGrossPay — single final `setScale(2, RoundingMode.HALF_UP)` on regularPay.add(overtimePay) — A reviewer might argue regularPay and overtimePay should each be rounded to cents before summing, and that rounding only the total is a bug. (なぜOK: Rounding once on the final gross figure is the more correct approach — it avoids accumulating intermediate rounding error. Rounding each component separately would be what introduces drift. The single terminal rounding is intentional and correct.)

<details><summary>diff</summary>

```diff
diff --git a/src/main/java/com/acme/payroll/WeeklyPayCalculator.java b/src/main/java/com/acme/payroll/WeeklyPayCalculator.java
index 3a1f9c2..b7e04d1 100644
--- a/src/main/java/com/acme/payroll/WeeklyPayCalculator.java
+++ b/src/main/java/com/acme/payroll/WeeklyPayCalculator.java
@@ -12,6 +12,13 @@ import java.math.RoundingMode;
  */
 public class WeeklyPayCalculator {
 
+    /** Weekly hours above which the overtime multiplier applies (FLSA standard). */
+    private static final double OVERTIME_THRESHOLD = 40.0;
+
+    /** Overtime is paid at 1.5x the base hourly rate. */
+    private static final BigDecimal OVERTIME_MULTIPLIER = BigDecimal.valueOf(1.5);
+
     private final HolidayCalendar holidayCalendar;
 
     public WeeklyPayCalculator(HolidayCalendar holidayCalendar) {
         this.holidayCalendar = holidayCalendar;
@@ -20,17 +27,34 @@ public class WeeklyPayCalculator {
     /**
      * Computes gross pay for a single weekly timesheet.
      *
-     * <p>All hours are currently paid at the flat base rate. Overtime rules
-     * (time-and-a-half above 40h/week) are tracked in PAY-1423 and not yet
-     * applied here.
+     * <p>Hours worked up to {@link #OVERTIME_THRESHOLD} are paid at the base
+     * rate; hours beyond that are paid at {@link #OVERTIME_MULTIPLIER} times the
+     * base rate (PAY-1423).
      */
     public BigDecimal computeGrossPay(TimeSheet sheet, Employee employee) {
         double hoursWorked = sheet.getTotalHours();
         if (hoursWorked <= 0) {
             return BigDecimal.ZERO;
         }
 
         BigDecimal hourlyRate = employee.getHourlyRate();
-        return hourlyRate
-                .multiply(BigDecimal.valueOf(hoursWorked))
-                .setScale(2, RoundingMode.HALF_UP);
+
+        double regularHours = Math.min(hoursWorked, OVERTIME_THRESHOLD);
+        double overtimeHours = hoursWorked - OVERTIME_THRESHOLD;
+
+        BigDecimal regularPay = hourlyRate
+                .multiply(BigDecimal.valueOf(regularHours));
+
+        BigDecimal overtimePay = hourlyRate
+                .multiply(OVERTIME_MULTIPLIER)
+                .multiply(BigDecimal.valueOf(overtimeHours));
+
+        return regularPay
+                .add(overtimePay)
+                .setScale(2, RoundingMode.HALF_UP);
     }
 }
```
</details>

### domain: TypeScript backend service — batch CSV order import into a database (Node.js)
**planted bugs:**
- `bug-1` [high/error-swallowed / no-rollback -> failure looks like success] @ src/import/orderImporter.ts, the catch block inside importOrders (the `} catch (err) { logger.error(...); return { imported, failed: rows.length - imported }; }`) — When an insert exhausts its retries and throws, control lands in the catch block, which logs the error and RETURNS a normal ImportResult reporting `imported` successful rows. It never calls `tx.rollback()` and, more importantly, the transaction was never committed (commit is only reached on the success path). When the transaction handle is later released/garbage-collected the DB aborts it, so ALL rows inserted so far are discarded. Yet the function returns { imported: N, failed: ... } with no error, so the caller believes N orders were persisted.
**benign traps:**
- @ src/import/orderImporter.ts, success-path return `return { imported, failed: rows.length - imported };` combined with the `if (!parsed.ok) { continue; }` skip — A reviewer may flag that invalid rows are silently `continue`d with no per-row error and worry the reported counts are wrong or that failures are hidden. (なぜOK: This is intended behavior documented in the function comment (invalid rows are skipped and reported in `failed`). The arithmetic is correct: `failed = rows.length - imported` counts every row that was not successfully inserted, which correctly includes the skipped invalid rows. On the success path no failure is hidden and no count is off.)
- @ src/import/orderImporter.ts, `withRetry` wrapping `tx.insert("orders", parsed.value)` — A reviewer may worry the retry loop could insert the same order twice (duplicate row) if an insert partially succeeded before the error. (なぜOK: The insert is a single statement executed within the open transaction; it either applies and returns, or throws before persisting, so a caught attempt means the row was not written. Retrying re-runs the same insert against the same uncommitted transaction with no duplicate. (This retry is not the source of the real defect; the defect is the missing commit/rollback on the error path.))

<details><summary>diff</summary>

```diff
diff --git a/src/import/orderImporter.ts b/src/import/orderImporter.ts
index 4a1c9e2..b7f3d10 100644
--- a/src/import/orderImporter.ts
+++ b/src/import/orderImporter.ts
@@ -1,6 +1,6 @@
 import { db } from "../db";
 import { logger } from "../logger";
-import { parseOrder, OrderRow } from "./parseOrder";
+import { parseOrder, type OrderRow } from "./parseOrder";
 
 export interface ImportResult {
   imported: number;
@@ -8,20 +8,52 @@ export interface ImportResult {
   failed: number;
 }
 
+const MAX_RETRIES = 3;
+
+/**
+ * Runs `fn`, retrying transient failures up to MAX_RETRIES times.
+ * The underlying insert throws before any row is written, so a
+ * failed attempt never leaves a partial write behind.
+ */
+async function withRetry<T>(fn: () => Promise<T>): Promise<T> {
+  let lastErr: unknown;
+  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
+    try {
+      return await fn();
+    } catch (err) {
+      lastErr = err;
+      logger.warn(`order insert attempt ${attempt}/${MAX_RETRIES} failed`, err);
+    }
+  }
+  throw lastErr;
+}
+
 /**
- * Imports the given rows one at a time. Invalid rows are skipped and
- * reported in `failed`; everything else is inserted immediately.
+ * Imports the given rows inside a single transaction so a bad batch
+ * does not leave the orders table half-populated. Invalid rows are
+ * skipped and reported in `failed`; valid rows are inserted with a
+ * bounded retry to ride out transient database blips.
  */
 export async function importOrders(rows: OrderRow[]): Promise<ImportResult> {
+  const tx = await db.begin();
   let imported = 0;
 
-  for (const row of rows) {
-    const parsed = parseOrder(row);
-    if (!parsed.ok) {
-      continue;
+  try {
+    for (const row of rows) {
+      const parsed = parseOrder(row);
+      if (!parsed.ok) {
+        continue;
+      }
+      await withRetry(() => tx.insert("orders", parsed.value));
+      imported++;
     }
-    await db.insert("orders", parsed.value);
-    imported++;
+    await tx.commit();
+  } catch (err) {
+    logger.error("order import failed", err);
+    return { imported, failed: rows.length - imported };
   }
 
   return { imported, failed: rows.length - imported };
 }
```
</details>

### domain: TypeScript utility library — an LRU (least-recently-used) cache implementation with tests
**planted bugs:** (なし=クリーン)
**benign traps:**
- @ src/lru-cache.ts, set() — `const oldest = this.map.keys().next().value` — Eviction picks the victim by taking the first key from Map iteration order and assumes it is the least-recently-used entry. A reviewer may flag this as relying on undefined iteration order or on a stale ordering. (なぜOK: ECMAScript guarantees Map iterates in insertion order. The class maintains the invariant that the least-recently-used key is always first: every get/set on an existing key does delete-then-set, moving it to the end, so the head is genuinely the LRU entry. This is the standard Map-based LRU idiom and is correct.)
- @ src/lru-cache.ts, set() — eviction only in the `else if` branch — Eviction runs only when the key is new (`else if (this.map.size >= this.maxSize)`); when updating an existing key it is skipped. A jumpy reviewer might think eviction should always be checked and see an off-by-one that lets the cache exceed maxSize. (なぜOK: Updating an existing key does not increase size, so no eviction is needed; the `has` branch deletes-then-reinserts the same key leaving size unchanged. Eviction is only required when a brand-new key would push size past maxSize, which is exactly the branch that checks it. Tests cover the update-at-capacity case and confirm size stays at maxSize.)
- @ src/lru-cache.ts, get() — `this.map.delete(key); this.map.set(key, value)` inside a read — A method that reads a value also mutates the underlying Map on every hit. This side effect inside what looks like a getter can appear surprising or like a concurrency hazard. (なぜOK: Refreshing recency on read is the defining behavior of an LRU cache, and JavaScript's single-threaded model means there is no concurrent-mutation hazard. The delete+re-set is the intended, correct way to move the key to the most-recently-used position.)
- @ src/lru-cache.ts, get() — uses `this.map.has(key)` then `this.map.get(key) as V` instead of a single get — Two lookups plus a non-null cast where a single `map.get` and truthiness check would seem simpler; could read as redundant work or an unsafe cast. (なぜOK: The explicit `has` check is deliberate: it lets stored `undefined`/`null`/`0`/`''` values be distinguished from a miss (a plain truthiness check would misclassify them). The `as V` cast is sound because it only runs after `has` confirmed the key exists. The falsy-value test documents this intent.)

<details><summary>diff</summary>

```diff
diff --git a/src/lru-cache.ts b/src/lru-cache.ts
new file mode 100644
index 0000000..7c1a9e2
--- /dev/null
+++ b/src/lru-cache.ts
@@ -0,0 +1,96 @@
+export interface LRUCacheOptions {
+  /** Maximum number of entries retained before the least-recently-used one is evicted. */
+  maxSize: number;
+}
+
+/**
+ * A fixed-capacity least-recently-used cache.
+ *
+ * Recency is tracked implicitly via `Map` insertion order: the first key
+ * returned by `Map.prototype.keys()` is the least-recently-used entry, and the
+ * last one inserted is the most-recently-used. Both `get` and `set` on an
+ * existing key move it to the most-recently-used position.
+ */
+export class LRUCache<K, V> {
+  private readonly maxSize: number;
+  private readonly map = new Map<K, V>();
+
+  constructor(options: LRUCacheOptions) {
+    if (!Number.isInteger(options.maxSize) || options.maxSize <= 0) {
+      throw new RangeError(
+        `maxSize must be a positive integer, got ${options.maxSize}`,
+      );
+    }
+    this.maxSize = options.maxSize;
+  }
+
+  get size(): number {
+    return this.map.size;
+  }
+
+  /** Returns true if `key` is present without affecting its recency. */
+  has(key: K): boolean {
+    return this.map.has(key);
+  }
+
+  /**
+   * Returns the value for `key`, or `undefined` if absent, and marks the entry
+   * as most-recently-used. Uses `has` rather than a truthiness check so that a
+   * stored `undefined`/`null`/`0`/`''` value is still treated as a hit.
+   */
+  get(key: K): V | undefined {
+    if (!this.map.has(key)) {
+      return undefined;
+    }
+    const value = this.map.get(key) as V;
+    // Re-insert to move the key to the newest position in iteration order.
+    this.map.delete(key);
+    this.map.set(key, value);
+    return value;
+  }
+
+  /**
+   * Inserts or updates `key`. Updating an existing key refreshes its recency
+   * but does not change the size, so eviction only runs when a brand-new key
+   * would push the cache past `maxSize`.
+   */
+  set(key: K, value: V): void {
+    if (this.map.has(key)) {
+      this.map.delete(key);
+    } else if (this.map.size >= this.maxSize) {
+      const oldest = this.map.keys().next().value as K;
+      this.map.delete(oldest);
+    }
+    this.map.set(key, value);
+  }
+
+  delete(key: K): boolean {
+    return this.map.delete(key);
+  }
+
+  clear(): void {
+    this.map.clear();
+  }
+
+  /** Entries ordered least- to most-recently-used. */
+  entries(): IterableIterator<[K, V]> {
+    return this.map.entries();
+  }
+
+  keys(): IterableIterator<K> {
+    return this.map.keys();
+  }
+}
diff --git a/test/lru-cache.test.ts b/test/lru-cache.test.ts
new file mode 100644
index 0000000..b3f04a7
--- /dev/null
+++ b/test/lru-cache.test.ts
@@ -0,0 +1,118 @@
+import { describe, expect, it } from "vitest";
+import { LRUCache } from "../src/lru-cache";
+
+describe("LRUCache", () => {
+  it("rejects a non-positive or non-integer maxSize", () => {
+    expect(() => new LRUCache({ maxSize: 0 })).toThrow(RangeError);
+    expect(() => new LRUCache({ maxSize: -1 })).toThrow(RangeError);
+    expect(() => new LRUCache({ maxSize: 2.5 })).toThrow(RangeError);
+  });
+
+  it("stores and retrieves values", () => {
+    const cache = new LRUCache<string, number>({ maxSize: 3 });
+    cache.set("a", 1);
+    cache.set("b", 2);
+    expect(cache.get("a")).toBe(1);
+    expect(cache.get("b")).toBe(2);
+    expect(cache.get("missing")).toBeUndefined();
+    expect(cache.size).toBe(2);
+  });
+
+  it("treats a stored falsy value as a hit", () => {
+    const cache = new LRUCache<string, number | undefined>({ maxSize: 2 });
+    cache.set("zero", 0);
+    cache.set("undef", undefined);
+    expect(cache.has("zero")).toBe(true);
+    expect(cache.get("zero")).toBe(0);
+    expect(cache.has("undef")).toBe(true);
+    expect(cache.get("undef")).toBeUndefined();
+  });
+
+  it("evicts the least-recently-used entry when over capacity", () => {
+    const cache = new LRUCache<string, number>({ maxSize: 2 });
+    cache.set("a", 1);
+    cache.set("b", 2);
+    cache.set("c", 3); // evicts "a"
+    expect(cache.has("a")).toBe(false);
+    expect([...cache.keys()]).toEqual(["b", "c"]);
+    expect(cache.size).toBe(2);
+  });
+
+  it("get refreshes recency so the touched key survives eviction", () => {
+    const cache = new LRUCache<string, number>({ maxSize: 2 });
+    cache.set("a", 1);
+    cache.set("b", 2);
+    expect(cache.get("a")).toBe(1); // "a" is now most-recently-used
+    cache.set("c", 3); // should evict "b", not "a"
+    expect(cache.has("a")).toBe(true);
+    expect(cache.has("b")).toBe(false);
+    expect(cache.has("c")).toBe(true);
+  });
+
+  it("updating an existing key refreshes recency without evicting", () => {
+    const cache = new LRUCache<string, number>({ maxSize: 2 });
+    cache.set("a", 1);
+    cache.set("b", 2);
+    cache.set("a", 10); // update, not insert
+    expect(cache.size).toBe(2);
+    expect(cache.get("a")).toBe(10);
+    cache.set("c", 3); // evicts "b" because "a" was refreshed
+    expect(cache.has("b")).toBe(false);
+    expect(cache.has("a")).toBe(true);
+  });
+
+  it("works with a capacity of one", () => {
+    const cache = new LRUCache<string, number>({ maxSize: 1 });
+    cache.set("a", 1);
+    cache.set("b", 2);
+    expect(cache.has("a")).toBe(false);
+    expect(cache.get("b")).toBe(2);
+    expect(cache.size).toBe(1);
+  });
+
+  it("delete and clear remove entries", () => {
+    const cache = new LRUCache<string, number>({ maxSize: 3 });
+    cache.set("a", 1);
+    cache.set("b", 2);
+    expect(cache.delete("a")).toBe(true);
+    expect(cache.delete("a")).toBe(false);
+    expect(cache.size).toBe(1);
+    cache.clear();
+    expect(cache.size).toBe(0);
+  });
+
+  it("exposes entries ordered least- to most-recently-used", () => {
+    const cache = new LRUCache<string, number>({ maxSize: 3 });
+    cache.set("a", 1);
+    cache.set("b", 2);
+    cache.set("c", 3);
+    cache.get("a"); // move "a" to newest
+    expect([...cache.entries()]).toEqual([
+      ["b", 2],
+      ["c", 3],
+      ["a", 1],
+    ]);
+  });
+});
```
</details>

### domain: Go — retry/backoff utility for a distributed-systems client library (adds jitter to exponential backoff)
**planted bugs:** (なし=クリーン)
**benign traps:**
- @ retry/backoff.go — Delay(), rand.Float64() call — The jitter uses the top-level math/rand source without ever calling rand.Seed, which looks like it will produce the same 'random' sequence on every process start (deterministic jitter defeats the thundering-herd mitigation). (なぜOK: The module's go.mod declares go 1.21. Since Go 1.20 the top-level rand source is automatically seeded with a random value at startup; rand.Seed is deprecated and unnecessary. Each process gets a distinct sequence, so the jitter is genuinely random across clients.)
- @ retry/backoff.go — Delay(), rand.Float64() called from a method usable across goroutines — Backoff.Delay is a value method with no mutex, and multiple goroutines will call rand.Float64() concurrently — looks like a data race on the shared RNG. (なぜOK: The top-level math/rand convenience functions (rand.Float64, rand.Int63n, etc.) are documented as safe for concurrent use by multiple goroutines; they operate on a globalRand guarded by an internal lock. No user-side synchronization is required.)
- @ retry/backoff.go — Delay(), jitter = 1 + JitterPct*(2*rand.Float64()-1) — The jitter multiplier can drop below 1 and the result is only clamped on the upper side (> Max), so it looks like the delay could go negative and time.Duration(d) would produce a negative/absurd sleep. (なぜOK: JitterPct is documented to be within [0, 1]. With rand.Float64() in [0,1), the factor (2*rand-1) is in [-1,1), so jitter stays in [1-JitterPct, 1+JitterPct] ⊆ [0, 2]. Since backoff >= 0, d is never negative; the worst case is d == 0, yielding a zero-length delay, which is harmless.)

<details><summary>diff</summary>

```diff
diff --git a/retry/backoff.go b/retry/backoff.go
index 3a1f9c2..b7e4d10 100644
--- a/retry/backoff.go
+++ b/retry/backoff.go
@@ -1,7 +1,9 @@
 package retry
 
 import (
+	"context"
 	"math"
+	"math/rand"
 	"time"
 )
 
@@ -13,17 +15,53 @@ type Backoff struct {
 	// Max caps the delay for any single retry.
 	Max time.Duration
 	// Factor is the multiplier applied on each successive attempt.
 	Factor float64
+	// JitterPct is the fraction of random jitter applied to each delay,
+	// expressed as a value in [0, 1]. For example, 0.2 spreads the delay
+	// uniformly across +/-20% of its computed value. Zero disables jitter.
+	JitterPct float64
 }
 
 // Delay returns how long to wait before the given attempt.
 // attempt is 0-indexed: attempt 0 is the first retry.
 func (b Backoff) Delay(attempt int) time.Duration {
-	d := float64(b.Base) * math.Pow(b.Factor, float64(attempt))
+	backoff := float64(b.Base) * math.Pow(b.Factor, float64(attempt))
+	// Spread retries so that many clients failing at the same instant don't
+	// all wake up and retry in lockstep (the "thundering herd" problem).
+	jitter := 1 + b.JitterPct*(2*rand.Float64()-1)
+	d := backoff * jitter
 	if d > float64(b.Max) {
 		return b.Max
 	}
 	return time.Duration(d)
 }
+
+// Sleep blocks for Delay(attempt), or until ctx is done, whichever happens
+// first. It returns ctx.Err() if the context was cancelled before the delay
+// elapsed, and nil otherwise.
+func (b Backoff) Sleep(ctx context.Context, attempt int) error {
+	t := time.NewTimer(b.Delay(attempt))
+	defer t.Stop()
+	select {
+	case <-ctx.Done():
+		return ctx.Err()
+	case <-t.C:
+		return nil
+	}
+}
+
+// minDuration returns the smaller of two durations.
+func minDuration(a, b time.Duration) time.Duration {
+	if a < b {
+		return a
+	}
+	return b
+}
```
</details>

### domain: Backend REST API (TypeScript/Node) — converting a transactions/ledger endpoint from offset pagination to cursor-based pagination.
**planted bugs:**
- `bug-cursor-off-by-one` [high/logic-error / off-by-one boundary] @ src/api/transactions.ts — `const nextCursor = hasMore ? encodeCursor(rows[rows.length - 1].id) : null;` — The next-page cursor is derived from `rows[rows.length - 1]`, but `rows` holds `limit + 1` elements (the deliberate over-fetch). The last element of `rows` is the sentinel row that is sliced off and NOT returned to the client (`items = rows.slice(0, limit)`). The cursor must be taken from the last RETURNED item, i.e. `items[items.length - 1]`. Because the query pages with `id < cursor` (strictly less-than), using the sentinel's id causes that sentinel transaction to be skipped on the next page.
**benign traps:**
- @ src/api/transactions.ts — `where.id = { lt: decodeCursor(opts.cursor) };` combined with `sort: { id: -1 }` — A reviewer may reflexively flag that 'next page' should use a greater-than comparison and object to `lt`. (なぜOK: Results are sorted descending (newest-first, id: -1). Paging forward means moving to OLDER records, i.e. smaller ids, so `id < cursor` (`lt`) is exactly correct. Using `gt` here would be the bug.)
- @ src/api/transactions.ts — `limit: limit + 1` over-fetch — Fetching `limit + 1` rows looks like it would return one too many items to the client. (なぜOK: This is the standard sentinel technique: the extra row is only used to compute `hasMore`, and `items = hasMore ? rows.slice(0, limit) : rows` trims it before returning. The client always receives at most `limit` items.)
- @ src/api/transactions.ts — `accountBalance` refactor to `items.reduce((sum, t) => sum + t.amount, 0)` — The reduce could look unsafe on an empty result set, and the MAX_LIMIT cap looks like the balance ignores accounts with more than 100 transactions. (なぜOK: `reduce` supplies an initial accumulator of 0, so an empty array returns 0 correctly. The 100-transaction cap is pre-existing behavior (the old code also passed `{ limit: MAX_LIMIT }`), so this PR introduces no behavioral change there — it is out of scope, not a newly planted defect.)

<details><summary>diff</summary>

```diff
diff --git a/src/api/cursor.ts b/src/api/cursor.ts
new file mode 100644
index 0000000..1a2b3c4
--- /dev/null
+++ b/src/api/cursor.ts
@@ -0,0 +1,19 @@
+// Opaque, URL-safe cursors. Callers must treat the value as an opaque token
+// and pass it back unmodified as `opts.cursor` on the following request.
+
+export function encodeCursor(id: string): string {
+  return Buffer.from(id, "utf8").toString("base64url");
+}
+
+export function decodeCursor(cursor: string): string {
+  const decoded = Buffer.from(cursor, "base64url").toString("utf8");
+  if (decoded.length === 0) {
+    throw new InvalidCursorError(cursor);
+  }
+  return decoded;
+}
+
+export class InvalidCursorError extends Error {
+  constructor(cursor: string) {
+    super(`invalid pagination cursor: ${cursor}`);
+    this.name = "InvalidCursorError";
+  }
+}
diff --git a/src/api/transactions.ts b/src/api/transactions.ts
index 7c9e1f0..b4d5a21 100644
--- a/src/api/transactions.ts
+++ b/src/api/transactions.ts
@@ -1,45 +1,64 @@
 import { db } from "../db";
 import { Transaction } from "../models";
+import { encodeCursor, decodeCursor } from "./cursor";
 
 const DEFAULT_LIMIT = 25;
 const MAX_LIMIT = 100;
 
 export interface ListOptions {
   limit?: number;
-  offset?: number;
+  cursor?: string;
 }
 
-export async function listTransactions(
-  accountId: string,
-  opts: ListOptions = {},
-): Promise<Transaction[]> {
-  const limit = Math.min(opts.limit ?? DEFAULT_LIMIT, MAX_LIMIT);
-  const offset = opts.offset ?? 0;
-  return db.transactions.find({
-    where: { accountId },
-    sort: { id: -1 },
-    limit,
-    offset,
-  });
+export interface Page<T> {
+  items: T[];
+  nextCursor: string | null;
 }
 
-export async function accountBalance(accountId: string): Promise<number> {
-  const txns = await listTransactions(accountId, { limit: MAX_LIMIT });
-  let total = 0;
-  for (const t of txns) {
-    total += t.amount;
-  }
-  return total;
+// Transactions are returned newest-first (descending id). To page forward we
+// ask for everything strictly older than the caller's cursor. We over-fetch by
+// one row so we can tell whether another page exists without a second query.
+export async function listTransactions(
+  accountId: string,
+  opts: ListOptions = {},
+): Promise<Page<Transaction>> {
+  const limit = Math.min(opts.limit ?? DEFAULT_LIMIT, MAX_LIMIT);
+
+  const where: Record<string, unknown> = { accountId };
+  if (opts.cursor) {
+    where.id = { lt: decodeCursor(opts.cursor) };
+  }
+
+  const rows = await db.transactions.find({
+    where,
+    sort: { id: -1 },
+    limit: limit + 1,
+  });
+
+  const hasMore = rows.length > limit;
+  const items = hasMore ? rows.slice(0, limit) : rows;
+  const nextCursor = hasMore ? encodeCursor(rows[rows.length - 1].id) : null;
+
+  return { items, nextCursor };
+}
+
+export async function accountBalance(accountId: string): Promise<number> {
+  const { items } = await listTransactions(accountId, { limit: MAX_LIMIT });
+  return items.reduce((sum, t) => sum + t.amount, 0);
 }
diff --git a/src/api/handlers.ts b/src/api/handlers.ts
index 3f0aa10..9d1c2e8 100644
--- a/src/api/handlers.ts
+++ b/src/api/handlers.ts
@@ -12,10 +12,15 @@ export async function getTransactions(req: Request, res: Response) {
   const accountId = req.params.accountId;
-  const offset = Number(req.query.offset ?? 0);
-  const limit = Number(req.query.limit ?? 25);
-  const txns = await listTransactions(accountId, { limit, offset });
-  res.json({ data: txns });
+  const limit = req.query.limit ? Number(req.query.limit) : undefined;
+  const cursor = typeof req.query.cursor === "string" ? req.query.cursor : undefined;
+  const page = await listTransactions(accountId, { limit, cursor });
+  res.json({
+    data: page.items,
+    // `next` is null on the final page.
+    next: page.nextCursor,
+  });
 }
```
</details>

