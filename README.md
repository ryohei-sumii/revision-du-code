# revision-du-code — 汎用コードレビュースキル / Universal Code Review Skill

インストール不要（`npm`/`pnpm`/`pip` 等の導入なし）で、あらゆる言語・リポジトリに
使える Claude Code 用のコードレビュースキルとスラッシュコマンドです。`git` と
ファイル読み取りだけで動作します。

An install-free, language-agnostic code review skill and slash command for
Claude Code. It runs on nothing but `git` and file reads — no dependency
install, no build step — so it works in a fresh clone of any repo.

## 使い方 / Usage

このリポジトリの `.claude/` を、レビューしたいプロジェクトに置くか、
`~/.claude/`（ユーザー全体）にコピーします。Claude Code から:

Drop this repo's `.claude/` directory into a project (or copy it into
`~/.claude/` to make it global), then from Claude Code:

```
/code-review              # 未コミットの変更をレビュー / review uncommitted changes
/code-review staged       # ステージ済みのみ / staged only
/code-review branch       # デフォルトブランチとの差分（PR相当）/ vs default branch (PR-style)
/code-review HEAD~3       # 任意の git ref との差分 / vs any git ref
```

自然言語でも起動します（スキルの description がトリガーになります）:
It also triggers from natural language:

> 「変更をレビューして」 / "review my changes before I commit"

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

## 設計方針 / Design

[claude-code-best-practice](https://github.com/shanraisshan/claude-code-best-practice)
のベストプラクティスに準拠:

- **スキルはフォルダ + 段階的開示** — `SKILL.md` を薄く保ち、詳細は
  `references/` と `scripts/` に分離（progressive disclosure）。
- **description はトリガー** — 「何をするか」ではなく「いつ発火すべきか」を記述。
- **レール化しない** — 手順を細かく縛らず、ゴールと制約を与えて判断を委ねる。
- **gotchas を明文化** — 誤検出しやすい箇所（テスト緑＝正しい、ではない等）を記録。
- **インストール不要・ネットワーク不要** — 新規クローンでもそのまま動く。

## 出力 / Output

指摘は重大度順（Critical → High → Medium → Low/Nit → Question）に並べ、各項目に
`file:line`・一行の要約・具体的な失敗シナリオを付けます。差分がきれいなら
「問題なし」と率直に返します。ファイルの編集は依頼がある場合のみ行います。

Findings are reported severity-first, each with `file:line`, a one-line defect
statement, and a concrete failure scenario. A clean diff gets an honest "looks
good." Files are only edited when you explicitly ask.

## 開発ログ / Development logs

このスキルは AI で自己改善しており、その過程を2つのトラックに記録しています。

This skill is self-improved with AI; the process is recorded in two tracks:

- **品質 / Quality** — recall・precision の測定駆動改善（8ラウンドで収束）:
  `docs/improvement-log.md`、生データは `docs/rounds/`。
- **コスト / Cost** — 1回あたりのトークン消費・モデル配分の測定と改善:
  `docs/cost/cost-log.md`、現状の実測ベースラインは
  `docs/cost/baseline-token-usage.md`。
