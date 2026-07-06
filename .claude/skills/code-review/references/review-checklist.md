# Review checklist

Language-agnostic. Apply the categories that fit the change; skip the ones that
don't. Depth beats breadth — a real bug found is worth more than ticking boxes.

## Correctness
- Off-by-one, boundary, and empty-collection cases (0, 1, N, max).
- Null / nil / undefined / None handling; unwrapping something that can be absent.
- Wrong operator or inverted condition (`&&` vs `||`, `<` vs `<=`, `!`).
- Type coercion / truthiness surprises; integer vs float division; overflow.
- Return value ignored, or the wrong value returned on an early exit.
- Does the change actually do what its name/commit message claims?

## Control flow & errors
- Errors swallowed, logged-and-continued, or turned into a wrong default.
- Resources not released on the error path (files, locks, connections, handles).
- Partial state left behind when an operation fails midway (no rollback).
- `try/catch` too broad, hiding failures it shouldn't.

## Security
- Untrusted input reaching a sink: SQL/OS command/template/eval injection.
- Untrusted input concatenated/interpolated/formatted INTO a query, command, path, or template string — the actual injection sink.
- A value already passed as a bound parameter (`?`/`$1`/named placeholder) is NOT an injection sink — do not flag it as SQLi/command-injection regardless of missing type validation. A crash from bad type/format (e.g. non-numeric `limit` raising ValueError) is at most a Low nit.
- Missing authentication or authorization on a new endpoint/action.
- Secrets, tokens, or keys hard-coded or logged.
- Path traversal, SSRF, unsafe deserialization, XSS in rendered output.
- Weak/missing input validation on data that crosses a trust boundary.

## Concurrency & state
- Shared mutable state without synchronization; race conditions.
- `await`/promise not awaited; unhandled rejection; fire-and-forget that matters.
- Deadlock / lock-ordering; check-then-act (TOCTOU) races.

## Data & API contracts
- Breaking change to a public signature, response shape, or DB schema — grep its
  call sites/consumers and confirm they still hold under the new contract.
- Backward/forward compatibility for persisted data and serialized formats.
- Migration present and reversible when the schema changes.
- Destructive or irreversible operation with no scoping predicate: DELETE/UPDATE/DROP/TRUNCATE (or equivalent ORM/file/cache call) with no filter, the wrong filter, or a filter that can evaluate to "match everything."
- Migration or code path that drops/renames/overwrites a column, table, key, or file that is still read elsewhere in the codebase.
- N+1 queries, unbounded result sets, missing pagination or index — including a bound parameter whose *value* is unchecked and could be arbitrarily large/negative (e.g. `LIMIT ?` fed an unvalidated huge or negative number) — that is a resource-exhaustion/Medium finding on its own axis, independent of the injection question.

## Performance (only when plausibly hot)
- Accidental quadratic loops; work inside a loop that belongs outside it.
- Repeated recomputation that could be hoisted or cached.
- Large allocations / reads with no streaming or limit.

## Tests
- New behavior and the bug being fixed are covered by a test.
- Edge cases from the "Correctness" section are tested, not just the happy path.
- Tests assert real outcomes, not tautologies or mocked-away logic.

## Maintainability (keep brief — nits, not blockers)
- Dead code, unused variables/imports, leftover debug prints or TODOs.
- Duplication that already exists elsewhere and could be reused.
- Names that mislead; a comment that now contradicts the code.
- Needless complexity where a simpler form is equivalent.
