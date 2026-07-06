# Severity rubric

Assign one level per finding and report highest first. When unsure between two
levels, pick the lower one and say why — over-flagging erodes trust in the review.

| Level | Meaning | Examples |
|-------|---------|----------|
| **Critical** | Data loss, security hole, or crash reachable in normal use. Must fix before merge. | SQL injection, auth bypass, secret committed, null-deref on a common path, corruption on the happy path. |
| **High** | Wrong behavior for a realistic input, or a resource/consistency leak. Should fix before merge. | Off-by-one dropping the last item, error swallowed so a failure looks like success, lock not released, missing rollback. |
| **Medium** | Bug on an edge case, missing test for new behavior, or a contract risk. Fix soon. | Unhandled empty input, N+1 query, breaking API change without a version bump, missing migration reversibility. |
| **Low / Nit** | Maintainability only; no behavior impact. Optional. | Dead code, misleading name, duplication, stale comment, needless complexity. |
| **Question** | You suspect an issue but can't confirm it from the diff. | "Can `items` be empty here? If so line X divides by zero." |

Rules of thumb:
- A finding is at least **High** only if you can name a concrete input/state that
  produces a wrong result. If you can't, it's a **Question** or a **Nit**.
- Security and data-loss findings default up a level, not down.
- Pre-existing issues outside the diff are capped at **Low** unless the change
  makes them materially worse.
- If nothing reaches Medium or above, say the change looks good and list only
  the nits worth mentioning (if any).
