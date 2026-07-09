# Field Round 2 — precision / 誤報疲れ / FP-fatigue on real correct code（gin）

**日付:** 2026-07-09 ／ **状態:** ✅ 完了・**スキル変更なし（precision の測定）** ／ **対象:** `gin-gonic/gin`（実 OSS）。

Round 1 が残した**最大の未測定軸**——「**危なく見えるが正しい実コード**での誤報率（＝採用可否を決める FP 疲れ）」——を測る。

---

## 1. 手法 / What we ran

- **正しい実変更（13件）:** gin に**マージされ mainline で生存**（＝正解＝正しい・振る舞い保存）した**実質的で危なく見える**
  コミット。sync.OnceValue へのリファクタ・`Keys` 型を `map[any]any` に変更・path/tree の正規表現→自前関数書き換え・
  SaveUploadedFile のシグネチャ変更・countParams の unsafe 最適化・TrustedProxies IPv6 対応・binding 書き換え等。
  テスト hunk 除去でソースのみ判定。**期待挙動＝ほぼ無指摘**（confident な欠陥主張は誤報）。
- **隠し positive（4件）:** 既知の実バグ（anti-fix）を混在 → **「黙って clean と言うだけ」でないこと**を同時証明。
- 本物のスキルを読ませた Sonnet 既定構成で各3run。判定(Opus/high)は**公平に**——マージ済みでも**本物の潜在バグはありうる**
  ので、真の指摘は FP に数えず `genuine_latent` に。敵対ゲート(Opus)が「FP と断じたものが実は本物でないか」を再検証。
- 70エージェント・エラー0・3.1M tok・約66分。

---

## 2. 実測結果 / Results

| 指標（正しい実変更 13件×3run=39run 上） | 値 |
|---|---|
| **confident FP（Medium+の誤報）run 率** | **0.13**（5件/39run） |
| confident FP を出した fixture | **4/13** |
| **完全 clean run（無指摘）率** | **0.46** |
| 1レビューあたり平均指摘数（ノイズ） | **0.64** |
| nit（低優先・多くが自己申告の保守性メモ） | 20 |
| **隠し positive の recall** | **4/4（per-run 1.00）** ← 黙っていない |

**大きな発見: `genuine_latent = 14`。** レビュアーが「正しい」はずのマージ済みコミットで指摘した多くは、**誤報でなく
本物の潜在バグ**だった（判定が in-source 検証）。例:
- `recovery.go`(perf): 新 `stack()` が単一行だけキャッシュしフレーム跨ぎでソース行を誤帰属＝**実回帰**（3/3 run が指摘）
- `binding`(書き換え): `case reflect.Ptr: v.ValidateStruct(value.Elem().Interface())` が **nil ポインタで panic**（Go で再現）
- `Keys`→`map[any]any`: `json.Marshal(Keys)` が壊れる回帰
- `SaveUploadedFile`: 無条件 `os.Chmod(filepath.Dir(dst), perm[0])` が既存ディレクトリの mode を変更——**gin は後に
  実際この挙動を修正した**（#4702）。レビュアーはそれを先回りで検出。

→ **「マージ済み＝バグ無し」ではなかった。** 「正解=生存」というグラウンドトゥルースは**スキルに有利な方向に汚染**
されており、真の confident-FP 率はさらに低く、真の recall はさらに高い。

---

## 3. 敵対ゲート＆判定 / Gate & assessment

**敵対ゲート: `judging-sound`（むしろスキルに寛大でなく公平）。** 5件の confident FP のうち4件は妥当な FP
（意図的な公開 API 破壊への批評・Windows 固有の Low ノイズ等）、1件（formdata key==""）は「本物の差異を FP に誤分類」
＝わずかに厳しめ。**本物の14 genuine_latent は全て検証済みの実回帰で、FP に紛れ込ませていない**。positive 4/4 も確認。

**判定: `assistant-ready-with-caveats`（据え置き。ただし precision 軸が測定され、強かった）。**
> 採用を左右するまさにその種の差分（実質リファクタ・perf・型/シグネチャ変更・並行プリミティブ入替・security）で、
> スキルは**静か**（clean 46%・0.64指摘/レビュー）で、口を開けば大半が**本物の潜在バグ(14)か妥当な設計観察**、真のノイズは
> 39run で~2〜3件のみ。同時に planted 4/4 を正しい場所・severity で検出——**低 FP は臆病さの産物ではない**。
> "assistant-ready" に格上げしないのは precision の問題ではなく**外部妥当性**（単一リポ・単一言語、正解の汚染、意図的
> 破壊変更を指摘する摩擦）——単一 gin 標本からの過信こそ本評価が排すべきもの、と判定側が明言。

---

## 4. スキル変更なし・監視項目 / No change; watch items

- **意図的な公開 API 破壊（例: `RemoteIP` の戻り値型変更・`SaveUploadedFile` の perm 追加）を"指摘"として挙げる摩擦。**
  観察としては正しいが、破壊が目的の差分ではノイズ。ただし **n=2・単一リポ**のため、過学習回避の標準規律で**スキルは
  変えず監視**（「意図的設計は欠陥でない」既存規律の範囲でおおむね吸収されている）。
- 本ラウンドは precision の**測定**。current スキルが実コードで良好と確認できたこと自体が成果。

---

## 5. 学び / What this teaches

1. **FP 疲れの本命軸で、スキルは"静かで的確"だった。** 正しい実変更で clean 46%・0.64指摘/レビュー・confident-FP run 率
   0.13（真値はさらに低い）。**しかも低 FP は沈黙で買ったものでない**（positive 4/4）。Round 1 の「precision 未測定」という
   最大の穴が埋まり、**recall・precision の両軸が実コードで検証**された。
2. **"マージ済み＝正しい"は漏れる——正解の汚染は実測の不可避なノイズ。** 14件の本物潜在バグが"正しい"集合から出た
   （1件は gin が後に実修正）。**field の precision 数値には、正解自身の誤りという系統ノイズが乗る**。良い測定は
   「真の指摘を FP に数えない」公平な判定＋敵対再検証を要する。
3. **これは組織的バグ発見能力の証拠でもある。** 14件は planted でない実コードの subtle バグ。「新規・organic バグを
   見つけられるか」という難しい主張に、**現場で直接の肯定証拠**が出た（Round 1 では未証明だった軸）。
4. **残る摩擦は"意図的破壊変更"。** 検出漏れでなく、正しい観察が破壊目的の差分では不要ノイズになる——**FP でなく
   framing の問題**。将来、意図の signal（changelog/コメント/差分の主目的）で抑制する余地はあるが、単一リポ n=2 では
   まだ変えない。

---

## 6. Field 検証の到達点 / Where field validation stands（2ラウンド）

Round 1（既知バグ回帰の検出）＋Round 2（正しいコードでの precision）で、**"実用に耐える"の3主張のうち2つを実コードで
強く実証**——①**実害バグを確実に検出**（12/12＋4/4）②**正しい変更でノイズを撒かない**（clean 46%・低 FP）。③**新規 organic
バグの発見**も、14件の latent 検出という副次証拠で部分的に裏付け。総合 **`assistant-ready-with-caveats`**：人間トリアージ
前提のレビュー・アシスタントとして実運用に足る。残る caveat は**外部妥当性**（多言語・大差分・非リプレイ organic バグ・
severity 較正）で、precision/recall の欠陥ではない。

（`gin-gonic/gin` は検証のためだけの一時 clone。スキル/リポには含めない。）
