# Field Review 01 — modulith-virtual-thread-sample

初めての**実リポジトリでの現場適用**の記録。改善ラウンド(R1〜R8)で使った合成フィクスチャではなく、
外部の実プロジェクトにスキルを当てた。

- **対象:** `github.com/ryo-s-personal-project/modulith-virtual-thread-sample`(Java 21 / Spring Boot 3.2 /
  Spring Modulith / Virtual Threads、DDD・イベント駆動、~30 Java ファイル)
- **形態:** 差分ではなく**リポジトリ全体**レビュー。中核(config / order / inventory / api)を精読、
  shipping・notification は流し読み、`@Version`/ロックの有無は全体 grep で確認。
- **日付:** field test #1。

## 見つけた実バグ(重大度順)

1. **Critical — 在庫予約の check-then-act 競合(ロックなし)。**
   `InventoryEventListener.onOrderCreated`(`findByProductId → hasEnoughStock → reserve → save`)。
   `InventoryItem` に `@Version` も悲観ロックも無し(全体 grep で確認)。`@Async` リスナーは並行実行され、
   同一商品への同時注文で二重予約=**超過販売/在庫マイナス**。付属の `LoadTestController` が200件を
   仮想スレッドで同時発行し、まさにこの経路を踏む。
2. **High — `@Async` が private・自己呼び出しで no-op。**
   `OrderService.publishOrderCreatedEvent` は `@Async private` を `this` 経由で呼ぶ。Spring AOP は
   private/自己呼び出しにプロキシを効かせないため**完全に無効**。「asynchronously using virtual thread」と
   いうコメントに反し、リクエストスレッド上で同期実行され仮想スレッドに載らない=**目玉機能が動いていない**。
3. **Medium — 補償ロジックの誤り。** 予約失敗→注文キャンセル→`onOrderCancelled` が「予約していない在庫」を
   `release()` → 例外(非同期で握り潰し)、並行時は**別注文の予約を誤解放**して在庫水増し。
4. **Low — 未検出が HTTP 500。** `getOrder`/`getInventory` が汎用 `RuntimeException` → 404 でなく 500。

**誤検出しないよう明記した(＝バグでない)もの:** HikariCP `maximum-pool-size: 200`(意図的設定)、
ベンチの `Thread.sleep`(I/O シミュレーション)、リクエスト毎の VT executor(`finally` で `shutdown`)、
`InterruptedException` の再設定(正しい)。

## 学び / Lessons

1. **言語非依存の主張が現場で検証された。** 改善は主に汎用/一部 Go・Python 題材で回したが、初見の
   **Java/Spring** リポジトリで実バグを2件検出。スキルは方法論(チェックリスト・重大度・スコープ規律)を
   与えるだけで、言語固有知識はモデルが供給する。**「スキル=方法論 × モデル=知識」の両輪**が要る。

2. **8ラウンドで鍛えた"まさにそのクラス"が現場の主役だった。**
   - 並行性(check-then-act / ロック欠如)は R2・R3 で強化した concurrency 軸と「concurrency は1段上げ」の
     重大度規則がそのまま効いた。
   - `@Version` 欠如の断定には**リポジトリ全体を grep** する必要があり、SKILL §2「見えないコードは
     読め/grep せよ」の習慣(R6・R7 で一般化)が決め手になった。単一ファイルの目視では出せない指摘。

3. **precision 規律が現場で誤検出を防いだ。** 「文書化/意図された設定は所与」(R3・R7)や「周辺コードを
   読む」により、HikariCP 200・Thread.sleep・VT executor を**誤報せず**に済んだ。これらを素朴に叩くと
   4〜5件の false positive でレビューが薄まっていた。**磨いた precision は合成題材だけでなく実コードでも効く。**

4. **フレームワーク意味論の知識が recall 倍率になる。** `@Async` no-op は「Spring AOP は private/自己呼び出しに
   効かない」という知識が無いと出せない。チェックリストには書けない**モデル側の知識**が、テキストブック級の
   実バグを surface させた。方法論だけでは届かない領域がある。

5. **全体レビュー時はスコープ規律の"逆"に注意。** スキルは差分前提で「スコープ外は指摘しない」が規律だが、
   リポジトリ全体レビューでは全ファイルが対象になる。結果、**網羅監査に流れず並行性の中核を優先**する、と
   いう**明示的な優先順位付けと正直なスコープ宣言**(「中核を精読、他は流し読み」)が品質と誠実さの鍵になった。

6. **見つかったのはテキストブック級のバグ2種。** e-commerce の超過販売(在庫競合)と Spring の `@Async`
   self-invocation no-op はいずれも"典型的だが実際によくやる"落とし穴。**スキルが奇をてらわず定番の実バグを
   確実に拾える**ことの確認になった(奇抜な指摘より定番の確実な検出が実務価値)。

## 次への含意

- 実運用フィードバック駆動のラウンド候補: この現場で**もし誤検出/見逃しがあれば**それを種に R9 を回す。
  今回は明確な誤検出は自己確認の範囲では無し(修正パッチを書いて実際にビルド/テストで検証すれば
  さらに確度が上がる — 未実施)。
- スキルを**差分専用**から**「差分 or 全体」明示モード**に広げる価値があるか、実運用の要望次第で検討。
