# Round 4 — 経験的評価スコア / Empirical Eval

R3 で残った弱クラス(injection / resource-exhaustion, 各 0.67)を**多様で難しいバリアント**で深掘り。

## ヘッドライン(R3 → R4)
- **Recall = 0.889**(24/27)  ← R3 は 0.926。**より難しい題材で微減**
- **Precision = 0.957**(誤検出 3/70)  ← R3 は 0.86。**大幅向上**
- 有効フィクスチャ **7/7**(欠測 なし)、extra_valid **37**(難題ゆえ本物の副次バグ多数を捕捉)
- 使用エージェント ?(エラー ?)、約 0s、トークン ?

## クラス別 recall
| bug class | recall |
|---|---|
| catastrophic-regex-backtracking (ReDoS, CPU/time exhaustion) | 0.67 |
| unbounded-memory | 0.67 |
| security-ssrf-redirect-bypass | 0.67 |
| os-command-injection | 1 |
| unsafe-deserialization | 1 |
| logic-error | 1 |
| SSRF (server-side request forgery) | 1 |
| resource-leak | 1 |
| resource-exhaustion | 1 |

- モデル別取りこぼし: {"haiku": 3}
- **残る穴:** ReDoS(壊滅的正規表現) 0.67 / unbounded-memory(全読み込み) 0.67 / SSRF-redirect-bypass 0.67 — いずれも haiku が主に取りこぼし。

## フィクスチャ別
| fixture | 目的 | 仕込み | 実行 | 累計catch |
|---|---|---|---|---|
| inj-command | recall deepen (injection 0.67 in R3) | 1 | 3 | 3 |
| inj-path-traversal | recall deepen (injection) | 0 | 3 | 0 |
| inj-deserialization | recall deepen (injection) | 2 | 3 | 6 |
| inj-ssrf | recall deepen (injection) | 1 | 3 | 3 |
| res-unbounded-loop | recall deepen (resource-exhaustion 0.67 in R3) | 1 | 3 | 2 |
| res-full-read | recall deepen (resource-exhaustion) | 3 | 3 | 7 |
| calibration-regression | two-way regression guard for R3 calibration change | 1 | 3 | 3 |

> 注: inj-path-traversal は verify で仕込みバグが本物と確認できず(nPlanted=0)、集計から除外。正解データの誠実性を優先。

## 誤検出(precision の穴)— 実例

- [inj-ssrf/haiku] src/routes/preview.js:28 — flags JSON.parse on cached data as needing try-catch; this is exactly the planted benign trap (untrusted-deserialization-looking JSON.parse on cache), not a real defect since cache only ever contains data the service itself wrote via JSON.stringify
- [res-unbounded-loop/sonnet] Medium finding claiming save_profile might silently overwrite email/website with empty strings when omitted from the request — save_profile's body is explicitly outside the diff and not confirmed, so this is speculative/unsubstantiated rather than a grounded defect (though the reviewer does hedge it appropriately).
- [calibration-regression/haiku] Finding 3 (export.py:16, High): 'order.customer.name without null-checking, which may be nullable' — the reviewer's own hedge ('assuming the ForeignKey is nullable') shows this is speculative; there is no diff evidence the customer FK is nullable, and it isn't one of the planted bugs or benign traps. Asserting a High-severity AttributeError crash on an unverified assumption is an unsubstantiated claim, not a confirmed defect.

## 重大度の誤較正

- [inj-command/sonnet] Finding 3 ("no tests added") is labeled Medium but is a coverage nit with an explicitly 'N/A' failure scenario — more appropriately Low/nit severity than Medium.
- [inj-command/haiku] 'Missing input validation for timestamp and resolution' (High) is largely a restatement of the already-reported critical shell-injection finding, but its failure_scenario is watered down to 'unclear error / resource-intensive operation' rather than RCE — the severity/impact framing undersells that this is the same root cause as the Critical finding, making it read as padding rather than a distinct High-severity issue.
- [inj-path-traversal/haiku] Finding 2 (missing Content-Type header) is labeled Medium but as described it's a UX/consistency nit (forces download vs inline display) rather than a functional defect or security issue; Low severity would be more appropriate unless content-type sniffing/XSS exposure is also implicated, which the finding does not substantiate.
- [inj-deserialization/sonnet] ttl-loaded-but-never-enforced: ground truth labels this medium, reviewer labels it High — arguably reasonable given security framing (indefinite session replay), not a clear miscalibration but worth noting as an upgrade in severity.
- [res-unbounded-loop/haiku] Finding 'Redundant nested quantifier in email regex pattern' (Low) is anchored at the exact planted-bug location (([\w.+-]+)+) but explicitly asserts 'without any behavioral change' — this is the near-catastrophic-ReDoS site (n=30 -> 66s), so the finding is not just under-severitied, it affirmatively denies the real defect exists. Should have been High/security, not Low/style.
- [res-unbounded-loop/haiku] Finding 'No test coverage shown for new validation functions' rated Medium — lack of test coverage is conventionally a nit/process observation, not a Medium-severity code defect; inflates severity relative to actual risk.
- [res-unbounded-loop/haiku] Finding 'Email regex validation is too permissive (RFC 5321/5322)' rated Medium — this is a minor strictness/spec-conformance nit (accepts a few non-RFC-compliant but harmless local-part forms), not a functional or security defect; Medium overstates impact.
- [res-full-read/opus] bug-1 (unbounded-memory OOM) rated 'critical' in ground truth but reviewer labeled it 'High' — a minor understatement, not materially wrong given it's a remotely triggerable single-request DoS.
- [res-full-read/sonnet] bug-3 (SSRF redirect bypass) ground truth severity is 'high'; reviewer labeled it 'Critical' — arguably justified given metadata-service SSRF impact, so not a serious miscalibration, just slightly elevated.
- [res-full-read/haiku] bug-2 (resource leak) planted as medium severity but reviewer labeled it High — arguably reasonable given it also covers the retry-loop leak angle loosely, but somewhat inflated since it's a slow-building leak, not an immediate high-impact issue.

logs: R4 measured: recall=0.889 precision=0.957; usable 7/7 (dropped: none); recall_by_class={"os-command-injection":1,"unsafe-deserialization":1,"logic-error":1,"SSRF (server-side request forgery)":1,"catastrophic-regex-backtracking (ReDoS, CPU/time exhaustion)":0.67,"unbounded-memory":0.67,"resource-leak":1,"security-ssrf-redirect-bypass":0.67,"resource-exhaustion":1}; FPs=3. / R4 diagnosis: 4 data-driven proposals. / R4: 0/4 proposals survived sparring.
