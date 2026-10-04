require "typeprof"
require "sqlite3"
require "set"
require "yaml"
require_relative "nilflow/guards"
require "pathname"

# Nilflow: a prototype that exports typeprof's type-propagation graph to SQLite and asks "where does this nil come from?".
#
# Inside typeprof,
#   Vertex#types     : { Type => Set[src] }    ... the vertices that brought each type in (backward provenance)
#   Vertex#next_vtxs : Set[Vertex|Filter|Box] ... where types flow to (forward)
# are kept. Nilflow writes them to SQLite as
#   type_flow(src, dst, type)  ... edges split by type
#   calls(call_site -> target) ... call targets resolved by MethodCallBox
#
module Nilflow
  # --- Patches to typeprof ---------------------------------------------------------

  # Vertex only validates its origin and does not keep it ("just for debug"), so make it keep it.
  module VertexOrigin
    def initialize(origin)
      super
      @nilflow_origin = origin
    end
    attr_reader :nilflow_origin
  end
  TypeProf::Core::Vertex.prepend(VertexOrigin)

  # Call-resolution results are dropped as local variables in run0, so intercept them here.
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

  # --- Analysis -------------------------------------------------------------------

  # dirs: directories to analyze (one or more). collection: path to rbs_collection.yaml (nil to skip)
  def self.analyze(dirs, collection: nil)
    options = { rbs_collection: load_collection(collection), position_encoding: Encoding::UTF_8 }
    service = TypeProf::Core::Service.new(options)
    Array(dirs).each { |dir| service.add_workspace(dir, dir) }
    service
  end

  # Read the lockfile the same way as typeprof CLI's setup_rbs_collection
  def self.load_collection(path)
    return nil unless path
    lock_path = RBS::Collection::Config.to_lockfile_path(Pathname(path))
    raise "lockfile not found: #{lock_path}; run 'rbs collection install'" unless File.readable?(lock_path)
    data = YAML.load_file(lock_path)
    # `type: rubygems` refers to the sig/ bundled with an installed gem, but under Bundler a gem not in this
    # Gemfile is invisible. Warn and skip such gems (a shortcut acceptable for an experiment).
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

  # --- Export ---------------------------------------------------------------------

  class Exporter
    SCHEMA = <<~SQL
      CREATE TABLE vertices (
        id INTEGER PRIMARY KEY,
        kind TEXT NOT NULL,        -- Vertex / Source / NilFilter / IsAFilter
        origin TEXT,               -- kind of origin (class name of the AST node, etc.)
        path TEXT, line INTEGER, col INTEGER, end_line INTEGER, end_col INTEGER,
        types TEXT                 -- type as displayed by typeprof (for reference)
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
        mid_line INTEGER, mid_col INTEGER, -- position of the method name (distinguishes chained calls sharing a start position)
        recv INTEGER NOT NULL,     -- receiver vertex
        ret INTEGER NOT NULL,      -- return-value vertex
        nil_responds INTEGER NOT NULL -- 1 if NilClass (or an ancestor) has this method
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
        key TEXT,                  -- receiver expression (identity key); NULL for expressions with side effects
        guarded_by TEXT            -- source of the dominating guard; NULL if unguarded
      );
      CREATE INDEX guards_pos ON guards(path, mid_line, mid_col, mid);
      CREATE TABLE calls (
        call_site INTEGER NOT NULL,
        target_kind TEXT NOT NULL, -- def (Ruby implementation) / decl (RBS declaration)
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
      @node_of_ret = {}.compare_by_identity # Source/Vertex => AST::Node (via node.ret)
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

    # Write the results of the syntactic guard analysis (Nilflow::Guards) for every analyzed .rb file
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

    # ChangeSet#edges is { src => { dst => true } }. Vertices created by Source.new inside a Box only
    # appear here, so use the AST node owning that ChangeSet as their location.
    def note_edge_sources(changes, node)
      changes.edges.each_key { |src| @node_of_ret[src] ||= node }
    end

    def each_box(changes, &blk)
      changes.boxes.each_value do |box|
        yield box
        each_box(box.changes, &blk) # Boxes created inside a Box (symbol procs, etc.)
      end
    end

    # Walk the graph in both directions and write every vertex and edge found
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
          # A Filter does not remember its predecessor; find it from predecessors' next_vtxs (loop below)
          queue << v.next_vtx
        when TypeProf::Core::Source
          # A Source has no edges (already reached via the following Vertex#types)
        end
      end
      # Vertex -> Filter edges: assume only the types that pass the Filter flow
      seen.each do |v|
        next unless v.is_a?(TypeProf::Core::Vertex)
        v.next_vtxs.each do |f|
          case f
          when TypeProf::Core::NilFilter
            v.types.each_key { |ty| insert_flow(v, f, ty) unless f.filter([ty], @genv.nil_type).empty? }
          when TypeProf::Core::Filter
            v.types.each_key { |ty| insert_flow(v, f, ty) } # IsAFilter/BotFilter approximated: let every type through
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

    # Origin and location of a vertex [path, line, col, end_line, end_col]
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
      # When FileContext has no path (e.g. core RBS), fall back to the RBS buffer name
      raw = node.instance_variable_get(:@raw_node)
      path ||= raw.location.buffer.name.to_s if raw.respond_to?(:location) && raw.location
      # The sqlite3 gem stores ASCII-8BIT strings as BLOBs, so force UTF-8
      [utf8(path), cr.first.lineno, cr.first.column, cr.last.lineno, cr.last.column]
    rescue StandardError
      [nil] * 5
    end

    # Whether NilClass or its ancestors (Object, Kernel, BasicObject, included modules) have mid.
    # A simplified version of the ancestor lookup in MethodCallBox#resolve.
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

  # --- Queries --------------------------------------------------------------------

  class Query
    def initialize(db_path)
      @db = SQLite3::Database.new(db_path, readonly: true)
      @db.results_as_hash = true
    end

    # Calls whose receiver may be nil (NoMethodError candidates).
    # By default, calls protected by a syntactic guard (guards table) are excluded.
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

    # The smallest vertex at the position that nil flows into
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

    # Vertices reachable backward along edges that carry nil only (recursive CTE)
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

    # Coverage, counted per method call
    def stats
      q = ->(sql) { @db.get_first_value(sql) }
      total = q.("SELECT count(*) FROM call_sites")
      {
        call_sites: total,
        # some type flows into the receiver (not an empty vertex)
        recv_typed: q.("SELECT count(*) FROM call_sites cs WHERE EXISTS (SELECT 1 FROM type_flow tf WHERE tf.dst = cs.recv)"),
        # the receiver's type includes untyped
        recv_has_untyped: q.("SELECT count(*) FROM call_sites cs JOIN vertices v ON v.id = cs.recv WHERE v.types LIKE '%untyped%'"),
        # at least one call target was resolved
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

    # --- For agents -----------------------------------------------------------------

    # Innermost method containing the position
    def method_at(path, line)
      @db.get_first_value(<<~SQL, [path, line, line])
        SELECT name FROM methods WHERE path = ? AND line <= ? AND end_line >= ?
        ORDER BY (end_line - line) LIMIT 1
      SQL
    end

    # Receiver confidence: resolved (typed, no untyped) / partial (some untyped) / unknown (no type info)
    def confidence_of(types)
      return "unknown" if types.nil? || types.empty? || types == "untyped"
      types.include?("untyped") ? "partial" : "resolved"
    end

    # Call sites of Klass#mid (type-resolved calls only; unresolved same-named calls are counted separately)
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

    # Calls on FILE:LINE and their resolved targets
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

    # Smallest typed vertex at the position
    def type_at(path, line, col)
      @db.get_first_row(<<~SQL, [path, line, line, col, line, line, col])
        SELECT v.* FROM vertices v
        WHERE v.path = ? AND v.types IS NOT NULL AND v.kind = 'Vertex'
          AND (v.line < ? OR (v.line = ? AND v.col <= ?))
          AND (v.end_line > ? OR (v.end_line = ? AND v.end_col >= ?))
        ORDER BY (v.end_line - v.line), (v.end_col - v.col) LIMIT 1
      SQL
    end

    # Provenance of any type (generalization of why). type is the displayed string in vertices.types/type_flow.type
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

    # Summary of a file (or line range): one line per call with receiver type, targets, confidence and nil inflow.
    # Meant to be attached to tool results by a hook, so information grep cannot give (cross-file targets, nil inflow) comes first.
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
      # Priority: nil inflow > resolved to a def in another file > others. Beyond the limit, only a count is shown
      ranked = lines.sort_by { |r, _| [r["nil_in"] == 1 ? 0 : 1, (r["targets"].to_s.include?(" def ") && !r["targets"].to_s.include?(path)) ? 0 : 1, r["line"]] }
      shown = ranked.first(limit).sort_by { |r, _| r["line"] }.map(&:last)
      shown << "(#{lines.size - limit} more calls omitted)" if lines.size > limit
      methods = @db.execute("SELECT line, name FROM methods WHERE path = ? #{from ? 'AND end_line >= ? AND line <= ?' : ''} ORDER BY line", binds)
      header = "[nilflow] #{rel(path)}#{from ? ":#{from}-#{to}" : ''}: #{rows.size} calls, #{rows.count { _1['targets'] }} resolved; methods: #{methods.map { "#{_1['name']}@L#{_1['line']}" }.join(', ')}"
      [header, *shown]
    end

    # Print provenance as a tree
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
