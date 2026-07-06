# Round 1 — 統合結果 / Synthesis Result

壁打ちを生き延びた改善と、実ファイルへの適用内容。

## サマリ
- クリティーク30件 → 壁打ち上位14件 → **生存 9 件**を採用
- 使用エージェント: ?(完了 ? / 失敗 ?)、subagentトークン: ?、所要 0s
- 既知の欠測: precision レンズの1体が構造化出力に5回失敗(欠測1)。品質判断は残り4レンズ+壁打ちで担保。

## 採用した改善(生存案)

### 1. [high] Destructive-operation / data-loss class is the #1 Critical in the rubric but has NO trigger in the checklist
- **file**: `.claude/skills/code-review/references/review-checklist.md`  |  lens: recall  |  recall: improves / precision: neutral
- **適用内容**:
  > In .claude/skills/code-review/references/review-checklist.md, under the existing "## Data & API contracts" heading (no new heading), add two bullets after the migration-reversibility line:
  >
  > - Destructive or irreversible operation with no scoping predicate: DELETE/UPDATE/DROP/TRUNCATE (or equivalent ORM/file/cache call) with no filter, the wrong filter, or a filter that can evaluate to "match everything."
  > - Migration or code path that drops/renames/overwrites a column, table, key, or file that is still read elsewhere in the codebase.
  >
  > (Drop the "bulk mutation over an unbounded set" wording since it duplicates the existing "unbounded result sets" bullet, and drop the "not idempotent under retry" point as a separate concern that dilutes this specific trigger.)

### 2. [high] Pre-existing-issue cap buries bugs the change newly makes reachable or triggerable
- **file**: `.claude/skills/code-review/references/severity-rubric.md`  |  lens: recall  |  recall: improves / precision: neutral
- **適用内容**:
  > In references/severity-rubric.md, replace line 18-19 with:
  >
  > "- Pre-existing issues outside the diff are capped at **Low** unless the change
  >   makes them materially worse. Two concrete cases count as materially worse,
  >   not merely pre-existing:
  >   - the diff newly routes untrusted or attacker-influenced input into an
  >     existing sink (parser, query, deserializer, eval) that wasn't reachable
  >     from that input before, or
  >   - the diff makes a previously dead/unreachable code path reachable in
  >     normal use.
  >   In either case, score the underlying defect at its true severity — don't
  >   cap it just because the buggy lines themselves are unchanged. This does
  >   **not** apply to the ordinary case of adding another caller to code that
  >   was already reachable and already exercised the same way; that stays
  >   capped at Low like any other pre-existing issue."

### 3. [high] Uncertain-but-real bugs are routed to 'nit' and disappear; the skill has ~6 precision guardrails and no recall counterweight
- **file**: `.claude/skills/code-review/SKILL.md`  |  lens: recall  |  recall: improves / precision: neutral
- **適用内容**:
  > In `.claude/skills/code-review/SKILL.md`, replace the sentence at line 66 —
  > "Only claim something is a bug if you can name how it breaks; otherwise mark it as a question or a nit."
  > — with:
  > "Only claim something is a confirmed bug if you can name how it breaks. If you can't confirm it and it has no behavioral impact, it's a nit. If you can't confirm it but it could be a real security, data-loss, concurrency, or crash bug, raise it as a Question at the severity it would carry if true — don't downgrade an unconfirmed suspicion to a nit just because you can't fully prove it."
  >
  > In `.claude/skills/code-review/references/severity-rubric.md`, replace the bullet —
  > "Security and data-loss findings default up a level, not down."
  > — with:
  > "Security, data-loss, and concurrency findings default up a level, not down — including ones you can only raise as a Question. Rank a Question about a potential Critical/High issue alongside the confirmed findings of that tier, not at the bottom with nits."
  >
  > This keeps the existing "concrete failure scenario" requirement (no relaxation of specificity), reuses the skill's own category names instead of adding new vocabulary, and fixes the two concrete, verifiable gaps — ambiguous Nit/Question routing in the instruction a model actually executes, and undefined ranking of Questions — without the moralizing "missing a critical is worse than a question" framing that risks inviting speculative padding.

### 4. [high] Reading surrounding code is motivated only by false-positive avoidance; no instruction to grep call sites to find newly-broken consumers
- **file**: `.claude/skills/code-review/SKILL.md`  |  lens: recall  |  recall: improves / precision: neutral
- **適用内容**:
  > In SKILL.md Section 2 ("Understand before judging"), after the existing paragraph, add:
  >
  > "When a change alters a function or method's signature, return value/type, nullability, units, thrown/rejected errors, or side effects, Grep for its call sites and read the ones that still use the old contract — an unchanged caller relying on it is a bug the diff introduced, not a pre-existing issue (see severity-rubric.md's "materially worse" carve-out), and belongs in the review at full severity. If the symbol is used pervasively (a core utility, a widely-implemented interface), sample a representative few callers across different modules rather than reading every occurrence — the goal is to catch the realistic break, not to audit the whole codebase."
  >
  > Optionally also tighten the checklist bullet in review-checklist.md under "Data & API contracts" from "Breaking change to a public signature, response shape, or DB schema." to "Breaking change to a public signature, response shape, or DB schema — grep its call sites/consumers and confirm they still hold under the new contract."

### 5. [high] The 'pre-existing issues capped at Low' rule suppresses bugs the diff newly activates
- **file**: `.claude/skills/code-review/references/severity-rubric.md`  |  lens: prompt-efficacy  |  recall: improves / precision: neutral
- **適用内容**:
  > In severity-rubric.md, replace the single line "Pre-existing issues outside the diff are capped at Low unless the change makes them materially worse." with:
  >
  > "- Pre-existing issues outside the diff are capped at **Low** unless the change makes them materially worse — including when the diff is what makes an existing issue newly reachable or exploitable. Score that case at the *full severity of the resulting behavior*, not Low: e.g., new code that passes attacker-controlled input into an existing, unsanitized `query()` is a **Critical** SQL-injection finding, because the diff is what turned a dormant function into a live attack path. This exception is about a *change in reachability or exploitability*, not mere proximity — if the diff calls a pre-existing function without changing what data, guards, or callers reach it, that's still a plain pre-existing issue and stays capped at Low."

### 6. [high] "At least High" rule requires a 'wrong result', but the table's own High examples (resource leaks) don't produce one
- **file**: `.claude/skills/code-review/references/severity-rubric.md`  |  lens: coverage  |  recall: improves / precision: neutral
- **適用内容**:
  > Replace the first rule of thumb with: "A finding is at least **High** only if you can name a concrete input/state/operation that produces a wrong result, or that leaks a resource or leaves state inconsistent — a lock not released, a file handle or connection not closed, a missing rollback on a partial failure — even when the symptom only surfaces after repetition or under load. If you can't name such a case, it's a **Question** or a **Nit**."

### 7. [high] Finding format never requires stating the severity label, only 'most-severe first' ordering
- **file**: `.claude/skills/code-review/SKILL.md`  |  lens: coverage  |  recall: neutral / precision: improves
- **適用内容**:
  > In SKILL.md step 4, change the finding-format sentence to: "For every finding give: **file:line**, its **severity level** (from `references/severity-rubric.md`: Critical / High / Medium / Low-Nit / Question), a one-line statement of the defect, and a concrete failure scenario (input/state → wrong result)." Apply the same addition to the parallel step 4 in `.claude/commands/code-review.md`: "Each finding: **file:line**, its **severity level** (per the rubric), the defect in one line, and a concrete failure scenario." Keep the existing "report most-severe first" ordering instruction unchanged — the label supplements it, it does not replace it.

### 8. [high] Binary file changes shown as 'Binary files differ' with no guidance for reviewer
- **file**: `.claude/skills/code-review/scripts/collect-diff.sh`  |  lens: mechanism  |  recall: improves / precision: neutral
- **適用内容**:
  > Drop the collect-diff.sh change entirely. Reason: (a) it is broken — `git diff --stat` emits `Bin N -> M bytes`, so `grep -E 'Binary|bin$'` matches nothing; (b) it is redundant — line 81's existing `git diff --stat` already lists binary files by name with byte-size deltas.
  >
  > Make only one edit, to SKILL.md Gotchas, mirroring the existing generated/vendored bullet (precision-safe framing):
  >
  > - **Binary files** (images, `.so`/`.jar`/`.wasm`, PDFs, other compiled assets) show in the stat as `Bin N -> M bytes` and in the diff as "Binary files ... differ" — their contents aren't in the diff and can't be line-reviewed. Don't pad the review with them. Do raise a finding only when a binary doesn't fit the change — e.g., an executable or shared library added in a docs- or config-only PR — which can be a supply-chain risk worth a manual/provenance check.

### 9. [medium] Weighting examples in §3 cue only injection/authz/parsing/refactor — never concurrency, data-loss, or crypto
- **file**: `.claude/skills/code-review/SKILL.md`  |  lens: recall  |  recall: improves / precision: neutral
- **適用内容**:
  > In .claude/skills/code-review/SKILL.md §3, extend the weighting sentence (currently lines 56-58) to include the invisible-in-hunk classes, kept to one added sentence to control length:
  >
  > "Weight toward the categories that match the change: a SQL query → injection and N+1; an auth path → access control; a parser → malformed input; a refactor → behavior preservation; shared state or async code → races and unawaited work; a webhook/retry/payment path → idempotency and double-processing; a delete or migration → data loss and reversibility; a token/password/hash → crypto misuse. The last four rarely look wrong in the hunk itself — check them deliberately against how the code runs, not just by reading the diff."
  >
  > (Optional, separate follow-up outside this proposal's scope: add a line to review-checklist.md's Security section for weak/predictable crypto and randomness, since that class currently has no checklist home at all.)

## 変更ファイル(統合が生成 / 適用)

- `/x` — y

## 主要テーマ(何を直したか)

- **recall の底上げ**: 破壊的操作/データ損失のトリガをチェックリストへ追加、差分が新たに到達可能/悪用可能にした既存バグを本来の重大度で評価、未確認だが重大なら Question として本来の階層で報告(nit に埋もれさせない)、契約変更時は呼び出し側を grep して確認。
- **calibration**: 「High はリソースリーク/状態不整合も含む」と是正、指摘フォーマットに**重大度ラベル必須**を追加。
- **precision は維持**: 全生存案が precision を害さない(neutral)ことを壁打ちで確認。
