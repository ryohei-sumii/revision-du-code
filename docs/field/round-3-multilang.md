# Field Round 3 — 多言語検証 / Cross-Language（Python requests ＋ JS axios）

**日付:** 2026-07-09 ／ **状態:** ✅ 完了・**スキル変更なし** ／ **狙い:** Round 1/2 が残した最大 caveat＝
「**単一リポ・単一言語（Go/gin）**」の外部妥当性を、別言語の実 OSS で弱める。

gin と同一手法（bug-fix 逆適用リプレイ＝recall／マージ済み実変更＝precision）を **Python `psf/requests`** と
**JS `axios/axios`** に適用。本物のスキルを読ませた Sonnet 既定構成で各3run。66エージェント・エラー0・2.64M tok。

---

## 1. 実測結果（言語別）/ Results by language

| | recall(per-run / majority) | correct fixture | confident-FP run率 | clean-run率 | genuine latent |
|---|---|---|--:|--:|--:|
| **Python (requests)** | **0.87（13/15）/ 4/5** | 1 | **0.00** | – | 3 |
| **JavaScript (axios)** | **0.83（15/18）→ 実質 1.00** | 4 | **0.08** | **0.92** | 0 |

**Recall（実バグ回帰検出）:**
- **JS の 0.83 は見かけ。** 1件（`axios-fix-1792eda11aff`）は**退化フィクスチャ**——実 fix がコメントのみで
  挙動は byte 単位同一（else 枝は両版とも `Infinity`）。つまり**無指摘が正解**。これを除くと **JS = 15/15 = 1.00**。
- **Python の唯一の majority-miss は本物の難所:** `__getattr__`/`hasattr` ベースのファイルラッパー検出（duck-typing）の
  回帰を 1/3 run のみ検出。**微妙な動的型の回帰**という実在の弱点（見かけの穴でない）。
- 捕捉したものは全て**具体的な行・機構を特定**（判定は 6f205ff run1 の Low ドキュメント nit を"catch"に数えず＝厳格）。
  検出例: Content-Type の値なしパラメータ誤処理・proxy_bypass の空文字全マッチ・URL 末尾スラッシュ・同一オリジン
  リダイレクトでの basic auth 復元漏れ（security）・abort 済みシグナル処理漏れ（concurrency）。

**Precision（正しい実変更での誤報）:**
- **JS はよく標本化され、ほぼクリーン**（correct 5件・12run で clean 0.92、confident-FP は 1件のみ=0.08）。
  唯一の FP（cookie-refactor で `remove()` の `path='/'` ハードコードを誤って欠陥主張）は**正しくスキルの失点として計上**。
- **Python は n=1 で薄い。** 唯一の correct（cert 再読込回避 perf）で 3 run 全てが**共有 module-level `_preloaded_ssl_context`**
  を Critical 指摘 → 判定は**本物の潜在バグ（genuine latent）**と判断（誤報でなく）。gin 同様「**マージ済み≠バグ無し**」を
  再現。ただしこれは本ラウンド**最も判定依存の一手**——もし FP なら Python の唯一 correct は 3/3 FP に反転する。

---

## 2. 敵対ゲート＆判定 / Gate & assessment

**敵対ゲート: `generalizes`。** 言語間で recall・FP とも同水準、見かけの差は精査で解消（JS の低 recall は退化
フィクスチャ、Python の低 FP は薄い標本）。唯一の脆さは Python correct の n=1 と、その共有 SSLContext 判定への依存。

**判定: `assistant-ready-with-caveats`（据え置き。ただし単一言語 caveat は明確に弱まった）。**
> 3言語（Go/gin＋Python/requests＋JS/axios）で**同じプロファイル**——実バグ回帰をほぼ確実に majority 検出、正しい
> リファクタでは静か——が再現。異なるバグクラス（correctness/error-handling/concurrency/security/resource）と
> 異なる言語イディオムで一貫。「Go でしか効かない」への実質的な反証。**ただし過信しない**: 各言語は依然**1リポずつ**で、
> 言語一般化とリポ一般化が分離できていない（3つとも成熟した HTTP ライブラリ）。Python の precision は n=1。
> → caveat を「単一言語」から「**3言語だが各1成熟ライブラリ・Python の correct 標本が薄い**」へ格下げ（撤回はしない）。

---

## 3. スキル変更なし・監視／方法論 / No change; watch & methodology

- **スキル変更なし**（検証ラウンド）。Python の duck-typing 回帰の majority-miss は **n=1 かつ動的型の本質的難所**——
  過学習回避の標準規律で**監視のみ**（チェックリストの列挙漏れではなく、判断の難しさ）。
- **方法論の学び（fixture QA）:** 逆適用リプレイで**実 fix がコメントのみだと退化フィクスチャ**になり、生の recall を
  汚す（今回 JS で1件）。→ **anti-fix 差分が実際に挙動を変えるか**を fixture 生成時に確認する QA を今後入れる。
- **要追加検証:** requests の共有 SSLContext 指摘が真の潜在バグか（本ラウンド最も contestable な一手）。真なら
  Python precision は clean、偽なら 3/3 FP——独立検証で確定させたい。

---

## 4. 学び / What this teaches

1. **コア挙動は3言語で再現した——外部妥当性の実質的前進。** 「実バグ回帰を捕まえ、正しいリファクタで黙る」という
   two-axis のプロファイルが Go/Python/JS の異なるイディオムで一貫。単一言語 caveat は弱まった。
2. **ただし"言語×リポ"の交絡は解けていない。** 各言語1リポ（全て成熟 HTTP ライブラリ）ゆえ、「言語一般化」と
   「このよく整ったライブラリで効く」を分離できない。**caveat は消えず、性質が変わっただけ**。過信は禁物。
3. **"マージ済み≠バグ無し"が別言語でも再現。** requests の"正しい"perf commit でも Critical 潜在バグを検出（3/3）。
   organic バグ発見能力の追加証拠であり、同時に**正解の汚染**が言語横断で不可避なことも示す。
4. **fixture の質が数字を左右する。** 退化（挙動不変）フィクスチャ1件が JS recall を 1.00→0.83 に見せた。
   **field 測定は「正解の設計」と同じくらい「刺激の設計（差分が本当にバグか）」の QA が要る**。

---

## 5. Field 検証の到達点（3ラウンド）/ Where field validation stands

| ラウンド | 主張 | 実コード結果 |
|---|---|---|
| R1（gin/Go） | 実バグ回帰の検出 | 12/12・誤報0/5 |
| R2（gin/Go） | 正しいコードでの precision | clean 46%・低FP・+14 latent 発見 |
| **R3（requests/Python・axios/JS）** | **言語一般化** | **Python 4/5・JS 実質 15/15・低FP・+3 latent** |

3ラウンドで **①実害バグ検出 ②正しい変更でノイズを撒かない ③organic バグ発見** を**3言語**で実証。総合
`assistant-ready-with-caveats`（人間トリアージ前提のアシスタントとして実運用可）。残 caveat は「各言語1ライブラリ・
Python 標本薄・大差分/非ライブラリ codebase 未検証・severity 較正」——precision/recall の欠陥ではなく**カバレッジ**。

（`requests`/`axios` は検証のためだけの一時 clone。スキル/リポには含めない。）
