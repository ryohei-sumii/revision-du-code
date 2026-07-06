# ラウンド成果物 / Round Artifacts

改善ループの**各ステップを都度ファイルとして出力**する場所です。チャットの要約ではなく、
生の検証記録をここに残します。

## 命名規則 / Naming

| ファイル | 内容 |
|---|---|
| `round-N-critique.md` | 各モデル・各レンズが出した弱点(敵対的クリティーク)の全一覧 |
| `round-N-spar.md` | 各改善案への壁打ち(反証・判定 keep/revise/reject と recall/precision 影響) |
| `round-N-result.md` | 生き残った改善・変更ファイル・changelog(統合結果) |
| `round-N-eval.md` | 経験的評価(仕込みバグ差分でのレビュー採点)がある場合のスコア |

各ファイルは生成のつどコミット & プッシュします。全体の流れと学びは
`../improvement-log.md` に集約します。
