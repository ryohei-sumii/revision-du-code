# Field Round 4 — Rust ＋ 非ライブラリ / ripgrep（新言語＋アプリ codebase）

**日付:** 2026-07-09 ／ **状態:** ✅ 完了・**スキル変更なし** ／ **対象:** `BurntSushi/ripgrep`（Rust 製 CLI grep）。

Round 3 が残した2 caveat を同時に叩く: **①未検証言語（Rust＝4言語目）** ②**非ライブラリ（アプリ）codebase**
（これまで Go/Python/JS はすべて HTTP ライブラリ）。同一手法（bug-fix 逆適用＝recall／マージ済み実変更＝precision）。
45/46エージェント（1エラー＝敵対ゲートが null）・2.33M tok。

---

## 1. 実測結果（Rust / ripgrep）/ Results

| 指標 | 値 |
|---|---|
| **recall（per-run / majority）** | **0.90（19/21）／ 7/7** |
| クラス | crash/panic・correctness・regex-correctness・**memory-refcycle**・escaping を網羅 |
| **confident FP（Medium+誤報）** | **0 / 12run（0.00）** |
| clean-run 率 | 0.67（非 clean は全て自己申告 Low/Nit・Medium+ 誤報ゼロ） |
| genuine latent | 0（ripgrep のマージ commit は本当にクリーン） |

**recall:** 7バグ全て majority 検出（≥2/3）。実コードで検出した実欠陥の例:
- `printer/util.rs`: `last_match > range.end` ガード除去で look-around 置換の**スライス panic**再導入
- `regex/literal.rs`: prefix 伝播/`make_inexact()` 除去で**内側リテラル抽出の false-negative**（#2884）
- `ignore/dir.rs`: キャッシュが `Weak<IgnoreInner>` でなく **strong `Arc` を保持 → 参照循環でリーク**
- `searcher/core.rs`: NUL 行終端で fast path を誤って有効化する correctness バグ
- 2件の単一 run miss（globset の `..` 末尾バイト・Arc/Weak 循環）はいずれも 2/3 で捕捉。

**特筆:** **Arc vs Weak の参照循環**を捕らえた——**Rust 固有の所有権/ライフタイム推論**であり、
「表層パターン照合でなく新言語のセマンティクスを実際に推論している」最良の証拠。

**precision:** 正しい実変更4件×3run で **Medium+ 誤報ゼロ**。非 clean は excludesFile の引用符正規表現・JSON の
`replacement` フィールドで、いずれも**自己申告の Low/Nit**（誤報でない）。報告閾値での precision は実質満点。

---

## 2. 判定 / Assessment（敵対ゲートは agent エラーで null → assess が自己批判的に代替）

**readiness: `assistant-ready-with-caveats`。**

- **未検証言語 caveat = 実質クローズ。** Go/Python/JS/Rust の**4言語で一貫**したプロファイル。Rust は他3言語に無い
  所有権/Arc-Weak 推論を要し、それを捕らえた＝**元3言語への過学習でない**証拠。
- **非ライブラリ caveat = 部分的に前進、ただし discharge していない（正直に）。** ripgrep は名目上アプリ（CLI）だが、
  バグ表面は**個別公開される library 級 crate**（searcher/globset/ignore/regex/printer）にあり、**構造的には
  ライブラリ**で、しかも例外的にテストが厚い。→ 「**初の非 HTTP ライブラリ・systems/CLI ドメイン**」であって
  「初の雑然としたアプリ」ではない。**"messy/テスト薄いアプリ" は依然未検証**（FP 率が最も悪化しうる領域）。
- **その他 gap:** 各言語まだ1リポ（Rust=ripgrep のみ）／replay は novel バグより易しい（recall を過大評価しうる）／
  N 小／precision 標本は高品質 PR のみ／miss 2件が globset/ignore のパス処理に集中（監視領域）。

**スキル変更なし**（検証ラウンド。miss はいずれも majority 通過・n 薄のため監視のみ、過学習回避の標準規律）。

---

## 3. 前ラウンドの保留2件を解消 / Two open items resolved

- **requests 共有 SSLContext 指摘（Round 3 で最も contestable だった一手）= 本物と検証。** 当該 commit は
  requests #6667＝**2.32.0 で実際に SSL 回帰を起こした変更**。レビュアーが共有 module-level `_preloaded_ssl_context`
  を Critical 潜在バグと指摘したのは**妥当（誤報でない）**。→ Round 3 の Python "0 confident-FP" は保持。
- **fixture 生成の空白タイポ（escaping fixture の `dir`）:** judge のグラウンドトゥルース・ファイル読取りは外れたが、
  当該 fixture は DIFF＋レビュアー指摘＋クラスから**正しく caught 3/3 と判定**（`{`/`}` エスケープ契約を正しく推論）。
  結果は非汚染。**方法論の再確認:** Round 3 で立てた fixture QA の必要性を裏付ける（今回は判定に影響せず）。

---

## 4. 学び / What this teaches

1. **4言語目で"未検証言語"caveat がクローズ——コア挙動は言語非依存だと実証。** Go/Python/JS/Rust で「実バグ回帰を捕え、
   正しい変更で黙る」が再現。Rust では Arc/Weak・スライス panic・所有権という**言語固有推論**まで通用。
2. **"アプリ"caveat は看板倒れになりうる——構造を見よ。** ripgrep は CLI だがバグ表面は library 級 crate。
   **「アプリで検証した」と安易に言えない**——"messy でテストの薄い業務コード" こそ FP が最も出る領域で、そこは未踏。
   caveat は「非ライブラリ」から「**雑然/低テストのアプリ未検証**」へ精密化（消えていない）。
3. **replay の易しさは recall を過大評価する（再掲・重要）。** 既知修正の逆適用は局所的で、野生の novel バグより易しい。
   field の recall 数値は上振れしていると読むべき。
4. **クリーンな codebase では genuine_latent が出ない——のは自然。** gin/requests では"正しい"commit に潜在バグを検出
   （14件/3件）したが、ripgrep では 0。これは検出力低下でなく、**ripgrep のマージ品質が実際に高い**ことの反映。

---

## 5. Field 検証の到達点（4ラウンド・4言語）/ Where field validation stands

| R | 言語/リポ | 種別 | 実コード結果 |
|---|---|---|---|
| R1 | Go / gin | 既知バグ回帰 | 12/12・誤報0/5 |
| R2 | Go / gin | 正しいコードの precision | clean 46%・低FP・+14 latent |
| R3 | Python / requests・JS / axios | 言語一般化 | Py 4/5・JS 実質15/15・低FP・+3 latent |
| **R4** | **Rust / ripgrep（アプリ）** | **新言語＋非ライブラリ** | **7/7・誤報0・Arc/Weak 推論** |

**4言語（Go/Python/JS/Rust）で ①実害バグ検出 ②正しい変更でノイズを撒かない ③organic バグ発見(gin/requests) を実証。**
総合 `assistant-ready-with-caveats`（人間トリアージ前提のアシスタントとして実運用可）。

**残る正直な caveat（precision/recall の欠陥でなくカバレッジ）:**
- 各言語まだ1リポ（言語一般化とリポ一般化が未分離）
- **雑然/低テストの"本物のアプリ"コード未検証**（FP が最も悪化しうる regime）
- replay ≤ novel バグ発見の難度／大差分・多ファイル相互作用未検証／severity 較正

（`ripgrep` は検証のためだけの一時 clone。スキル/リポには含めない。）
