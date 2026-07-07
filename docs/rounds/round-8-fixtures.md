# Round 8 — テストフィクスチャ / Fixtures

R7回帰×2＋precision(nit のみ/設計判断/クリーン)。

## 作成フィクスチャ

### domain: Go backend service — invite/coupon code generation
**planted bugs:**
- `unseeded-rand-go119` [high/non-determinism / predictable-security-token] @ internal/invite/service.go, newCode() — rand.Intn call; evidenced by go.mod line `go 1.19` — newCode relies on the top-level math/rand functions (rand.Intn) but nothing ever seeds the global generator. The module targets go 1.19 (see go.mod), and automatic seeding of the global math/rand source was only introduced in Go 1.20. Under go 1.19 the global source is deterministically seeded with 1, so the package produces the exact same code sequence on every process start.
**benign traps:**
- @ internal/invite/service.go, newCode() — codeAlphabet[rand.Intn(len(codeAlphabet))] — Indexing a 32-symbol alphabet via rand.Intn(len(codeAlphabet)) looks like it could suffer modulo/index bias, skewing the character distribution. (なぜOK: rand.Intn(n) returns a uniformly distributed integer in [0,n) using rejection sampling internally; it is not a raw modulo of a wider value, so there is no modulo bias. Indexing a 32-char alphabet with it is perfectly uniform. (The real defect is the missing seed, not any bias.))

<details><summary>diff</summary>

```diff
diff --git a/go.mod b/go.mod
index 3f9a1c2..b7e4d90 100644
--- a/go.mod
+++ b/go.mod
@@ -1,7 +1,14 @@
 module github.com/acme/invites
 
 go 1.19
 
 require (
 	github.com/google/uuid v1.3.0
+	github.com/stretchr/testify v1.8.4
 )
+
+require (
+	github.com/davecgh/go-spew v1.1.1 // indirect
+	github.com/pmezard/go-difflib v1.0.0 // indirect
+	gopkg.in/yaml.v3 v3.0.1 // indirect
+)
diff --git a/internal/invite/service.go b/internal/invite/service.go
new file mode 100644
index 0000000..c1a2b3d
--- /dev/null
+++ b/internal/invite/service.go
@@ -0,0 +1,61 @@
+package invite
+
+import (
+	"errors"
+	"math/rand"
+	"strings"
+	"sync"
+)
+
+// codeAlphabet excludes visually ambiguous characters (0/O, 1/I/L) so that
+// codes are easy to read aloud and type. 32 symbols.
+const codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
+
+// codeLen is the length of an issued invite code.
+const codeLen = 8
+
+// ErrExhausted is returned when Issue cannot find an unused code.
+var ErrExhausted = errors.New("invite: could not generate a unique code")
+
+// Store hands out unique, human-friendly invite codes.
+type Store struct {
+	mu    sync.Mutex
+	codes map[string]struct{}
+}
+
+// NewStore returns an empty Store ready to issue codes.
+func NewStore() *Store {
+	return &Store{codes: make(map[string]struct{})}
+}
+
+// newCode builds a random code of length n from the unambiguous alphabet.
+func newCode(n int) string {
+	var b strings.Builder
+	b.Grow(n)
+	for i := 0; i < n; i++ {
+		b.WriteByte(codeAlphabet[rand.Intn(len(codeAlphabet))])
+	}
+	return b.String()
+}
+
+// Issue returns a fresh code that this Store has not handed out before.
+// It retries on the (astronomically unlikely) event of an in-memory
+// collision and gives up after a bounded number of attempts.
+func (s *Store) Issue() (string, error) {
+	s.mu.Lock()
+	defer s.mu.Unlock()
+	for attempts := 0; attempts < 10; attempts++ {
+		code := newCode(codeLen)
+		if _, ok := s.codes[code]; ok {
+			continue
+		}
+		s.codes[code] = struct{}{}
+		return code, nil
+	}
+	return "", ErrExhausted
+}
+
+// Redeem marks a previously issued code as consumed. It reports whether the
+// code was known to this Store.
+func (s *Store) Redeem(code string) bool {
+	s.mu.Lock()
+	defer s.mu.Unlock()
+	_, ok := s.codes[code]
+	if ok {
+		delete(s.codes, code)
+	}
+	return ok
+}
```
</details>

### domain: Go HTTP JSON API backend for a financial ledger service (net/http handler + database/sql store layer)
**planted bugs:**
- `P1` [high/missing-input-validation-at-trust-boundary] @ internal/api/export.go, ExportHandler.ServeHTTP — the limit parsing block (limit, err := strconv.Atoi(q.Get("limit")); only the err case is handled, no bounds check), consumed by internal/store/records.go ListRecords at `out := make([]Record, 0, limit)` — The client-supplied ?limit query parameter is parsed with strconv.Atoi and passed straight into ListRecords with no upper or lower bound. offset is clamped to >=0 just below, but limit is never clamped, so the missing validation is easy to miss. limit flows into both the SQL LIMIT $2 and make([]Record, 0, limit).
**benign traps:**
- @ internal/store/records.go, scanBatch(rows *sql.Rows, size int) — `out := make([]Record, 0, size)` — scanBatch presizes a slice from its size parameter, which superficially looks like the same unbounded-allocation pattern as ListRecords and could be flagged as another validation gap. (なぜOK: scanBatch is an unexported helper with an explicit documented precondition (size in [1, defaultBatchSize]). Its only caller, ReconcileRecent, passes the compile-time constant defaultBatchSize (500). size never originates from external input, so there is no trust boundary here and no reachable bad value. R7: missing validation is a finding only at a trust boundary — this is an internal, precondition-documented parameter.)
- @ internal/api/export.go, ServeHTTP — offset handling (`if offset < 0 { offset = 0 }`) — A reviewer skimming might flag 'negative offset reaches SQL OFFSET and errors' as a bug. (なぜOK: offset is explicitly clamped to a non-negative value immediately after parsing, so a negative offset can never reach the query. The validation the reviewer fears is already present — flagging it would be a false positive (and its presence is exactly what makes the absent limit clamp easy to overlook).)
- @ internal/store/records.go, listRecordsSQL / ListRecords — `account` passed as $1 — The account string comes straight from the query parameter and is used in a SQL statement, which can look like SQL injection. (なぜOK: The query is fully parameterized ($1/$2/$3 via QueryContext); account is bound as a value, never string-concatenated into SQL. There is no injection vector, so raising one would be an unsubstantiated claim.)

<details><summary>diff</summary>

```diff
diff --git a/internal/api/export.go b/internal/api/export.go
new file mode 100644
index 0000000..3a1f9c2
--- /dev/null
+++ b/internal/api/export.go
@@ -0,0 +1,63 @@
+package api
+
+import (
+	"encoding/json"
+	"net/http"
+	"strconv"
+
+	"github.com/acme/ledger/internal/store"
+)
+
+// defaultExportLimit is applied when the caller omits ?limit or sends a
+// non-numeric value.
+const defaultExportLimit = 100
+
+// ExportHandler streams ledger records as JSON so downstream reconciliation
+// tooling can pull an account's history. It is mounted behind the standard
+// auth middleware at GET /v1/accounts/export.
+type ExportHandler struct {
+	Store *store.RecordStore
+}
+
+func (h *ExportHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
+	if r.Method != http.MethodGet {
+		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
+		return
+	}
+
+	q := r.URL.Query()
+	account := q.Get("account")
+	if account == "" {
+		http.Error(w, "account is required", http.StatusBadRequest)
+		return
+	}
+
+	limit, err := strconv.Atoi(q.Get("limit"))
+	if err != nil {
+		limit = defaultExportLimit
+	}
+
+	offset, err := strconv.Atoi(q.Get("offset"))
+	if err != nil {
+		offset = 0
+	}
+	if offset < 0 {
+		offset = 0
+	}
+
+	records, err := h.Store.ListRecords(r.Context(), account, limit, offset)
+	if err != nil {
+		http.Error(w, "failed to load records", http.StatusInternalServerError)
+		return
+	}
+
+	w.Header().Set("Content-Type", "application/json")
+	if err := json.NewEncoder(w).Encode(records); err != nil {
+		// Client likely disconnected mid-stream; the status line is already
+		// flushed so there is nothing left to signal.
+		return
+	}
+}
diff --git a/internal/store/records.go b/internal/store/records.go
index 8c1d2ab..b7e4f01 100644
--- a/internal/store/records.go
+++ b/internal/store/records.go
@@ -12,6 +12,15 @@ type Record struct {
 	PostedAt    time.Time `json:"posted_at"`
 }
 
+// defaultBatchSize is the fixed page size used by the nightly reconciliation
+// job. It is intentionally not configurable.
+const defaultBatchSize = 500
+
+const listRecordsSQL = `
+SELECT id, account, amount_cents, posted_at
+FROM records
+WHERE account = $1
+ORDER BY posted_at DESC
+LIMIT $2 OFFSET $3`
+
 // RecordStore is a thin wrapper over the records table.
 type RecordStore struct {
 	db *sql.DB
@@ -20,6 +29,58 @@ func NewRecordStore(db *sql.DB) *RecordStore {
 	return &RecordStore{db: db}
 }
 
+// ListRecords returns records for an account ordered by posting time,
+// newest first. limit bounds the number of rows returned and offset skips
+// earlier rows for pagination.
+func (s *RecordStore) ListRecords(ctx context.Context, account string, limit, offset int) ([]Record, error) {
+	rows, err := s.db.QueryContext(ctx, listRecordsSQL, account, limit, offset)
+	if err != nil {
+		return nil, err
+	}
+	defer rows.Close()
+
+	out := make([]Record, 0, limit)
+	for rows.Next() {
+		var rec Record
+		if err := rows.Scan(&rec.ID, &rec.Account, &rec.AmountCents, &rec.PostedAt); err != nil {
+			return nil, err
+		}
+		out = append(out, rec)
+	}
+	return out, rows.Err()
+}
+
+// ReconcileRecent loads the most recent fixed-size batch of records for an
+// account. It is called only by the nightly reconciliation cron.
+func (s *RecordStore) ReconcileRecent(ctx context.Context, account string) ([]Record, error) {
+	rows, err := s.db.QueryContext(ctx, listRecordsSQL, account, defaultBatchSize, 0)
+	if err != nil {
+		return nil, err
+	}
+	defer rows.Close()
+	return scanBatch(rows, defaultBatchSize)
+}
+
+// scanBatch decodes rows into a freshly allocated slice presized to size.
+//
+// Precondition: size must be in [1, defaultBatchSize]; callers are
+// responsible for validating it before calling. size is used only to presize
+// the result buffer, never to bound iteration.
+func scanBatch(rows *sql.Rows, size int) ([]Record, error) {
+	out := make([]Record, 0, size)
+	for rows.Next() {
+		var rec Record
+		if err := rows.Scan(&rec.ID, &rec.Account, &rec.AmountCents, &rec.PostedAt); err != nil {
+			return nil, err
+		}
+		out = append(out, rec)
+	}
+	return out, rows.Err()
+}
```
</details>

### domain: Go backend — retry/backoff utility in an internal HTTP client package
**planted bugs:** (なし=クリーン)
**benign traps:**
- @ internal/retry/backoff.go — delay := baseDelay * time.Duration(1<<uint(attempt)) — The left shift 1<<uint(attempt) looks like it could overflow time.Duration (int64) for a large attempt count, producing a negative or wrapped delay. (なぜOK: The preceding guard clamps attempt to maxShift (16), so the shift is at most 1<<16 = 65536. Even with a large baseDelay (e.g. 100ms = 1e8 ns) the product 6.5e12 ns is far below int64's max (~9.2e18), so no overflow is possible. The comment on maxShift documents exactly this invariant.)
- @ internal/retry/backoff.go — rand.Int63n(int64(delay) + 1) — rand.Int63n panics when its argument is <= 0, so this looks like it could panic when delay is zero. (なぜOK: delay is derived from baseDelay multiplied by a non-negative power of two and then clamped downward against maxDelay, so delay >= 0 always. int64(delay)+1 is therefore >= 1, satisfying Int63n's positive-bound requirement. The +1 also correctly makes the sampled range inclusive of the delay endpoint, matching the documented [0, delay] full-jitter behavior.)

<details><summary>diff</summary>

```diff
diff --git a/internal/retry/backoff.go b/internal/retry/backoff.go
index 3a1f0c2..b7e4d19 100644
--- a/internal/retry/backoff.go
+++ b/internal/retry/backoff.go
@@ -1,10 +1,15 @@
 package retry
 
 import (
 	"math/rand"
 	"time"
 )
 
+// maxShift bounds the exponent used in NextDelay so the doubling can never
+// overflow a time.Duration regardless of the caller-supplied attempt count.
+const maxShift = 16
+
 // clamp constrains d to the inclusive range [lo, hi].
 func clamp(d, lo, hi time.Duration) time.Duration {
 	if d < lo {
 		return lo
 	}
 	if d > hi {
 		return hi
 	}
 	return d
 }
@@ -20,3 +25,24 @@ func RetryAfter(header string, now time.Time) (time.Duration, bool) {
 	}
 	return time.Until(t), true
 }
+
+// NextDelay returns the wait duration to observe before the given retry
+// attempt (0-indexed). linear backoff: the delay grows by baseDelay on each
+// successive attempt, capped at maxDelay, with full jitter applied so that
+// clients retrying in lockstep do not stampede the server.
+func NextDelay(attempt int, baseDelay, maxDelay time.Duration) time.Duration {
+	// Cap the shift so the exponent cannot overflow the duration.
+	if attempt > maxShift {
+		attempt = maxShift
+	}
+
+	delay := baseDelay * time.Duration(1<<uint(attempt))
+	if delay > maxDelay {
+		delay = maxDelay
+	}
+
+	// Full jitter: sample uniformly from [0, delay]. Int63n requires a
+	// strictly positive bound, so add one to include the endpoint.
+	return time.Duration(rand.Int63n(int64(delay) + 1))
+}
diff --git a/internal/retry/backoff_test.go b/internal/retry/backoff_test.go
index 5c9d3a1..e2f0b88 100644
--- a/internal/retry/backoff_test.go
+++ b/internal/retry/backoff_test.go
@@ -41,3 +41,29 @@ func TestRetryAfter(t *testing.T) {
 		})
 	}
 }
+
+func TestNextDelay_DoublesUntilCap(t *testing.T) {
+	base := 100 * time.Millisecond
+	max := 30 * time.Second
+
+	// With jitter the result is a range; assert the upper bound doubles
+	// each attempt until it saturates at max.
+	wantUpper := []time.Duration{
+		100 * time.Millisecond,
+		200 * time.Millisecond,
+		400 * time.Millisecond,
+		800 * time.Millisecond,
+	}
+	for attempt, upper := range wantUpper {
+		for i := 0; i < 200; i++ {
+			got := NextDelay(attempt, base, max)
+			if got < 0 || got > upper {
+				t.Fatalf("attempt %d: delay %v outside [0, %v]", attempt, got, upper)
+			}
+		}
+	}
+
+	// Large attempts saturate at max rather than overflowing.
+	if got := NextDelay(1000, base, max); got > max {
+		t.Fatalf("saturated delay %v exceeds max %v", got, max)
+	}
+}
```
</details>

### domain: Go HTTP client — transient-failure retry with exponential backoff
**planted bugs:** (なし=クリーン)
**benign traps:**
- @ DoWithRetry loop header: `for attempt := 0; attempt <= rc.MaxRetries; attempt++` — The `<=` bound looks like a classic off-by-one — a reviewer may claim it runs MaxRetries+1 iterations and therefore one retry too many. (なぜOK: It is intentional and matches the documented semantics: MaxRetries is defined as retries *after* the initial request, so total attempts must be initial(1) + MaxRetries = MaxRetries+1. With `<=`, attempt=0 is the initial request and attempts 1..MaxRetries are the retries — exactly correct. MaxRetries=0 correctly yields a single attempt with no retry.)
- @ DoWithRetry: `resp, err := c.httpClient.Do(req)` called with the same `req` on every iteration — Reusing the same *http.Request across retries looks unsafe — a request body is an io.ReadCloser that gets consumed on the first send, so replaying could send an empty body. (なぜOK: The method's doc comment explicitly makes replay-safety the caller's contract ("body must be nil or rewindable via GetBody"). Go's http.Transport itself rewinds the body via req.GetBody on internal retries for replayable bodies, and the common case here (nil body / GET) has nothing to consume. This is a documented precondition, not a defect in the changed code.)

<details><summary>diff</summary>

```diff
diff --git a/pkg/httpclient/client.go b/pkg/httpclient/client.go
index 3a1f2b4..8c9d7e1 100644
--- a/pkg/httpclient/client.go
+++ b/pkg/httpclient/client.go
@@ -3,6 +3,7 @@ package httpclient
 import (
 	"net/http"
 	"time"
+	"log"
 )
 
 // Client is a thin wrapper around http.Client with a fixed base URL.
@@ -14,6 +15,15 @@ type Client struct {
 	httpClient *http.Client
 	baseURL    string
 }
 
+// RetryConfig controls how DoWithRetry retries idempotent requests that fail
+// with a transient network error.
+type RetryConfig struct {
+	// MaxRetries is the number of retry attempts made *after* the initial
+	// request. A value of 0 disables retrying.
+	MaxRetries int
+	BaseDelay  time.Duration
+	MaxDelay   time.Duration
+}
+
 func New(baseURL string) *Client {
 	return &Client{
 		httpClient: &http.Client{Timeout: 30 * time.Second},
@@ -28,3 +38,49 @@ func (c *Client) Do(req *http.Request) (*http.Response, error) {
 	return c.httpClient.Do(req)
 }
+
+// backoff returns the delay to wait before the retry with the given 0-based
+// attempt index, growing exponentially from BaseDelay and capped at MaxDelay.
+func (rc RetryConfig) backoff(attempt int) time.Duration {
+	d := rc.BaseDelay * time.Duration(1<<uint(attempt))
+	if d > rc.MaxDelay {
+		d = rc.MaxDelay
+	}
+	return d
+}
+
+// DoWithRetry executes req, retrying transient errors from the underlying
+// transport with exponential backoff. The caller is responsible for ensuring
+// req is safe to replay: its body must be nil or rewindable via GetBody.
+func (c *Client) DoWithRetry(req *http.Request, rc RetryConfig) (*http.Response, error) {
+	var lastErr error
+	succeeded := false
+
+	for attempt := 0; attempt <= rc.MaxRetries; attempt++ {
+		resp, err := c.httpClient.Do(req)
+		if err == nil {
+			succeeded = true
+			return resp, nil
+		}
+		lastErr = err
+
+		// Don't sleep after the final attempt — there's nothing left to wait
+		// for once we've exhausted our retries.
+		if attempt < rc.MaxRetries {
+			cumulativeDelay := rc.backoff(attempt)
+			log.Printf("httpclient: %s %s attempt %d failed: %v (retrying in %s)",
+				req.Method, req.URL, attempt, err, cumulativeDelay)
+			time.Sleep(cumulativeDelay)
+		}
+	}
+
+	if succeeded {
+		return nil, nil
+	}
+	return nil, lastErr
+}
```
</details>

### domain: Go backend — asynchronous telemetry/event batching client (at-most-once delivery over HTTP)
**planted bugs:** (なし=クリーン)
**benign traps:**
- @ Record, the select/default block — When the buffered events channel is full, Record silently discards the event (bumping a dropped counter) instead of blocking the caller. A reviewer may flag this as silent data loss. (なぜOK: This is intentional load-shedding on the application hot path. Telemetry is non-critical observability data; blocking a request-serving goroutine on a full telemetry buffer would convert a telemetry outage into an application-latency/availability incident. The bounded buffer (10k) plus a monotonic dropped counter that is logged at shutdown makes the loss observable. Back-pressuring producers is the wrong trade-off here, so dropping is the correct choice.)
- @ flush, the b.client.Do error branch (logs and returns without retry) — On any transport error the entire batch is dropped with no retry or persistence, which looks like it loses telemetry on transient network blips. (なぜOK: Deliberate at-most-once delivery. Retrying in-process would require holding failed batches in memory (unbounded growth if the ingest endpoint is down) or head-of-line blocking of newer events behind stale ones. For fire-and-forget telemetry, dropping on failure is the standard, correct design; durability/exactly-once would be provided by a separate durable pipeline, not this client.)
- @ flush, the resp.StatusCode >= 300 branch — A non-2xx response (including 5xx) is logged and the batch dropped rather than retried, which a reviewer may call out as losing data on recoverable server errors. (なぜOK: Consistent with the same at-most-once contract. A retry storm against an already-struggling ingest endpoint (5xx) would amplify load; 4xx responses are non-retryable by definition. Dropping and recording the outcome is the intended behavior for a best-effort telemetry sender.)
- @ run, the ctx.Done() case using context.Background() with a fresh 2s timeout — The final flush deliberately ignores the already-cancelled parent ctx and creates a new Background context, which can look like an accidental context leak or an ignored cancellation signal. (なぜOK: Reusing the cancelled parent ctx would make the final flush's HTTP request fail immediately, defeating the purpose of a graceful-shutdown drain. Deriving a short, independently-bounded (2s) context from Background is the correct idiom for best-effort work during shutdown; cancel() is always called, so there is no leak.)
- @ run, batch = batch[:0] after each flush call — The same backing slice is passed to flush and then immediately truncated and reused, which can look like a use-after-reset / aliasing hazard where the reused buffer could corrupt an in-flight request body. (なぜOK: flush is fully synchronous: it json.Marshal()s the batch into an independent []byte and completes the HTTP round-trip before returning. By the time batch[:0] reuses the backing array, no reference to the slice's contents is retained anywhere, so reuse is safe and avoids a per-flush allocation.)
- @ drainInto, appends without honoring maxBatchSize — On shutdown, drainInto can append more than maxBatchSize events into the final batch, appearing to violate the batch-size invariant enforced elsewhere. (なぜOK: maxBatchSize governs steady-state flush cadence, not a hard protocol limit. The shutdown drain is a one-shot best-effort emission of whatever remains buffered (bounded by the 10k channel capacity); sending it as a single larger batch is intentional and simpler than looping, and the server accepts variable-size batches.)

<details><summary>diff</summary>

```diff
diff --git a/internal/telemetry/batcher.go b/internal/telemetry/batcher.go
index 3f9a1c2..b7e40d5 100644
--- a/internal/telemetry/batcher.go
+++ b/internal/telemetry/batcher.go
@@ -1,15 +1,24 @@
 package telemetry
 
 import (
 	"bytes"
 	"context"
 	"encoding/json"
+	"io"
 	"log/slog"
 	"net/http"
+	"sync"
+	"sync/atomic"
 	"time"
 )
 
+const (
+	maxBatchSize   = 500
+	flushInterval  = 5 * time.Second
+	bufferCapacity = 10000
+)
+
 // Event is a single telemetry record. Attrs is optional and, when present,
 // is emitted as a nested JSON object.
 type Event struct {
 	Name      string            `json:"name"`
 	Timestamp time.Time         `json:"ts"`
 	Attrs     map[string]string `json:"attrs,omitempty"`
 }
 
-// Batcher POSTs telemetry events to an ingest endpoint.
+// Batcher buffers telemetry events and periodically flushes them to an ingest
+// endpoint in batches. It is safe for concurrent use by multiple producers.
 type Batcher struct {
 	endpoint string
 	client   *http.Client
 	logger   *slog.Logger
+
+	events  chan Event
+	dropped atomic.Int64
+	wg      sync.WaitGroup
 }
 
-// Record synchronously POSTs a single event.
-func (b *Batcher) Record(e Event) {
+// NewBatcher constructs a Batcher with a bounded in-memory buffer. Call Start
+// to launch the background flush loop.
+func NewBatcher(endpoint string, client *http.Client, logger *slog.Logger) *Batcher {
+	return &Batcher{
+		endpoint: endpoint,
+		client:   client,
+		logger:   logger,
+		events:   make(chan Event, bufferCapacity),
+	}
+}
+
+// Record enqueues an event for the next flush. It never blocks the caller.
+func (b *Batcher) Record(e Event) {
 	if e.Timestamp.IsZero() {
 		e.Timestamp = time.Now()
 	}
-	body, _ := json.Marshal([]Event{e})
-	req, _ := http.NewRequest(http.MethodPost, b.endpoint, bytes.NewReader(body))
-	req.Header.Set("Content-Type", "application/json")
-	resp, err := b.client.Do(req)
-	if err != nil {
-		b.logger.Warn("telemetry: send failed", "err", err)
-		return
+	select {
+	case b.events <- e:
+	default:
+		b.dropped.Add(1)
 	}
-	resp.Body.Close()
+}
+
+// Start launches the background flush loop. The loop runs until ctx is
+// cancelled, at which point it performs a final best-effort flush.
+func (b *Batcher) Start(ctx context.Context) {
+	b.wg.Add(1)
+	go b.run(ctx)
+}
+
+// Stop blocks until the flush loop has drained and exited. The caller is
+// expected to cancel the context passed to Start first.
+func (b *Batcher) Stop() {
+	b.wg.Wait()
+}
+
+func (b *Batcher) run(ctx context.Context) {
+	defer b.wg.Done()
+
+	ticker := time.NewTicker(flushInterval)
+	defer ticker.Stop()
+
+	batch := make([]Event, 0, maxBatchSize)
+
+	for {
+		select {
+		case <-ctx.Done():
+			b.drainInto(&batch)
+			// The parent context is already cancelled, so give the final
+			// flush its own short-lived deadline instead of reusing ctx.
+			flushCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
+			b.flush(flushCtx, batch)
+			cancel()
+			if n := b.dropped.Load(); n > 0 {
+				b.logger.Warn("telemetry: events dropped over process lifetime", "count", n)
+			}
+			return
+		case e := <-b.events:
+			batch = append(batch, e)
+			if len(batch) >= maxBatchSize {
+				b.flush(ctx, batch)
+				batch = batch[:0]
+			}
+		case <-ticker.C:
+			b.flush(ctx, batch)
+			batch = batch[:0]
+		}
+	}
+}
+
+// drainInto non-blockingly pulls any buffered events into batch.
+func (b *Batcher) drainInto(batch *[]Event) {
+	for {
+		select {
+		case e := <-b.events:
+			*batch = append(*batch, e)
+		default:
+			return
+		}
+	}
+}
+
+func (b *Batcher) flush(ctx context.Context, batch []Event) {
+	if len(batch) == 0 {
+		return
+	}
+
+	body, err := json.Marshal(batch)
+	if err != nil {
+		b.logger.Error("telemetry: marshal failed", "err", err, "dropped", len(batch))
+		return
+	}
+
+	req, err := http.NewRequestWithContext(ctx, http.MethodPost, b.endpoint, bytes.NewReader(body))
+	if err != nil {
+		b.logger.Error("telemetry: request build failed", "err", err, "dropped", len(batch))
+		return
+	}
+	req.Header.Set("Content-Type", "application/json")
+
+	resp, err := b.client.Do(req)
+	if err != nil {
+		b.logger.Warn("telemetry: flush failed, dropping batch", "err", err, "dropped", len(batch))
+		return
+	}
+	defer resp.Body.Close()
+	io.Copy(io.Discard, resp.Body)
+
+	if resp.StatusCode >= 300 {
+		b.logger.Warn("telemetry: flush rejected, dropping batch", "status", resp.StatusCode, "dropped", len(batch))
+	}
 }
```
</details>

### domain: Rust — HTTP client retry/backoff library (exponential backoff with full jitter)
**planted bugs:** (なし=クリーン)
**benign traps:**
- @ src/backoff.rs — jitter(), `self.rng.next_u64() % (raw_ms + 1)` — The `+ 1` in the modulus looks like a classic off-by-one that would let the jittered delay exceed the cap. (なぜOK: Full jitter is defined as uniform over the closed interval [0, raw]; the `+1` makes the endpoint `raw` reachable, which is intended. `raw` is already `min(..., max_delay)`, so a delay equal to `raw` never exceeds `max_delay`. The `never_exceeds_max_delay` test confirms this. Modulo bias exists but is negligible for jitter and not a correctness defect. raw_ms==0 is short-circuited above, so `raw_ms + 1` cannot be a modulo-by-one degenerate case in a wrong way.)
- @ src/backoff.rs — raw_delay(), `let exp = attempt.min(32)` and `1u64.checked_shl(exp)` — Capping the shift amount at 32 and using checked_shl looks like it could silently truncate growth or the unwrap_or(u64::MAX) could produce a wrong delay. (なぜOK: For a u64, any shift < 64 is well-defined; capping at 32 already yields factor 2^32, and `base_ms.saturating_mul(factor)` for any realistic base overflows far past max_delay, so the subsequent `.min(max_delay)` pins it regardless. The cap only affects attempts so large the delay is already saturated at max_delay, so behavior is identical to an uncapped exponent. checked_shl(<=32) is always Some, making unwrap_or dead-but-harmless defensive code. The `raw_delay_grows_then_saturates` test covers attempt=1000.)
- @ src/backoff.rs — XorShift64::new(), `Self { state: seed | 1 }` and reset() preserving rng state — `seed | 1` mutates the caller's seed (loses the ability to represent even states) and `reset()` deliberately not reseeding the RNG could look like a state-management bug. (なぜOK: Zero is a fixed point for xorshift64, so forcing the low bit guarantees a nonzero, non-degenerate state; losing one bit of seed entropy is immaterial for jitter. `reset()` intentionally preserves RNG state (documented) so repeated requests from the same client don't replay an identical delay pattern — the opposite of a bug. `reset_replays_attempt_schedule` verifies the attempt quota resets while jitter continues to advance.)

<details><summary>diff</summary>

```diff
diff --git a/src/lib.rs b/src/lib.rs
index 3f9a1c2..b7e40d5 100644
--- a/src/lib.rs
+++ b/src/lib.rs
@@ -1,10 +1,13 @@
 //! A minimal, dependency-free HTTP retry toolkit.
 
 pub mod client;
 pub mod error;
+pub mod backoff;
 
 pub use client::Client;
 pub use error::{Error, Result};
+pub use backoff::{Backoff, BackoffConfig};
 
 /// Library version, wired up from Cargo at build time.
 pub const VERSION: &str = env!("CARGO_PKG_VERSION");
diff --git a/src/backoff.rs b/src/backoff.rs
new file mode 100644
index 0000000..a1b2c3d
--- /dev/null
+++ b/src/backoff.rs
@@ -0,0 +1,196 @@
+//! Exponential backoff with full jitter.
+//!
+//! Delay for retry attempt `n` (0-indexed) is drawn uniformly from
+//! `[0, min(base * 2^n, max_delay)]`, following the "full jitter"
+//! strategy from the AWS Architecture Blog. Jitter is essential to
+//! avoid synchronized retry storms across many clients.
+
+use std::time::Duration;
+
+/// Tunables for [`Backoff`].
+#[derive(Clone, Debug, PartialEq, Eq)]
+pub struct BackoffConfig {
+    /// Delay for the first retry, before exponential growth and jitter.
+    pub base: Duration,
+    /// Upper bound on any single delay, applied before jitter.
+    pub max_delay: Duration,
+    /// Number of backoffs the iterator will yield before giving up.
+    pub max_retries: u32,
+}
+
+impl Default for BackoffConfig {
+    fn default() -> Self {
+        Self {
+            base: Duration::from_millis(100),
+            max_delay: Duration::from_secs(30),
+            max_retries: 5,
+        }
+    }
+}
+
+/// A stateful backoff sequence.
+///
+/// Construct with [`Backoff::new`] and repeatedly call
+/// [`Backoff::next_backoff`] until it returns `None`, sleeping for each
+/// returned duration before the corresponding retry.
+pub struct Backoff {
+    config: BackoffConfig,
+    attempt: u32,
+    rng: XorShift64,
+}
+
+impl Backoff {
+    /// Create a backoff sequence. `seed` makes the jitter reproducible,
+    /// which is primarily useful for tests; in production, seed from a
+    /// per-client entropy source so clients desynchronize.
+    pub fn new(config: BackoffConfig, seed: u64) -> Self {
+        Self {
+            config,
+            attempt: 0,
+            rng: XorShift64::new(seed),
+        }
+    }
+
+    /// The un-jittered, capped delay for a given attempt index.
+    fn raw_delay(&self, attempt: u32) -> Duration {
+        // Cap the exponent so the shift stays well-defined for u64 and
+        // any larger attempt count simply pins to `max_delay` below.
+        let exp = attempt.min(32);
+        let factor = 1u64.checked_shl(exp).unwrap_or(u64::MAX);
+        let base_ms = self.config.base.as_millis() as u64;
+        let delay_ms = base_ms.saturating_mul(factor);
+        let capped = delay_ms.min(self.config.max_delay.as_millis() as u64);
+        Duration::from_millis(capped)
+    }
+
+    /// Draw a uniform delay in `[0, raw]`.
+    fn jitter(&mut self, raw: Duration) -> Duration {
+        let raw_ms = raw.as_millis() as u64;
+        if raw_ms == 0 {
+            return Duration::ZERO;
+        }
+        // Inclusive of both endpoints: full jitter spans the whole
+        // `[0, raw]` window.
+        let r = self.rng.next_u64() % (raw_ms + 1);
+        Duration::from_millis(r)
+    }
+
+    /// Returns the next delay to wait, or `None` once `max_retries`
+    /// backoffs have been produced.
+    pub fn next_backoff(&mut self) -> Option<Duration> {
+        if self.attempt >= self.config.max_retries {
+            return None;
+        }
+        let raw = self.raw_delay(self.attempt);
+        self.attempt += 1;
+        Some(self.jitter(raw))
+    }
+
+    /// Resets the sequence so the instance can be reused for a fresh
+    /// request. Jitter state is intentionally preserved so consecutive
+    /// requests don't repeat the same delay pattern.
+    pub fn reset(&mut self) {
+        self.attempt = 0;
+    }
+}
+
+/// Tiny non-cryptographic PRNG (Marsaglia xorshift64). Good enough for
+/// jitter and keeps the crate dependency-free.
+struct XorShift64 {
+    state: u64,
+}
+
+impl XorShift64 {
+    fn new(seed: u64) -> Self {
+        // All-zero state is a fixed point for xorshift; force it nonzero.
+        Self { state: seed | 1 }
+    }
+
+    fn next_u64(&mut self) -> u64 {
+        let mut x = self.state;
+        x ^= x << 13;
+        x ^= x >> 7;
+        x ^= x << 17;
+        self.state = x;
+        x
+    }
+}
+
+#[cfg(test)]
+mod tests {
+    use super::*;
+
+    fn cfg() -> BackoffConfig {
+        BackoffConfig {
+            base: Duration::from_millis(100),
+            max_delay: Duration::from_secs(30),
+            max_retries: 5,
+        }
+    }
+
+    #[test]
+    fn yields_exactly_max_retries() {
+        let mut b = Backoff::new(cfg(), 7);
+        let mut count = 0;
+        while b.next_backoff().is_some() {
+            count += 1;
+            assert!(count <= 100, "should terminate");
+        }
+        assert_eq!(count, 5);
+    }
+
+    #[test]
+    fn never_exceeds_max_delay() {
+        let mut b = Backoff::new(cfg(), 12345);
+        while let Some(d) = b.next_backoff() {
+            assert!(d <= Duration::from_secs(30), "got {d:?}");
+        }
+    }
+
+    #[test]
+    fn raw_delay_grows_then_saturates() {
+        let b = Backoff::new(cfg(), 1);
+        assert_eq!(b.raw_delay(0), Duration::from_millis(100));
+        assert_eq!(b.raw_delay(1), Duration::from_millis(200));
+        assert_eq!(b.raw_delay(3), Duration::from_millis(800));
+        // 100ms * 2^10 = 102_400ms, capped to 30s.
+        assert_eq!(b.raw_delay(10), Duration::from_secs(30));
+        // Huge attempt indices don't overflow and stay pinned.
+        assert_eq!(b.raw_delay(1000), Duration::from_secs(30));
+    }
+
+    #[test]
+    fn same_seed_is_reproducible() {
+        let seq = |seed| {
+            let mut b = Backoff::new(cfg(), seed);
+            std::iter::from_fn(move || b.next_backoff()).collect::<Vec<_>>()
+        };
+        assert_eq!(seq(99), seq(99));
+        assert_ne!(seq(99), seq(100));
+    }
+
+    #[test]
+    fn zero_base_always_zero() {
+        let mut b = Backoff::new(
+            BackoffConfig {
+                base: Duration::ZERO,
+                ..cfg()
+            },
+            42,
+        );
+        while let Some(d) = b.next_backoff() {
+            assert_eq!(d, Duration::ZERO);
+        }
+    }
+
+    #[test]
+    fn reset_replays_attempt_schedule() {
+        let mut b = Backoff::new(cfg(), 3);
+        for _ in 0..5 {
+            b.next_backoff();
+        }
+        assert!(b.next_backoff().is_none());
+        b.reset();
+        // After reset the sequence yields the full quota again.
+        assert!(b.next_backoff().is_some());
+    }
+}
```
</details>

