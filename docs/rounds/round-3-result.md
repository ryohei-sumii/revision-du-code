# Round 3 — 診断 → 壁打ち → 適用 / Diagnosis, Sparring, Applied

測定された穴だけを改善案化し、別モデルが過学習・既出を疑って反証、生存案のみ適用。

## 診断(データ駆動の提案 2件)

### 1. [high] file=`/home/user/revision-du-code/.claude/skills/code-review/references/review-checklist.md`
- **狙う穴(測定値)**: Recurring false positive across all 3 models (opus/sonnet/haiku): raising a still-enforced finite cap `page_size le=100 -> le=500` flagged as a resource-exhaustion defect. Also the sibling severity under-calibration where a truly unbounded load is rated Medium.
- **提案**: Rewrite the single resource-exhaustion bullet (line 41) so it splits the class into two clearly-distinguished cases instead of one undifferentiated 'Medium' bucket. Replace:

'- N+1 queries, unbounded result sets, missing pagination or index — including a bound parameter whose *value* is unchecked and could be arbitrarily large/negative (e.g. `LIMIT ?` fed an unvalidated huge or negative number) — that is a resource-exhaustion/Medium finding on its own axis, independent of the injection question.'

with:

'- N+1 queries, unbounded result sets, missing pagination or index. Two distinct cases with different severities:
  - A query/result set that is loaded fully into memory with NO ceiling at all — no LIMIT, no pagination, no streaming (e.g. `q.all()` buffered into a CSV/JSON blob) — can exhaust process memory and take down the worker. This is High, or Critical when it runs in a shared worker/process or an attacker can trigger it on demand. Do not file it as Medium.
  - A bound parameter whose *value* is unvalidated and can be arbitrarily large or negative (e.g. `LIMIT ?` fed an unchecked huge/negative number, with no hard cap) is a Medium resource-exhaustion finding on its own axis, independent of the injection question.
- NOT a finding: raising a bound that remains a hard, finite, enforced cap (e.g. a `le=100` page-size limit changed to `le=500`, still rejecting larger values with offset/limit intact) is a bounded tuning change, not a new DoS vector. Do not flag a cap that still caps.'
- **予想効果**: Eliminates the most consistent false positive in the corpus (le=100->le=500, hit by 3/3 models) by explicitly naming the 'cap that still caps' non-finding, and simultaneously supplies the correct severity ladder so the unbounded full-table-into-memory export stops being anchored at Medium.

### 2. [medium] file=`/home/user/revision-du-code/.claude/skills/code-review/references/severity-rubric.md`
- **狙う穴(測定値)**: Recurring severity under-calibration (opus + sonnet): unbounded-export (unbounded `q.all()` + full in-memory buffer, OOM blast radius across a whole worker) rated Medium by reviewer, ground truth Critical. Root cause is the rubric offering only 'N+1 query' as a resource example, all at Medium.
- **提案**: Add a rule-of-thumb bullet in the 'Rules of thumb' list (after the security/data-loss/concurrency 'default up a level' bullet) to break the Medium anchor for the OOM case:

'- A result set materialized fully into memory with no ceiling — no LIMIT, no pagination, no streaming — is not a Medium like an N+1. If it can exhaust process/worker memory (unbounded rows buffered into a blob), it is High, and Critical when the OOM takes down a shared worker or an attacker can trigger it on demand. The Medium resource-exhaustion guidance applies to bounded-but-large or unvalidated-parameter cases, not to a load with no upper bound at all.'
- **予想効果**: Corrects the Critical-rated-as-Medium under-calibration seen in 2/3 models by giving the rubric an explicit high/critical example for unbounded in-memory loads, so reviewers stop defaulting the whole resource class to Medium.

## 壁打ち(反証 2件)

### 1. verdict=**keep** recall:neutral / precision:neutral / data支持:True / 既出:False
- 反論: Is this overfitting to one fixture, and could a fresh Critical/High anchor cause over-calibration on the very benign resource trap (page_size le=100 -> le=500) that already drives most FPs in this fixture?
- 応答: Not overfitting: the Medium-vs-Critical miss replicated across 2 of 3 models (opus + sonnet), and the underlying principle — an unbounded, fully-materialized in-memory result set can OOM a worker — is a standard, generalizable class, not a run-specific artifact. The over-calibration risk is directly mitigated by the guardrail clause that keeps 'bounded-but-large or unvalidated-parameter' cases at Medium, which is exactly the page_size trap (hard-capped at 500). So it corrects the real under-calibration without touching the FP surface. It is also genuinely not covered: bullet 1 anchors High on resource *leaks* (not released), and a one-shot huge allocation isn't a leak, leaving N+1@Medium as the only resource anchor — which is precisely why reviewers defaulted the whole class to Medium.

### 2. verdict=**keep** recall:neutral / precision:improves / data支持:True / 既出:False
- 反論: Two attacks: (1) Overfitting — is "3/3 models flag le=100→le=500" really a systemic checklist defect, or just one fixture's decoy getting lucky/unlucky with a small n=1-fixture sample run 3 times? (2) Recall risk — the new "NOT a finding: a cap that still caps" carve-out is worded generically ("hard, finite, enforced cap") without a magnitude qualifier, so a model could misuse it to wave off a real resource-exhaustion bug where the "cap" was raised to something absurd (le=100 -> le=1000000) that is technically finite but still a genuine DoS vector — the instruction as written doesn't distinguish "reasonable tuning" from "cap raised so high it's exploitable." Also check for conflict: severity-rubric.md's example table lists "N+1 query" itself as a Medium example, which sits awkwardly next to the new checklist language calling unbounded-in-memory loads High/Critical — is this a contradiction reviewers will trip over?
- 応答: Not overfitting: this isn't one model idiosyncrasy, it's the same decoy fooling all three architecturally-different models (opus, sonnet, haiku) in the same way, which is a stronger signal of a checklist-language gap than a stochastic miss would be — the current bullet's phrasing ("unchecked and could be arbitrarily large") is genuinely ambiguous about whether "raising a still-enforced bound" counts, and all three models resolved that ambiguity the same wrong way. That's exactly the kind of systematic, reproducible failure a checklist edit should target. On the magnitude-qualifier concern: the proposed carve-out is anchored to the concrete fixture pattern ("still rejecting larger values with offset/limit intact") not a bare "it's capped" — a truly absurd cap (100->1000000) would not read as "a bounded tuning change" under any reasonable application of this text, and the skill already leans on model judgment elsewhere (e.g., "Fix soon" for Medium, "plausibly hot" for performance) rather than bright-line numeric thresholds, so this is consistent with the document's existing register. On the N+1-as-Medium tension: that rubric example is about repeated-query overhead (an efficiency/consistency concern), which is a different mechanism from "loads an unbounded result set fully into memory with no ceiling at all" (an OOM/crash mechanism) — the checklist bullet's new ladder doesn't relabel N+1's severity, it only sharpens the distinct "no ceiling at all" sub-case that the evidence shows was being under-rated. There's no direct textual contradiction since N+1 isn't mentioned in the new language, though it's a fair note that the two documents could someday cross-reference more explicitly.

## 生存 → 適用(2件)

### 1. file=`/home/user/revision-du-code/.claude/skills/code-review/references/review-checklist.md` recall:neutral / precision:improves
- 狙う穴: Recurring false positive across all 3 models (opus/sonnet/haiku): raising a still-enforced finite cap `page_size le=100 -> le=500` flagged as a resource-exhaustion defect. Also the sibling severity under-calibration where a truly unbounded load is rated Medium.
- 適用: Adopt the proposed rewrite of line 41 essentially as specified, with one small tightening: in the "NOT a finding" clause, keep the concrete anchor example (le=100→le=500, still hard-capped, offset/limit intact) but add a short explicit caveat so the carve-out can't be stretched to cover a cap raised to an unreasonable magnitude, e.g. append: "(the carve-out is for a modest, still-reasonable ceiling — not for a bound raised so high that the finite cap itself becomes the practical resource-exhaustion vector)." Keep the rest of the proposed severity ladder (High/Critical for no-ceiling-at-all loads, Medium for unvalidated-value-into-a-bound-parameter) unchanged, since it directly matches the ground-truth severity the evidence cites and mirrors the document's existing successful pattern of explicit "NOT a finding" carve-outs (cf. line 23's parameterized-value carve-out for injection).

### 2. file=`/home/user/revision-du-code/.claude/skills/code-review/references/severity-rubric.md` recall:neutral / precision:neutral
- 狙う穴: Recurring severity under-calibration (opus + sonnet): unbounded-export (unbounded `q.all()` + full in-memory buffer, OOM blast radius across a whole worker) rated Medium by reviewer, ground truth Critical. Root cause is the rubric offering only 'N+1 query' as a resource example, all at Medium.
- 適用: Add this bullet to the 'Rules of thumb' list, immediately after the 'default up a level' bullet (line 23), tightened from the proposal but preserving the bounded-case guardrail: '- A result set materialized fully into memory with no ceiling (no LIMIT, no pagination, no streaming) is not a Medium like an N+1 — it is at least High, and Critical when the OOM can take down a shared worker or an attacker can trigger it on demand. The Medium resource guidance covers bounded-but-large or unvalidated-parameter loads, not loads with no upper bound at all.'

## changelog

Applied both vetted improvements by editing the two target reference files; SKILL.md needed no change (no vetted improvement targets it).

1. review-checklist.md (Data & API contracts section): Replaced the single flat "N+1 queries, unbounded result sets..." bullet with a three-way severity ladder that resolves the recurring cross-model false positive and the sibling under-calibration:
   - No ceiling at all (no LIMIT/pagination/streaming, e.g. q.all() buffered into memory) -> High, or Critical when OOM can down a shared worker or an attacker can trigger it on demand.
   - A bound exists but its value is unchecked (e.g. LIMIT ? fed an unvalidated huge/negative number) -> Medium, on its own axis independent of injection.
   - NOT a finding: raising a still-enforced finite cap (le=100 -> le=500, still hard-capped, offset/limit intact) is routine tuning. Added the tightening caveat that the carve-out is for a modest, still-reasonable ceiling, not a bound raised so high the finite cap itself becomes the practical resource-exhaustion vector.
   Mirrors the document's existing "NOT a finding" carve-out pattern (cf. the bound-parameter injection carve-out).

2. severity-rubric.md (Rules of thumb list): Added a new bullet immediately after the "Security, data-loss, and concurrency findings default up a level" bullet, stating that a result set materialized fully into memory with no ceiling is not a Medium like an N+1 — it is at least High, and Critical when the OOM can take down a shared worker or an attacker can trigger it on demand; the Medium resource guidance covers only bounded-but-large or unvalidated-parameter loads. (Placed at the specified position after an initial mis-placement was corrected; no duplicate remains.)

## 変更ファイル

- `/home/user/revision-du-code/.claude/skills/code-review/references/review-checklist.md` — Rewrote the unbounded-result-set checklist bullet into a three-way calibration ladder: no-ceiling load -> High/Critical, unchecked value into a bound -> Medium, raising a still-enforced finite cap (le=100 -> le=500) -> explicitly NOT a finding, with a caveat that the carve-out excludes caps raised so high the bound itself becomes the exhaustion vector.
- `/home/user/revision-du-code/.claude/skills/code-review/references/severity-rubric.md` — Added a Rules-of-thumb bullet (immediately after the 'default up a level' bullet) stating that a result set materialized fully into memory with no ceiling is at least High and Critical when it can OOM a shared worker or be attacker-triggered, distinguishing it from bounded/unvalidated-parameter Medium loads.
