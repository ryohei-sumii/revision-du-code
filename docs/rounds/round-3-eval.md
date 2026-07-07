# Round 3 — 経験的評価スコア / Empirical Eval

現行スキル(R2適用済み)を実際にレビューさせ正解と照合した測定値。**R2 の3つの穴**
(欠測/取りこぼしクラス/precision修正の回帰)を狙って設計。

## ヘッドライン(R2 → R3)
- **Recall = 0.926**(仕込み照合 25/27)  ← R2 は 0.80。**向上**
- **Precision = 0.86**(誤検出 7/50)  ← R2 は 0.84。**ほぼ維持**
- **有効フィクスチャ 6/6**(欠測 なし)  ← R2 は 3/4 で1件欠測。**堅牢化成功**
- extra_valid 9 件、使用エージェント ?(エラー ?)、約 0s、トークン ?

## クラス別 recall(高いほど見逃さない)

| bug class | recall |
|---|---|
| resource-exhaustion | 0.67 |
| injection | 0.67 |
| api-contract-break-units | 1 |
| wrong-operator (min vs max) | 1 |
| broken-access-control | 1 |
| sql-injection | 1 |
| logic-error | 1 |
| destructive-data-loss / unscoped DELETE (missing WHERE clause) | 1 |
| toctou-across-await / shared-mutable-buffer race | 1 |

- モデル別取りこぼし: {"haiku": 2}

## フィクスチャ別

| fixture | 目的 | 仕込み | 実行 | 累計catch |
|---|---|---|---|---|
| contract-break | regression (dropped in R2) | 1 | 3 | 3 |
| logic-error | recall target (missed in R2) | 1 | 3 | 3 |
| resource-exhaustion | recall target (missed in R2) | 3 | 3 | 7 |
| sqli-mixed | regression guard for R2 precision fix | 2 | 3 | 6 |
| data-loss | regression | 1 | 3 | 3 |
| concurrency | regression | 1 | 3 | 3 |

## 誤検出(precision の穴)— 実例

- [resource-exhaustion/opus] Finding 4 (Low, page_size le=100 -> le=500): ground truth explicitly verifies this is a benign bounded tuning change (still hard-capped at 500 with offset/limit), not a resource-exhaustion vector or bug. Reviewer frames it as a defect worth confirming with a failure_scenario, which mischaracterizes a verified-fine trap as a mild issue.
- [resource-exhaustion/sonnet] Low finding on 'page_size Query bound le=100 -> le=500' presents it as a concern needing confirmation, but ground truth explicitly verifies this is a bounded, deliberate tuning change and not a bug (still hard-capped at 500 with offset/limit).
- [resource-exhaustion/haiku] page_size le=100 -> le=500 flagged as High resource-exhaustion risk, but this is an explicitly verified benign trap: FastAPI still enforces a hard le=500 bound with offset/limit, so it's a bounded tuning change, not a new DoS vector.
- [resource-exhaustion/haiku] Sorting order inconsistency (asc vs desc) flagged as Medium bug, but no such asc/desc mismatch is part of the ground truth; the actual export bug is the missing LIMIT/streaming (unbounded-export), which this finding does not identify. This appears to misdescribe the code and is not a substantiated defect.
- [sqli-mixed/haiku] Finding 3 (reports.js:23) claims 'missing format validation on userId' can cause 'database performance degradation or unexpected behavior' from an 'extremely long or specially-formatted' string. But per the SQLi finding's own context, userId is passed as a bound `?` placeholder (parameterized), so its format/length poses no injection risk and no credible performance mechanism is given — this is speculative and unsubstantiated, not a concrete defect.
- [data-loss/sonnet] Medium finding claiming op.drop_column("guest_sessions", "legacy_token") is a bug because downgrade() doesn't restore data — this is exactly the planted benign trap (drop_column reads as risky but isn't flagged as a real defect in ground truth); asserting irreversible data loss as a defect on a column not shown to be used elsewhere in the diff is unsubstantiated.
- [concurrency/sonnet] Finding 1 (Critical, flush() at lines 64-69): claims clearing this.buffer before the send resolves is itself a bug causing permanent data loss on transport failure. This attacks the exact capture-then-clear-before-await pattern that ground truth explicitly calls out as the *correct* approach (contrasted with record()'s buggy in-place mutation). Dropping a batch on transport failure is a common, often-intentional at-most-once delivery tradeoff for metrics/telemetry systems, not an inherent defect; the finding also asserts an unverifiable comparison to 'pre-diff behavior' not shown in the diff. Overstated as Critical for what is at most a design/retry-policy question.
- [concurrency/haiku] Finding 4 ('Breaking behavioral change: events are no longer sent immediately on record()') treats the intentional switch to batching as a defect, framing it as a regression/durability issue without evidence this violates any stated contract in the diff — this is the intended feature (batching), not a bug.

## 重大度の誤較正

- [resource-exhaustion/opus] Finding 3 (unbounded-export) rated Medium by reviewer but ground truth severity is Critical — this is a significant under-calibration given the described DoS/OOM blast radius across a whole worker process.
- [resource-exhaustion/opus] Finding 2 (csv-formula-injection) rated High by reviewer but ground truth severity is Medium (contingent on unconfirmed provenance of tx.description) — a minor over-calibration, not a major issue.
- [resource-exhaustion/sonnet] unbounded-export (unbounded q.all() + full in-memory CSV buffer) rated Medium by the reviewer but ground truth rates it Critical given DoS/OOM blast radius and its combination with the missing-authz bug to let any user trigger it against any account on demand.
- [sqli-mixed/sonnet] Finding 'No tests were added for the new filtering/sorting logic or the export endpoint' is labeled Medium severity but is a test-coverage nit/process observation rather than a code defect — arguably over-weighted relative to actual bugs.
- [sqli-mixed/sonnet] Filename collision from Date.now() millisecond resolution is correctly labeled Low/Nit — appropriately calibrated, not an issue.

logs: R3 measured: recall=0.926 precision=0.86; usable 6/6 (dropped: none); recall_by_class={"api-contract-break-units":1,"wrong-operator (min vs max)":1,"resource-exhaustion":0.67,"broken-access-control":1,"injection":0.67,"sql-injection":1,"logic-error":1,"destructive-data-loss / unscoped DELETE (missing WHERE clause)":1,"toctou-across-await / shared-mutable-buffer race":1}; FPs=7. / R3 diagnosis: 2 data-driven proposals. / R3: 2/2 proposals survived sparring.
