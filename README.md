# nilflow

typeprof を**ライブラリとして**使い、その内部の型伝播グラフを SQLite に書き出す試作です。
「この式に nil が来るのはどこからか」「この呼び出しは、受信者の型で解決するとどのメソッドに行くか」を
SQL で問い合わせられるようにします。型注釈は書きません。

想定している使い手は、Rails アプリを調査する AI エージェントです。
grep では分からない「受信者の型で解決した呼び出し先」と「値の来歴」を渡せば、
調査の手戻りが減るのではないか、という仮説を検証するために作りました。

> 状態: 実験用の試作です。gem として配布する予定はありません。

## 例

`example/` には、Ruby 実装の `Greeter` と、RBS だけがある外部ライブラリ想定の `Store` があります。

```ruby
# example/sig/store.rbs
class Store
  def fetch: (String key) -> String?
end

# example/lib/greeter.rb
class Greeter
  def initialize(store)
    @store = store
  end

  def name_for(id)
    @store.fetch(id)
  end

  def greet(id)
    n = name_for(id)
    "Hello " + n.upcase      # 12 行目
  end
  # ...
end
```

```console
$ bundle exec exe/nilflow build example -o example.db
$ bundle exec exe/nilflow why example/lib/greeter.rb:12:15 example.db
nil reaches: [113] Vertex/CallNode @ greeter.rb:12:15  : String?
  <- [41] Vertex/LocalVariableWriteNode @ greeter.rb:11:4  : String?
    <- [33] Vertex/CallNode @ greeter.rb:11:8  : String?
      <- [18] Vertex/DefNode @ greeter.rb:6:2  : String?
        ...
              <- [20] Vertex/SigTyOptionalNode @ store.rbs:4:29  : String?
```

ローカル変数、メソッド境界、RBS の宣言位置までさかのぼって、nil の出どころを示します。
`unless n` などで narrowing された後の式には「nil は届かない」と答えます。

## 仕組み

typeprof の内部表現がそのまま来歴のグラフになっています。

- `Vertex#types` は `{ Type => Set[src] }` で、型ごとに「その型を持ち込んだ頂点」を保持しています。これが後ろ向きの来歴です。
- `Vertex#next_vtxs` は型を流す先で、前向きの辺です。
- `NilFilter` / `IsAFilter` は `if x` や `is_a?` による narrowing を辺の上で表現しています。
- `MethodCallBox` は受信者の型から呼び出し先を解決し、`MethodDefBox#call` が実引数から仮引数へ、戻り値から呼び出し式への辺を張ります。

nilflow はこのグラフを歩いて、型ごとに分けた辺として SQLite に書き出します。
typeprof 本体は変更せず、`prepend` を二つ当てるだけです(`lib/nilflow.rb` の冒頭)。

1. `Vertex#initialize` で origin を保持します。本家では検証にだけ使われ、捨てられています。
2. `MethodDefBox#call` と `MethodDeclBox#resolve_overloads` で、呼び出し解決の結果を記録します。本家では `MethodCallBox#run0` のローカル変数で捨てられています。

### テーブル

| table | 内容 |
|---|---|
| `vertices` | 頂点。種別、由来の AST ノード、位置、表示用の型 |
| `type_flow(src, dst, type, is_nil)` | 型ごとに分けた辺。`is_nil = 1` の辺だけを辿れば nil の経路になる |
| `call_sites` | メソッド呼び出し。受信者と戻り値の頂点、NilClass がそのメソッドに応答できるか |
| `calls` | 呼び出しの解決先。`def` は Ruby 実装、`decl` は RBS 宣言 |
| `methods` | メソッド定義の位置 |
| `guards` | 構文的なガード解析の結果(後述) |

`why` の中身は、再帰 CTE 一本です。

```sql
WITH RECURSIVE back(id, depth) AS (
  SELECT :target, 0
  UNION
  SELECT tf.src, back.depth + 1 FROM type_flow tf JOIN back ON tf.dst = back.id
  WHERE tf.is_nil = 1 AND back.depth < 64
)
SELECT ... FROM back
```

## 使い方

```sh
bundle install
bundle exec exe/nilflow build app lib --collection rbs_collection.yaml -o graph.db
```

| コマンド | 内容 |
|---|---|
| `why FILE:LINE:COL [--type T]` | その式に nil(または型 T)が来る経路を木で表示 |
| `callers 'Klass#mid'` | 受信者の型で解決した呼び出し元。解決できなかった同名の呼び出しの数も示す |
| `callees FILE:LINE` | その行の各呼び出しの受信者型、解決先、確度 |
| `type-at FILE:LINE:COL` | その位置の式の型と確度 |
| `summary FILE[:FROM:TO]` | ファイルの呼び出しを 1 行ずつ要約(エージェントへの自動注入用) |
| `nil-receivers [--all]` | 受信者が nil になり得て、ガードされていない呼び出し |
| `stats` | 呼び出し単位のカバレッジ |

列番号は 0 始まりです。相対パスは `NILFLOW_ROOT`(既定はカレントディレクトリ)を基準に解決します。
確度は、`[resolved]` が受信者の型がすべて分かっている、`[partial]` が一部 untyped、`[unknown]` が型情報なし、です。

```sh
bundle exec rake test
```

## mastodon での計測

mastodon の `app/` と `lib/` を、型注釈なしで解析しました。gem の RBS は `rbs collection` で入れています。

| 対象 | 行数 | typeprof 解析 | 受信者に型あり | 呼び出し先が解決 |
|---|---|---|---|---|
| mastodon app/ + lib/ | 72,262 | 14 秒 | 62% | 39% |
| ruby/rbs lib/ | 23,677 | 1.6 秒 | 74% | 57% |

書き出しは、今は 1 行ずつ INSERT しているので、mastodon で 20〜30 秒かかります。

nil が来得る受信者は 806 件ありました。ランダムに 20 件を目で確認したところ、来歴が示す nil の出どころはすべて正しいものでした。
一方で、実際に問題になる nil は 0 件でした。主な原因はインスタンス変数や `present?` によるガードです。
`lib/nilflow/guards.rb` で構文的なガード解析を足しても、806 件は 699 件にしか減りませんでした。
残りの多くは、別のメソッドで設定されるインスタンス変数への暗黙の依存か、nil 以外の経路が untyped のものです。

## AI エージェントでの評価実験

mastodon の過去のバグ修正 5 件を課題にして、Claude Code をヘッドレスで動かしました。
道具なし、CLI の説明のみ、フックで自動注入、フックで使用を強制、人手で書いた理想的な解析結果を注入、の 5 条件を比べています。
結果の要点は次の通りです。詳細は [eval/README.md](eval/README.md) にあります。

- 原因のファイルには、どの条件でも 1〜2 手でたどり着きました。この課題の作り方では、場所の特定に差が出る余地がありませんでした。
- CLI の説明を渡すだけでは、nilflow は一度も使われませんでした。
- フックで注入や強制をしても、修正の正しさは変わりませんでした。バグの核心にある式が ActiveRecord の属性やインスタンス変数を経由していて、nilflow は `untyped [unknown]` と答えていたからです。
- 理想的な解析結果を注入すると、エージェントは grep では気づかなかった欠陥を正しく言い当てました。それでも「最小限の修正」という指示に従って、その欠陥は直しませんでした。

## typeprof について気づいたこと

ライブラリとして使ってみて、気づいた点です。

- **origin が残らない。** `Vertex.new(origin)` は origin を検証するだけで保持しません。来歴を位置つきで出すには、origin の保持が必要でした。
- **呼び出し解決の結果を取り出す口がない。** `MethodCallBox#run0` の中で解決した `MethodDefBox` / `MethodDeclBox` は、ローカル変数に入るだけです。コールグラフを作るために、`MethodDefBox#call` と `MethodDeclBox#resolve_overloads` に `prepend` しています。
- **Filter が前段を覚えていない。** `NilFilter` などは `next_vtx` しか持たないので、前段の頂点の `next_vtxs` から逆引きしています。
- **narrowing はローカル変数だけ。** `if x` の `x` が `LocalVariableReadNode` の場合にだけ効きます(`core/ast/control.rb`)。Rails のコードではインスタンス変数と `present?` によるガードが多く、nil の偽陽性の主な原因になっていました。
- **同じ呼び出し式に、範囲の重なる頂点が二つある。** 一方は `String`、もう一方は `String?` になることがあり、位置から型を引くときに曖昧になります。
- **`ruby/rbs` の `sig/` を読ませると落ちる。** `SigTyBaseBottomNode#typecheck`(`core/ast/sig_type.rb`)で `vtx` が nil になります。`Location[bot, bot]?` のような型引数の `bot` が関係していそうですが、最小の再現はまだ作れていません。

## 分かっている制約

- union を使い、パスを区別しない解析です。nil が union に入ると、その先全体に「来得る」と出ます。
- `IsAFilter` と `BotFilter` は、すべての型を通す近似で扱っています。
- 頂点の ID は実行ごとに振り直します。差分更新には向きません。
- RBS collection の `type: rubygems` の gem は、nilflow 自身の bundle から見えるものだけを読みます。
- typeprof 0.33.2 の内部クラスに依存しています。

## License

MIT
