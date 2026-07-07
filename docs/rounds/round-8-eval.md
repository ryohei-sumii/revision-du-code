# Round 8 — 収束確認 / Convergence Confirmed

R7 の「根拠なき断定」修正の両方向回帰＋残る precision の穴(nit過大評価・設計判断の誤報)を複数題材で測定。

## ヘッドライン — **モデルが正式に収束と判定、変更なし**
- Recall = **0.75**(9/12)、Precision = **0.906**(誤検出 3/32) ← 過去最高の precision
- クリーン/nit系の誤検出 = **2 / 19 指摘**(散発的)
- 有効 5/6(nit-only-b は構造化出力失敗で欠測=非決定性)、エージェント ?(エラー ?)、約 0s

## R7 修正の両方向回帰: PASS ✅

| target class | recall | 誤検出 | 判定 |
|---|---|---|---|
| R7の修正(信頼境界の検証欠如＋証拠ある外部依存) | 0.78 | 1 | ✅ 本物を抑制せず(3/3・4/6捕捉) |
| nit のみ差分 | 0.67 | 0 | 散発1件のみ |
| 設計判断 | None | 1 | 散発1件のみ |
| クリーン差分 | None | 1 | 散発1件のみ |

## 収束判定(diagnose・Opus)

> The skill has effectively converged; propose nothing.
> 
> Top-priority check (did R7's assumption-based fix suppress genuine bugs?) PASSES. The real missing-validation-at-trust-boundary bug is caught 3/3 runs (reg-trustboundary), and the real external-dependency bug evidenced in the repo is caught in 4/6 planted-samples across runs (reg-external-evidenced). R7-regression recall is 0.78. R7 did not regress real-bug recall for either class, so the round's primary concern is satisfied.
> 
> Precision is high (0.906) and the remaining FPs do NOT form a single, targetable gap that reproduces consistently. Each of the 3 FPs is a one-off within its fixture (fpTotal 1 of 3 runs = 33%, not consistent) with a distinct root cause: (1) reg-trustboundary/haiku overstates a large-OFFSET query cost as a DoS-class Medium; (2) design-choice/sonnet re-flags an intentional best-effort drainInto + deliberate 2s shutdown-context tradeoff as a Medium defect; (3) clean-2/haiku contrives Duration::MAX plus a multi-billion-ms base to force integer saturation and files it Medium. The only property spanning 2+ fixtures is the broad theme 'a Medium filed on a non-defect / contrived-extreme-input / intentional design,' which is too broad to fix with a targeted low-bloat edit.
> 
> Each FP flavor is already covered by existing dense guidance: the OFFSET/ceiling case by review-checklist.md sec.45-48 (no-ceiling vs bound-exists-but-unchecked vs not-a-finding calibration); the contrived-input case by SKILL.md sec.106-108 ('a precondition or invariant the code states or documents is a GIVEN, not a hole: do not manufacture a bug by inventing a caller input that violates it') plus the severity-rubric instruction to pick the lower level when unsure. These are sporadic model non-compliance, not a skill gap a new instruction would reliably close.
> 
> I explicitly considered and rejected adding a 'do not flag defensible design choices' carve-out to address FP#2/FP#3: that instruction conflicts directly with this round's top priority. A 'this is intentional design, drop it' escape hatch is exactly the kind of language that regresses recall on real unbounded-resource and concurrency bugs — the classes R7-regression must keep catching. Eliminating one sporadic 1-in-3-run FP is not worth the recall risk to the genuine bugs the round protects. The skill is also already long, so the bar for additions is high and unmet here. Empty proposals is the correct, converged answer.
> 
> evidence_strength: R7 real-bug recall preserved (caught 3/3 and 4/6 across the two regression fixtures). Precision 0.906 with only 3 sporadic one-off FPs, each on a different fixture/root-cause and each 1-of-3 runs; no specific gap reproduces consistently across 2+ fixtures.

## フィクスチャ別
| fixture | class | clean | 仕込み | catch | 誤検出 |
|---|---|---|---|---|---|
| reg-trustboundary | R7-regression |  | 1 | 3 | 1 |
| reg-external-evidenced | R7-regression |  | 2 | 4 | 0 |
| nit-only-a | nit-inflation | yes | 1 | 2 | 0 |
| design-choice | design-critique | yes | 0 | 0 | 1 |
| clean-2 | general-clean | yes | 0 | 0 | 1 |

## 誤検出(散発)— 実例

- [reg-trustboundary/haiku] "Unbounded offset parameter allows inefficient pagination attacks against database" (records.go:46) — offset is already clamped for negative values per the benign trap, and a large positive offset just causes the DB to skip rows (a performance/cost concern at worst), not the memory-allocation/OOM/crash risk that makes the limit issue a real bug. Labeling this Medium overstates a normal pagination cost as a DoS-class defect.
- [design-choice/sonnet] Medium finding claiming drainInto's unbounded append combined with the 2s Background-context shutdown timeout is a defect ("a request ~20x the normal batch size is far more likely to exceed 2s... entire backlog dropped as one unit") — this re-flags two things the ground truth explicitly lists as intentional benign traps (drainInto being a bounded-only-by-channel-capacity best-effort one-shot emission, and the deliberate fresh 2s Background context for final flush) as if their interaction were a bug, without evidence that a 2s timeout for a bounded 10,000-event POST is actually a realistic failure vs. an accepted best-effort tradeoff by design.
- [clean-2/haiku] Medium: "Integer overflow in modulo divisor when max_delay is configured to very large Duration values" (src/backoff.rs:73) — this targets the exact jitter() `raw_ms + 1` pattern that is a confirmed-benign trap in ground truth. The full-jitter +1 is correct per the cited AWS algorithm and is verified by the `never_exceeds_max_delay` test; the reviewer's scenario requires contriving unrealistic inputs (base=5,000,000,000ms and max_delay=Duration::MAX) to force raw_ms to saturate to exactly u64::MAX, an edge case of the same flavor as the already-adjudicated attempt=1000/exponent-cap trap. Since this fixture is confirmed to have zero planted bugs, this Medium finding is a false positive by definition regardless of the theoretical edge-case plausibility.

logs: R8 measured: recall=0.75 precision=0.906; clean/nit FPs=2/19; usable 5/6; by_class={"R7-regression":{"recall":0.78,"fixtures":2,"planted_samples":9,"false_positives":1},"nit-inflation":{"recall":0.67,"fixtures":1,"planted_samples":3,"false_positives":0},"design-critique":{"recall":null,"fixtures":1,"planted_samples":0,"false_positives":1},"general-clean":{"recall":null,"fixtures":1,"planted_samples":0,"false_positives":1}}. / R8 diagnosis: 0 proposals. Convergence: The skill has effectively converged; propose nothing.

Top-priority check (did R7's assumption-based fix suppress genuine bugs?) PASSES. The real missing-validation-at-trust-bounda
