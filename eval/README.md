# 評価実験: 型で解決した呼び出し関係と値の来歴は、AI エージェントの手戻りを減らすか

## 仮説

Rails アプリのバグ調査で、grep と Read しか持たないエージェントに比べ、
「受信者の型で解決した呼び出し先」と「値の来歴」を受け取れるエージェントは、
原因箇所に早くたどり着き、誤った編集が少なく、正しい修正をする割合が高い。

## 課題

mastodon の過去のバグ修正コミットから 5 件を選びました(`tasks/*.yaml`)。

| 課題 | 修正コミット | 内容 |
|---|---|---|
| t1_idempotency_500 | 4e15f3db | 同じ Idempotency-Key で二度投稿すると 500 になる |
| t2_create_author_change | 9d51f51c | 既知の投稿を別の作者が Create すると RecordInvalid になる |
| t3_reach_filter_threshold | 5d7465a9 | 決して真にならない条件のせいで、飽和しきい値が誤る |
| t4_reported_statuses_purge | cd4e10bb | アカウント削除時に、通報された投稿に deleted_at が付かない |
| t5_quote_edit_text | 18865140 | 引用投稿の本文を編集できない |

選んだ条件は四つです。app/ か lib/ を変更していること、spec も変更していること、80 行未満の修正であること、2025 年 6 月以降であること。
エージェントには修正コミットの親を渡し、症状の説明だけを与えます。ファイル名とメソッド名は伏せました。
正解は、修正コミットが変更したメソッドです。修正の正しさは、修正コミットに含まれる spec で判定します。
環境のせいで元から落ちる example を除くため、本物の修正を当てたときの失敗集合を基準にしています(`oracle.sh`)。

## 条件

| 条件 | エージェントに渡すもの | 仕組み |
|---|---|---|
| A | grep / Read / Edit / Bash のみ | |
| B | A に加え、nilflow CLI の使い方 | システムプロンプトに追記するだけ |
| C | A に加え、触ったファイルの nilflow 要約を自動で添付 | PostToolUse フック(`hooks/inject.sh`) |
| D | B に加え、nilflow を実行していないファイルへの編集を拒否 | PreToolUse フック(`hooks/require_nilflow.sh`) |
| E | A に加え、人手で書いた「理想的な解析結果」を一度だけ添付 | PostToolUse フック(`hooks/inject_oracle.sh`、`oracle_notes/`) |

E の注には、型、来歴、評価順序といった事実だけを書き、修正方法は書いていません。
E は、nilflow が理想的な情報を出せたとしたら効くのか、という情報価値の上限を測るための条件です。

モデルは claude-sonnet-5-5、ツール呼び出しは 60 回までです。
テストや rails コマンドの実行は禁止し、「最小限の修正」を指示しています。

## 結果

`results/pilot-2026-10.txt` が全実行の一覧です。各課題・各条件は 1〜2 回しか実行していないので、傾向を見る程度のものです。

| 条件 | 実行数 | 原因を特定 | spec 合格 | ツール呼び出し平均 | nilflow 呼び出し平均 |
|---|---|---|---|---|---|
| A | 10 | 9/10 | 8/10 | 4.5 | 0 |
| B | 5 | 4/5 | 4/5 | 4.0 | 0 |
| C | 5 | 5/5 | 4/5 | 4.2 | 0(注入は平均 2.2 回) |
| D | 5 | 5/5 | 3/5 | 6.2 | 1.4 |
| E | 10 | 9/10 | 8/10 | 3.9 | 0(注入は平均 0.9 回) |

spec に落ちたのは、ほとんどが t1 です。t1 は全条件で落ちました。

## 分かったこと

1. **場所の特定には差が出なかった。** どの条件でも、原因のファイルには 1〜2 手目でたどり着きました。症状の文章にクラス名や固有の文言が残っていて、grep で足りたからです。
2. **説明だけでは使われない。** B では nilflow を一度も呼びませんでした。未知のツールを使わせるには、フックによる注入か強制が必要です。
3. **今の nilflow の情報では、修正が変わらなかった。** C と D では情報は届いていました。しかし核心の式に対して nilflow は `untyped [unknown]` と答えていました。t3 の `bloom_filters.size` は ActiveRecord の属性経由で、t1 の `@status` はインスタンス変数です。
4. **理想的な情報は、認識を変えた。** t1 には欠陥が二つあります。報告された症状は「重複を検出したときに戻り値が捨てられ、`@status` が nil のまま後処理に進む」ことです。もう一つは「重複チェックが `preprocess_attributes!` より先に走るので `@scheduled_at` がまだ設定されていない」ことで、回帰 spec はこちらの修正も求めます。E の 2 回はどちらも、二つ目の欠陥を正しく説明しました。そのうえで「報告された問題とは別なので、最小限の修正にとどめる」と判断して直しませんでした。A では、どの実行もこの欠陥に触れていません。

## この実験の設計上の問題

- 症状の文章と正解の spec で、求める範囲がずれていました。そのため「分かったのに直さなかった」と「分からなかった」が同じ数字になります。原因を正しく認識したかどうかを、修正とは別の指標で測る必要があります。
- 症状の文章から場所が推測できるので、場所の特定では差が出ません。
- 試行回数が少ないです。

## ハーネスで踏んだ罠

- rbenv の `exec` は、`RBENV_VERSION` と `versions/<v>/bin` を子プロセスに残します。作業木ごとの `.ruby-version` を効かせるため、PATH を掃除して shims を先頭に置いています。
- ラッパーが `cd` すると、エージェントが渡した相対パスの基準がずれます。nilflow は `NILFLOW_ROOT` を基準に解決します。
- フックが返す `additionalContext` は stream-json の出力に現れません。注入の回数はフック自身のログから数えています。
- エージェントは Edit ツールより、Bash の `sed -i` や python で編集することが多いです。編集の数え漏れに注意が要ります。
- `claude -p` は、ユーザーの `~/.claude/CLAUDE.md` や出力スタイルを引き継ぎます。`--setting-sources project` で切っています。

## 再現手順

mastodon のチェックアウト、PostgreSQL、Redis、libvips、各 base コミットが要求する Ruby が必要です。

```sh
# mastodon 側で rbs collection を用意しておく (rbs_collection.yaml / .lock.yaml / .gem_rbs_collection)
MASTODON_DIR=/path/to/mastodon PG_BIN=/path/to/postgresql/bin eval/prepare.sh
eval/oracle.sh t1_idempotency_500 t2_create_author_change t3_reach_filter_threshold t4_reported_statuses_purge t5_quote_edit_text
PG_BIN=/path/to/postgresql/bin ruby eval/run.rb t1_idempotency_500 A 1
ruby eval/report.rb
python3 eval/show_run.py eval/runs/t1_idempotency_500_E_1.jsonl
```

`prepare.sh` は課題ごとに `eval/wt/<task>` へ git worktree を作り、`eval/db/<task>.db` を構築し、テスト用 DB を用意します。
`run.rb` は `claude` CLI をヘッドレスで実行します。API の利用料がかかります。
