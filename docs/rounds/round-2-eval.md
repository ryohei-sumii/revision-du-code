# Round 2 — 経験的評価スコア / Empirical Eval

**現行スキル(Round 1適用済み)を実際にレビューさせ、正解と突き合わせて測定した数値**です。
意見ではなく測定値。

## ヘッドライン
- **Recall(見逃さない力)= 0.8**  (仕込みバグ照合 12 / 15)
- **Precision(誤検出しない力)= 0.84**  (誤検出 4 / 全指摘 25)
- 有効フィクスチャ: 3 / 4(1件=contract-break は構造化出力5回失敗で欠測=**非決定性が再び顕在化**、下記 logs)
- extra_valid(正解表に無いが本物の指摘)= 8 件 → スキルは仕込み以外の本物も拾えている
- 使用エージェント ?(完了 ? / 失敗 ?)、約 0s、subagentトークン ?

## 取りこぼし(recall の穴)
- クラス別: {"logic-error": 2, "resource-exhaustion": 1}
- モデル別: {"opus": 1, "haiku": 2}

## 誤検出(precision の穴)— 実例

- [concurrency/opus] Low-Nit on SetRate: claims frequent SetRate calls could let clients evade limits by resetting buckets, but ground truth confirms this map-reassignment is fully serialized (Lock vs RLock, no race) and is explicitly the intended/documented behavior (apply new rate immediately). The finding is hedged ('worth confirming', 'if rare this is fine') but still flags the exact benign trap as a potential issue rather than recognizing it as intended.
- [reachability-sqli/opus] IDOR claim on customer_orders (High severity) is speculative — the reviewer itself concedes 'a global auth middleware isn't visible in the diff' yet still assigns High severity as a definite defect; with no evidence either way this is an unsubstantiated claim beyond the diff's scope, not a confirmed bug.
- [reachability-sqli/opus] limit validation finding (Medium) re-flags the exact location the ground truth explicitly calls a benign trap, stating the ValueError case is 'a robustness nit rather than a security bug'; the reviewer instead treats it as an actual Medium-severity defect requiring a fix, contradicting the intended benign classification.
- [reachability-sqli/sonnet] Finding 3 (Medium, app/api/orders.py limit param feeding recent_orders_by_customer's LIMIT ?): this is exactly benign trap #2's scenario (int-cast limit, bound via '?' parameter, no injection possible). Ground truth explicitly calls the non-numeric-limit crash 'a robustness nit rather than a security bug,' but the reviewer elevates it to a standalone Medium-severity bug finding (adding a negative-limit LIMIT-bypass claim), i.e. flags a benign trap as a bug.

## 重大度の誤較正

- [reachability-sqli/haiku] Medium severity on the 'missing input validation on limit' finding is overstated — negative/huge limit values on a parameterized query is a minor robustness edge case with no security impact, not a Medium-severity bug

## フィクスチャ別

| fixture | 仕込み数 | 実行回数 | 累計catch |
|---|---|---|---|
| data-loss | 2 | 3 | 4 |
| concurrency | 2 | 3 | 5 |
| reachability-sqli | 1 | 3 | 3 |

logs: pipeline[2] failed: agent({schema}): StructuredOutput retry cap (5) exceeded — 5 failed calls with no valid output / Measured: recall=0.8 precision=0.84 over 3 fixtures; misses_by_class={"logic-error":2,"resource-exhaustion":1}; FPs=4. / Diagnosis produced 2 data-driven proposals. / 2 of 2 proposals survived sparring.
