require "typeprof"
require "sqlite3"
require "set"
require "yaml"
require_relative "nilflow/guards"
require "pathname"

# Nilflow: typeprof の型伝播グラフを SQLite に書き出し、「nil はどこから来たか」を問う試作。
#
# typeprof の内部では
#   Vertex#types   : { Type => Set[src] }   … この型を持ち込んだ元 (後ろ向きの来歴)
#   Vertex#next_vtxs : Set[Vertex|Filter|Box] … 型を流す先 (前向き)
# が保持されている。Nilflow はこれを
#   type_flow(src, dst, type)  … 型ごとに分かれた辺
#   calls(call_site → target)  … MethodCallBox が解決した呼び出し先
# として SQLite に落とす。
module Nilflow
  # --- typeprof へのパッチ ---------------------------------------------------

  # Vertex は origin を検証するだけで保持しない ("just for debug") ので、保持させる。
  module VertexOrigin
    def initialize(origin)
      super
      @nilflow_origin = origin
    end
    attr_reader :nilflow_origin
  end
  TypeProf::Core::Vertex.prepend(VertexOrigin)

  # 呼び出し解決の結果は run0 のローカル変数で捨てられるので、ここで横取りする。
  CALLS = {} # [call_node, target_box] => true

  module RecordDefCall
    def call(changes, genv, a_args, ret)
      CALLS[[changes.node, self]] = true
      super
    end
  end
  TypeProf::Core::MethodDefBox.prepend(RecordDefCall)

  module RecordDeclCall
    def resolve_overloads(changes, genv, node, param_map, a_args, ret, &blk)
      CALLS[[node, self]] = true
      super
    end
  end
  TypeProf::Core::MethodDeclBox.prepend(RecordDeclCall)

  # --- 解析 ------------------------------------------------------------------

  # dirs: 解析対象ディレクトリ (複数可)。collection: rbs_collection.yaml のパス (nil なら読まない)
  def self.analyze(dirs, collection: nil)
    options = { rbs_collection: load_collection(collection), position_encoding: Encoding::UTF_8 }
    service = TypeProf::Core::Service.new(options)
    Array(dirs).each { |dir| service.add_workspace(dir, dir) }
    service
  end

  # typeprof CLI の setup_rbs_collection と同じ手順で lockfile を読む
  def self.load_collection(path)
    return nil unless path
    lock_path = RBS::Collection::Config.to_lockfile_path(Pathname(path))
    raise "lockfile not found: #{lock_path}; run 'rbs collection install'" unless File.readable?(lock_path)
    data = YAML.load_file(lock_path)
    # type: rubygems は「インストール済み gem 同梱の sig/」を指すが、Bundler 配下では
    # この Gemfile にない gem は見えない。見つからないものは警告して外す (実験用の割り切り)。
    data["gems"] = data["gems"].reject do |g|
      next false unless g.dig("source", "type") == "rubygems"
      begin
        Gem::Specification.find_by_name(g["name"])
        false
      rescue Gem::LoadError
        warn "nilflow: skipping RBS of gem #{g['name']} (not visible from this bundle)"
        true
      end
    end
    RBS::Collection::Config::Lockfile.from_lockfile(lockfile_path: lock_path, data: data)
  end

  # --- エクスポート ----------------------------------------------------------

  class Exporter
    SCHEMA = <<~SQL
      CREATE TABLE vertices (
        id INTEGER PRIMARY KEY,
        kind TEXT NOT NULL,        -- Vertex / Source / NilFilter / IsAFilter
        origin TEXT,               -- 由来の種別 (AST ノードのクラス名など)
        path TEXT, line INTEGER, col INTEGER, end_line INTEGER, end_col INTEGER,
        types TEXT                 -- typeprof が表示する型 (参考用)
      );
      CREATE TABLE type_flow (
        src INTEGER NOT NULL, dst INTEGER NOT NULL,
        type TEXT NOT NULL, is_nil INTEGER NOT NULL,
        PRIMARY KEY (src, dst, type)
      );
      CREATE INDEX type_flow_dst ON type_flow(dst, is_nil);
      CREATE INDEX type_flow_src ON type_flow(src, is_nil);
      CREATE TABLE call_sites (
        id INTEGER PRIMARY KEY,
        path TEXT, line INTEGER, col INTEGER, end_line INTEGER, end_col INTEGER,
        mid TEXT NOT NULL,
        mid_line INTEGER, mid_col INTEGER, -- メソッド名の位置 (同じ開始位置に並ぶ連鎖呼び出しを区別する)
        recv INTEGER NOT NULL,     -- 受信者 Vertex
        ret INTEGER NOT NULL,      -- 戻り値 Vertex
        nil_responds INTEGER NOT NULL -- NilClass (と祖先) がこの mid を持つなら 1
      );
      CREATE TABLE methods (
        path TEXT, line INTEGER, end_line INTEGER,
        name TEXT NOT NULL          -- Klass#mid / Klass.mid
      );
      CREATE INDEX methods_pos ON methods(path, line);
      CREATE INDEX methods_name ON methods(name);
      CREATE TABLE guards (
        path TEXT, line INTEGER, col INTEGER, mid TEXT,
        mid_line INTEGER, mid_col INTEGER,
        key TEXT,                  -- 受信者の式 (同一視キー)。nil なら副作用のある式
        guarded_by TEXT            -- 支配するガード条件のソース。nil なら未ガード
      );
      CREATE INDEX guards_pos ON guards(path, mid_line, mid_col, mid);
      CREATE TABLE calls (
        call_site INTEGER NOT NULL,
        target_kind TEXT NOT NULL, -- def (Ruby 実装) / decl (RBS 宣言)
        target TEXT NOT NULL,      -- Klass#mid
        path TEXT, line INTEGER
      );
    SQL

    def initialize(service, db_path)
      @service = service
      @genv = service.genv
      File.delete(db_path) if File.exist?(db_path)
      @db = SQLite3::Database.new(db_path)
      @ids = {}.compare_by_identity
      @node_of_ret = {}.compare_by_identity # Source/Vertex => AST::Node (node.ret 経由)
      @call_boxes = []
    end

    def run
      @db.execute_batch(SCHEMA)
      roots = @service.instance_variable_get(:@rb_text_nodes).values +
              @service.instance_variable_get(:@rbs_text_nodes).values.flatten
      roots.each { |n| n.traverse { |ev, node| visit_node(node) if ev == :enter } }

      @db.transaction do
        seeds = @node_of_ret.keys + @call_boxes.flat_map { |b| [b.recv, b.ret] }
        walk(seeds)
        export_call_sites
        export_calls
        export_guards
      end
      @db
    end

    # 構文的ガード解析 (Nilflow::Guards) の結果を書く。解析対象は解析済み .rb ファイル全部
    def export_guards
      paths = @service.instance_variable_get(:@rb_text_nodes).keys
      stmt = @db.prepare("INSERT INTO guards VALUES (?,?,?,?,?,?,?,?)")
      paths.each do |path|
        Guards.new(path).scan.each do |h|
          stmt.execute(utf8(h.path), h.line, h.col, h.mid, h.mid_line, h.mid_col, h.key, h.guarded_by)
        end
      end
      stmt.close
    end

    private

    def visit_node(node)
      if node.is_a?(TypeProf::Core::AST::DefNode)
        cpath = (node.lenv.cref.cpath.join("::") rescue "?")
        path, line, _, end_line, = loc_of(node)
        @db.execute("INSERT INTO methods VALUES (?,?,?,?)",
                    [path, line, end_line, "#{cpath}#{node.singleton ? '.' : '#'}#{node.mid}"])
      end
      @node_of_ret[node.ret] = node if node.ret
      note_edge_sources(node.changes, node)
      each_box(node.changes) do |box|
        @node_of_ret[box.ret] ||= node if box.respond_to?(:ret) && box.ret
        note_edge_sources(box.changes, node)
        @call_boxes << box if box.is_a?(TypeProf::Core::MethodCallBox)
      end
    end

    # ChangeSet#edges は { src => { dst => true } }。Box 内で Source.new された頂点は
    # ここにしか現れないので、その ChangeSet を持つ AST ノードを位置として採用する。
    def note_edge_sources(changes, node)
      changes.edges.each_key { |src| @node_of_ret[src] ||= node }
    end

    def each_box(changes, &blk)
      changes.boxes.each_value do |box|
        yield box
        each_box(box.changes, &blk) # Box の中で作られた Box (symbol proc など)
      end
    end

    # グラフを前後両方向に辿り、見つけた頂点と辺をすべて書き出す
    def walk(seeds)
      queue = seeds.compact
      seen = Set.new.compare_by_identity
      until queue.empty?
        v = queue.shift
        next if seen.include?(v)
        seen << v
        case v
        when TypeProf::Core::Vertex
          v.types.each do |ty, srcs|
            srcs.each do |src|
              insert_flow(src, v, ty)
              queue << src
            end
          end
          v.next_vtxs.each { |n| queue << n unless n.is_a?(TypeProf::Core::Box) }
        when TypeProf::Core::Filter
          # Filter は前段を覚えていないので、前段の next_vtxs から逆引きする (下のループ)
          queue << v.next_vtx
        when TypeProf::Core::Source
          # Source は辺を持たない (後続の Vertex#types から到達済み)
        end
      end
      # Vertex → Filter の辺: Filter を通過できる型だけを流したとみなす
      seen.each do |v|
        next unless v.is_a?(TypeProf::Core::Vertex)
        v.next_vtxs.each do |f|
          case f
          when TypeProf::Core::NilFilter
            v.types.each_key { |ty| insert_flow(v, f, ty) unless f.filter([ty], @genv.nil_type).empty? }
          when TypeProf::Core::Filter
            v.types.each_key { |ty| insert_flow(v, f, ty) } # IsAFilter/BotFilter は近似: 全型を通す
          end
        end
      end
    end

    def insert_flow(src, dst, ty)
      @db.execute("INSERT OR IGNORE INTO type_flow VALUES (?,?,?,?)",
                  [id_of(src), id_of(dst), ty.show, ty == @genv.nil_type ? 1 : 0])
    end

    def id_of(v)
      @ids[v] ||= begin
        id = @ids.size + 1
        kind = v.class.name.split("::").last
        origin, loc = describe(v)
        types = v.respond_to?(:show) ? v.show : nil
        @db.execute("INSERT INTO vertices VALUES (?,?,?,?,?,?,?,?,?)",
                    [id, kind, origin, *loc, types])
        id
      end
    end

    # 頂点の由来と位置 [path, line, col, end_line, end_col]
    def describe(v)
      origin =
        case v
        when TypeProf::Core::Vertex then v.nilflow_origin
        when TypeProf::Core::NilFilter, TypeProf::Core::IsAFilter then v.instance_variable_get(:@node)
        when TypeProf::Core::Source then @node_of_ret[v]
        end
      origin ||= @node_of_ret[v]
      case origin
      when TypeProf::Core::AST::Node
        [origin.class.name.split("::").last, loc_of(origin)]
      when RBS::AST::Declarations::Base
        l = origin.location
        ["RBS:" + origin.class.name.split("::").last,
         [utf8(l&.buffer&.name.to_s), l&.start_line, l&.start_column, l&.end_line, l&.end_column]]
      when nil
        ["?", [nil] * 5]
      else
        [origin.class.name.split("::").last, [nil] * 5]
      end
    end

    def loc_of(node)
      cr = node.code_range
      path = node.lenv.file_context.path
      # core RBS など FileContext に path がない場合は RBS の buffer 名で代用する
      raw = node.instance_variable_get(:@raw_node)
      path ||= raw.location.buffer.name.to_s if raw.respond_to?(:location) && raw.location
      # ASCII-8BIT の文字列は sqlite3 gem が BLOB として保存してしまうので UTF-8 に揃える
      [utf8(path), cr.first.lineno, cr.first.column, cr.last.lineno, cr.last.column]
    rescue StandardError
      [nil] * 5
    end

    # NilClass とその祖先 (Object, Kernel, BasicObject, include されたモジュール) が mid を持つか。
    # MethodCallBox#resolve の祖先探索を簡略化したもの。
    def nil_responds?(mid)
      @nil_responds ||= {}
      return @nil_responds[mid] if @nil_responds.key?(mid)
      seen = Set.new.compare_by_identity
      queue = [@genv.nil_type.mod]
      found = false
      until queue.empty? || found
        mod = queue.shift
        next if mod.nil? || seen.include?(mod)
        seen << mod
        me = mod.get_method(false, mid)
        found = !me.decls.empty? || !me.defs.empty? || !me.aliases.empty? || !!me.builtin
        queue.concat(mod.included_modules.values, mod.prepended_modules.values)
        queue << mod.superclass
      end
      @nil_responds[mid] = found
    end

    def utf8(s)
      s&.to_s&.dup&.force_encoding(Encoding::UTF_8)
    end

    def export_call_sites
      @call_boxes.each do |box|
        mcr = box.node.respond_to?(:mid_code_range) ? box.node.mid_code_range : nil
        @db.execute("INSERT INTO call_sites VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                    [box.object_id, *loc_of(box.node), box.mid.to_s, mcr&.first&.lineno, mcr&.first&.column,
                     id_of(box.recv), id_of(box.ret), nil_responds?(box.mid) ? 1 : 0])
      end
    end

    def export_calls
      box_by_node = Hash.new { |h, k| h[k] = [] }
      @call_boxes.each { |b| box_by_node[b.node] << b }
      CALLS.each_key do |node, target|
        kind = target.is_a?(TypeProf::Core::MethodDefBox) ? "def" : "decl"
        name = "#{target.cpath.join('::')}#{target.singleton ? '.' : '#'}#{target.mid}"
        path, line = loc_of(target.node)
        box_by_node[node].select { |b| b.mid == target.mid }.each do |b|
          @db.execute("INSERT INTO calls VALUES (?,?,?,?,?)", [b.object_id, kind, name, path, line])
        end
      end
    end
  end

  # --- 問い合わせ ------------------------------------------------------------

  class Query
    def initialize(db_path)
      @db = SQLite3::Database.new(db_path, readonly: true)
      @db.results_as_hash = true
    end

    # 受信者が nil になり得る呼び出し (NoMethodError 候補)。
    # 既定では構文的ガード (guards 表) で守られているものを除く。
    def nil_receivers(include_guarded: false)
      cond = include_guarded ? "" : "AND g.guarded_by IS NULL"
      @db.execute(<<~SQL)
        SELECT DISTINCT cs.path, cs.line, cs.col, cs.mid, cs.recv, v.types, g.key, g.guarded_by
        FROM call_sites cs
        JOIN type_flow tf ON tf.dst = cs.recv AND tf.is_nil = 1
        JOIN vertices v ON v.id = cs.recv
        LEFT JOIN guards g ON g.path = cs.path AND g.mid_line = cs.mid_line AND g.mid_col = cs.mid_col AND g.mid = cs.mid
        WHERE cs.nil_responds = 0 #{cond}
        ORDER BY cs.path, cs.line, cs.col
      SQL
    end

    # 位置に重なる頂点のうち、nil が流れ込んでいる最小のもの
    def vertex_at(path, line, col)
      @db.get_first_row(<<~SQL, [path, line, line, col, line, line, col])
        SELECT v.* FROM vertices v
        WHERE v.path = ?
          AND (v.line < ? OR (v.line = ? AND v.col <= ?))
          AND (v.end_line > ? OR (v.end_line = ? AND v.end_col >= ?))
          AND EXISTS (SELECT 1 FROM type_flow tf WHERE tf.dst = v.id AND tf.is_nil = 1)
        ORDER BY (v.end_line - v.line), (v.end_col - v.col)
        LIMIT 1
      SQL
    end

    # nil だけを運ぶ辺を逆向きに辿った到達集合 (再帰 CTE)
    def nil_origin_edges(vertex_id, max_depth: 64)
      @db.execute(<<~SQL, [vertex_id, max_depth])
        WITH RECURSIVE back(id, depth) AS (
          SELECT ?, 0
          UNION
          SELECT tf.src, back.depth + 1
          FROM type_flow tf JOIN back ON tf.dst = back.id
          WHERE tf.is_nil = 1 AND back.depth < ?
        )
        SELECT DISTINCT tf.src, tf.dst FROM type_flow tf
        JOIN back ON tf.dst = back.id
        WHERE tf.is_nil = 1
      SQL
    end

    # カバレッジ指標。呼び出し (method call) 単位で数える
    def stats
      q = ->(sql) { @db.get_first_value(sql) }
      total = q.("SELECT count(*) FROM call_sites")
      {
        call_sites: total,
        # 受信者に何らかの型が流れ込んでいる (空頂点ではない)
        recv_typed: q.("SELECT count(*) FROM call_sites cs WHERE EXISTS (SELECT 1 FROM type_flow tf WHERE tf.dst = cs.recv)"),
        # 受信者の型に untyped が混ざる
        recv_has_untyped: q.("SELECT count(*) FROM call_sites cs JOIN vertices v ON v.id = cs.recv WHERE v.types LIKE '%untyped%'"),
        # 呼び出し先が 1 つ以上解決した
        resolved: q.("SELECT count(DISTINCT call_site) FROM calls"),
        resolved_to_def: q.("SELECT count(DISTINCT call_site) FROM calls WHERE target_kind = 'def'"),
        resolved_to_decl: q.("SELECT count(DISTINCT call_site) FROM calls WHERE target_kind = 'decl'"),
        nil_receivers_all: nil_receivers(include_guarded: true).size,
        nil_receivers_unguarded: nil_receivers.size,
        vertices: q.("SELECT count(*) FROM vertices"),
        type_flow: q.("SELECT count(*) FROM type_flow"),
        nil_flow: q.("SELECT count(*) FROM type_flow WHERE is_nil = 1"),
      }
    end

    def vertex(id)
      @db.get_first_row("SELECT * FROM vertices WHERE id = ?", [id])
    end

    def calls_at(path, line)
      @db.execute(<<~SQL, [path, line])
        SELECT cs.col, cs.mid, c.target_kind, c.target, c.path AS tpath, c.line AS tline
        FROM call_sites cs JOIN calls c ON c.call_site = cs.id
        WHERE cs.path = ? AND cs.line = ?
      SQL
    end

    # --- エージェント向け --------------------------------------------------

    # 位置を含む最も内側のメソッド名
    def method_at(path, line)
      @db.get_first_value(<<~SQL, [path, line, line])
        SELECT name FROM methods WHERE path = ? AND line <= ? AND end_line >= ?
        ORDER BY (end_line - line) LIMIT 1
      SQL
    end

    # 受信者の確度: resolved (型あり・untyped なし) / partial (untyped 混在) / unknown (型情報なし)
    def confidence_of(types)
      return "unknown" if types.nil? || types.empty? || types == "untyped"
      types.include?("untyped") ? "partial" : "resolved"
    end

    # Klass#mid を呼んでいる箇所 (型解決済みの呼び出しのみ。未解決の同名呼び出しは別に数える)
    def callers(target)
      rows = @db.execute(<<~SQL, [target])
        SELECT DISTINCT cs.path, cs.line, cs.col, cs.mid, v.types, c.path AS def_path, c.line AS def_line
        FROM calls c JOIN call_sites cs ON cs.id = c.call_site JOIN vertices v ON v.id = cs.recv
        WHERE c.target = ? ORDER BY cs.path, cs.line
      SQL
      mid = target.split(/[#.]/).last
      unresolved = @db.get_first_value(<<~SQL, [mid])
        SELECT count(*) FROM call_sites cs WHERE cs.mid = ?
          AND NOT EXISTS (SELECT 1 FROM calls c WHERE c.call_site = cs.id)
      SQL
      [rows, unresolved]
    end

    # FILE:LINE にある呼び出しと、その解決先
    def callees(path, line)
      @db.execute(<<~SQL, [path, line])
        SELECT cs.id, cs.col, cs.mid, v.types,
               group_concat(c.target_kind || ' ' || c.target || ' @ ' || coalesce(c.path, '-') || ':' || coalesce(c.line, ''), char(10)) AS targets
        FROM call_sites cs JOIN vertices v ON v.id = cs.recv
        LEFT JOIN calls c ON c.call_site = cs.id
        WHERE cs.path = ? AND cs.line = ?
        GROUP BY cs.id ORDER BY cs.col
      SQL
    end

    # 位置に重なる最小の頂点 (型が付いているもの)
    def type_at(path, line, col)
      @db.get_first_row(<<~SQL, [path, line, line, col, line, line, col])
        SELECT v.* FROM vertices v
        WHERE v.path = ? AND v.types IS NOT NULL AND v.kind = 'Vertex'
          AND (v.line < ? OR (v.line = ? AND v.col <= ?))
          AND (v.end_line > ? OR (v.end_line = ? AND v.end_col >= ?))
        ORDER BY (v.end_line - v.line), (v.end_col - v.col) LIMIT 1
      SQL
    end

    # 任意の型の来歴 (why の一般化)。type は vertices.types/type_flow.type の表示文字列
    def origin_edges(vertex_id, type, max_depth: 64)
      @db.execute(<<~SQL, [vertex_id, type, max_depth, type])
        WITH RECURSIVE back(id, depth) AS (
          SELECT ?, 0
          UNION
          SELECT tf.src, back.depth + 1
          FROM type_flow tf JOIN back ON tf.dst = back.id
          WHERE tf.type = ? AND back.depth < ?
        )
        SELECT DISTINCT tf.src, tf.dst FROM type_flow tf JOIN back ON tf.dst = back.id WHERE tf.type = ?
      SQL
    end

    def rel(path) = path&.sub(%r{\A#{Regexp.escape(@root || '')}/?}, "")
    attr_accessor :root

    # ファイル (行範囲) の要約: 呼び出しごとに受信者型・解決先・確度・nil 流入を 1 行で。
    # フックで tool 結果に添えるために、grep では分からない情報 (他ファイルへの解決先、nil 流入) を優先して並べる。
    def summary(path, from = nil, to = nil, limit: 40)
      cond = from ? "AND cs.line BETWEEN ? AND ?" : ""
      binds = from ? [path, from, to] : [path]
      rows = @db.execute(<<~SQL, binds)
        SELECT cs.id, cs.line, cs.mid, v.types,
               EXISTS(SELECT 1 FROM type_flow tf WHERE tf.dst = cs.recv AND tf.is_nil = 1) AS nil_in,
               cs.nil_responds,
               (SELECT guarded_by FROM guards g WHERE g.path = cs.path AND g.mid_line = cs.mid_line AND g.mid_col = cs.mid_col AND g.mid = cs.mid LIMIT 1) AS guarded,
               (SELECT group_concat(c.target_kind || ' ' || c.target || ' @ ' || coalesce(c.path, '-') || ':' || coalesce(c.line, ''), ' | ')
                  FROM calls c WHERE c.call_site = cs.id) AS targets
        FROM call_sites cs JOIN vertices v ON v.id = cs.recv
        WHERE cs.path = ? #{cond}
        ORDER BY cs.line, cs.col
      SQL
      root = @root || ""
      lines = rows.map do |r|
        conf = confidence_of(r["types"])
        tgt = r["targets"]
        tgt = tgt ? tgt.gsub(root + "/", "").gsub(%r{\S*/gems/rbs-[^/]*/}, "rbs:") : "unresolved"
        flag = (r["nil_in"] == 1 && r["nil_responds"] == 0 && r["guarded"].nil?) ? "  !! receiver may be nil (unguarded)" : ""
        ty = (r["types"] || "untyped")
        ty = ty[0, 70] + "…" if ty.size > 70
        [r, "L#{r['line']} .#{r['mid']} recv=#{ty} [#{conf}] -> #{tgt}#{flag}"]
      end
      # 優先度: nil 流入 > 他ファイルの def に解決 > その他。上限を超えたら残りは件数だけ
      ranked = lines.sort_by { |r, _| [r["nil_in"] == 1 ? 0 : 1, (r["targets"].to_s.include?(" def ") && !r["targets"].to_s.include?(path)) ? 0 : 1, r["line"]] }
      shown = ranked.first(limit).sort_by { |r, _| r["line"] }.map(&:last)
      shown << "(#{lines.size - limit} more calls omitted)" if lines.size > limit
      methods = @db.execute("SELECT line, name FROM methods WHERE path = ? #{from ? 'AND end_line >= ? AND line <= ?' : ''} ORDER BY line", binds)
      header = "[nilflow] #{rel(path)}#{from ? ":#{from}-#{to}" : ''}: #{rows.size} calls, #{rows.count { _1['targets'] }} resolved; methods: #{methods.map { "#{_1['name']}@L#{_1['line']}" }.join(', ')}"
      [header, *shown]
    end

    # 来歴を木として表示する
    def explain(path, line, col, io: $stdout)
      v = vertex_at(path, line, col)
      if v.nil?
        io.puts "no expression at #{path.sub(%r{\A#{Regexp.escape(@root.to_s)}/?}, '')}:#{line}:#{col} has a nil flowing into it (nil cannot reach here, or the position is not on a typed expression)"
        return
      end
      preds = Hash.new { |h, k| h[k] = [] }
      nil_origin_edges(v["id"]).each { |e| preds[e["dst"]] << e["src"] }
      io.puts "nil reaches: #{fmt(v)}"
      print_tree(v["id"], preds, Set.new, 1, io)
    end

    private

    def print_tree(id, preds, seen, depth, io)
      preds[id].sort.each do |src|
        sv = vertex(src)
        mark = seen.include?(src) ? " (seen)" : ""
        io.puts "#{'  ' * depth}<- #{fmt(sv)}#{mark}"
        next if seen.include?(src)
        seen << src
        print_tree(src, preds, seen, depth + 1, io)
      end
    end

    def fmt(v)
      loc = v["path"] ? "#{File.basename(v['path'])}:#{v['line']}:#{v['col']}" : "-"
      "[#{v['id']}] #{v['kind']}/#{v['origin']} @ #{loc}  : #{v['types']}"
    end
  end
end
