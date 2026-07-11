# revision-du-code — 汎用コードレビュースキル / Universal Code Review Skill

インストール不要（`npm`/`pnpm`/`pip` 等の導入なし）で、あらゆる言語・リポジトリに
使える Claude Code 用のコードレビュースキルとスラッシュコマンドです。`git` と
ファイル読み取りだけで動作します。

An install-free, language-agnostic code review skill and slash command for
Claude Code. It runs on nothing but `git` and file reads — no dependency
install, no build step — so it works in a fresh clone of any repo.

> **このリポジトリの価値の半分は「スキルそのもの」、もう半分は「AI で AI 用スキルを
> 測定駆動・敵対的に自己改善した21ラウンドの記録と学び」です。** 後者は下の
> [総括 / 学び](#総括--学び--key-learnings) と `docs/` にまとめてあります。

---

## 使い方 / Usage

このリポジトリの `.claude/` を、レビューしたいプロジェクトに置くか、
`~/.claude/`（ユーザー全体）にコピーします。Claude Code から:

```
/code-review              # 未コミットの変更をレビュー / review uncommitted changes
/code-review staged       # ステージ済みのみ / staged only
/code-review branch       # デフォルトブランチとの差分（PR相当）/ vs default branch (PR-style)
/code-review HEAD~3       # 任意の git ref との差分 / vs any git ref
```

自然言語でも起動します（スキルの description がトリガー）:
> 「変更をレビューして」 / "review my changes before I commit"

### 推奨設定 / Recommended setup

コスト計測（下記）の結論として、**レビューは Sonnet で回すのが最適**です
（Opus 比 約40%安・品質は同等以上、Haiku は品質が崖から落ちる）。スキル自体は
モデル非依存なので、モデルは呼び出し側で選びます。

Per the cost measurements below, **run reviews on Sonnet** — ~40% cheaper than
Opus at equal-or-better quality; Haiku drops below the recall floor. The skill
itself is model-agnostic.

---

## 中身 / What's inside

```
.claude/
├── commands/
│   └── code-review.md              # /code-review スラッシュコマンド
└── skills/
    └── code-review/
        ├── SKILL.md                # レビュー手法（トリガー・手順・gotchas）
        ├── scripts/
        │   └── collect-diff.sh     # git だけで差分収集（POSIX sh, 移植性重視）
        └── references/
            ├── review-checklist.md # 言語非依存のレビュー観点
            └── severity-rubric.md  # 重大度の判定基準
```

**設計方針**（[claude-code-best-practice](https://github.com/shanraisshan/claude-code-best-practice) 準拠）:
スキルはフォルダ＋段階的開示（`SKILL.md` を薄く保ち詳細は `references/` へ）／
description はトリガー／レール化しない（ゴールと制約を与え判断を委ねる）／
誤検出しやすい gotchas を明文化／インストール・ネットワーク不要。

**出力**: 指摘は重大度順（Critical → High → Medium → Low/Nit → Question）、各項目に
`file:line`・一行要約・具体的な失敗シナリオ。差分がきれいなら率直に「問題なし」。
ファイル編集は依頼時のみ。

---

## どう作ったか / How it was built

このスキルは、**複数モデルの敵対的ワークフローで測定駆動に自己改善**しました。
合成フィクスチャ（仕込みバグ＋benign trap）と実 OSS のバグ修正コミットを使い、
recall（見逃さない）・precision（誤検出しない）・cost（トークン）を毎回**実測**。
各ラウンドは「**測定 → 敵対的検証（別モデルが反証を試みる）→ 適用**」の型で、
提案は必ず**採用前にゲート**を通しました。全 **21ラウンド**を3トラックで記録:

The skill was **self-improved, measurement-first, with multi-model adversarial
workflows** — synthetic planted-bug fixtures plus real-OSS bug-fix commits,
measuring recall / precision / cost every round under a *measure → adversarially
verify → apply* loop, gating every proposal before adoption. 21 rounds, 3 tracks:

| トラック | ラウンド | 何を測ったか | 記録 |
|---|--:|---|---|
| **品質 / Quality** | 8 | recall・precision（合成フィクスチャ） | `docs/improvement-log.md`, `docs/rounds/` |
| **コスト / Cost** | 5 | 1回あたりトークン・読込スコープ・モデル配分 | `docs/cost/` |
| **現場 / Field** | 8 | 実 OSS 6リポ・5言語での recall/precision | `docs/field/` |

---

## 総括 — 学び / Key learnings

21ラウンドで一貫して現れた、移植可能な学びを総括します。

### 0. 全体を貫く一番の教訓 / The one meta-lesson

**「機構を足す前に測れ — 単純案がしばしば勝つ。」** 測って検証した"賢い"機構は、
3トラックすべてでほぼ棄却/縮小されました:

> **Measure before adding machinery; the simpler option usually wins.** Every
> mechanism that was measured rather than assumed was rejected or shrunk:

- コスト: **フル読込**（＜純予算制）・**hybrid 読込**（＝純予算制と同点で複雑なだけ）・**難度別モデルルーター**（Sonnet で足りる）
- 品質: 単一フィクスチャの誤検出からの過剰追加（収束後は「変更しない」を選択）
- 現場: 認証弱点に対する**候補チェックリスト文面**（A/B で recall 利得ゼロ→棄却）

### 1. AI／LLM についての学び / About LLMs

- **プロンプトは非決定的**。同じ入力でも run 間で結果が揺れる（recall がフリップする）。
  → 検証は**複数 run＋多数決**、単発結果を機能/劣化と誤認しない。
- **中間忘却（lost-in-the-middle）と位置バイアス**はレビューにも効く。**「もっと読ませる」と
  かえって悪化した**——周辺コンテキストを増やすと本物のバグへの注意が薄まり、誤検出が増えた
  （フル読込の並行 recall が純予算制より低く、誤検出は最多）。
- **recall の律速は"読む量"でなく"モデルの判断力"**。ある点を超えると、読ませても・
  文面を足しても recall は上がらない（現場 R8 で実証）。
- **採点者も LLM**。だから**"正解"の設計が9割**——実 fix を正解に使い、テストのヒントを除き、
  敵対ゲートが生 diff を独立再読することで、LLM 採点でも客観に近づけた。

### 2. 品質 / Quality（recall・precision）

- **見えないものは断定しない（READ, not downgrade）**。参照されているが差分に無いコード
  （validator・guard・型）は、**READ してから**主張する。読めない時だけ、真の重大度の Question に。
- **確認できないが実害が大きい疑い（security/data-loss/concurrency）は、真の重大度の Question に**
  格上げする——nit に落とさない。逆に**根拠のない断定はしない**。
- **収束は"当てた題材分布の上"での収束**。8ラウンドでモデル自身が収束宣言したが、大標本で
  言語を広げたら**新しい系統ギャップ（C の手動メモリ・ヒープリーク）が1件出た**——
  チェックリストの列挙漏れ＝**手法で直るフックの欠落**だったので修正した。

### 3. コスト / Cost

- **読込スコープ＝純予算制で確定。** 「差分が触れたファイル＋1ホップの呼び出し先/元」だけ読む。
  広く読んでも recall は上がらず・誤検出増・コスト増（大標本80バグでも再現）。
- **モデル＝Sonnet を既定。** subtle バグでも Opus と同点以上、precision 高、**Opus 比 約40%安**
  （$0.39→$0.23/回）。難度別ルーティングは不要（単純案が勝つ）。
- **コスト削減には recall フロアがある**——なめらかなトレードオフでなく**階段**。最安の Haiku は
  認可・並行・クラッシュ級バグを落とし、最適点は「最安」でなく「品質を保つ最安＝Sonnet」。
- **メタコスト ≫ プロダクトコスト。** 「改善する1ラウンド」は「使う1回」の10〜60倍。大標本は
  **author 使い回し・resume 前提・上限リセット後にまとめ流し**が3点セット（大規模実行はレート上限にも当たる）。

### 4. 現場検証 / Field（実 OSS・5言語）

手法: 実際の bug-fix コミットを**逆適用**して"バグ再注入差分"を作り検出できるか（recall）＋
正しい実変更で誤報しないか（precision）を、6リポ・5言語（Go/Python/JS/Rust/Ruby）で実測。

- **合成では見えない前進:** 実コードの既知バグ回帰を **12/12** 検出・クリーン差分で **0 誤報**、
  しかも**"正しい"マージ済みコミットに実在する潜在バグを多数発見**（"merged ≠ bug-free"）。
- **再現ゲートは正負両方向に効く。** ある messy アプリで**初の劣化**を観測したが、別アプリで
  検証すると——**怖い誤報（意図的な権限変更を"バイパス"と誤報）は再現せず＝リポ特有**、
  **地味な見逃し（意図的に見える認証巻き戻し）は再現＝言語一般**。**単発の劣化も機能同様、
  再現で確定**する。
- **"再現した弱点"に"効く修正"があるとは限らない。** 言語一般と確定した弱点へ候補文面を
  A/B したが、**recall 利得ゼロで棄却**。この弱点は**チェックリストで埋まるフックの欠落でなく、
  モデルの"意図と欠陥の弁別"というドメイン判断の限界**——**プロンプトで直せないと実測で確定**。
  正しい扱いは「効かない文面を足す」でなく「**境界を明示＋人間が重点レビュー**」。
- **replay は recall を過大評価する。** 既知修正の逆適用は局所的で、野生の novel バグより易しい。

---

## 信頼境界 / Trust boundary（正直な地図）

5言語・lib もアプリも実コードで測った結果、**どこを信頼し・どこは人間が重点レビューすべきか**が
地図化されました。総合評価は **`assistant-ready-with-caveats`**——人間がトリアージする
レビュー・アシスタントとして実運用に足る、自律マージゲートとしてはまだ。

Measured on real code across 5 languages, libraries and applications. Overall:
**assistant-ready-with-caveats** — deployable as a human-triaged review assistant,
not yet as an autonomous merge gate.

- ✅ **信頼できる / Reliable** — 構造・クラッシュ・並行・エラー処理・契約（API/型）バグ、
  および**明白な**認証バグ（IDOR・token-scope・アクセス制御）。5言語・lib もアプリも。
- ⚠️ **人間が重点レビュー / Needs human review** — 「**意図的な別実装に見える微妙な認証/可視性/
  モデレーションの巻き戻し**」。言語一般の弱点で、**プロンプトでは緩和できない**と実証済み
  （候補文面は A/B で効果ゼロ）。認可/可視性差分は人間が精査すべき。
- 📏 **限界の限界 / Caveats on the caveats** — 検証は合成フィクスチャと実 OSS の
  bug-fix リプレイが中心（大標本・多言語だが各言語1〜2リポ、小 N）。**方向性の信号**であり、
  確定した統計的推定ではない。replay は novel バグ発見より易しい。

---

## 開発ログ / Development logs

自己改善の全過程（測定・敵対検証・適用・棄却）を記録しています。

- **品質 / Quality**（8ラウンド・収束）: `docs/improvement-log.md`、生データ `docs/rounds/`
- **コスト / Cost**（5ラウンド・2大レバー決着）: `docs/cost/cost-log.md`、
  実測ベースライン `docs/cost/baseline-token-usage.md`、各 `docs/cost/round-*.md`
- **現場 / Field**（8ラウンド・5言語）: `docs/field/round-1..8-*.md`

> 到達点は、品質・コスト・現場のいずれも敵対ループが「これ以上**割に合う変更も、効く修正も
> 見つからない**」点に自然到達した**局所最適**です。合成・小標本という限界の上での結論であり、
> 大域最適の証明ではありません——そう明記することも、この記録の一部です。
