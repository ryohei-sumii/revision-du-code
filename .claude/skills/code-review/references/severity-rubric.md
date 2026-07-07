# Severity rubric

Assign one level per finding and report highest first. When unsure between two
levels, pick the lower one and say why — over-flagging erodes trust in the review.

| Level | Meaning | Examples |
|-------|---------|----------|
| **Critical** | Data loss, security hole, or crash reachable in normal use. Must fix before merge. | SQL injection, auth bypass, secret committed, null-deref on a common path, corruption on the happy path. |
| **High** | Wrong behavior for a realistic input, or a resource/consistency leak. Should fix before merge. | Off-by-one dropping the last item, error swallowed so a failure looks like success, lock not released, missing rollback. |
| **Medium** | Bug on an edge case or a contract risk. Fix soon. | Unhandled empty input, N+1 query, breaking API change without a version bump, missing migration reversibility. |
| **Low / Nit** | Maintainability only; no behavior impact. Optional. | Dead code, misleading name, duplication, stale comment, needless complexity. |
| **Question** | You suspect an issue but can't confirm it from the diff. | "Can `items` be empty here? If so line X divides by zero." |

Rules of thumb:
- A finding is at least **High** only if you can name a concrete input/state/operation
  that produces a wrong result, or that leaks a resource or leaves state inconsistent
  — a lock not released, a file handle or connection not closed, a missing rollback
  on a partial failure — even when the symptom only surfaces after repetition or under
  load. If you can't name such a case, it's a **Question** or a **Nit**.
- Security, data-loss, and concurrency findings default up a level, not down —
  including ones you can only raise as a Question. Rank a Question about a potential
  Critical/High issue alongside the confirmed findings of that tier, not at the bottom
  with nits.
- A result set materialized fully into memory with no ceiling (no LIMIT, no pagination,
  no streaming) is not a Medium like an N+1 — it is at least **High**, and **Critical**
  when the OOM can take down a shared worker or an attacker can trigger it on demand.
  The Medium resource guidance covers bounded-but-large or unvalidated-parameter loads,
  not loads with no upper bound at all.
- A bare observation that a change ships with no tests, or that new behavior lacks a
  dedicated test, is not on its own a reportable defect — at most a one-line Low or Nit
  aside. File a test-related finding at Medium-or-above only when you can name BOTH the
  specific untested path AND the concrete bug it lets through; in that case report the
  underlying bug at its own severity (Critical, High, or Medium as the bug itself
  warrants), not as a "missing test."
- Pre-existing issues outside the diff are capped at **Low** unless the change
  makes them materially worse. Score the underlying defect at its *true, full
  severity* — not Low — in either of these cases:
  - the diff newly routes untrusted or attacker-influenced input into an existing
    sink (parser, query, deserializer, eval) that the input couldn't reach before
    — e.g. new code passing attacker-controlled data into an existing, unsanitized
    `query()` is a **Critical** SQL-injection finding, because the diff is what
    turned a dormant function into a live attack path; or
  - the diff makes a previously dead or unreachable code path reachable in normal use.
  This exception is about a *change in reachability or exploitability*, not proximity.
  Adding another caller to code that was already reachable and already exercised the
  same way — without changing what data, guards, or callers reach it — is an ordinary
  pre-existing issue and stays capped at **Low**.
- If nothing reaches Medium or above, say the change looks good and list only
  the nits worth mentioning (if any).
