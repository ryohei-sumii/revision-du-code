# コスト・トラック / Cost Track

品質トラック（`../improvement-log.md` + `../rounds/`）が **レビュー品質（recall / precision）**
を測定駆動で改善してきたのに対し、このフォルダは **コスト（トークン消費・実行時間・モデル配分）**
を同じやり方で測定・改善する記録です。

> The quality track improved *review quality* (recall / precision). This folder is
> the parallel track for *cost* — token spend, wall-clock, model allocation —
> measured and improved the same way.

## なぜ品質と分けるのか / Why a separate track

- **軸が違う。** 品質は「見逃さない／誤検出しない」。コストは「1回のレビューに何トークン
  使うか・そのトークンは減らせるか・減らすと品質はどう動くか」。混ぜると、どちらの結論も
  濁る。
- **トレードオフを可視化するため。** コスト削減はしばしば品質を犠牲にする（例: 周辺コードの
  読み込みを削れば安くなるが recall が落ちる）。品質側の recall↔precision の振り子に対し、
  こちらは **recall↔cost の振り子**。別トラックにして初めて、片方を動かしたときの他方への
  影響を定量で追える。

## 命名規則 / Naming

品質側の `rounds/` 慣習をそのまま踏襲する。

| ファイル | 内容 |
|---|---|
| `cost-log.md` | コストの学び・ラウンド記録を集約（品質側 `improvement-log.md` の対） |
| `baseline-token-usage.md` | Round 0 = 現状の1回あたりトークン消費の実測ベースライン |
| `round-N-*.md` | 以降のコスト最適化ラウンドの生データ（品質側 `rounds/` と同形式） |

各ファイルは生成のつどコミット & プッシュする。

## 測定の原則 / Measurement principles

品質側で得た「AI の学び」はコストにもそのまま効く。

- **測れないものは最適化できない。** 「プロンプトは走らせて観察するしか検証できない（品質側 学び5）」
  の対。トークン消費も **実測が唯一の真実**。見積もりは出発点、実測が結論。
- **1回では断定しない（非決定性）。** 同じ差分でも実行のたびに読むファイル数・出力量は揺れる。
  コスト数値も複数回・複数題材で測り、レンジで語る。
- **固定費と可変費を分ける。** progressive disclosure による固定オーバーヘッド（スキル指示）と、
  差分サイズ・周辺読み込みに比例する可変費は、削減手段がまったく違う。混ぜて平均しない。
