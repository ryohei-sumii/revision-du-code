# Round L1 — 大標本キャンペーン / Large-Sample Campaign (20言語題材・80バグ・敵対検証)

**日付:** 2026-07-09 ／ **状態:** ✅ 完了・**両デフォルトを大標本で確認＋品質ギャップ1件を修正** ／
**手法:** 20の多言語フィクスチャ（~80仕込みバグ）を一度だけ author し、4条件で走らせて
read-scope とモデルのデフォルトを**タイトな標本**で決着＋既定構成の系統的取りこぼしを狩る。

小標本（4〜5題材）で「差が1バグに依存＝ノイズ」だった過去結論を、**5倍規模**で検証した。

---

## 1. 実験デザイン / What we ran

- **共有コーパス:** Python/Go/TS/JS/Java/Rust/Ruby/C#/Kotlin/PHP/C/Scala の20題材、各~4バグ
  （難度 mechanical/subtle × クラス concurrency/contract-guard/security-auth/resource/correctness/
  error-handling）＝**80 planted-bug チェック/条件**。author は一度だけ（メタコスト対策）。
- **4条件**（コーパス共有）: **S-budget**(Sonnet＋純予算=現行デフォルト) / **O-budget**(Opus＋純予算) /
  **S-full**(Sonnet＋フル読込) / **H-budget**(Haiku＋純予算)。各3run（Haikuは1）。
- **判定**(Opus/題材)→**ギャップ狩り**(Opus/high)→敵対ゲート→**判定**(Opus/提案のみ)。
- 規模: 243エージェント（242完了）・総 **7.79M tok**・2014ツール・実時間は途中で**セッション上限**に当たり
  リセット後 resume で完走（詳細は §5）。

---

## 2. 実測結果 — 両デフォルト確認＋強化 / Results

| 条件 | 全体 | mech | subtle | 並行 | 契約 | 認可 | 資源 | 正確性 | 誤処理 | precision | FP | 読込 |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| **S-budget(既定)** | **0.95** | 0.94 | **0.96** | **0.98** | 0.92 | 1.00 | 0.85 | 0.98 | 0.94 | 0.97 | 8 | 5.18 |
| O-budget | 0.92 | 0.93 | 0.91 | 0.90 | 0.96 | 1.00 | 0.88 | 0.93 | 0.85 | 0.98 | 4 | 4.13 |
| S-full | 0.94 | 0.94 | 0.94 | 0.95 | 0.92 | 1.00 | 0.88 | 0.96 | 0.92 | 0.97 | 10 | 6.68 |
| H-budget | 0.73 | 0.80 | 0.65 | 0.64 | 0.50 | 0.69 | 0.64 | 0.87 | 0.88 | 0.93 | 5 | 4.90 |

**モデル（Sonnet vs Opus）: `keep-sonnet` を確認・強化。**
- subtle 差 = **−0.05**（Opus 0.91 < Sonnet 0.96）——Round 5 で「ノイズ域」だった Sonnet 優位が、80バグでは
  **Sonnet が明確に上**。全体も 0.95 > 0.92、並行クラスは 0.98 vs 0.90、認可は 1.0 タイ。しかも**安い**。
  → Opus に替える理由なし。むしろ替えると保護クラス(並行)の recall を下げる（標準則(a)違反）。

**読込スコープ（budget vs full）: `keep-budget` を確認・強化。**
- 全体差 = **−0.01**（S-full 0.94 ≤ S-budget 0.95）——フル読込は budget を**どの保護クラスでも上回らず**、
  **誤検出は増え**（FP 10 vs 8）、**読込は+29%**（6.68 vs 5.18）。Round 3〜4 の「読むほど良いは偽／レビューにも
  lost-in-the-middle」を80バグで**再現**。full の唯一の勝ちは resource(0.88 vs 0.85)——これは§4のスキル修正で
  より安く埋める。

**Haiku フロア: 確定的に危険。** 全体 0.73、subtle 0.65・契約 0.50・認可 0.69・並行 0.64。しかも総指摘 69件
（Sonnet 280件）で**そもそも報告数が足りない**。Round 5 のフロア警告を大標本で裏付け——**Haiku は使わない**。

---

## 3. 判定 / Decision（proposing-only）

- **model_decision = `keep-sonnet`** — S-budget 0.95 > O-budget 0.92、保護クラスでも優位、より安い。
- **readscope_decision = `keep-budget`** — S-full は保護クラスで budget を超えず、FP増・コスト増。
- **skill_changes = 3件**（下記§4。ギャップ狩り由来・precision-safe に絞り込み）。

※ 敵対ゲート・エージェントは上限に当たり空応答（1件の empty result）。判定側は独立に保守的に推論し、
model/readscope を確認、スキル変更を最小3件にトリムした。ゲート欠測でも結論は堅い（deltas が明瞭・多クラスで一貫）。

---

## 4. 見つかった品質ギャップと修正 / The quality gap (applied)

**系統的な既定の取りこぼしは1件だけ**——C の**所有ヒープ文字列リーク**（resource・mechanical）。既定(S-budget)は
全runで見逃したが Opus(2/3)・full(1/3)は捕捉＝「難しいバグ」でなく**チェックリストのフック欠落**。ギャップ狩り(Opus)が
**一般的なテキスト欠陥**を特定: `review-checklist.md` も `severity-rubric.md` も、解放すべき資源を
「files/locks/connections/handles」と列挙し**ヒープ/malloc メモリを一度も挙げていない**。resource は全条件で
**最弱クラス**（0.85〜0.88）で、手動メモリ言語（C/C++/unsafe Rust/Zig）のリークにフックが無かった。

**適用した3修正（precision-safe）:**
1. `review-checklist.md` の資源解放バレットに **`, and heap memory`** を追加（カテゴリ名を広げるだけ・閾値不変）。
2. その直後に**手動メモリ言語バレット**を新設: 「各 owned allocation は**全 exit path** で free と対に。
   **リークの具体経路を名指せる時だけ**（overwrite-without-free／早期 return が cleanup ラベルを飛ばす／
   destroy が保有ヒープ member を解放しない）flag。**断定前に free/destructor と呼び出し側を READ**——
   呼び出し側が所有権を取る／`defer`/cleanup が解放するなら drop」。→ ReDoS・injection と同じ
   「具体例を名指してから確認」規律で FP を防ぐ。
3. `severity-rubric.md` の High 例に **`a heap allocation not freed`** を追加（整合・確認済みリークを High に）。

**過学習ガード:** 裏付けは n=1 の miss だが、(a)欠落は**両ファイルの列挙に共通するカテゴリ級**、(b)resource は
全条件で最弱、(c)当該バグは mechanical で Opus/full が捕れた＝明白に検出可能——「フィクスチャの綾」でなく
一般ギャップ。修正は**具体経路の名指し＋free/呼び出し側の READ 必須**で precision-safe。

---

## 5. メタ: セッション上限に当たった話 / What the run itself taught

- **初回実行が途中でアカウントのセッション上限に到達**（122/243 完了で失敗、`resets 04:10 UTC`）。author 20体は
  ディスク保持、~102レビューはキャッシュ済み。`resumeFromRunId` で成功分を無料リプレイし、失敗分だけ再実行して完走。
- **教訓（運用）:** 大標本は**メタコストだけでなくレート/セッション上限にも当たる**。①**author を一度だけ**にして
  再実行時の再生成を避けた設計が効いた（resume で丸ごと救えた）②上限は`resets`時刻まで**間欠的に残り**、
  リセット前の resume は retry-crawl で遅い——大規模ジョブは**上限リセット後にまとめて流す**のが速い。
  ③`resumeFromRunId` は「同一 script＝キャッシュ命中」で、**部分失敗した長時間ジョブの救済に有効**。
- 学び4「メタコスト≫プロダクトコスト」の**実運用版**: 大標本は正しく設計しないと上限で頓挫する。**author 使い回し・
  resume 前提・上限後にまとめ流し**が大規模実験の3点セット。

---

## 6. 到達点への含意 / Implications

- **両デフォルト（純予算制・Sonnet）は大標本で確認され、むしろ差が Sonnet/budget 有利に締まった。** 小標本の
  「ノイズ域」留保は解消——Sonnet は Opus に subtle でも勝ち、budget は full を超える。過去5ラウンドの結論は堅牢。
- **品質は大標本で初めて見える系統ギャップ（手動メモリ・resource）を1件埋めた。** 合成小標本では出なかった穴で、
  **多言語・大標本の主目的（新しい recall ギャップの発見）が結実**。
- 学び18〜19を `cost-log.md`／`improvement-log.md` に集約。
