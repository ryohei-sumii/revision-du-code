# Round 7 — 収束判定＋広域回帰 / Convergence + Broad Regression

6ラウンドの狭い調整(security/resource/regex)による**過学習/肥大化**を検査し、収束したかを判定。

## ヘッドライン
- Recall = **0.933**(14/15)、Precision = **0.814**(誤検出 8/43)
- **クリーン差分の誤検出 = 0 / 1 指摘** → 過学習なし(でっち上げ指摘をしない)
- 有効 7/7、エージェント ?(エラー ?、空 ?)、約 0s

## クラス別(過学習・回帰の検査)

| target class | recall | 誤検出 | 判定 |
|---|---|---|---|
| R6の2修正(両方向回帰) | 1 | 0 | ✅ recall 1.0・誤検出0 — 両方向で検証 |
| 素の correctness(null-deref等) | 0.89 | 3 | ✅ 0.89 — 狭い調整で基礎を損なっていない |
| 完全にクリーンな差分 | None | 0 | ✅ 誤検出0 — でっち上げなし |
| nit のみ | None | 5 | ⚠ 誤検出5 — 良性トラップを Medium に膨らませる(下記) |

## 収束判定(diagnose)

> Converged on recall (0.933 overall; R6-regression 1.0 with 0 FP across both regression fixtures and all 3 models — both R6 changes validated; clean fixture 0 FP; general-correctness 0.89). There is ONE real, reproducible precision gap, not full convergence: benign-trap re-derivation. 6 of 8 FPs share a single root — asserting a defect that rests on an assumption the diff/repo does not support: (a) inventing out-of-contract input to violate a DOCUMENTED precondition (JitterPct in [0,1] flagged by opus AND haiku), and (b) resting a finding on an UNCONFIRMED external fact — math/rand auto-seeding pre-Go-1.20 (sonnet AND haiku), an unverifiable DB-driver transaction-abort semantic (gen-errorhandling/opus, self-admittedly 'not in the repo'), or that a removed param was public API with no evidence (gen-mixed/sonnet). This reproduces across all 3 models and 3 fixtures. The existing §4 'don't assert a defect you cannot see' guidance only covers READING referenced-but-unshown code; it does not cover these two assumption types, so the gap is genuine and worth one targeted, low-bloat addition rather than declaring full convergence.

- モデル別 誤検出: {"opus": 4, "sonnet": 2, "haiku": 2} / 取りこぼし: {"haiku": 1}

## フィクスチャ別
| fixture | class | clean | 仕込み | catch | 誤検出 |
|---|---|---|---|---|---|
| reg-test-recall | R6-regression |  | 1 | 3 | 0 |
| reg-zerovalue | R6-regression |  | 1 | 3 | 0 |
| gen-correctness | general-correctness |  | 1 | 3 | 0 |
| gen-errorhandling | general-correctness |  | 1 | 3 | 1 |
| gen-clean | general-clean | yes | 0 | 0 | 0 |
| gen-nits | general-maintainability |  | 0 | 0 | 5 |
| gen-mixed | general-correctness |  | 1 | 2 | 2 |

## 誤検出(precision の穴)— 実例

- [gen-errorhandling/opus] Finding 3 (Medium, withRetry wrapping tx.insert at line 47): claims retrying a single insert inside the same transaction is ineffective/contradicts the retry comment because a statement error aborts the whole transaction on 'common SQL engines'. This flags the confirmed-benign trap (withRetry around tx.insert cannot cause duplicates and is unrelated to the real defect) as a design flaw/defect, based on speculative unconfirmed driver semantics ('exact driver semantics aren't in the repo'), and is not the planted bug (missing rollback/commit handling).
- [gen-nits/opus] Medium: "Max cap applied after jitter defeats jitter at the ceiling / causes thundering herd" — this is a design-pattern critique, not a substantiated defect on this clean fixture; capping the already-jittered value at Max is a common, valid implementation choice (backoff never exceeds the max, herd converges only once already at the ceiling, which is expected/acceptable behavior), so this Medium finding is a false positive per the clean-fixture rule.
- [gen-nits/opus] Low: "JitterPct unvalidated so a caller setting it >1 can produce a negative Duration causing a busy retry loop" — this directly re-derives the documented benign trap (jitter math relies on the stated JitterPct ∈ [0,1] precondition, under which d is never negative) by assuming the caller violates the documented contract, then presents the resulting hypothetical as a defect needing a fix/clamp. This is flagging the confirmed-benign trap as a bug rather than accepting the documented precondition.
- [gen-nits/sonnet] Finding 1 (Question, Medium if true) on rand.Float64() seeding for Go <1.20 thundering-herd risk directly re-raises the confirmed-benign trap about math/rand auto-seeding; despite being hedged as a 'Question', it asserts a concrete failure scenario and assigns a conditional Medium severity, effectively flagging a benign trap as a plausible bug.
- [gen-nits/haiku] "JitterPct parameter not validated... allowing negative jitter multipliers" — this re-derives the exact benign trap about only the upper bound being clamped; it ignores the documented precondition that JitterPct ∈ [0,1] (stated in the ground truth as the reason the code is safe) and instead invents an out-of-range caller input (1.5) to manufacture a failure scenario. Flagging this as a Medium bug is a false positive.
- [gen-nits/haiku] "math/rand used without explicit seeding... deterministic sequence in Go <1.20" — this is precisely the benign trap confirmed safe by Go 1.20+ auto-seeding of the global rand source (Seed is unnecessary/deprecated). The finding hedges with 'or Go 1.20+ if seeding is not configured elsewhere' but the whole point of the trap is that no explicit seeding is required. False positive.
- [gen-mixed/opus] Finding on accountBalance summing only first page/MAX_LIMIT: ground truth explicitly labels this as a benign trap ('fine / unchanged from prior behavior'), so flagging it as a Low-severity defect (even framed as a pre-existing aside) is a false positive.
- [gen-mixed/sonnet] Medium: removal of `offset` query param as a silent breaking API change — asserts a specific external-contract break and unversioned deployment without any evidence in the diff that `offset` was a documented/public parameter or that no version bump occurred; speculative rather than substantiated.

logs: R7 measured: recall=0.933 precision=0.814; clean-diff FPs=0/1 findings; usable 7/7; by_class={"R6-regression":{"recall":1,"fixtures":2,"planted_samples":6,"false_positives":0},"general-correctness":{"recall":0.89,"fixtures":3,"planted_samples":9,"false_positives":3},"general-clean":{"recall":null,"fixtures":1,"planted_samples":0,"false_positives":0},"general-maintainability":{"recall":null,"fixtures":1,"planted_samples":0,"false_positives":5}}. / R7 diagnosis: 1 proposals. Convergence: Converged on recall (0.933 overall; R6-regression 1.0 with 0 FP across both regression fixtures and all 3 models — both R6 changes validated; clean fixture 0 FP; general-correctnes / R7: 1/1 proposals survived sparring.
