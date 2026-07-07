# Round 6 — 経験的評価スコア / Empirical Eval

**R5 の ReDoS/regex 追加の両方向回帰確認**＋**繰り返し見えた precision の穴の系統測定**。

## ヘッドライン
- Recall = **0.722**(13/18)、Precision = **0.817**(誤検出 11/60)
- 有効 6/6、extra_valid 35、エージェント ?(エラー ?)、約 0s、トークン ?

## 回帰確認: R5 の ReDoS/regex 追加は両方向で機能 ✅

| target class | recall | 誤検出 | 判定 |
|---|---|---|---|
| 本物のReDoS(拾うべき) | 0.83 | 3 | ✅ 0.83 — ゲートは recall を殺していない |
| 良性ReDoSそっくり(誤報しない) | 0 | 0 | ✅ 誤検出0 — ゲートが効いている |
| 未アンカー検証(拾うべき) | 1 | 0 | ✅ 1.0 — R5 の recall 追加が機能 |

## 系統測定で再現した precision の穴

| テスト未追加のみの差分 | 0.67 | 3 | ⚠ 誤検出3 — 「no tests」を Medium 単独指摘 |
| 暗号/リファクタそっくり | 1 | 5 | ⚠ 誤検出5 — 良性トラップ誤報＋test-coverage |

- モデル別 誤検出: {"opus": 1, "sonnet": 5, "haiku": 5}(sonnet/haiku に集中)
- モデル別 取りこぼし: {"haiku": 3, "opus": 1, "sonnet": 1}

## フィクスチャ別
| fixture | class | 仕込み | 実行 | catch | 誤検出 |
|---|---|---|---|---|---|
| redos-real | ReDoS-recall-regression | 2 | 3 | 5 | 3 |
| redos-benign | ReDoS-precision-regression | 1 | 3 | 0 | 0 |
| regex-anchoring | regex-correctness-recall | 1 | 3 | 3 | 0 |
| prec-tests | precision-test-coverage | 1 | 3 | 2 | 3 |
| prec-crypto | precision-benign-lookalike | 0 | 3 | 0 | 1 |
| prec-refactor | precision-benign-lookalike | 1 | 3 | 3 | 4 |

## 誤検出(precision の穴)— 実例

- [redos-real/opus] Medium finding claiming validateProfile makes displayName mandatory on every PATCH (via `const { bio, displayName, tags = [] } = req.body` + unconditional validateDisplayName call), breaking partial-update semantics. This targets the exact location flagged in ground truth as a benign trap ('Only tags gets a destructuring default; could be mistaken for a crash risk when bio/displayName are omitted'). The reviewer avoided the literal 'crash' framing but substituted an unverified claim about validateProfile's internals (that it unconditionally type-checks displayName as a required string with no undefined/omitted-field branch) which is not supported by the ground truth and is not a planted or confirmed-real defect — it's the same trap location repackaged as a validation-regression claim rather than a crash claim.
- [redos-real/sonnet] High: "displayName now required, backward-incompatible" — asserts validateDisplayName has no undefined/optional branch and always rejects a bio-only PATCH; this contradicts the benign-trap context (the destructuring-default trap implies displayName/bio absence is handled gracefully, not that validation now hard-requires the field) and is not a planted or independently substantiated defect — reads as an invented/unverified claim about validator internals not shown in the diff excerpt.
- [redos-real/sonnet] Medium: "No tests were added for the new validators... test coverage gap" — files a bare no-tests/process observation as a Medium standalone defect (explicitly disqualified per review-quality rules regardless of the secondary tags-overwrite speculation bundled into the same finding).
- [prec-tests/sonnet] "No tests accompany a brand-new package..." filed as a standalone Medium severity defect about missing test coverage — this is a bare process/no-tests observation elevated to Medium, which the scoring rubric treats as a false positive regardless of how well-reasoned the surrounding technical detail (refill arithmetic, concurrency, TTL eviction) is.
- [prec-tests/haiku] Finding 1 ("Limiter goroutine never stopped, causing a resource leak", server.go:26-33) is exactly the documented benign trap: Stop() exists and is documented, and a single long-lived janitor goroutine tied to the process-lifetime *http.Server is intentional, not a leak.
- [prec-tests/haiku] Finding 3 ("Breaking API change to Config struct... existing code... now fails to compile", server.go:12-16) is factually wrong: adding new fields to a Go struct does not break existing keyed struct literals like Config{Addr: ..., ReadTimeout: ...} — they still compile fine with the new fields zero-valued. That same zero-value fact is actually the mechanism behind the real planted bug (fail-closed permanent rejection), but the finding mischaracterizes it as a compile-time breaking change rather than the actual silent runtime failure, so it does not correctly identify bug-1 either.
- [prec-crypto/sonnet] "The new ThumbnailCache class ships with no unit tests" filed as a standalone Medium-severity defect — this is a bare 'no tests added' process observation, not a concrete code defect, and per scoring rules such findings are false positives regardless of how well-reasoned the surrounding justification is.
- [prec-refactor/sonnet] Finding 5 (OrderProcessor.test.ts): flags the test's inability to catch bugs 2 and 3 as a Medium standalone defect — this is a test-coverage/process observation, not a defect in the shipped code, and per rubric should not be filed as a Medium-or-higher standalone finding.
- [prec-refactor/haiku] Test imports FakeGateway from file not present in diff and assumes undocumented property (src/orders/OrderProcessor.test.ts:4,25) — flags absence of a file not included in the diff as a compile-blocking defect, which is speculative given partial-diff review rather than a demonstrated bug in shown code.
- [prec-refactor/haiku] Order object passed to test includes idempotencyKey field not shown in Order type definition — same speculative 'type not shown in diff' complaint, not a concrete defect.
- [prec-refactor/haiku] Test verifies only charge count, not idempotency contract for caller — a test-quality/coverage critique filed as a standalone Medium defect rather than a production code bug.

## 重大度の誤較正(抜粋)

- [redos-real/haiku] tags-some-not-every labeled 'Critical' by reviewer vs ground-truth 'high' — overstated but directionally reasonable given it's a validation bypass, not a major miscalibration on its own.
- [prec-tests/sonnet] bug-1 (zero-value RateLimitPerSec/RateLimitBurst causing permanent rejection of all requests) was correctly identified with the exact right mechanism and failure scenario, but was downgraded to a 'Question' severity purely because the reviewer couldn't see the config-loading call site in the diff. Ground truth treats this as a definite High-severity fail-closed/availability bug — the standard Go zero-value-on-new-field risk is real and doesn't require seeing external code to flag at High/Medium confidence; hedging it down to a non-blocking Question undersells a serious finding that happens to be exactly correct.
- [prec-tests/sonnet] The ttl<=0 -> NewTicker panic in janitor() is filed as Medium, but the only current call site hardcodes 10*time.Minute so the defect is purely speculative/future-facing (no live path in this diff triggers it) — arguably more appropriate as a Low/nit or Question than a standalone Medium defect.
- [prec-tests/haiku] Finding 1 was labeled High severity but is not a bug at all (confirmed benign trap), so the severity is moot/wrong.
- [prec-tests/haiku] The single planted High-severity bug (fail-closed rate limiter takes down the whole service including /healthz) was entirely missed — no finding touches the RateLimitPerSec/RateLimitBurst zero-value fail-closed behavior.
- [prec-refactor/haiku] Finding on non-null assertion for STRIPE_KEY rated 'High' — real defensive-coding point but arguably overstated versus a config validation nit; borderline extra_valid rather than a high-severity correctness bug.

logs: R6 measured: recall=0.722 precision=0.817; usable 6/6; by_target_class={"ReDoS-recall-regression":{"recall":0.83,"fixtures":1,"planted_samples":6,"false_positives":3},"ReDoS-precision-regression":{"recall":0,"fixtures":1,"planted_samples":3,"false_positives":0},"regex-correctness-recall":{"recall":1,"fixtures":1,"planted_samples":3,"false_positives":0},"precision-test-coverage":{"recall":0.67,"fixtures":1,"planted_samples":3,"false_positives":3},"precision-benign-lookalike":{"recall":1,"fixtures":2,"planted_samples":3,"false_positives":5}}; FPs=11. / R6 diagnosis: 2 data-driven proposals. / R6: 2/2 proposals survived sparring.
