# nilflow

A prototype that uses typeprof **as a library** and exports its internal type-propagation graph to SQLite.
It lets you ask questions such as "where can the nil reaching this expression come from?" and
"which method does this call resolve to, given the receiver's type?" in SQL. No type annotations are required.

The intended consumer is an AI agent investigating a Rails application.
The hypothesis being tested: if an agent receives information that grep cannot give it, namely call targets
resolved by receiver type and the provenance of values, it will need fewer investigation round-trips and make fewer wrong edits.

> Status: experimental prototype. There are no plans to distribute it as a gem.

## Example

`example/` contains `Greeter`, implemented in Ruby, and `Store`, which stands in for an external library that only ships RBS.

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
    "Hello " + n.upcase      # line 12
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

The trace follows the nil back through a local variable and a method boundary, all the way to the RBS declaration.
For an expression after a guard such as `unless n`, it answers that no nil can reach it.

## How it works

typeprof's internal representation already is a provenance graph.

- `Vertex#types` is `{ Type => Set[src] }`. For each type, it records the vertices that brought that type in. This is backward provenance.
- `Vertex#next_vtxs` holds the vertices a type flows to. These are the forward edges.
- `NilFilter` and `IsAFilter` represent narrowing by `if x` or `is_a?` as nodes on the edges.
- `MethodCallBox` resolves the call target from the receiver's type. `MethodDefBox#call` adds edges from actual arguments to formal parameters and from the return value to the call expression.

nilflow walks this graph and writes it to SQLite as edges split by type.
It does not modify typeprof itself; it only applies two `prepend`s (top of `lib/nilflow.rb`).

1. Keep the origin in `Vertex#initialize`. Upstream only validates the origin and then drops it.
2. Record call-resolution results in `MethodDefBox#call` and `MethodDeclBox#resolve_overloads`. Upstream keeps them only in a local variable inside `MethodCallBox#run0`.

### Tables

| table | contents |
|---|---|
| `vertices` | Vertices: kind, originating AST node, location, displayed type |
| `type_flow(src, dst, type, is_nil)` | Edges split by type. Following only `is_nil = 1` edges gives the nil paths |
| `call_sites` | Method calls: receiver and return-value vertices, whether NilClass responds to the method |
| `calls` | Resolved call targets: `def` for a Ruby implementation, `decl` for an RBS declaration |
| `methods` | Locations of method definitions |
| `guards` | Results of the syntactic guard analysis (see below) |

`why` is a single recursive CTE:

```sql
WITH RECURSIVE back(id, depth) AS (
  SELECT :target, 0
  UNION
  SELECT tf.src, back.depth + 1 FROM type_flow tf JOIN back ON tf.dst = back.id
  WHERE tf.is_nil = 1 AND back.depth < 64
)
SELECT ... FROM back
```

## Usage

```sh
bundle install
bundle exec exe/nilflow build app lib --collection rbs_collection.yaml -o graph.db
```

| command | description |
|---|---|
| `why FILE:LINE:COL [--type T]` | Show, as a tree, the paths by which nil (or type T) reaches the expression |
| `callers 'Klass#mid'` | Call sites resolved to the method by receiver type, plus the number of same-named calls that could not be resolved |
| `callees FILE:LINE` | For each call on the line: receiver type, resolved targets, confidence |
| `type-at FILE:LINE:COL` | Type and confidence of the expression at that position |
| `summary FILE[:FROM:TO]` | One line per call in the file (used for automatic injection into an agent's context) |
| `nil-receivers [--all]` | Calls whose receiver may be nil and is not guarded |
| `stats` | Coverage, counted per call |

Columns are 0-based. Relative paths are resolved against `NILFLOW_ROOT` (default: the current directory).
Confidence is `[resolved]` when all receiver types are known, `[partial]` when some paths are untyped, and `[unknown]` when there is no type information.

```sh
bundle exec rake test
```

## Measurements on mastodon

We analyzed mastodon's `app/` and `lib/` without any type annotations. Gem signatures come from `rbs collection`.

| target | lines | typeprof analysis | receiver typed | call target resolved |
|---|---|---|---|---|
| mastodon app/ + lib/ | 72,262 | 14 s | 62% | 39% |
| ruby/rbs lib/ | 23,677 | 1.6 s | 74% | 57% |

Exporting currently inserts one row at a time and takes 20–30 s on mastodon.

There were 806 calls whose receiver may be nil. In a random sample of 20, the nil origin reported by the provenance trace was correct every time.
However, none of the 20 was a real problem. Most were guarded by instance-variable checks or `present?`.
Adding a syntactic guard analysis (`lib/nilflow/guards.rb`) only reduced the 806 to 699.
Most of the remainder are either implicit dependencies on instance variables set by another method, or receivers whose non-nil paths are untyped.

## Evaluation with an AI agent

We ran Claude Code headless on five past bug fixes from mastodon.
Five conditions were compared: no tool, CLI documentation only, automatic injection via a hook, mandatory use enforced by a hook, and injection of hand-written "ideal" analysis results.
The key findings are below; see [eval/README.md](eval/README.md) for details.

- Under every condition, the agent reached the faulty file within one or two steps. With these tasks, there was no room for a difference in localization.
- With only the CLI documentation, nilflow was never used.
- Injecting or enforcing nilflow did not change the correctness of the fixes. The key expressions went through ActiveRecord attributes or instance variables, and nilflow answered `untyped [unknown]` for them.
- With ideal analysis results injected, the agent correctly identified a defect it had not noticed with grep alone. It still did not fix that defect, following the instruction to keep the fix minimal.

## Notes on typeprof

Things noticed while using typeprof as a library:

- **The origin is not retained.** `Vertex.new(origin)` only validates the origin. Retaining it was necessary to report provenance with locations.
- **There is no way to get call-resolution results.** The `MethodDefBox` / `MethodDeclBox` resolved inside `MethodCallBox#run0` only live in a local variable. To build the call graph, nilflow prepends to `MethodDefBox#call` and `MethodDeclBox#resolve_overloads`.
- **Filters do not remember their predecessor.** `NilFilter` and friends only hold `next_vtx`, so nilflow finds the predecessor by scanning the `next_vtxs` of vertices.
- **Narrowing only applies to local variables.** It takes effect only when `x` in `if x` is a `LocalVariableReadNode` (`core/ast/control.rb`). Rails code guards heavily with instance variables and `present?`, which was the main source of nil false positives.
- **A call expression can have two vertices with overlapping ranges.** One may be `String` and the other `String?`, which makes looking up a type by position ambiguous.
- **Loading `ruby/rbs`'s `sig/` crashes.** `vtx` is nil in `SigTyBaseBottomNode#typecheck` (`core/ast/sig_type.rb`). A `bot` type argument, as in `Location[bot, bot]?`, looks related, but there is no minimal reproduction yet.

## Known limitations

- The analysis is union-based and path-insensitive. Once nil enters a union, everything downstream reports that nil "may" arrive.
- `IsAFilter` and `BotFilter` are approximated as letting every type through.
- Vertex IDs are reassigned on every run, so the database is not suited to incremental updates.
- For RBS collection gems with `type: rubygems`, only gems visible from nilflow's own bundle are loaded.
- nilflow depends on internal classes of typeprof 0.33.2.

## License

MIT
