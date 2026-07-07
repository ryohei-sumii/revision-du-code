# Round 5 — 経験的評価スコア / Empirical Eval

**弱クラスを各複数フィクスチャで測定**し、R4 の取りこぼしが再現するか(＝恒久変更に足る証拠か)を検証。

## ヘッドライン
- Recall = **0.822**(37/45)、Precision = **0.872**(誤検出 10/78)
- 有効フィクスチャ 8/8、extra_valid 23、使用エージェント ?(エラー ?)、約 0s、トークン ?

## クラス別 recall(多フィクスチャ証拠)— R4単発値との比較

| target class | R5 recall | フィクスチャ数 | サンプル数 | R4(単発) |
|---|---|---|---|---|
| ReDoS | **0.73** | 3 | 15 | 0.67 |
| unbounded-memory | **0.86** | 3 | 21 | 0.67 |
| SSRF-redirect | **0.89** | 2 | 9 | 0.67 |

> **重要:** R4 で 0.67 と見えた3クラスは、多フィクスチャで測ると 0.73 / 0.86 / 0.89 と改善。
> ⇒ **R4 の取りこぼしは主に単発フィクスチャのノイズ／難問固有**であり、一貫した穴ではなかった。
> **R4 の壁打ち却下(過学習防止)が正しかったことを実測が裏づけた。**

- モデル別取りこぼし: {"haiku": 7, "sonnet": 1}(haiku 集中)

## フィクスチャ別
| fixture | class | 仕込み | 実行 | 累計catch |
|---|---|---|---|---|
| redos-email | ReDoS | 2 | 3 | 5 |
| redos-url | ReDoS | 1 | 3 | 2 |
| redos-sanitize | ReDoS | 2 | 3 | 4 |
| mem-httpbody | unbounded-memory | 3 | 3 | 7 |
| mem-fileread | unbounded-memory | 2 | 3 | 5 |
| mem-aggregate | unbounded-memory | 2 | 3 | 6 |
| ssrf-webhook | SSRF-redirect | 2 | 3 | 5 |
| ssrf-imgproxy | SSRF-redirect | 1 | 3 | 3 |

## 誤検出(precision の穴)— 実例

- [redos-email/opus] EMAIL_REGEX = /\A([\w.%+\-]+)+@.../ flagged as a 'canonical catastrophic-backtracking (ReDoS)' shape. Empirically verified (ran the exact pattern against inputs up to 50,000 chars with no '@') that it matches in linear/constant time with no blow-up — the inner character class has no internal ambiguity (no alternation, no overlapping sub-patterns), so there is nothing for the backtracking engine to explode over, unlike a true (a|aa)+ or (a+)+ -with-ambiguous-split case. The reviewer's own hedge ('I could not reproduce a hang... latent, not a live defect') already signals this isn't a substantiated defect, and it was not among the planted bugs or traps — it's a look-alike pattern that isn't actually vulnerable, structurally the same kind of trap as the USERNAME_REGEX benign trap in ground truth.
- [redos-email/sonnet] Finding #1 (Critical, EMAIL_REGEX line 14): claims `([\w.%+\-]+)+` causes catastrophic ReDoS backtracking. Empirically verified false — tested this exact pattern and the textbook `(a+)+` ReDoS shape in Ruby 3.3.6 against inputs up to 20,000 chars with no exponential blowup (modern Onigmo mitigates this nested-quantifier shape). This is structurally the same 'looks risky but isn't' trap the ground truth planted for USERNAME_REGEX, just misapplied to EMAIL_REGEX with a Critical severity label — the worst kind of false positive since it's both wrong and alarmingly overrated.
- [redos-email/haiku] Finding on EMAIL_REGEX 'redundant nested quantifier' at line 12: claims ([\w.%+\-]+)+ is a defect suggesting 'regex misunderstanding', but explicitly admits 'No behavioral impact' — no concrete failure scenario, not a genuine defect, just an unsubstantiated style nit presented as a finding.
- [mem-fileread/opus] Finding at avatar.go:73 flags MD5 used for the content-addressed dedup key as a 'weak-hash' issue needing SHA-256, but the ground truth explicitly marks this as a benign trap — no security/integrity decision depends on collision resistance since keys are already namespaced per-user; hedging it as a 'Nit' doesn't change that it's asserting a non-existent vulnerability.
- [mem-fileread/sonnet] Finding 4 (MD5 used to derive content-addressed storage key, severity Low) flags the explicitly benign trap: MD5 here is purely a dedup/content-addressing key scoped under the user's own storage prefix, no security/integrity decision relies on collision resistance. The reviewer even concedes it's 'not exploitable as a real vulnerability here' yet still lists it as a defect/finding, which is exactly the trap the ground truth says must not be flagged as a bug.
- [mem-aggregate/sonnet] Medium finding claiming unknown currency codes silently fall back to 2 decimal places in the amount formatting (~lines 51-56) — this targets the explicitly-benign 'F+scale formatting via CultureInfo.InvariantCulture' trap location; no evidence in the diff of a TryGetValue-with-default fallback behavior, it's an unsubstantiated behavioral claim about the exact trap construct.
- [mem-aggregate/sonnet] Medium finding claiming ToDictionary in the constructor throws ArgumentException on duplicate currency Codes, crashing service construction — this targets the explicitly-benign 'materializes full currency table into a dictionary at construction' trap; the concern is purely hypothetical (assumes bad/duplicate reference data that isn't indicated anywhere in the diff) rather than a substantiated defect.
- [mem-aggregate/haiku] Constructor signature change (adding ICurrencyRepository param) flagged as a defect — this is just normal DI-based refactoring, not a bug in the diff; no evidence given that any non-DI call site exists.
- [mem-aggregate/haiku] Synchronous currency-table load in constructor flagged as a 'blocking initialization' bug — this is the planted benign trap (constructor materializes full currency table) being mischaracterized as a defect without evidence of actual scale/latency problems.
- [mem-aggregate/haiku] No error handling for currencyRepo.GetAll() failure flagged as a bug — again the same benign constructor trap; lack of try/catch around a repository call is a generic nit, not a substantiated defect, and constructor-throws-on-dependency-failure is often desired fail-fast behavior.

## 重大度の誤較正(抜粋)

- [redos-email/opus] overlong-email-accepted (ground truth severity: medium) was labeled 'High' by the reviewer — the underlying defect description is accurate, but severity is overstated relative to ground truth.
- [redos-url/sonnet] Second finding ('no tests added for redirect-validation changes') is labeled Medium but is a process/test-coverage nit, not a concrete present-day defect with its own failure scenario (the failure scenario described is hypothetical future regression) — should be Low/nit, not Medium.
- [redos-sanitize/sonnet] soft-hyphen-noop: reviewer labeled 'High', ground truth is 'medium' — minor over-rating, not consequential.
- [redos-sanitize/haiku] soft-hyphen-noop labeled 'High' by reviewer vs ground truth 'medium' — overstated but not egregious, and directionally reasonable since it's a real functional break
- [mem-httpbody/opus] body-leak-on-non-200: ground truth labels this Medium (resource leak / fd exhaustion over time), reviewer labeled it High. Directionally reasonable given it compounds with fd exhaustion, but overstates severity relative to ground truth.
- [mem-httpbody/opus] missing-ssrf-guard: reviewer downgraded this to a 'Question' and hedged on whether rawURL is attacker-controlled, when the package name (internal/unfurl) and function context (a link-preview fetcher) make it clear rawURL is externally supplied; ground truth treats this as a confirmed High SSRF. The hedge is defensible epistemic caution but is a mild underconfidence miscalibration since the surrounding code makes the trust boundary fairly evident.
- [mem-httpbody/sonnet] "No tests accompany this new feature" rated Medium — lack of test coverage is typically a Low-severity process nit, not a Medium code defect; inflates perceived severity of a non-bug observation.
- [mem-httpbody/sonnet] "Duplicate og:title overwrite" rated Low is reasonable/well-calibrated, not an issue.
- [mem-httpbody/sonnet] SSRF rated Critical vs ground-truth High is not a miscalibration in the concerning direction (over-caution on a real high-severity bug is acceptable).
- [mem-httpbody/haiku] 'Breaking API change: NewFetcher() signature changed' labeled High — a signature change causing a compile error is immediately visible at build time and trivially fixed, not a High-severity runtime/security risk on par with the unbounded-memory or SSRF issues; more reasonably Low/Medium depending on whether call sites were already updated elsewhere in the diff.
- [mem-fileread/sonnet] Both planted bugs were labeled 'Critical' vs ground truth 'high' — not a real miscalibration (arguably justified for the missing-return bug given full validation bypass), just noting the label difference since ground truth doesn't require exact match.
- [mem-fileread/sonnet] Finding 3 (no rollback/cleanup after SetAvatarKey failure) labeled Medium is reasonable but borderline — orphaned blob storage with no user-facing data corruption is arguably Low; not a serious miscalibration.

logs: R5 measured: recall=0.822 precision=0.872; usable 8/8; recall_by_target_class={"ReDoS":{"recall":0.73,"fixtures":3,"samples":15},"unbounded-memory":{"recall":0.86,"fixtures":3,"samples":21},"SSRF-redirect":{"recall":0.89,"fixtures":2,"samples":9}}; FPs=10. / R5 diagnosis: 2 data-driven proposals. / R5: 2/2 proposals survived sparring.
