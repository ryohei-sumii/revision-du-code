# Field Round 1 — 実リポジトリ検証 / gin bug-fix replay（合成でない実コード）

**日付:** 2026-07-09 ／ **状態:** ✅ 完了・**スキル変更なし（現場性能の測定）** ／
**対象:** `gin-gonic/gin`（Go, 実 OSS）／ **手法:** 実 bug-fix コミットの逆適用リプレイ＋クリーン実コミット。

合成フィクスチャの限界（合成≠実・採点者が LLM・仕込みバグは実バグより易しい）を閉じるための現場ラウンド。
**本物のスキルファイル（SKILL.md＋references）を読ませた Sonnet 既定構成**で、実コードをレビューさせた。

---

## 1. 手法 / What we ran

- **fix リプレイ（12件）:** 実際に gin に landed した bug-fix コミットを**逆適用**し、"バグを再注入する差分"を作成。
  ディスク上のコードは**バグのある親ツリー**、DIFF はソースのみ（**テスト hunk は除去**——テスト名が答えを漏らさないため）。
  正解＝現実の fix（subject/body/patch を `GROUND_TRUTH.txt` に格納、判定エージェントが読む）。エージェントがその
  **現実の欠陥を regression として指摘できるか**を測る。クラス: crash/nil-crash/concurrency/contract/security/
  error-handling/correctness。
- **クリーン（5件）:** 実際の benign コミット（docs/typo/version-bump）。**現場の誤報率**を測る。
- 各 fixture 3 run（Sonnet）→ 判定(Opus/high)→**敵対ゲート**(Opus, 生 DIFF/GROUND_TRUTH を独立に再読)→**readiness 判定**。
- 70エージェント・エラー0・2.93M tok・約50分。

---

## 2. 実測結果 / Results

| 指標 | 値 |
|---|---|
| **実バグ recall（per-run / majority）** | **12/12（1.00 / 1.00）** |
| クラス別 | crash 3/3・nil-crash 3/3・concurrency 1/1・contract 2/2・security 1/1・error-handling 1/1・correctness 1/1 |
| **クリーン差分の誤検出** | **0/5（誤報ゼロ）** |
| fix 差分上の誤検出 run | 0 |
| severity 較正のブレ | 1件（nil-handler panic を 3 run 中2で低 severity に誤格下げ・検出自体はできている） |

**敵対ゲートの独立検証: `judging-sound`。** ゲートは判定サマリでなく**各 fixture の生 DIFF/GROUND_TRUTH を自分で再読**し、
「12件すべて"caught"は landed-fix のまさにその欠陥・場所」「クリーン5件は本当に benign」と確認。**採点の水増しなし**。
検出例（実コードの実欠陥を正しく指摘）:
- atomic 同期の除去 → gin mode の data race（#1580）を Critical で指摘
- `strings.Join(Header.Values,",")` → `Header.Get`（先頭値のみ）への差し替え → 複数行 XFF での ClientIP 誤り（security）
- `if len(vs)==0` → `if !ok` への改変 → 空スライスで `vs[0]` index-out-of-range（contract）
- `sync.Once` 除去 → `engine.Handler()` 経由でリテラルコロンルートが不一致（correctness, #4415）
- nil body ガード除去 → `io.ReadAll(nil)` panic、`URL != nil` ガードの縮小 → nil-deref、など

---

## 3. 正直な位置づけ — この 100% をどう読むか / Honest framing

**強い証拠だが、"一般的な recall 保証"ではない。** readiness 判定（Opus, 提案のみ）は **`assistant-ready-with-caveats`**。

- **fix リプレイは"易しめ"の設定。** 再注入バグは**既知の landed-fix を局所的に巻き戻したもの**で、欠陥が小さな単一
  ファイル hunk 内に収まる。**新規の・複数ファイルに跨る・ハンクに見えない**組織的なバグより検出しやすい。
  → この 100% は「**局所的で自己完結した実欠陥に非常に強い**」と読むべきで、汎用の recall 保証ではない。
- **誤報 0/5 は"最も弱くしか検証できていない"次元。** クリーン5件は全て自明に benign（docs/typo/version）。
  **"実質的だが正しい"変更**（本物のリファクタ・安全なロック順序変更・エラー経路の書き換え・性能改善）——
  現場で FP 疲れを生む"危なく見えるが正しい"差分——は1件も含まない。→ この結果は「自明に無害な変更にバグを
  幻視しない」ことしか示さず、**採用可否を決める難しい precision は未測定**。
- **単一リポ・単一言語（Go/gin）・小 n・小差分。** 他言語・大差分・異なるイディオムの証拠は無い。
- **severity 較正は不安定。** High の nil-handler panic を 2/3 run が低 severity に誤格下げ——**検出できても
  ランク付けを誤る**。自律的なマージゲートには致命的になりうる（検出＝十分でない）。

---

## 4. 判定 / Verdict

> **`assistant-ready-with-caveats`。** 人間がトリアージするレビュー"アシスタント"としては配備してよい——panic・
> nil-deref・data race・security/contract 回帰といった**実害の大きい実欠陥を確実に表面化させ、無害な変更にノイズを
> 撒かない**。ただし**自律的なマージゲートとしては production-trustworthy でない**。理由: (1)採用を左右する precision が
> **自明 benign 差分でしか検証されていない**、(2)単一リポ・単一言語・小さな局所 anti-fix・severity ランクのブレ。

**スキル変更: なし。** 本ラウンドは現場性能の**測定**（現行スキルを実コードで走らせて確認）。見つかった gap は
「修正すべき欠陥」でなく**カバレッジの穴**（もっと検証が要る）。severity ブレは n=1 のため、過学習回避の標準規律に
従い**スキルは変えず"監視対象"として記録**（8ラウンドの「散発1件は改善対象でない」に一致）。

---

## 5. 学び / What this teaches（→ improvement-log にも集約）

1. **実コードの"既知バグ回帰"検出は非常に強い——が、それは field-readiness の一部分でしかない。** 実 OSS で
   12/12・誤報0・敵対ゲート通過は、合成では得られない強い前進。だが「回帰を捕まえる」≠「新規の組織的バグを見つける」
   ≠「危なく見える正しい差分で黙る」。**"実用に耐える"は3つの別々の主張で、今回は1つ目を強く実証した**。
2. **良い field テストは"正解"の設計が9割。** landed-fix を正解に使う（＋テスト hunk を除去）ことで、**LLM 採点でも
   客観に近い**測定になった。敵対ゲートが生 diff を独立再読して水増しを排したのも効いた。
3. **次に測るべきは precision（"実質的だが正しい"リファクタでの誤報）。** これが FP 疲れ＝採用可否を決める。今回の
   0/5 は自明 benign 限定で、ここが field-readiness の**最大の未測定軸**。

---

## 6. Production-trustworthy への残タスク / What would close the gap

- **本物のリファクタ・正しい大改修のコーパスで precision を測る**（FP 疲れの本命・最大の穴）。
- **多言語・organic（非リプレイ）バグ・大差分**への拡張。
- severity 較正の再現テスト（High 級の panic を確実に High に載せるか）。

（対象リポジトリ `gin-gonic/gin` は本検証のためだけに一時 clone。スキル/リポには含めない。）
