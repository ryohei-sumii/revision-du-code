# Field Round 7 — 残存弱点の言語横断確認 / Mastodon（Ruby）＝弱点は再現・言語一般と確定

**日付:** 2026-07-09 ／ **状態:** ✅ 完了・**スキル変更なし（次で候補文面を A/B 検証）** ／ **対象:** `mastodon/mastodon`（Ruby 製 SNS）。

R5/R6 で Go 2アプリに各1件見られた唯一の残存弱点＝「**意図的な別実装に見える微妙な認証/可視性巻き戻しの見逃し**」が、
**非 Go（Ruby, 5言語目）でも再現するか**を確認。recall のみ、可視性/ブロック/モデレーション意味論の bug 再注入6件。26体・エラー0・1.30M tok。

---

## 1. 実測結果 — 再現した / Results: it reproduces

| 指標（Ruby / mastodon, recall） | 値 |
|---|---|
| recall（per-run / majority） | **0.83（15/18）／ 5/6** ← Go ベースラインと同帯 |
| confident FP | 0（ただし correct fixture 0＝precision 未検証） |

**見逃した2件は、まさに"意図的に見える認証巻き戻し"の族:**
- **`block-policy`（97ba08）:** `StatusPolicy#quote?` から `!blocking_author?` ガードを除去＝**ブロックした相手を quote できる**
  という教科書的 auth 巻き戻し。**1/3 で見逃し**——Go 2アプリと**同じ ~1-miss-per-repo の署名**。
- **`subscription-visibility`（bc3871）:** `notify?` から `update? ||` を除去＝**投稿"編集"時にも購読者へ通知**。バグ版が
  「もっともらしい意図的挙動」に見え、**majority-miss（1/3 catch）**——Go 2アプリより**強い再現**。
- 残る4件（停止アカウント露出・silence 配信・report 権限チェック・filter correctness）は **3/3 検出**。

**敵対ゲート `generalizes`:** 「弱点は **Go でなく"バグの形"（意図的に見える認証/可視性巻き戻し）に付随**する。Ruby でも
Go と同帯の recall で、canonical サブモードが同じ ~1/3 cadence で外れた。**言語一般の弱点**と読むのが正しい」。

---

## 2. R6 との対比 — 何が一般で何が特有か / What generalizes vs what didn't

Field 検証は、認証/権限の2つの failure mode を**別々に**追跡し、正反対の結論を出した:

| failure mode | R5 起点 | 再現テスト | 結論 |
|---|---|---|---|
| **FP: 意図的な権限変更を"bypass"と誤報** | PocketBase（2/9） | gitea（R6）で **0/12・直接アナログ clean 3/3** | **再現せず＝PocketBase 特有** |
| **recall: 意図的に見える認証巻き戻しを見逃し** | PocketBase・gitea（各1） | mastodon（R7）で **2/6・同 cadence 再現** | **再現＝言語一般の本物の弱点** |

→ **怖い誤報は特有（消える）、地味な見逃しは一般（残る）。** 敵対＋再現の規律が、両者を取り違えずに切り分けた。

---

## 3. スキル変更の判断 — 今回は"検証に進む"（まだ編集しない）/ Decision

R6 では FP モードが**再現しなかった**ので編集を見送った。R7 では recall サブモードが**再現した**——**編集を"検討する"バーを
初めて満たした**。だが規律（品質8ラウンド／コストの hybrid）は「**候補文面を足す前に A/B で検証せよ**」。安易な追記は、
最も高リスクな認証クラスで **recall↑ と引き換えに precision↓（R6 が示した FP リスク）** を招きうる。

→ **今回はスキル変更なし。** 代わりに次ラウンドで**候補文面を A/B 検証**する:
- **候補（review-checklist.md 追記案）:** 「**認可/可視性/モデレーションの述語**（policy メソッド・`can?`/`visible?`/
  `notify?`・block/mute/suspend/silence/private 判定）で条件が**除去/弱化**されたら、たとえ単純化が意図的に見えても
  **誰のアクセス/可視性が広がるか**（ブロック相手が行為可能に・停止/silence アカウントが露出/再配信）を述べてから受け入れよ。
  もっともらしい単純化に見えても access-control 回帰でありうる」。
- **A/B の合格条件:** 見逃した"意図的に見える"fixture 群で **recall が上がり**、かつ R6 の correct-permission fixture＋
  クリーン差分で **confident FP が増えない**——両立したときだけ採用（片方を壊すなら不採用、hybrid の教訓）。

---

## 4. 学び / What this teaches

1. **弱点は"言語"でなく"バグの形"に付随する。** 「意図的に見える認証/可視性巻き戻し」という**形**が、Go でも Ruby でも
   ~1/repo 外れる。tool の盲点は言語横断で、**認証/可視性/モデレーション差分は全言語で人間が重点レビュー**すべき。
2. **再現が"正の判断"（編集を検討）も"負の判断"（見送り）も可能にする。** R6 は非再現で編集見送り、R7 は再現で
   編集検討へ——**同じ再現ゲートが両方向に働く**。単発では決してこの判断はできなかった。
3. **ただし"再現＝即編集"ではない。** 再現は「検討のバー」であって「採用」ではない。高リスク領域の編集は A/B で
   recall↑×precision維持を確認してから——**候補を測らずに足さない**（コストの hybrid が3回教えた規律）。

---

## 5. Field 検証の到達点（7ラウンド・5言語）/ Where field validation stands

| R | リポ（言語/種別） | 主眼 | 結果 |
|---|---|---|---|
| R1-R4 | gin/requests/axios/ripgrep（Go/Py/JS/Rust, lib） | 基本 | 高 recall・0 FP・+latent |
| R5 | pocketbase（Go, app） | messy app | 初の劣化（認証/権限） |
| R6 | gitea（Go, app） | FP 再現? | **再現せず**（FP は PocketBase 特有） |
| **R7** | **mastodon（Ruby, app）** | **recall 再現?** | **再現**（見逃しは言語一般） |

**総合 `assistant-ready-with-caveats`。確定した信頼境界:**
- **信頼できる（5言語・lib もアプリも）:** 構造・crash・並行・error-handling・契約バグ、および**明白な**認証バグ
  （IDOR・token-scope・停止アカウント露出・silence 配信）。
- **確定した既知の限界（言語一般・人間が重点レビュー）:** 「**意図的な別実装に見える微妙な認証/可視性/モデレーション
  巻き戻し**」を ~1-2件/repo 見逃す。→ 次ラウンドで候補文面を A/B 検証（採用は recall↑×precision維持が条件）。

（`mastodon` は検証のためだけの一時 clone。スキル/リポには含めない。precision は本ラウンド未検証＝correct fixture 0。)
