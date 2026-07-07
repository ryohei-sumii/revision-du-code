# Round 6 — テストフィクスチャ / Fixtures

回帰(ReDoS本物/良性そっくり/未アンカー)＋precision(テスト未追加/暗号そっくり/リファクタそっくり)。

## 作成フィクスチャ

### domain: Node.js / Express REST API — user profile input validation
**planted bugs:**
- `redos-displayname` [critical/redos] @ src/validators/profile.js — DISPLAY_NAME_RE = /^([A-Za-z0-9]+ ?)*$/, tested in validateDisplayName against unbounded user input — Catastrophic ReDoS. The pattern nests an unbounded quantifier (+) inside an unbounded group repetition (*) — `([A-Za-z0-9]+ ?)*` — with an anchored `$`. For a run of word characters containing no space, the group can partition that run in 2^(N-1) distinct ways, all of which the backtracking V8 engine must exhaust before it can fail the anchor. displayName comes straight from req.body with no length cap and is tested synchronously on the request thread, blocking the Node event loop.
- `tags-some-not-every` [high/logic/validation-bypass] @ src/validators/profile.js — validateTags, `const allValid = tags.some(...)` — Uses Array.prototype.some instead of every to validate the tags array. `some` returns true if AT LEAST ONE tag is a valid string matching TAG_RE, so the whole array is accepted as long as one element is valid — every other element (invalid strings, or even non-string values like objects/numbers) passes validation and is persisted via req.user.update({ tags }).
**benign traps:**
- @ src/validators/profile.js — TAG_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/ — Also nests a quantified group under `*` — `(-[a-z0-9]+)*` — and a hasty reviewer flags it as a second ReDoS alongside DISPLAY_NAME_RE. (なぜOK: Not ambiguous: every group iteration is forced to begin with a literal `-`, and `-` is excluded from the inner `[a-z0-9]+` class. There is exactly one way to segment any input, so matching is linear. Verified: `'a-'.repeat(40) + '!'` and `'a'.repeat(40) + '!'` both run in ~0.1ms.)
- @ src/validators/profile.js — validateTags, `if (tags.length > MAX_TAGS)` — Uses `>` rather than `>=` against MAX_TAGS = 20, which can look like an off-by-one that permits 21 tags. (なぜOK: `length > 20` rejects 21+ and accepts exactly 20, which is the intended inclusive maximum of 20 tags. Correct boundary.)
- @ src/routes/profile.js — `const { bio, displayName, tags = [] } = req.body` — Only `tags` gets a default; a reviewer may worry undefined displayName/bio crashes validation. (なぜOK: validateBio and validateDisplayName both begin with a `typeof x !== 'string'` guard that returns a clean {ok:false} error for undefined, so missing fields yield a 400 rather than a throw. The `tags = []` default is a deliberate convenience so tags is optional; the other two are effectively required by their type guards.)

<details><summary>diff</summary>

```diff
diff --git a/src/validators/profile.js b/src/validators/profile.js
index 3a1f2c4..b7e9d10 100644
--- a/src/validators/profile.js
+++ b/src/validators/profile.js
@@ -1,6 +1,15 @@
 const MAX_BIO_LENGTH = 500;
+const MAX_TAGS = 20;
+
+// Display name: letters and digits, single spaces allowed between words.
+// e.g. "Ada Lovelace", "user42", "Grace Hopper 2"
+const DISPLAY_NAME_RE = /^([A-Za-z0-9]+ ?)*$/;
+
+// Tag: a lowercase alphanumeric word, optionally hyphenated.
+// e.g. "javascript", "machine-learning", "web3"
+const TAG_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
 
 function validateBio(bio) {
   if (typeof bio !== 'string') {
     return { ok: false, error: 'bio must be a string' };
   }
@@ -8,8 +17,44 @@ function validateBio(bio) {
   if (bio.length > MAX_BIO_LENGTH) {
     return { ok: false, error: 'bio too long' };
   }
   return { ok: true };
 }
 
-module.exports = { validateBio };
+function validateDisplayName(name) {
+  if (typeof name !== 'string') {
+    return { ok: false, error: 'displayName must be a string' };
+  }
+  if (!DISPLAY_NAME_RE.test(name)) {
+    return { ok: false, error: 'displayName has invalid characters' };
+  }
+  return { ok: true };
+}
+
+function validateTags(tags) {
+  if (!Array.isArray(tags)) {
+    return { ok: false, error: 'tags must be an array' };
+  }
+  if (tags.length > MAX_TAGS) {
+    return { ok: false, error: 'too many tags' };
+  }
+  const allValid = tags.some(
+    (t) => typeof t === 'string' && TAG_RE.test(t)
+  );
+  if (!allValid) {
+    return { ok: false, error: 'one or more tags are invalid' };
+  }
+  return { ok: true };
+}
+
+function validateProfile({ bio, displayName, tags }) {
+  for (const check of [
+    validateBio(bio),
+    validateDisplayName(displayName),
+    validateTags(tags),
+  ]) {
+    if (!check.ok) return check;
+  }
+  return { ok: true };
+}
+
+module.exports = {
+  validateBio,
+  validateDisplayName,
+  validateTags,
+  validateProfile,
+};
diff --git a/src/routes/profile.js b/src/routes/profile.js
index 5c8a1b2..e4d7f36 100644
--- a/src/routes/profile.js
+++ b/src/routes/profile.js
@@ -1,20 +1,26 @@
 const express = require('express');
 const router = express.Router();
-const { validateBio } = require('../validators/profile');
+const { validateProfile } = require('../validators/profile');
 
 router.patch('/profile', async (req, res) => {
-  const { bio } = req.body;
-  const bioCheck = validateBio(bio);
-  if (!bioCheck.ok) {
-    return res.status(400).json({ error: bioCheck.error });
-  }
+  const { bio, displayName, tags = [] } = req.body;
 
-  await req.user.update({ bio });
+  const check = validateProfile({ bio, displayName, tags });
+  if (!check.ok) {
+    return res.status(400).json({ error: check.error });
+  }
+
+  await req.user.update({ bio, displayName, tags });
   return res.json({ ok: true });
 });
 
 module.exports = router;
```
</details>

### domain: Go backend — OAuth/login post-authentication redirect allowlist validation (open-redirect defense)
**planted bugs:**
- `P1` [critical/regex-anchoring / open-redirect (auth bypass)] @ internal/auth/redirect.go — buildHostPattern (the regexp compiled from the allowlist), consumed by IsSafeRedirect — The refactor replaces the anchored host validator `\A([a-z0-9-]+\.)*example\.com\z` with a dynamically built pattern `([a-z0-9-]+\.)*<domain>` joined by `|`, with NO `\A`/`\z` anchors. regexp.MatchString performs an unanchored substring search, so any host that merely CONTAINS an allowed domain as a substring passes.
**benign traps:**
- @ internal/auth/redirect.go — safePathRe — The same-origin path regex character class is changed from `[a-zA-Z0-9/_.-]` to `[\w/.-]` (pattern goes `\A/[a-zA-Z0-9/_.-]*\z` -> `\A/[\w/.-]*\z`). (なぜOK: In Go's RE2, `\w` is exactly `[0-9A-Za-z_]`, so `[\w/.-]` denotes the identical set as `[a-zA-Z0-9/_.-]` (underscore is covered by `\w`). The pattern remains anchored with `\A...\z`, and Go's `$`/`\z` semantics are end-of-text (no multiline by default), so there is no newline-injection weakening. Behavior is unchanged — alarming-looking but a pure cosmetic simplification.)
- @ internal/auth/redirect.go — buildHostPattern (regexp.QuoteMeta + strings.ToLower) — Domain values are passed through regexp.QuoteMeta and lowercased before being embedded in the pattern. (なぜOK: QuoteMeta correctly escapes regex metacharacters (e.g. the `.` in `example.com` becomes literal `\.`), so a configured domain cannot inject regex operators or turn `.` into a wildcard. Lowercasing both the domain and the parsed hostname makes the case-insensitive comparison correct. These lines are defensively sound; the vulnerability is solely the missing anchors, not the escaping.)
- @ internal/auth/redirect.go — SetAllowedDomains empty-slice guard — SetAllowedDomains returns early on an empty slice instead of applying it. (なぜOK: This is a deliberate fail-safe: an empty/mis-parsed config keeps the existing (default) allowlist rather than compiling `regexp.MustCompile("")`, which matches every string and would allow all hosts. The guard prevents a fail-open configuration and is correct, not a bug.)
- @ internal/auth/redirect_test.go — added subdomain/tenant test cases — New assertions accept `https://team.eu.example.com/` and `https://portal.acme.io/home`. (なぜOK: Both are legitimately in-scope: multi-level subdomains of an allowed domain and a subdomain of an explicitly configured tenant domain are intended to pass. The tests are correct expectations; they simply fail to include a substring-attack case (e.g. `example.com.evil.com`), which is why the P1 regression slips through — a test-coverage gap, not a wrong assertion.)

<details><summary>diff</summary>

```diff
diff --git a/internal/auth/redirect.go b/internal/auth/redirect.go
index 3a1f9c2..b7e40d1 100644
--- a/internal/auth/redirect.go
+++ b/internal/auth/redirect.go
@@ -5,20 +5,44 @@ import (
 	"regexp"
 	"strings"
 )
 
-// redirectHostRe matches example.com and any of its subdomains.
-var redirectHostRe = regexp.MustCompile(`\A([a-z0-9-]+\.)*example\.com\z`)
+// hostPattern matches any allowed redirect host. It is rebuilt from the
+// configured allowlist via SetAllowedDomains; the default covers our own
+// domain and its subdomains.
+var hostPattern = buildHostPattern([]string{"example.com"})
 
 // safePathRe matches an absolute, same-origin request path.
-var safePathRe = regexp.MustCompile(`\A/[a-zA-Z0-9/_.-]*\z`)
+var safePathRe = regexp.MustCompile(`\A/[\w/.-]*\z`)
+
+// buildHostPattern compiles a single regexp that matches any of the given
+// domains or their subdomains, e.g. "example.com" also matches
+// "app.example.com" and "team.eu.example.com".
+func buildHostPattern(domains []string) *regexp.Regexp {
+	alts := make([]string, 0, len(domains))
+	for _, d := range domains {
+		alts = append(alts, `([a-z0-9-]+\.)*`+regexp.QuoteMeta(strings.ToLower(d)))
+	}
+	return regexp.MustCompile(strings.Join(alts, "|"))
+}
+
+// SetAllowedDomains reconfigures the redirect allowlist for multi-tenant
+// deployments. It should be called once at startup, before any requests are
+// served. Passing an empty slice keeps the current allowlist.
+func SetAllowedDomains(domains []string) {
+	if len(domains) == 0 {
+		return
+	}
+	hostPattern = buildHostPattern(domains)
+}
 
 // IsSafeRedirect reports whether rawURL is safe to use as a post-login
 // redirect target: either a same-origin path or a URL whose host is on the
 // allowlist.
 func IsSafeRedirect(rawURL string) bool {
 	u, err := url.Parse(rawURL)
 	if err != nil {
 		return false
 	}
 	if u.Host == "" {
 		return safePathRe.MatchString(u.Path)
 	}
-	return redirectHostRe.MatchString(strings.ToLower(u.Hostname()))
+	return hostPattern.MatchString(strings.ToLower(u.Hostname()))
 }
diff --git a/internal/auth/redirect_test.go b/internal/auth/redirect_test.go
index c11a2f8..e9d5b3a 100644
--- a/internal/auth/redirect_test.go
+++ b/internal/auth/redirect_test.go
@@ -14,10 +14,22 @@ func TestIsSafeRedirect(t *testing.T) {
 		{"/dashboard", true},
 		{"/reports/2026-07", true},
 		{"https://example.com/", true},
 		{"https://app.example.com/dashboard", true},
+		{"https://team.eu.example.com/", true},
 		{"https://evil.com/", false},
 		{"ht!tp://[::bad", false},
 	}
 	for _, tc := range cases {
 		if got := IsSafeRedirect(tc.in); got != tc.want {
 			t.Errorf("IsSafeRedirect(%q) = %v, want %v", tc.in, got, tc.want)
 		}
 	}
 }
+
+func TestSetAllowedDomains(t *testing.T) {
+	SetAllowedDomains([]string{"acme.io", "example.com"})
+	t.Cleanup(func() { SetAllowedDomains([]string{"example.com"}) })
+	if !IsSafeRedirect("https://portal.acme.io/home") {
+		t.Fatal("expected configured tenant domain to be allowed")
+	}
+}
```
</details>

### domain: Backend HTTP service (Go) — per-client token-bucket rate limiting middleware
**planted bugs:** (なし=クリーン)
**benign traps:**
- @ internal/ratelimit/limiter.go — cleanup(), the for/range loop calling delete(l.buckets, key) — Deletes map entries while ranging over the same map, which a hasty reviewer may flag as 'mutating a map during iteration' / undefined behavior. (なぜOK: The Go language spec explicitly permits deleting entries during a range over a map: 'The iteration order over maps is not specified... If a map entry that has not yet been reached is removed during iteration, the corresponding iteration value will not be produced.' Deletion during range is safe and idiomatic (verified: a range+delete loop reduces the map and never panics). The whole method holds l.mu, so there is no concurrent-access race either.)
- @ internal/ratelimit/limiter.go — New() starts `go l.janitor()`; internal/server/server.go — limiter created but Stop() never called — New() launches a background goroutine, and the server wiring never calls limiter.Stop(), which looks like a goroutine leak. (なぜOK: Stop() is provided and documented, and the janitor exits cleanly on the stop channel. In server.New the limiter's lifetime is intentionally tied to the process-lifetime *http.Server; a single long-lived limiter with one background goroutine is the intended design, not a leak. A leak would only matter if servers were created and discarded in a loop, which this code path does not do. This is at most a stylistic nit, not a defect.)
- @ internal/httpx/ratelimit.go — ClientIP uses r.RemoteAddr and does NOT consult X-Forwarded-For — Rate-limiting by r.RemoteAddr can look wrong to a reviewer who expects X-Forwarded-For handling behind a proxy, or conversely a security reviewer may hunt for XFF spoofing here. (なぜOK: Using RemoteAddr is the safe default for a rate-limit key precisely because it is set by the Go net/http server from the accepted TCP connection and cannot be spoofed by the client, unlike X-Forwarded-For. Trusting XFF without a vetted trusted-proxy list would be the actual vulnerability. The comment documents this intent. Whether to honor XFF is a deployment/design decision, not a correctness bug in the changed code.)

<details><summary>diff</summary>

```diff
diff --git a/internal/ratelimit/limiter.go b/internal/ratelimit/limiter.go
new file mode 100644
index 0000000..3f9a1c2
--- /dev/null
+++ b/internal/ratelimit/limiter.go
@@ -0,0 +1,118 @@
+// Package ratelimit implements a per-key token-bucket rate limiter.
+package ratelimit
+
+import (
+	"sync"
+	"time"
+)
+
+// Limiter is a token-bucket rate limiter keyed by an arbitrary string
+// (typically a client IP or API key). It is safe for concurrent use.
+//
+// Each key gets its own bucket that refills continuously at rate tokens per
+// second up to a maximum of burst tokens. Buckets that have not been touched
+// within ttl are evicted by a background janitor so the map does not grow
+// without bound. ttl must be a positive duration.
+type Limiter struct {
+	mu      sync.Mutex
+	buckets map[string]*bucket
+	rate    float64 // tokens replenished per second
+	burst   float64 // maximum tokens a bucket may hold
+	ttl     time.Duration
+	now     func() time.Time // injectable clock for tests
+	stop    chan struct{}
+}
+
+type bucket struct {
+	tokens   float64
+	lastSeen time.Time
+}
+
+// New constructs a Limiter and starts its background janitor. Callers must
+// invoke Stop when the Limiter is no longer needed to release the janitor
+// goroutine.
+func New(rate, burst float64, ttl time.Duration) *Limiter {
+	l := &Limiter{
+		buckets: make(map[string]*bucket),
+		rate:    rate,
+		burst:   burst,
+		ttl:     ttl,
+		now:     time.Now,
+		stop:    make(chan struct{}),
+	}
+	go l.janitor()
+	return l
+}
+
+// Allow reports whether a request identified by key may proceed, consuming a
+// single token when it returns true.
+func (l *Limiter) Allow(key string) bool {
+	l.mu.Lock()
+	defer l.mu.Unlock()
+
+	now := l.now()
+	b, ok := l.buckets[key]
+	if !ok {
+		// A brand-new client starts with a full bucket.
+		b = &bucket{tokens: l.burst, lastSeen: now}
+		l.buckets[key] = b
+	}
+
+	// Continuously refill based on elapsed wall-clock time, then clamp.
+	elapsed := now.Sub(b.lastSeen).Seconds()
+	b.tokens += elapsed * l.rate
+	if b.tokens > l.burst {
+		b.tokens = l.burst
+	}
+	b.lastSeen = now
+
+	if b.tokens < 1 {
+		return false
+	}
+	b.tokens--
+	return true
+}
+
+// Stop terminates the background janitor. It is safe to call at most once.
+func (l *Limiter) Stop() {
+	close(l.stop)
+}
+
+func (l *Limiter) janitor() {
+	ticker := time.NewTicker(l.ttl)
+	defer ticker.Stop()
+	for {
+		select {
+		case <-ticker.C:
+			l.cleanup()
+		case <-l.stop:
+			return
+		}
+	}
+}
+
+// cleanup evicts buckets untouched for longer than ttl.
+func (l *Limiter) cleanup() {
+	l.mu.Lock()
+	defer l.mu.Unlock()
+
+	cutoff := l.now().Add(-l.ttl)
+	for key, b := range l.buckets {
+		if b.lastSeen.Before(cutoff) {
+			delete(l.buckets, key)
+		}
+	}
+}
diff --git a/internal/httpx/ratelimit.go b/internal/httpx/ratelimit.go
new file mode 100644
index 0000000..b71e0aa
--- /dev/null
+++ b/internal/httpx/ratelimit.go
@@ -0,0 +1,46 @@
+package httpx
+
+import (
+	"net"
+	"net/http"
+	"strconv"
+
+	"example.com/svc/internal/ratelimit"
+)
+
+// RateLimit returns middleware that rejects requests exceeding the limiter's
+// budget for the key produced by keyFn. Rejected requests receive a 429 with a
+// Retry-After header.
+func RateLimit(l *ratelimit.Limiter, keyFn func(*http.Request) string) func(http.Handler) http.Handler {
+	return func(next http.Handler) http.Handler {
+		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+			if !l.Allow(keyFn(r)) {
+				w.Header().Set("Retry-After", strconv.Itoa(1))
+				http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
+				return
+			}
+			next.ServeHTTP(w, r)
+		})
+	}
+}
+
+// ClientIP extracts the remote host portion of r.RemoteAddr for use as a
+// rate-limit key. RemoteAddr is set by the Go HTTP server from the accepted
+// connection and is therefore not attacker-controlled.
+func ClientIP(r *http.Request) string {
+	host, _, err := net.SplitHostPort(r.RemoteAddr)
+	if err != nil {
+		// RemoteAddr had no port (unusual, e.g. some test transports).
+		return r.RemoteAddr
+	}
+	return host
+}
diff --git a/internal/server/server.go b/internal/server/server.go
index a1b2c3d..d4e5f6a 100644
--- a/internal/server/server.go
+++ b/internal/server/server.go
@@ -1,14 +1,18 @@
 package server
 
 import (
 	"net/http"
 	"time"
+
+	"example.com/svc/internal/httpx"
+	"example.com/svc/internal/ratelimit"
 )
 
 // Config holds runtime configuration for the API server.
 type Config struct {
-	Addr         string
-	ReadTimeout  time.Duration
+	Addr            string
+	ReadTimeout     time.Duration
+	RateLimitPerSec float64
+	RateLimitBurst  float64
 }
 
 // New wires the HTTP routes and returns a configured *http.Server.
 func New(cfg Config, apiHandler http.Handler) *http.Server {
 	mux := http.NewServeMux()
 	mux.HandleFunc("/healthz", healthz)
 	mux.Handle("/api/", apiHandler)
 
+	// Idle client buckets are evicted after 10 minutes of inactivity.
+	limiter := ratelimit.New(cfg.RateLimitPerSec, cfg.RateLimitBurst, 10*time.Minute)
+	handler := httpx.RateLimit(limiter, httpx.ClientIP)(mux)
+
 	return &http.Server{
 		Addr:        cfg.Addr,
 		ReadTimeout: cfg.ReadTimeout,
-		Handler:     mux,
+		Handler:     handler,
 	}
 }
 
 func healthz(w http.ResponseWriter, _ *http.Request) {
 	w.WriteHeader(http.StatusOK)
 }
```
</details>

### domain: Go (Golang) HTTP backend — promo/coupon redemption service using the standard library net/http and regexp (RE2) packages
**planted bugs:**
- `off-by-one-remaining` [high/correctness / off-by-one boundary allowing over-redemption] @ internal/promo/redeem.go, the exhaustion guard `if coupon.Remaining < 0 { return nil, ErrCouponExhausted }` — The guard uses `< 0` where it must be `<= 0`. `Remaining` counts redemptions still left; a used-up coupon has `Remaining == 0`. Because 0 is not `< 0`, an exhausted coupon passes the guard, the discount is applied, and `Remaining--` drives it to -1. Only on the NEXT attempt (Remaining == -1) does the check finally reject. Net effect: every coupon can be redeemed exactly one time beyond its intended limit.
**benign traps:**
- @ internal/promo/redeem.go, `emailRe = regexp.MustCompile(`^([\w.%+-]+)+@[\w.-]+\.[a-zA-Z]{2,}$`)` — The local-part pattern `([\w.%+-]+)+` is a nested quantifier over a character class — the textbook visual signature of a catastrophic-backtracking ReDoS. A hasty reviewer will flag it Critical/High, and indeed in a backtracking engine (I verified: Python `re` takes ~42s on a 28-char adversarial input like "aaaa...!" and blows up exponentially beyond that). (なぜOK: This is Go. The standard-library `regexp` package is implemented on RE2, which compiles to an NFA and matches in guaranteed O(n) time with NO backtracking — it structurally cannot exhibit catastrophic backtracking regardless of nested quantifiers. Go's regexp even rejects backreferences/lookarounds precisely because it forbids the constructs that make ReDoS possible. So there is no adversarial input that degrades this match beyond linear time; flagging it as ReDoS on a Go codebase is a false positive. (The pattern is functionally redundant/ugly, but that is at most a style nit, not a Critical/High security finding.))
- @ internal/promo/redeem.go, `discount := req.Subtotal * coupon.PercentOff / 100` — A reviewer might flag `Subtotal * PercentOff` as an integer-overflow risk before the `/100`. (なぜOK: Both operands are `int64`. `Subtotal` is order-cents and `PercentOff` is documented/validated as 0-100, so the intermediate product is at most ~100 x a realistic cents amount — many orders of magnitude below the int64 max (~9.2e18). Multiplying before dividing is intentional to preserve precision, and overflow is not reachable with any legitimate order total. Not a real defect.)
- @ internal/promo/handler.go, `json.NewDecoder(r.Body).Decode(&req)` — Decoding the request body without an explicit `http.MaxBytesReader` size cap may look like an unbounded-body DoS vector. (なぜOK: This is a routine hardening suggestion, not a correctness/security bug in the changed logic, and the server's own read limits/timeouts normally bound body size at the transport layer. Raising it as a blocking Critical/High finding would be a nit-as-blocker; at most it is a low-severity optional hardening note.)
- @ internal/promo/redeem.go, package-level `regexp.MustCompile(...)` — `MustCompile` panics on a bad pattern, which can look like an unhandled-panic risk. (なぜOK: The patterns are compile-time constants, so `MustCompile` at package init is the idiomatic Go pattern — if the literal were malformed the program would fail to start deterministically during tests, never at request time. There is no runtime panic path from user input. Not a defect.)

<details><summary>diff</summary>

```diff
diff --git a/internal/promo/redeem.go b/internal/promo/redeem.go
new file mode 100644
index 0000000..b1f3c2a
--- /dev/null
+++ b/internal/promo/redeem.go
@@ -0,0 +1,104 @@
+package promo
+
+import (
+	"context"
+	"errors"
+	"regexp"
+	"time"
+)
+
+var (
+	// emailRe validates the redeemer's email before we touch the datastore.
+	// Local part allows word chars plus the common . % + - specials.
+	emailRe = regexp.MustCompile(`^([\w.%+-]+)+@[\w.-]+\.[a-zA-Z]{2,}$`)
+
+	// codeRe validates a promo code: starts alphanumeric, 4-32 chars total,
+	// upper-case alnum plus internal dashes (e.g. SUMMER-2026).
+	codeRe = regexp.MustCompile(`^[A-Z0-9][A-Z0-9-]{3,31}$`)
+)
+
+var (
+	ErrInvalidEmail    = errors.New("promo: invalid email")
+	ErrInvalidCode     = errors.New("promo: invalid code")
+	ErrCouponExpired   = errors.New("promo: coupon expired")
+	ErrCouponExhausted = errors.New("promo: coupon exhausted")
+)
+
+// Coupon is the stored representation of a redeemable discount.
+type Coupon struct {
+	Code        string
+	PercentOff  int64 // 0-100, validated at creation time
+	MaxDiscount int64 // cents; 0 means uncapped
+	Remaining   int   // redemptions left before the coupon is used up
+	ExpiresAt   time.Time
+}
+
+// RedeemRequest is the decoded body of POST /promo/redeem.
+type RedeemRequest struct {
+	Email    string `json:"email"`
+	Code     string `json:"code"`
+	Subtotal int64  `json:"subtotal"` // cents, pre-discount
+}
+
+// RedeemResult is returned to the caller on a successful redemption.
+type RedeemResult struct {
+	Discount int64 `json:"discount"`
+	Total    int64 `json:"total"`
+}
+
+// Store is the persistence boundary for coupons.
+type Store interface {
+	GetCoupon(ctx context.Context, code string) (Coupon, error)
+	SaveCoupon(ctx context.Context, c Coupon) error
+}
+
+// Service applies coupons to an order subtotal.
+type Service struct {
+	store Store
+	now   func() time.Time
+}
+
+func NewService(store Store) *Service {
+	return &Service{store: store, now: time.Now}
+}
+
+// Redeem validates the request, applies the coupon, and decrements its
+// remaining redemption count. All monetary values are in integer cents.
+func (s *Service) Redeem(ctx context.Context, req RedeemRequest) (*RedeemResult, error) {
+	if !emailRe.MatchString(req.Email) {
+		return nil, ErrInvalidEmail
+	}
+	if !codeRe.MatchString(req.Code) {
+		return nil, ErrInvalidCode
+	}
+
+	coupon, err := s.store.GetCoupon(ctx, req.Code)
+	if err != nil {
+		return nil, err
+	}
+
+	if coupon.ExpiresAt.Before(s.now()) {
+		return nil, ErrCouponExpired
+	}
+	if coupon.Remaining < 0 {
+		return nil, ErrCouponExhausted
+	}
+
+	discount := req.Subtotal * coupon.PercentOff / 100
+	if coupon.MaxDiscount > 0 && discount > coupon.MaxDiscount {
+		discount = coupon.MaxDiscount
+	}
+	if discount > req.Subtotal {
+		discount = req.Subtotal
+	}
+
+	coupon.Remaining--
+	if err := s.store.SaveCoupon(ctx, coupon); err != nil {
+		return nil, err
+	}
+
+	return &RedeemResult{
+		Discount: discount,
+		Total:    req.Subtotal - discount,
+	}, nil
+}
diff --git a/internal/promo/handler.go b/internal/promo/handler.go
index 3a1d0e4..7c9b512 100644
--- a/internal/promo/handler.go
+++ b/internal/promo/handler.go
@@ -1,10 +1,12 @@
 package promo
 
 import (
+	"encoding/json"
 	"net/http"
 )
 
 // Handler exposes the promo endpoints over HTTP.
 type Handler struct {
 	svc *Service
 }
 
 func NewHandler(svc *Service) *Handler {
 	return &Handler{svc: svc}
 }
 
 // Routes registers the promo routes on the given mux.
 func (h *Handler) Routes(mux *http.ServeMux) {
 	mux.HandleFunc("POST /promo/validate", h.handleValidate)
+	mux.HandleFunc("POST /promo/redeem", h.handleRedeem)
 }
+
+func (h *Handler) handleRedeem(w http.ResponseWriter, r *http.Request) {
+	var req RedeemRequest
+	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
+		http.Error(w, "bad request", http.StatusBadRequest)
+		return
+	}
+
+	res, err := h.svc.Redeem(r.Context(), req)
+	if err != nil {
+		// Only surface known validation errors to the client; anything
+		// else (store failures, etc.) is reported generically.
+		switch err {
+		case ErrInvalidEmail, ErrInvalidCode, ErrCouponExpired, ErrCouponExhausted:
+			http.Error(w, err.Error(), http.StatusUnprocessableEntity)
+		default:
+			http.Error(w, "could not redeem coupon", http.StatusInternalServerError)
+		}
+		return
+	}
+
+	w.Header().Set("Content-Type", "application/json")
+	_ = json.NewEncoder(w).Encode(res)
+}
```
</details>

### domain: TypeScript / Node.js payments backend (Express checkout service). PR titled "Refactor OrderProcessor to dependency injection + add idempotency cache".
**planted bugs:**
- `bug-ttl-unit-mismatch` [high/unit-mismatch / incorrect-expiry-logic] @ src/orders/idempotency.ts, get(), line: `if (this.clock.now() - entry.storedAt > this.ttlSeconds)` — clock.now() and storedAt are both epoch milliseconds (SystemClock.now() returns Date.now()), so their difference is in milliseconds, but it is compared directly against ttlSeconds (86_400, a value in seconds). The window is 1000x too short: entries expire after 86,400 ms (~86.4 seconds) instead of 24 hours. The correct check needs `> this.ttlSeconds * 1000`.
**benign traps:**
- @ src/orders/OrderProcessor.ts, constructor changed from `constructor()` to `constructor(gateway, clock, idempotency)` — The public constructor signature changes from zero args to three required args, which looks like a breaking contract change for every caller that does `new OrderProcessor()`. (なぜOK: Every call site is updated within the same diff: the singleton in src/api/checkout.ts is rewritten to pass all three dependencies, and src/orders/OrderProcessor.test.ts is updated to inject FakeGateway/FixedClock/IdempotencyCache. No un-migrated `new OrderProcessor()` remains.)
- @ src/time/clock.ts (SystemClock added here) and src/orders/OrderProcessor.ts (its `import { SystemClock } from '../time/clock'` removed) — SystemClock is moved/introduced in clock.ts while OrderProcessor drops its SystemClock import and no longer constructs one, which can look like a dangling-import or lost-dependency error. (なぜOK: The DI refactor intentionally relocates clock construction to the composition root. checkout.ts now imports SystemClock from '../time/clock' (its real, exported location) and injects it. OrderProcessor legitimately no longer needs the import because it receives a Clock. Imports resolve and types check.)
- @ src/orders/OrderProcessor.ts, gateway field type widened from `StripeGateway` to `PaymentGateway` — The gateway dependency's type changes from the concrete StripeGateway to the new PaymentGateway interface, which a hasty reviewer might read as loosening or breaking the charge contract. (なぜOK: PaymentGateway declares the identical `charge(amountCents, currency): Promise<ChargeResult>` used by process(). StripeGateway (injected in checkout.ts) and FakeGateway (injected in the test) both satisfy it. Widening to the interface is the point of the DI refactor and changes no runtime behavior.)
- @ src/orders/OrderProcessor.ts, process() now returns early with `if (cached) return cached;` — process() gains an early-return path that short-circuits the gateway call, which looks like an altered code path that could skip charging. (なぜOK: This is the intended idempotency feature, and the early return only triggers on a genuine prior receipt for the same key. The separate real defect is in how long that cache entry is considered valid (the TTL unit bug), not in the short-circuit itself.)

<details><summary>diff</summary>

```diff
diff --git a/src/time/clock.ts b/src/time/clock.ts
index a1b2c3d..d4e5f6a 100644
--- a/src/time/clock.ts
+++ b/src/time/clock.ts
@@ -1,11 +1,17 @@
 export interface Clock {
   /** Milliseconds since the Unix epoch. */
   now(): number;
 }
 
+export class SystemClock implements Clock {
+  now(): number {
+    return Date.now();
+  }
+}
+
 export class FixedClock implements Clock {
   constructor(private readonly fixed: number) {}
 
   now(): number {
     return this.fixed;
   }
 }
diff --git a/src/payments/gateway.ts b/src/payments/gateway.ts
new file mode 100644
index 0000000..b7c8d90
--- /dev/null
+++ b/src/payments/gateway.ts
@@ -0,0 +1,8 @@
+export interface ChargeResult {
+  id: string;
+}
+
+export interface PaymentGateway {
+  charge(amountCents: number, currency: string): Promise<ChargeResult>;
+}
diff --git a/src/orders/OrderProcessor.ts b/src/orders/OrderProcessor.ts
index 3f2a1b0..9c4d7e2 100644
--- a/src/orders/OrderProcessor.ts
+++ b/src/orders/OrderProcessor.ts
@@ -1,26 +1,29 @@
-import { StripeGateway } from '../payments/stripe';
-import { SystemClock, Clock } from '../time/clock';
+import { PaymentGateway } from '../payments/gateway';
+import { Clock } from '../time/clock';
+import { IdempotencyCache } from './idempotency';
 import { Order, Receipt } from './types';
 
 export class OrderProcessor {
-  private readonly gateway: StripeGateway;
-  private readonly clock: Clock;
-
-  constructor() {
-    this.gateway = new StripeGateway(process.env.STRIPE_KEY!);
-    this.clock = new SystemClock();
-  }
+  constructor(
+    private readonly gateway: PaymentGateway,
+    private readonly clock: Clock,
+    private readonly idempotency: IdempotencyCache,
+  ) {}
 
   async process(order: Order): Promise<Receipt> {
+    const cached = this.idempotency.get(order.idempotencyKey);
+    if (cached) {
+      return cached;
+    }
+
     const charge = await this.gateway.charge(order.total, order.currency);
-    return {
+    const receipt: Receipt = {
       orderId: order.id,
       chargedAt: this.clock.now(),
       chargeId: charge.id,
     };
+    this.idempotency.set(order.idempotencyKey, receipt);
+    return receipt;
   }
 }
diff --git a/src/orders/idempotency.ts b/src/orders/idempotency.ts
new file mode 100644
index 0000000..a0b1c2d
--- /dev/null
+++ b/src/orders/idempotency.ts
@@ -0,0 +1,34 @@
+import { Clock } from '../time/clock';
+import { Receipt } from './types';
+
+interface Entry {
+  receipt: Receipt;
+  storedAt: number;
+}
+
+/**
+ * In-memory idempotency cache. Guarantees that an order carrying a given
+ * idempotency key is charged at most once within the TTL window (24h default).
+ */
+export class IdempotencyCache {
+  private readonly entries = new Map<string, Entry>();
+
+  constructor(
+    private readonly clock: Clock,
+    private readonly ttlSeconds: number = 86_400,
+  ) {}
+
+  get(key: string): Receipt | undefined {
+    const entry = this.entries.get(key);
+    if (!entry) {
+      return undefined;
+    }
+    if (this.clock.now() - entry.storedAt > this.ttlSeconds) {
+      this.entries.delete(key);
+      return undefined;
+    }
+    return entry.receipt;
+  }
+
+  set(key: string, receipt: Receipt): void {
+    this.entries.set(key, { receipt, storedAt: this.clock.now() });
+  }
+}
diff --git a/src/api/checkout.ts b/src/api/checkout.ts
index 5d6e7f8..1a2b3c4 100644
--- a/src/api/checkout.ts
+++ b/src/api/checkout.ts
@@ -1,16 +1,24 @@
 import { Request, Response } from 'express';
 import { OrderProcessor } from '../orders/OrderProcessor';
+import { IdempotencyCache } from '../orders/idempotency';
+import { StripeGateway } from '../payments/stripe';
+import { SystemClock } from '../time/clock';
 
-const processor = new OrderProcessor();
+const clock = new SystemClock();
+const processor = new OrderProcessor(
+  new StripeGateway(process.env.STRIPE_KEY!),
+  clock,
+  new IdempotencyCache(clock),
+);
 
 export async function checkout(req: Request, res: Response): Promise<void> {
   const order = req.body;
   const receipt = await processor.process(order);
   res.json(receipt);
 }
diff --git a/src/orders/OrderProcessor.test.ts b/src/orders/OrderProcessor.test.ts
index 7e8f9a0..2b3c4d5 100644
--- a/src/orders/OrderProcessor.test.ts
+++ b/src/orders/OrderProcessor.test.ts
@@ -1,21 +1,31 @@
 import { OrderProcessor } from './OrderProcessor';
+import { IdempotencyCache } from './idempotency';
 import { FixedClock } from '../time/clock';
+import { FakeGateway } from '../payments/fake';
 
-it('charges the order', async () => {
-  const processor = new OrderProcessor();
+it('charges the order once per idempotency key', async () => {
+  const clock = new FixedClock(1_700_000_000_000);
+  const gateway = new FakeGateway();
+  const processor = new OrderProcessor(
+    gateway,
+    clock,
+    new IdempotencyCache(clock),
+  );
   const order = {
     id: 'o1',
+    idempotencyKey: 'k1',
     total: 500,
     currency: 'usd',
   };
 
   const receipt = await processor.process(order);
   expect(receipt.chargeId).toBeDefined();
+
+  // Re-submitting the same key must not charge again.
+  await processor.process(order);
+  expect(gateway.charges).toHaveLength(1);
 });
```
</details>

### domain: Python / Django web service — per-user avatar thumbnail caching layer
**planted bugs:**
- `lru-evicts-mru` [high/correctness / wrong LRU eviction end] @ apps/media/cache.py, ThumbnailCache.put — self._store.popitem(last=True) — On overflow the cache evicts with popitem(last=True), which removes the most-recently-used entry. But the just-inserted key was moved to the tail (last) immediately before, so the entry being evicted is the one that was just put in.
**benign traps:**
- @ apps/media/cache.py, _key — hashlib.md5(source).hexdigest() — MD5 is used to derive the cache key from avatar source bytes. A hasty reviewer may flag it as a crypto vulnerability (weak hash, collision attacks, forged entries) and demand SHA-256 or usedforsecurity=False. (なぜOK: The digest is a purely local, non-security content-addressing/dedup handle for identical in-process bytes, and it is namespaced with user_id so cross-user reads are impossible regardless of digest collisions. No adversary chooses the input to attack another user, nothing is authenticated or verified by the digest, and a hypothetical MD5 collision would at worst let one user's two blobs share a slot (harmless). MD5 is chosen here for speed, which is the correct trade-off; swapping to SHA-256 would only add CPU cost with zero security benefit.)
- @ apps/media/cache.py, get/put — time.monotonic() for TTL — TTL arithmetic uses time.monotonic() rather than time.time(); a reviewer might object that monotonic timestamps aren't wall-clock and 'can't be compared across restarts' or persisted. (なぜOK: The cache is entirely in-process and ephemeral; expiries are only ever compared against other monotonic readings within the same process lifetime. monotonic() is in fact the correct choice for measuring durations because it is immune to wall-clock jumps (NTP steps, DST) that could otherwise make a wall-clock TTL expire early or never. Nothing is persisted or shared across processes, so cross-restart comparison never happens.)
- @ apps/media/views.py — THUMB_SIZE not included in cache key — The cache key is (user_id, md5(source)) and does not encode the render size, so a reviewer may warn that different requested thumbnail sizes would collide and return a wrong-size image. (なぜOK: THUMB_SIZE is a single module-level constant and every call site renders at exactly that one canonical size (the handler passes size=THUMB_SIZE unconditionally). There is no per-request size parameter, so there is exactly one size in the value space and no collision is possible. Adding size to the key would be dead complexity given the current single-size contract.)

<details><summary>diff</summary>

```diff
diff --git a/apps/media/cache.py b/apps/media/cache.py
new file mode 100644
index 0000000..b3a1f42
--- /dev/null
+++ b/apps/media/cache.py
@@ -0,0 +1,71 @@
+"""In-process caching for rendered avatar thumbnails.
+
+Thumbnails are cheap to serve but expensive to render (decode -> resize ->
+re-encode to webp). Since the same handful of avatars are requested over and
+over, an in-process LRU with a short TTL removes almost all of the render cost
+without needing a round-trip to Redis.
+"""
+
+import hashlib
+import threading
+import time
+from collections import OrderedDict
+
+
+class ThumbnailCache:
+    """Thread-safe, content-addressed LRU cache for rendered thumbnails.
+
+    Entries are keyed by ``user_id`` plus a digest of the *source* bytes, so a
+    user who re-uploads a byte-identical avatar transparently reuses the slot,
+    while a user who changes their avatar gets a fresh slot (the old one ages
+    out via TTL / LRU eviction).
+    """
+
+    def __init__(self, capacity=512, ttl_seconds=3600):
+        self._store = OrderedDict()
+        self._lock = threading.Lock()
+        self.capacity = capacity
+        self.ttl_seconds = ttl_seconds
+
+    def _key(self, user_id, source):
+        # Namespace the digest per user so that two accounts uploading
+        # colliding blobs can never read each other's rendered output. The
+        # digest is only a dedup handle for identical local bytes, never an
+        # authentication or integrity check.
+        digest = hashlib.md5(source).hexdigest()
+        return "{}:{}".format(user_id, digest)
+
+    def get(self, user_id, source):
+        key = self._key(user_id, source)
+        with self._lock:
+            entry = self._store.get(key)
+            if entry is None:
+                return None
+            value, expires_at = entry
+            if time.monotonic() >= expires_at:
+                # Stale; drop it and report a miss so the caller re-renders.
+                del self._store[key]
+                return None
+            # Mark as most-recently-used.
+            self._store.move_to_end(key)
+            return value
+
+    def put(self, user_id, source, value):
+        key = self._key(user_id, source)
+        expires_at = time.monotonic() + self.ttl_seconds
+        with self._lock:
+            self._store[key] = (value, expires_at)
+            self._store.move_to_end(key)
+            if len(self._store) > self.capacity:
+                # Over capacity: shed one entry to make room.
+                self._store.popitem(last=True)
+
+    def clear(self):
+        with self._lock:
+            self._store.clear()
+
+
+# Module-level singleton shared across requests in this worker process.
+_thumb_cache = ThumbnailCache()
+
+
+def get_cache():
+    return _thumb_cache
diff --git a/apps/media/views.py b/apps/media/views.py
index 5c1a09e..7d4e5b8 100644
--- a/apps/media/views.py
+++ b/apps/media/views.py
@@ -1,10 +1,12 @@
 from django.http import Http404, HttpResponse
 
 from .avatars import _load_avatar_bytes, render_thumbnail
+from .cache import get_cache
 
 THUMB_SIZE = 128  # px; single canonical size served to all clients
 
+_thumb_cache = get_cache()
+
 
 def avatar_thumbnail(request, user_id):
     """Return the user's avatar rendered to a THUMB_SIZE webp thumbnail."""
     source = _load_avatar_bytes(user_id)
     if source is None:
         raise Http404("no avatar")
-    thumb = render_thumbnail(source, size=THUMB_SIZE)
-    return HttpResponse(thumb, content_type="image/webp")
+    cached = _thumb_cache.get(user_id, source)
+    if cached is not None:
+        return HttpResponse(cached, content_type="image/webp")
+    thumb = render_thumbnail(source, size=THUMB_SIZE)
+    _thumb_cache.put(user_id, source, thumb)
+    return HttpResponse(thumb, content_type="image/webp")
```
</details>

