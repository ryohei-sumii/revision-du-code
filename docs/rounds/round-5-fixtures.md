# Round 5 — テストフィクスチャ / Fixtures

弱クラス各複数(ReDoS×3 / unbounded-memory×3 / SSRF-redirect×2)。Opus作成→Sonnet検証。

## 作成フィクスチャ

### domain: Ruby on Rails — account signup contact-field validation (ActiveModel concern)
**planted bugs:**
- `redos-email-regex` [critical/catastrophic-backtracking-redos] @ app/models/concerns/account_validatable.rb — EMAIL_REGEX constant, used in email_format via EMAIL_REGEX.match?(email) — EMAIL_REGEX uses the classic evil pattern ([\w.%+\-]+)+@... — an inner quantified character class [\w.%+\-]+ wrapped in an outer + quantifier over the same overlapping class. On input whose local part matches the class but which ultimately fails the match (no '@', or an invalid trailing char), the Onigmo engine explores exponentially many ways to partition the run of characters between the inner and outer quantifiers.
- `reserved-username-case` [high/case-sensitivity-auth-bypass] @ app/models/concerns/account_validatable.rb — username_not_reserved (RESERVED_USERNAMES.include?(username)) — The reserved-word check was changed from RESERVED_USERNAMES.include?(username.downcase) to RESERVED_USERNAMES.include?(username). RESERVED_USERNAMES holds only lowercase entries, normalize_contact_fields strips but does NOT downcase username, and USERNAME_REGEX is case-insensitive, so mixed/upper-case variants are accepted.
- `overlong-email-accepted` [medium/early-return-skips-validation] @ app/models/concerns/account_validatable.rb — email_format (return if email.length > MAX_EMAIL_LENGTH) — The length guard uses `return if email.length > MAX_EMAIL_LENGTH`, which returns from the validator WITHOUT adding an error. The intent (per the comment 'reject before the regex runs') was to reject long addresses, but the effect is that any email longer than 254 characters skips the format check entirely and is treated as valid.
**benign traps:**
- @ app/models/concerns/account_validatable.rb — email_format, `EMAIL_REGEX.match?(email)` replacing `email =~ EMAIL_REGEX` — The match operator was switched from `=~` to `String/Regexp#match?`. A reviewer may flag this as a behavior change (=~ returns an index and sets $~/MatchData globals; match? returns a bare boolean). (なぜOK: The result is only used in a boolean `unless` context, where both forms behave identically for accept/reject. match? is in fact the correct, idiomatic choice: it allocates no MatchData and sets no global state, so it is faster and cleaner. No behavioral regression — this is an improvement, not a bug.)
- @ app/models/concerns/account_validatable.rb — USERNAME_REGEX — USERNAME_REGEX = /\A[a-z0-9](?:[a-z0-9]|[_.](?![_.])){1,30}[a-z0-9]\z/i looks alarming: a quantified group with an alternation and a negative lookahead resembles a second ReDoS candidate, right next to the real evil regex. (なぜOK: It is linear, not catastrophic. Every branch of the group (?:[a-z0-9]|[_.](?![_.])) consumes exactly one character, the repetition is bounded {1,30}, and the branches do not overlap ambiguously (a position is either alnum or a separator, never both). There is no nested unbounded quantifier over an overlapping class, so no exponential partitioning is possible. The lookahead only forbids consecutive separators. Safe as written.)
- @ app/models/concerns/account_validatable.rb — normalize_contact_fields (`self.email = email.to_s.strip.downcase`) — email normalization now downcases in addition to stripping, which changes stored data and could look like it might break case-sensitive email semantics or existing records. (なぜOK: Email domains are case-insensitive and the app already treats addresses case-insensitively (EMAIL_REGEX carries the /i flag, and downcasing supports consistent uniqueness). Normalizing to lowercase at the boundary is standard and correct; it does not interact with the planted bugs. (Note the username line deliberately is NOT downcased — that omission is the separate reserved-name bug, not this trap.))

<details><summary>diff</summary>

```diff
diff --git a/app/models/concerns/account_validatable.rb b/app/models/concerns/account_validatable.rb
index 8c21a9f..b3d47e2 100644
--- a/app/models/concerns/account_validatable.rb
+++ b/app/models/concerns/account_validatable.rb
@@ -1,34 +1,54 @@
 # frozen_string_literal: true
 
 # Shared validation for models that carry public contact fields
 # (User, Invitation, WaitlistEntry). Extracted from User so the new
 # WaitlistEntry model can reuse the exact same rules.
 module AccountValidatable
   extend ActiveSupport::Concern
 
-  EMAIL_REGEX = /\A[^@\s]+@[^@\s]+\z/
-
   RESERVED_USERNAMES = %w[admin root support billing help api].freeze
 
+  # Local part allows the common RFC 5321 subset (letters, digits, and
+  # + . _ % -) followed by a dotted domain with a 2+ char TLD. Case
+  # insensitive because we normalize to lowercase anyway.
+  EMAIL_REGEX = /\A([\w.%+\-]+)+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]{2,}\z/i
+
+  # 3-32 chars, must start/end alphanumeric, single "." or "_" separators
+  # allowed in the middle (no doubled separators).
+  USERNAME_REGEX = /\A[a-z0-9](?:[a-z0-9]|[_.](?![_.])){1,30}[a-z0-9]\z/i
+
+  # RFC 5321 caps an address at 254 octets; reject before the regex runs.
+  MAX_EMAIL_LENGTH = 254
+
   included do
     before_validation :normalize_contact_fields
 
     validate :email_format
     validate :username_format
     validate :username_not_reserved
   end
 
   private
 
   def normalize_contact_fields
-    self.email = email.to_s.strip
-    self.username = username.to_s.strip
+    self.email = email.to_s.strip.downcase
+    self.username = username.to_s.strip
   end
 
   def email_format
     return if email.blank?
+    return if email.length > MAX_EMAIL_LENGTH
 
-    errors.add(:email, :invalid) unless email =~ EMAIL_REGEX
+    errors.add(:email, :invalid) unless EMAIL_REGEX.match?(email)
   end
 
   def username_format
     return if username.blank?
 
     errors.add(:username, :invalid) unless USERNAME_REGEX.match?(username)
   end
 
   def username_not_reserved
     return if username.blank?
 
-    errors.add(:username, :reserved) if RESERVED_USERNAMES.include?(username.downcase)
+    errors.add(:username, :reserved) if RESERVED_USERNAMES.include?(username)
   end
 end
```
</details>

### domain: Python / Django backend — user-generated content sanitization service that cleans blog comments before they are persisted and later rendered as plain text.
**planted bugs:**
- `redos-trailing-ws` [critical/catastrophic-backtracking-redos] @ blog/services/sanitizer.py — _TRAILING_WS_RE = re.compile(r"([ \t]+)+$", re.MULTILINE) and its use in the _TRAILING_WS_RE.sub("", text) line — The trailing-whitespace regex uses a nested quantifier ([ \t]+)+ over the same character class. When a line contains a long run of spaces/tabs that is NOT immediately followed by the line end (i.e. interior padding followed by any non-whitespace char), the engine explores exponentially many ways to partition the whitespace run before the $ anchor finally fails, causing catastrophic backtracking on attacker-controlled input.
- `soft-hyphen-noop` [medium/discarded-return-value-noop] @ blog/services/sanitizer.py — the line `text.replace(SOFT_HYPHEN, "")` inside sanitize_comment — str.replace returns a new string and does not mutate in place, but the return value is discarded (the line is a bare expression statement, not `text = text.replace(...)`). The soft-hyphen removal step is therefore a silent no-op; U+00AD characters are never stripped.
**benign traps:**
- @ blog/services/sanitizer.py — _TAG_RE = re.compile(r"(<[^<>]+>)+") — Looks like a nested-quantifier ReDoS: an outer + wrapping a group that itself contains + — the same shape as the real bug two lines below. A reviewer pattern-matching on '(...+...)+' may flag it as catastrophic backtracking. (なぜOK: It is linear. The inner class [^<>] cannot match '<' or '>', so each '>' is a hard, unambiguous boundary between iterations — there is no overlap for the outer + to redistribute, hence no exponential partitioning. Verified linear in Python re: 40,000 repeated '<b>' plus adversarial trailing '<<<<no close' ran in 0.008s (scales linearly with n). The change from <[^<>]+> to (<[^<>]+>)+ is a harmless micro-optimization that collapses adjacent tags in one pass.)
- @ blog/services/sanitizer.py — _CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]") — The control-character range is broken into two spans with gaps, which looks like an incomplete or buggy filter (a reviewer might claim it misses 0x09, 0x0A, 0x0D and demand [\x00-\x1f]). (なぜOK: The gaps are intentional and correct: 0x09 (tab), 0x0A (line feed) and 0x0D (carriage return) are deliberately excluded so multi-line and tabbed comments survive sanitization — exactly as the adjacent comment documents. Verified: 'a\tb\nc\rd\x00\x07e' -> 'a\tb\nc\rde' (tab/newline/CR preserved, 0x00 and 0x07 removed). Widening to [\x00-\x1f] would be the regression, not this.)
- @ blog/services/sanitizer.py — `if not raw:` guard at the top of sanitize_comment — Using `if not raw` rather than an explicit `raw is None` check can look like an over-broad guard that might swallow meaningful falsy values. (なぜOK: raw is typed str; for strings the only falsy value is the empty string, for which returning '' is the intended behaviour. It also safely handles None passed at runtime. No legitimate non-empty comment is affected, so the guard is correct.)

<details><summary>diff</summary>

```diff
diff --git a/blog/services/sanitizer.py b/blog/services/sanitizer.py
index 5c1a2f0..b3e9d47 100644
--- a/blog/services/sanitizer.py
+++ b/blog/services/sanitizer.py
@@ -1,18 +1,54 @@
-import re
+import re
+import unicodedata
 
-# Strip inline HTML; comments are rendered as plain text downstream.
-_TAG_RE = re.compile(r"<[^<>]+>")
+# Zero-width / invisible characters users paste from Word, PDFs, etc.
+SOFT_HYPHEN = "­"
 
+# Non-printable control chars that corrupt rendering. Tab (09), LF (0A) and
+# CR (0D) are intentionally preserved so multi-line comments survive.
+_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")
 
-def sanitize_comment(raw: str) -> str:
-    """Remove markup and surrounding whitespace from a user comment."""
-    if not raw:
-        return ""
-    text = _TAG_RE.sub("", raw)
-    return text.strip()
+# Strip inline HTML; comments are rendered as plain text downstream. A run of
+# adjacent tags (``<b><i>``) collapses in one pass.
+_TAG_RE = re.compile(r"(<[^<>]+>)+")
+
+# Trailing whitespace left on a line after tags are removed.
+_TRAILING_WS_RE = re.compile(r"([ \t]+)+$", re.MULTILINE)
+
+# Squash 3+ consecutive newlines down to a single blank line.
+_BLANK_LINES_RE = re.compile(r"\n{3,}")
+
+
+def sanitize_comment(raw: str) -> str:
+    """Normalise and clean a user-submitted comment before it is persisted.
+
+    The result is stored verbatim and later rendered as plain text, so this is
+    the single choke point where untrusted content is cleaned.
+    """
+    if not raw:
+        return ""
+
+    # Canonical form first so equivalent glyphs compare/store consistently.
+    text = unicodedata.normalize("NFC", raw)
+
+    # Drop non-printable control characters that break the renderer.
+    text = _CONTROL_RE.sub("", text)
+
+    # Remove invisible soft hyphens that show up from copy/paste.
+    text.replace(SOFT_HYPHEN, "")
+
+    # Strip inline HTML tags.
+    text = _TAG_RE.sub("", text)
+
+    # Tidy whitespace introduced by the substitutions above.
+    text = _TRAILING_WS_RE.sub("", text)
+    text = _BLANK_LINES_RE.sub("\n\n", text)
+
+    return text.strip()
diff --git a/blog/tests/test_sanitizer.py b/blog/tests/test_sanitizer.py
index 8ab77c1..d24f6ee 100644
--- a/blog/tests/test_sanitizer.py
+++ b/blog/tests/test_sanitizer.py
@@ -10,3 +10,19 @@ def test_strips_simple_tag():
 
 def test_blank_input_returns_empty():
     assert sanitize_comment("") == ""
+
+
+def test_strips_adjacent_tags():
+    assert sanitize_comment("<b><i>hi</i></b>") == "hi"
+
+
+def test_drops_control_chars_but_keeps_newlines():
+    assert sanitize_comment("a\x00b\nc") == "a b\nc".replace(" ", "")
+
+
+def test_collapses_extra_blank_lines():
+    assert sanitize_comment("a\n\n\n\n\nb") == "a\n\nb"
+
+
+def test_leading_trailing_whitespace_removed():
+    assert sanitize_comment("   hello   ") == "hello"
```
</details>

### domain: Web application security — open-redirect prevention / URL host allow-list validation in a Python (Flask) authentication flow. Framed as a PR titled "Harden login redirect validation; stop relying on urlparse for host extraction."
**planted bugs:**
- `redos-host-pattern` [high/catastrophic-backtracking (ReDoS)] @ security/redirect_guard.py, line 9 — the `_HOST_RE` definition, specifically the sub-expression `(([\w-]+\.)+([\w-]+)*)` — `_HOST_RE` contains the nested-quantifier form `([\w-]+)*` — an outer `*` applied to a group whose body `[\w-]+` already matches one-or-more word characters. This is the canonical `(x+)*` ambiguity: a contiguous run of word characters can be partitioned into iterations of the outer star in exponentially many ways. When the overall match must ultimately fail (a trailing character that satisfies neither the host char class `[\w-]` nor the tail set `[/?#]` nor `$`), Python's backtracking `re` engine explores all of those partitions before giving up. `is_safe_redirect` is reached via an UNAUTHENTICATED GET `/login?next=<payload>` (views/auth.py), so the attacker fully controls the string handed to `.match()`.
**benign traps:**
- @ security/redirect_guard.py, line 17 — `if target.startswith("/") and not target.startswith("//")` — The site-relative fast-path returns True for any target beginning with `/`, which at a glance looks like it would green-light a protocol-relative open redirect such as `//evil.com`. (なぜOK: The `and not target.startswith("//")` clause explicitly excludes protocol-relative URLs. `//evil.com` skips the fast-path, falls through to `_HOST_RE`, which extracts host `evil.com`; `evil.com` is not in `ALLOWED_HOSTS`, so it correctly returns False. Verified: `//evil.com` -> False.)
- @ security/redirect_guard.py, line 22 — `return match.group(1).lower() in ALLOWED_HOSTS` — Switching from `urlparse(...).hostname` to a regex-captured host plus a `frozenset` membership test looks like it could enable subdomain/suffix confusion (e.g. `example.com.evil.com` or `example.com@evil.com` slipping through). (なぜOK: `group(1)` captures the ENTIRE host span and the check is exact set membership, not a suffix/substring match. `http://example.com.evil.com` captures `example.com.evil.com` (not in set -> False), and `http://example.com@evil.com` fails the pattern entirely because `@` is outside both the host class and the tail set. Verified: both -> False. `.lower()` is correct because hostnames are case-insensitive.)
- @ security/redirect_guard.py, line 16 — the added `target = target.strip()` — Newly trimming the input before validation can look like it might normalize away characters an attacker uses to smuggle a payload past the check. (なぜOK: `strip()` only removes leading/trailing ASCII whitespace and is applied before both the relative-path check and the regex, so the exact string that is validated is the string whose host is compared. It cannot expose a different host than the one checked; it only prevents whitespace-padded values from spuriously failing. A minor, safe behavioral note (not a bug): the regex also rejects `example.com:8080`, which the old urlparse path accepted — this is a fail-closed change, never an over-permissive one.)

<details><summary>diff</summary>

```diff
diff --git a/security/redirect_guard.py b/security/redirect_guard.py
index a1b2c3d..e4f5a60 100644
--- a/security/redirect_guard.py
+++ b/security/redirect_guard.py
@@ -1,15 +1,22 @@
-from urllib.parse import urlparse
+import re
 
 ALLOWED_HOSTS = frozenset({"example.com", "app.example.com"})
 
+# Redirect targets look like "[scheme://]host[/path][?query][#frag]".
+# urlparse() returns hostname=None for scheme-less values such as
+# "app.example.com/dashboard", which made legitimate bare-host targets
+# look unsafe, so we extract the host with one anchored pattern instead.
+_HOST_RE = re.compile(r"^(?:https?://)?(([\w-]+\.)+([\w-]+)*)(?:[/?#].*)?$", re.I)
+
 
 def is_safe_redirect(target):
     """Return True if *target* is a safe post-login redirect destination."""
     if not target:
         return False
+    target = target.strip()
     if target.startswith("/") and not target.startswith("//"):
         return True
-    host = urlparse(target).hostname
-    if host is None:
+    match = _HOST_RE.match(target)
+    if not match:
         return False
-    return host.lower() in ALLOWED_HOSTS
+    return match.group(1).lower() in ALLOWED_HOSTS
diff --git a/views/auth.py b/views/auth.py
index 7c8d9e0..1a2b3c4 100644
--- a/views/auth.py
+++ b/views/auth.py
@@ -1,6 +1,7 @@
 from flask import Blueprint, request, render_template, redirect, session
 
 from services.accounts import authenticate
+from security.redirect_guard import is_safe_redirect
 
 bp = Blueprint("auth", __name__)
 
@@ -8,7 +9,9 @@ bp = Blueprint("auth", __name__)
 @bp.route("/login", methods=["GET"])
 def login():
     next_url = request.args.get("next", "")
-    return render_template("login.html", next_url=next_url)
+    if not is_safe_redirect(next_url):
+        next_url = ""
+    return render_template("login.html", next_url=next_url)
 
 
 @bp.route("/login", methods=["POST"])
```
</details>

### domain: Go HTTP microservice — link-preview / URL unfurl service that fetches user-submitted URLs and extracts Open Graph metadata
**planted bugs:**
- `unbounded-body-read` [high/unbounded-memory / DoS] @ internal/unfurl/fetcher.go, in Fetch: `body, err := io.ReadAll(resp.Body)` — The response body of a user-supplied remote URL is read fully into memory via io.ReadAll with no size cap. There is no io.LimitReader, no Content-Length gate, and the HTTP client's Timeout does not bound body size (a slow-but-steady or large 200 response keeps streaming until the 8s deadline, and a fast large body completes well within it). Since rawURL is attacker-controlled (this is an unfurl endpoint), a caller can point it at an endpoint serving a multi-gigabyte or endless body.
- `body-leak-on-non-200` [medium/resource-leak] @ internal/unfurl/fetcher.go, in Fetch: the `if resp.StatusCode != http.StatusOK { return ... }` block sits ABOVE `defer resp.Body.Close()` — On any non-200 response the function returns before `defer resp.Body.Close()` is registered, so resp.Body is never closed on that path. The status check must come after the defer.
**benign traps:**
- @ internal/unfurl/fetcher.go, cacheKey: `md5.Sum([]byte(rawURL))` — Use of MD5, which security scanners and reviewers routinely flag as weak/broken cryptography. (なぜOK: MD5 here is only a cache-key hash for a URL string — a non-security use with no adversarial collision or preimage concern (a collision would at worst share a cache slot between two URLs, and the values are the URLs themselves). It is not used for authentication, signing, passwords, or integrity, so the weak-hash finding does not apply.)
- @ internal/unfurl/fetcher.go, NewFetcher CheckRedirect: `if len(via) >= maxRedirects` — Looks like a classic off-by-one on the redirect cap (>= vs >), which a reviewer might flag as allowing one too few or one too many redirects. (なぜOK: This matches Go's own default policy semantics: `via` holds the requests already made, so `len(via) >= maxRedirects` permits exactly maxRedirects redirects before stopping. The bound is correct and errors out cleanly, preventing unbounded redirect chains.)
- @ internal/unfurl/fetcher.go, `fetchTimeout = 8 * time.Second` applied as http.Client.Timeout — An 8-second whole-request timeout might look too aggressive (could truncate slow legitimate pages) or, conversely, be mistaken for the mechanism that bounds body size. (なぜOK: An overall client timeout is a reasonable, safe default for an outbound fetcher and does not cause incorrect behavior. It is a tuning value, not a defect — and importantly it is NOT the fix for the unbounded-read bug, so flagging it as either the cause or the mitigation would be a false positive.)

<details><summary>diff</summary>

```diff
diff --git a/internal/unfurl/fetcher.go b/internal/unfurl/fetcher.go
index 3a1c9e2..b7f4d81 100644
--- a/internal/unfurl/fetcher.go
+++ b/internal/unfurl/fetcher.go
@@ -1,13 +1,20 @@
 package unfurl
 
 import (
+	"bytes"
 	"context"
+	"crypto/md5"
+	"encoding/hex"
 	"fmt"
+	"io"
 	"net/http"
+	"strings"
 	"time"
+
+	"golang.org/x/net/html"
 )
 
 const (
-	fetchTimeout = 8 * time.Second
+	fetchTimeout = 8 * time.Second
+	maxRedirects = 5
+	userAgent    = "LinkPreviewBot/1.3 (+https://example.com/bot)"
 )
 
 // Preview holds the Open Graph metadata we surface to callers.
@@ -18,20 +25,80 @@ type Preview struct {
 	ImageURL    string
 }
 
 // Fetcher retrieves remote pages and extracts preview metadata.
 type Fetcher struct {
 	client *http.Client
+	cache  Cache
 }
 
-// NewFetcher builds a Fetcher with sane network defaults.
-func NewFetcher() *Fetcher {
-	return &Fetcher{
-		client: &http.Client{Timeout: fetchTimeout},
+// NewFetcher builds a Fetcher with sane network defaults.
+func NewFetcher(cache Cache) *Fetcher {
+	client := &http.Client{
+		Timeout: fetchTimeout,
+		CheckRedirect: func(req *http.Request, via []*http.Request) error {
+			if len(via) >= maxRedirects {
+				return fmt.Errorf("stopped after %d redirects", maxRedirects)
+			}
+			return nil
+		},
+	}
+	return &Fetcher{client: client, cache: cache}
+}
+
+// cacheKey derives a stable key for a target URL.
+func cacheKey(rawURL string) string {
+	sum := md5.Sum([]byte(rawURL))
+	return hex.EncodeToString(sum[:])
+}
+
+// Fetch retrieves rawURL and extracts Open Graph metadata, caching the result.
+func (f *Fetcher) Fetch(ctx context.Context, rawURL string) (*Preview, error) {
+	key := cacheKey(rawURL)
+	if p, ok := f.cache.Get(key); ok {
+		return p, nil
+	}
+
+	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
+	if err != nil {
+		return nil, fmt.Errorf("build request: %w", err)
+	}
+	req.Header.Set("User-Agent", userAgent)
+	req.Header.Set("Accept", "text/html,application/xhtml+xml")
+
+	resp, err := f.client.Do(req)
+	if err != nil {
+		return nil, fmt.Errorf("fetch %s: %w", rawURL, err)
+	}
+	if resp.StatusCode != http.StatusOK {
+		return nil, fmt.Errorf("unexpected status %d for %s", resp.StatusCode, rawURL)
+	}
+	defer resp.Body.Close()
+
+	body, err := io.ReadAll(resp.Body)
+	if err != nil {
+		return nil, fmt.Errorf("read body: %w", err)
+	}
+
+	preview := &Preview{URL: rawURL}
+	if err := parseOpenGraph(bytes.NewReader(body), preview); err != nil {
+		return nil, fmt.Errorf("parse %s: %w", rawURL, err)
+	}
+
+	f.cache.Set(key, preview)
+	return preview, nil
+}
+
+// parseOpenGraph walks the HTML tree and fills og:* metadata into p.
+func parseOpenGraph(r io.Reader, p *Preview) error {
+	doc, err := html.Parse(r)
+	if err != nil {
+		return err
 	}
+	var walk func(*html.Node)
+	walk = func(n *html.Node) {
+		if n.Type == html.ElementNode && n.Data == "meta" {
+			var prop, content string
+			for _, a := range n.Attr {
+				switch strings.ToLower(a.Key) {
+				case "property", "name":
+					prop = a.Val
+				case "content":
+					content = a.Val
+				}
+			}
+			switch prop {
+			case "og:title":
+				p.Title = content
+			case "og:description":
+				p.Description = content
+			case "og:image":
+				p.ImageURL = content
+			}
+		}
+		for c := n.FirstChild; c != nil; c = c.NextSibling {
+			walk(c)
+		}
+	}
+	walk(doc)
+	return nil
 }
```
</details>

### domain: Go (net/http) backend — multipart avatar upload endpoint for a photo-sharing service, storing to an object store
**planted bugs:**
- `oom-readall-upload` [critical/unbounded-memory / resource-exhaustion (DoS)] @ internal/handlers/avatar.go, UploadAvatar, `data, err := io.ReadAll(file)` (~line 62) — The uploaded multipart file is slurped entirely into a single []byte via io.ReadAll with no size cap. r.Body is never wrapped in http.MaxBytesReader, and ParseMultipartForm(32<<20) does NOT bound the file size — it only caps how much is buffered in RAM before spilling the remainder to a temp file on disk. FormFile then returns a multipart.File backed by that temp file, and io.ReadAll loads the whole thing (which can be many gigabytes) into memory at once. The same []byte is then held for md5.Sum and store.Put, so the peak lives for the whole request.
- `missing-return-after-415` [high/control-flow / missing return after error response] @ internal/handlers/avatar.go, UploadAvatar, content-type check block (~lines 68-70) — After the content-type is rejected, the handler calls http.Error(w, ..., StatusUnsupportedMediaType) but does not `return`. Execution falls through and the disallowed payload is still hashed, stored via store.Put, and recorded on the user profile with SetAvatarKey.
**benign traps:**
- @ internal/handlers/avatar.go, `sum := md5.Sum(data)` (~line 73) — Use of MD5, which typically trips 'weak/broken hash algorithm' security lint. (なぜOK: MD5 here is a content-addressing / deduplication key, not a security or integrity control against an adversary. Collision resistance is irrelevant: even a deliberate collision only means one user's image maps to an existing key under their own `avatars/{userID}/` prefix. No signature, password, or trust decision depends on the digest, so MD5 is an acceptable (and fast) choice.)
- @ internal/handlers/avatar.go, `ext := filepath.Ext(header.Filename)` used to build `key` (~lines 74-75) — An attacker-controlled multipart filename is fed into the storage key, which looks like path traversal / key-injection (e.g. filename '../../secret'). (なぜOK: filepath.Ext returns only the trailing extension of the final path element and stops at any path separator, so its result can never contain '/' or '..'. It is appended as a cosmetic suffix onto a server-generated, hash-derived key that is itself scoped under the per-user prefix `avatars/{userID}/`. There is no way for the filename to escape the prefix, collide across users, or inject separators into the key.)
- @ internal/handlers/avatar.go, `contentType := http.DetectContentType(data)` (~line 67) — Passing the whole payload to DetectContentType and validating the sniffed type looks redundant/fragile (it only inspects the first bytes) and one might flag trusting it. (なぜOK: http.DetectContentType only examines up to the first 512 bytes internally, so passing the full slice is harmless. Sniffing the actual bytes and checking against an allow-list is the correct, safer approach here — it does NOT trust the client-supplied Content-Type header or filename extension. This is sound as written; the real defect nearby is the missing return, not the sniffing itself.)

<details><summary>diff</summary>

```diff
diff --git a/internal/handlers/avatar.go b/internal/handlers/avatar.go
new file mode 100644
index 0000000..b3a91c2
--- /dev/null
+++ b/internal/handlers/avatar.go
@@ -0,0 +1,86 @@
+package handlers
+
+import (
+	"context"
+	"crypto/md5"
+	"encoding/hex"
+	"fmt"
+	"io"
+	"net/http"
+	"path/filepath"
+)
+
+// ObjectStore is the subset of our blob storage we depend on here.
+type ObjectStore interface {
+	Put(ctx context.Context, key string, body []byte, contentType string) error
+}
+
+// ProfileStore persists the avatar key against the user record.
+type ProfileStore interface {
+	SetAvatarKey(ctx context.Context, userID, key string) error
+}
+
+type AvatarHandler struct {
+	store ObjectStore
+	users ProfileStore
+}
+
+func NewAvatarHandler(store ObjectStore, users ProfileStore) *AvatarHandler {
+	return &AvatarHandler{store: store, users: users}
+}
+
+var allowedContentTypes = map[string]bool{
+	"image/jpeg": true,
+	"image/png":  true,
+	"image/webp": true,
+}
+
+// UploadAvatar handles POST /me/avatar. The client sends the image in a
+// multipart form field named "avatar". We content-sniff the payload,
+// store it under a content-addressed key, and update the user's profile.
+func (h *AvatarHandler) UploadAvatar(w http.ResponseWriter, r *http.Request) {
+	userID, ok := UserIDFromContext(r.Context())
+	if !ok {
+		http.Error(w, "unauthorized", http.StatusUnauthorized)
+		return
+	}
+
+	// Keep in-memory buffering modest; larger parts spill to temp files.
+	if err := r.ParseMultipartForm(32 << 20); err != nil {
+		http.Error(w, "invalid multipart upload", http.StatusBadRequest)
+		return
+	}
+
+	file, header, err := r.FormFile("avatar")
+	if err != nil {
+		http.Error(w, "missing avatar field", http.StatusBadRequest)
+		return
+	}
+	defer file.Close()
+
+	data, err := io.ReadAll(file)
+	if err != nil {
+		http.Error(w, "could not read upload", http.StatusInternalServerError)
+		return
+	}
+
+	contentType := http.DetectContentType(data)
+	if !allowedContentTypes[contentType] {
+		http.Error(w, "unsupported media type", http.StatusUnsupportedMediaType)
+	}
+
+	// Content-addressed key => uploading the same image twice is idempotent.
+	sum := md5.Sum(data)
+	ext := filepath.Ext(header.Filename)
+	key := fmt.Sprintf("avatars/%s/%s%s", userID, hex.EncodeToString(sum[:]), ext)
+
+	if err := h.store.Put(r.Context(), key, data, contentType); err != nil {
+		http.Error(w, "could not store avatar", http.StatusInternalServerError)
+		return
+	}
+
+	if err := h.users.SetAvatarKey(r.Context(), userID, key); err != nil {
+		http.Error(w, "could not update profile", http.StatusInternalServerError)
+		return
+	}
+
+	w.Header().Set("Content-Type", "application/json")
+	w.WriteHeader(http.StatusCreated)
+	fmt.Fprintf(w, `{"key":%q,"contentType":%q}`, key, contentType)
+}
diff --git a/internal/server/routes.go b/internal/server/routes.go
index 4f1c2ab..9d7e5f0 100644
--- a/internal/server/routes.go
+++ b/internal/server/routes.go
@@ -18,6 +18,7 @@ func (s *Server) routes() http.Handler {
 	mux := http.NewServeMux()
 
 	mux.Handle("GET /healthz", s.health())
+	avatars := handlers.NewAvatarHandler(s.blobs, s.profiles)
 
 	// Authenticated API surface.
 	api := http.NewServeMux()
@@ -25,6 +26,7 @@ func (s *Server) routes() http.Handler {
 	api.HandleFunc("GET /me", s.handleGetMe)
 	api.HandleFunc("PATCH /me", s.handlePatchMe)
 	api.HandleFunc("GET /me/photos", s.handleListPhotos)
+	api.HandleFunc("POST /me/avatar", avatars.UploadAvatar)
 
 	mux.Handle("/", s.requireAuth(api))
 	return s.withRequestLogging(mux)
```
</details>

### domain: C# / .NET (ASP.NET Core) — financial ledger service; PR adds a CSV export endpoint for an account's settled-transaction ledger, built on top of an existing streaming repository.
**planted bugs:**
- `BUG-1` [critical/unbounded-memory] @ src/Reporting/TransactionExportService.cs — BuildLedgerCsvAsync (the `var rows = new List<Transaction>()` + `await foreach { rows.Add(tx); }` accumulation, the full StringBuilder, and the `Encoding.UTF8.GetBytes(sb.ToString())` return), amplified by LedgerController.ExportLedger defaulting `from` to DateTime.MinValue. — The export drains the entire `StreamSettledAsync` async stream into an in-memory `List<Transaction>`, then builds the whole CSV in a single StringBuilder, then materializes it again as a byte[] — three full copies of an unbounded result set with no page size, row cap, or streaming to the response body. The repository deliberately exposes a streaming API (used correctly by BuildSummaryAsync right above), but the new method defeats it.
- `BUG-2` [medium/csv-injection-and-field-corruption] @ src/Reporting/TransactionExportService.cs — BuildLedgerCsvAsync, the `.Append(tx.Counterparty).Append(',')` line — The `Counterparty` free-text field is written into the CSV without RFC-4180 quoting/escaping. A counterparty name containing a comma, double-quote, CR, or LF shifts or breaks the column layout, and a leading '=', '+', '-', or '@' enables CSV/formula injection when the file is opened in a spreadsheet.
**benign traps:**
- @ src/Reporting/TransactionExportService.cs — constructor, `_currencyScale = currencyRepo.GetAll().ToDictionary(c => c.Code, c => c.DecimalPlaces);` — Looks like the classic 'loads an entire DB table into memory' anti-pattern — a `.GetAll()` with no pagination materialized into a Dictionary in a constructor. (なぜOK: GetAll() here returns the ISO-4217 currency reference table, a fixed, bounded set of ~180 rows that changes almost never. Caching it once as a Code→scale lookup is the correct optimization and explicitly avoids a per-row DB hit during export. Bounded cardinality means constant, negligible memory — this is not the unbounded-buffering bug and should not be flagged as one.)
- @ src/Reporting/TransactionExportService.cs — BuildSummaryAsync, the `await foreach (var tx in _repository.StreamSettledAsync(...))` loop — An unbounded async stream consumed in a loop — superficially the same shape as the buggy export and could be mistaken for another unbounded-memory issue. (なぜOK: This loop retains only three scalar accumulators (credits, debits, count) and never stores the transactions themselves, so its memory is O(1) regardless of how many rows the stream yields. It is the correct streaming-aggregation pattern; flagging it would be a false positive.)
- @ src/Reporting/TransactionExportService.cs — amount/balance formatting via `"F" + scale` with CultureInfo.InvariantCulture — Building a format string by concatenating a runtime `scale` int, plus per-row currency lookup, may look fragile or like a hidden localization/precision bug. (なぜOK: scale comes from the bounded currency table and falls back to 2 when absent, so the format specifier is always valid (F0–F4 in practice). InvariantCulture guarantees a '.' decimal separator and no thousands grouping, which is exactly what CSV numeric fields need — this is correct and actually prevents a locale-dependent formatting bug rather than introducing one.)

<details><summary>diff</summary>

```diff
diff --git a/src/Reporting/TransactionExportService.cs b/src/Reporting/TransactionExportService.cs
index 3b1f0a2..9c4e771 100644
--- a/src/Reporting/TransactionExportService.cs
+++ b/src/Reporting/TransactionExportService.cs
@@ -1,4 +1,5 @@
 using System.Globalization;
+using System.Text;
 
 namespace Ledger.Reporting;
 
@@ -6,15 +7,20 @@ namespace Ledger.Reporting;
 public sealed class TransactionExportService
 {
     private readonly ITransactionRepository _repository;
+    private readonly ICurrencyRepository _currencyRepo;
+    private readonly IReadOnlyDictionary<string, int> _currencyScale;
 
-    public TransactionExportService(ITransactionRepository repository)
+    public TransactionExportService(ITransactionRepository repository, ICurrencyRepository currencyRepo)
     {
         _repository = repository;
+        _currencyRepo = currencyRepo;
+        // Preload ISO-4217 minor-unit scales so we don't hit the DB per row.
+        _currencyScale = currencyRepo.GetAll().ToDictionary(c => c.Code, c => c.DecimalPlaces);
     }
 
     public async Task<LedgerSummary> BuildSummaryAsync(Guid accountId, DateRange range, CancellationToken ct)
     {
         decimal credits = 0m, debits = 0m;
         var count = 0;
+        // Streams settled rows; only running scalars are retained.
         await foreach (var tx in _repository.StreamSettledAsync(accountId, range, ct))
         {
             if (tx.Amount >= 0m) credits += tx.Amount; else debits += tx.Amount;
@@ -22,4 +28,42 @@ public sealed class TransactionExportService
         }
         return new LedgerSummary(count, credits, debits);
     }
+
+    /// <summary>
+    /// Renders the settled ledger for an account as a CSV document, ordered by
+    /// settlement time. Columns: id, settled_at, counterparty, amount, currency, balance.
+    /// </summary>
+    public async Task<byte[]> BuildLedgerCsvAsync(Guid accountId, DateRange range, CancellationToken ct)
+    {
+        var rows = new List<Transaction>();
+        await foreach (var tx in _repository.StreamSettledAsync(accountId, range, ct))
+        {
+            rows.Add(tx);
+        }
+
+        // Settlement order isn't guaranteed by the read model, so sort here.
+        rows.Sort((a, b) => a.SettledAt.CompareTo(b.SettledAt));
+
+        var sb = new StringBuilder();
+        sb.Append("id,settled_at,counterparty,amount,currency,balance\n");
+        foreach (var tx in rows)
+        {
+            var scale = _currencyScale.TryGetValue(tx.Currency, out var s) ? s : 2;
+            sb.Append(tx.Id).Append(',')
+              .Append(tx.SettledAt.ToString("O", CultureInfo.InvariantCulture)).Append(',')
+              .Append(tx.Counterparty).Append(',')
+              .Append(tx.Amount.ToString("F" + scale, CultureInfo.InvariantCulture)).Append(',')
+              .Append(tx.Currency).Append(',')
+              .Append(tx.RunningBalance.ToString("F" + scale, CultureInfo.InvariantCulture))
+              .Append('\n');
+        }
+
+        return Encoding.UTF8.GetBytes(sb.ToString());
+    }
 }
diff --git a/src/Api/Controllers/LedgerController.cs b/src/Api/Controllers/LedgerController.cs
index 5a2c118..d0b93ee 100644
--- a/src/Api/Controllers/LedgerController.cs
+++ b/src/Api/Controllers/LedgerController.cs
@@ -34,6 +34,23 @@ public sealed class LedgerController : ControllerBase
         var summary = await _exportService.BuildSummaryAsync(accountId, range, ct);
         return Ok(summary);
     }
+
+    [HttpGet("accounts/{accountId:guid}/ledger.csv")]
+    [Produces("text/csv")]
+    public async Task<IActionResult> ExportLedger(
+        Guid accountId,
+        [FromQuery] DateTime? from,
+        [FromQuery] DateTime? to,
+        CancellationToken ct)
+    {
+        var range = new DateRange(from ?? DateTime.MinValue, to ?? DateTime.UtcNow);
+        var csv = await _exportService.BuildLedgerCsvAsync(accountId, range, ct);
+        return File(csv, "text/csv", $"ledger-{accountId}.csv");
+    }
 }
```
</details>

### domain: Go backend service — outbound webhook delivery with SSRF hardening (net/http)
**planted bugs:**
- `ssrf-redirect-follow` [critical/ssrf-via-redirect] @ internal/webhook/delivery.go, NewDelivery() http.Client construction (used by Send via d.client.Do) — validateWebhookURL only vets the ORIGINAL endpoint's resolved IPs, but the http.Client built in NewDelivery sets no CheckRedirect policy, so it uses Go's default of auto-following up to 10 3xx redirects. The followed Location URL is never re-validated, so a registered webhook whose host passes the check can 302-redirect the request to an internal address.
**benign traps:**
- @ internal/webhook/delivery.go, Send() — io.Copy(io.Discard, io.LimitReader(resp.Body, maxResponseBytes)) — Reads and discards the response body through a 64 KiB LimitReader instead of io.ReadAll. Looks like it could truncate or drop response data the caller needs. (なぜOK: Send intentionally ignores the body content (only status matters for delivery success) and drains it so the connection can be reused. Capping with LimitReader is deliberate DoS protection against a malicious endpoint streaming an unbounded body. Correct.)
- @ internal/webhook/delivery.go, privateCIDRs (includes 100.64.0.0/10) and the 'reject if any resolved IP is blocked' loop in validateWebhookURL — Blocking the whole CGNAT range 100.64.0.0/10 and rejecting a host if ANY of its resolved records is internal looks overly aggressive and could reject legitimate endpoints. (なぜOK: This is the safe, intended posture for SSRF hardening: rejecting on any private record prevents an attacker from mixing one public and one private record to slip a private target past validation, and 100.64.0.0/10 is genuinely non-routable internal space. Not a defect.)
- @ internal/webhook/delivery.go, Send() — if resp.StatusCode >= 300 returns an error — Treating every status >= 300 as a delivery failure looks like it would wrongly fail legitimate 3xx redirect responses. (なぜOK: By the time Do returns, redirects have already been followed, so resp is the terminal response — a remaining 3xx means the redirect chain did not resolve to a real endpoint. Defining delivery success as a sub-300 final status is reasonable and not a correctness bug (it is unrelated to the actual redirect-follow vulnerability).)

<details><summary>diff</summary>

```diff
diff --git a/internal/webhook/delivery.go b/internal/webhook/delivery.go
index 3f1a2b7..b9c4e01 100644
--- a/internal/webhook/delivery.go
+++ b/internal/webhook/delivery.go
@@ -3,7 +3,9 @@ package webhook
 import (
 	"bytes"
 	"context"
 	"fmt"
 	"io"
+	"net"
 	"net/http"
+	"net/url"
 	"time"
 )
 
 const maxResponseBytes = 64 * 1024
@@ -21,6 +23,72 @@ func NewDelivery() *Delivery {
 	return &Delivery{
 		client: &http.Client{
 			Timeout: 10 * time.Second,
 		},
 	}
 }
 
+// privateCIDRs enumerates address ranges that customer webhooks must never
+// target. Blocking these up front stops a caller from pointing a webhook at
+// cloud metadata endpoints or internal-only services.
+var privateCIDRs = []string{
+	"10.0.0.0/8",
+	"172.16.0.0/12",
+	"192.168.0.0/16",
+	"127.0.0.0/8",
+	"169.254.0.0/16", // link-local, includes 169.254.169.254 metadata
+	"100.64.0.0/10",  // carrier-grade NAT
+	"::1/128",
+	"fc00::/7",
+	"fe80::/10",
+}
+
+var blockedNets []*net.IPNet
+
+func init() {
+	for _, c := range privateCIDRs {
+		_, n, err := net.ParseCIDR(c)
+		if err != nil {
+			panic(fmt.Sprintf("webhook: invalid CIDR %q: %v", c, err))
+		}
+		blockedNets = append(blockedNets, n)
+	}
+}
+
+func isBlockedIP(ip net.IP) bool {
+	if ip.IsUnspecified() || ip.IsMulticast() {
+		return true
+	}
+	for _, n := range blockedNets {
+		if n.Contains(ip) {
+			return true
+		}
+	}
+	return false
+}
+
+// validateWebhookURL rejects endpoints that resolve to internal addresses.
+func validateWebhookURL(raw string) error {
+	u, err := url.Parse(raw)
+	if err != nil {
+		return fmt.Errorf("invalid webhook url: %w", err)
+	}
+	if u.Scheme != "http" && u.Scheme != "https" {
+		return fmt.Errorf("unsupported webhook scheme %q", u.Scheme)
+	}
+	host := u.Hostname()
+	if host == "" {
+		return fmt.Errorf("webhook url missing host")
+	}
+	ips, err := net.LookupIP(host)
+	if err != nil {
+		return fmt.Errorf("cannot resolve webhook host %q: %w", host, err)
+	}
+	// Reject if *any* resolved address is internal, so a multi-record host
+	// cannot smuggle a private A/AAAA record past the check.
+	for _, ip := range ips {
+		if isBlockedIP(ip) {
+			return fmt.Errorf("webhook host %q resolves to blocked address %s", host, ip)
+		}
+	}
+	return nil
+}
+
 // Send POSTs payload to the customer endpoint and drains the response.
 func (d *Delivery) Send(ctx context.Context, endpoint string, payload []byte) error {
+	if err := validateWebhookURL(endpoint); err != nil {
+		return err
+	}
+
 	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
 	if err != nil {
 		return err
 	}
 	req.Header.Set("Content-Type", "application/json")
 	req.Header.Set("User-Agent", "acme-webhooks/1.0")
 
 	resp, err := d.client.Do(req)
 	if err != nil {
 		return fmt.Errorf("webhook delivery failed: %w", err)
 	}
 	defer resp.Body.Close()
 
 	if _, err := io.Copy(io.Discard, io.LimitReader(resp.Body, maxResponseBytes)); err != nil {
 		return err
 	}
 	if resp.StatusCode >= 300 {
 		return fmt.Errorf("webhook returned status %d", resp.StatusCode)
 	}
 	return nil
 }
```
</details>

### domain: Ruby on Rails web service — server-side link/image unfurl (preview) endpoint that fetches a user-supplied URL to render an inline preview. Uses Faraday HTTP client with the follow_redirects middleware.
**planted bugs:**
- `ssrf-redirect-follow` [critical/ssrf] @ app/services/link_preview_fetcher.rb — connection (conn.response :follow_redirects) combined with call (ensure_public! runs only on the initial uri.host) — The SSRF guard ensure_public! is applied exactly once, to the host of the originally submitted URL. The Faraday connection then enables the follow_redirects middleware (limit: 5), which transparently follows 3xx responses to arbitrary Location hosts. Redirect targets are never re-validated against BLOCKED_RANGES, so a public origin can bounce the request into internal address space.
**benign traps:**
- @ app/services/link_preview_fetcher.rb — call: `uri.is_a?(URI::HTTP)` — The scheme check only tests `URI::HTTP`, which looks like it would reject https:// URLs and silently break the feature for secure links. (なぜOK: In Ruby's stdlib URI, `URI::HTTPS` is a subclass of `URI::HTTP`, so `URI.parse("https://…").is_a?(URI::HTTP)` is true. Both http and https are accepted; non-HTTP schemes (file:, ftp:, gopher:, data:) are correctly rejected. No bug.)
- @ app/services/link_preview_fetcher.rb — BLOCKED_RANGES: `IPAddr.new("172.16.0.0/12")` — The private-range entry uses a /12 mask, which a reviewer may flag as too narrow (e.g. 'this misses 172.31.x' or 'should be /16 per subnet'). (なぜOK: 172.16.0.0/12 is exactly the RFC 1918 block and correctly spans 172.16.0.0 through 172.31.255.255. The list also correctly covers loopback, link-local (incl. 169.254 metadata range), CGNAT (100.64.0.0/10), and the IPv6 loopback/ULA/link-local ranges. The range set itself is sound — the vulnerability is that it is only consulted for the first hop.)
- @ app/services/link_preview_fetcher.rb — on_data size guard `if received_bytes > MAX_BYTES` — The download-size limit reads chunks into an in-memory buffer, which can look like it never actually caps the response (unbounded memory / the check uses the wrong variable). (なぜOK: Faraday's on_data callback yields the cumulative byte count as its second argument (received_bytes), not the per-chunk size, so the guard raises FetchError as soon as the total crosses MAX_BYTES and stops appending. The 5 MiB cap is enforced correctly.)
- @ app/controllers/link_previews_controller.rb — `rate_limit to: 30, within: 1.minute, only: :create` — Adds a rate limit only on :create and not on other actions, which might read as an incomplete/inconsistent control. (なぜOK: Rails' built-in rate_limit scoped to the new outbound-fetch action is appropriate and correct; the index action lists the caller's own records and needs no such throttle. This is a reasonable, non-buggy addition.)

<details><summary>diff</summary>

```diff
diff --git a/app/services/link_preview_fetcher.rb b/app/services/link_preview_fetcher.rb
new file mode 100644
index 0000000..8b1f2ac
--- /dev/null
+++ b/app/services/link_preview_fetcher.rb
@@ -0,0 +1,86 @@
+require "resolv"
+require "ipaddr"
+require "uri"
+
+# Fetches a remote resource for inline link unfurling in the message composer.
+# Only public HTTP(S) endpoints are permitted: the destination host is resolved
+# and rejected if it maps to a loopback/link-local/private range, so that a
+# user-supplied URL cannot be used to reach internal infrastructure.
+class LinkPreviewFetcher
+  class UnsafeUrlError < StandardError; end
+  class FetchError < StandardError; end
+
+  MAX_BYTES        = 5 * 1024 * 1024
+  REQUEST_TIMEOUT  = 5
+  REDIRECT_LIMIT   = 5
+
+  # Ranges that must never be reachable via a preview request.
+  BLOCKED_RANGES = [
+    IPAddr.new("0.0.0.0/8"),
+    IPAddr.new("10.0.0.0/8"),
+    IPAddr.new("100.64.0.0/10"),
+    IPAddr.new("127.0.0.0/8"),
+    IPAddr.new("169.254.0.0/16"),
+    IPAddr.new("172.16.0.0/12"),
+    IPAddr.new("192.168.0.0/16"),
+    IPAddr.new("::1/128"),
+    IPAddr.new("fc00::/7"),
+    IPAddr.new("fe80::/10"),
+  ].freeze
+
+  def self.call(raw_url)
+    new(raw_url).call
+  end
+
+  def initialize(raw_url)
+    @raw_url = raw_url.to_s.strip
+  end
+
+  def call
+    uri = URI.parse(@raw_url)
+    unless uri.is_a?(URI::HTTP) && uri.host.present?
+      raise UnsafeUrlError, "only absolute http(s) URLs are supported"
+    end
+    ensure_public!(uri.host)
+
+    body = +""
+    response = connection.get(uri.to_s) do |req|
+      req.options.timeout = REQUEST_TIMEOUT
+      req.options.on_data = proc do |chunk, received_bytes|
+        raise FetchError, "response exceeds #{MAX_BYTES} bytes" if received_bytes > MAX_BYTES
+        body << chunk
+      end
+    end
+
+    raise FetchError, "upstream returned #{response.status}" unless response.success?
+
+    { content_type: response.headers["content-type"], body: body }
+  end
+
+  private
+
+  def ensure_public!(host)
+    addresses = Resolv.getaddresses(host)
+    raise UnsafeUrlError, "could not resolve host" if addresses.empty?
+
+    addresses.each do |address|
+      ip = IPAddr.new(address)
+      if BLOCKED_RANGES.any? { |range| range.include?(ip) }
+        raise UnsafeUrlError, "host resolves to a non-public address"
+      end
+    end
+  end
+
+  def connection
+    @connection ||= Faraday.new(headers: { "User-Agent" => "AcmeLinkPreview/1.0" }) do |conn|
+      conn.response :follow_redirects, limit: REDIRECT_LIMIT
+      conn.adapter Faraday.default_adapter
+    end
+  end
+end
diff --git a/app/controllers/link_previews_controller.rb b/app/controllers/link_previews_controller.rb
index 3a1c9de..f42b7a1 100644
--- a/app/controllers/link_previews_controller.rb
+++ b/app/controllers/link_previews_controller.rb
@@ -1,9 +1,29 @@
 class LinkPreviewsController < ApplicationController
   before_action :authenticate_user!
+  rate_limit to: 30, within: 1.minute, only: :create
 
-  def index
-    render json: { previews: current_user.link_previews.recent }
+  # POST /link_previews
+  # Body: { "link_preview": { "url": "https://example.com/cat.png" } }
+  def create
+    result = LinkPreviewFetcher.call(preview_params[:url])
+
+    render json: {
+      content_type: result[:content_type],
+      data: Base64.strict_encode64(result[:body]),
+    }
+  rescue LinkPreviewFetcher::UnsafeUrlError => e
+    render json: { error: e.message }, status: :unprocessable_entity
+  rescue LinkPreviewFetcher::FetchError => e
+    render json: { error: e.message }, status: :bad_gateway
+  end
+
+  def index
+    render json: { previews: current_user.link_previews.recent }
   end
+
+  private
+
+  def preview_params
+    params.require(:link_preview).permit(:url)
+  end
 end
```
</details>

