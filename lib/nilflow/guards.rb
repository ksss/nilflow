require "prism"
require "set"

module Nilflow
  # 構文的な nil ガード解析。
  #
  # typeprof の narrowing は `if x` の x がローカル変数の時だけ効く (control.rb の LocalVariableReadNode 判定)。
  # Rails コードで多い「ivar のガード」「present?/blank?」「attr_reader へのガード」を、
  # 型とは独立に Prism の構文木だけで判定し、呼び出し単位で「受信者がガード済みか」を出す。
  #
  # 判定は支配関係のみ (path-sensitive ではない)。受信者の "キー" は
  #   @ivar / local / bare_call / recv.bare_call ...
  # のような副作用のなさそうな式のソース文字列で、同じキーならば同じ値とみなす。
  # 途中で同じキーへの代入があれば、そのキーのガードは解除する。
  class Guards
    Hit = Struct.new(:path, :line, :col, :mid, :mid_line, :mid_col, :key, :guarded_by)

    # 真なら「key は nil でない」と言える述語
    POSITIVE_PREDICATES = %i[present? is_a? kind_of? instance_of? respond_to? any? persisted?].freeze
    # 真なら「key は nil かもしれない」(偽なら nil でない) と言える述語
    NEGATIVE_PREDICATES = %i[nil? blank?].freeze
    EXIT_CALLS = %i[raise fail].freeze

    def self.scan_dirs(dirs)
      hits = []
      Array(dirs).each do |dir|
        Dir.glob(File.join(dir, "**", "*.rb")).sort.each do |path|
          hits.concat(new(path).scan)
        end
      end
      hits
    end

    def initialize(path)
      @path = path
      @hits = []
    end

    def scan
      result = Prism.parse_file(@path)
      visit(result.value, {})
      @hits
    end

    private

    # guarded: { key => guarded_by } (この地点で nil でないと分かっているキー)
    def visit(node, guarded)
      return unless node
      case node
      when Prism::StatementsNode
        visit_statements(node.body, guarded)
      when Prism::IfNode
        visit(node.predicate, guarded)
        pos, neg = split(node.predicate)
        visit(node.statements, merge(guarded, pos, node.predicate))
        visit(subsequent_of(node), merge(guarded, neg, node.predicate))
      when Prism::UnlessNode
        visit(node.predicate, guarded)
        pos, neg = split(node.predicate)
        visit(node.statements, merge(guarded, neg, node.predicate))
        visit(node.else_clause, merge(guarded, pos, node.predicate))
      when Prism::AndNode
        visit(node.left, guarded)
        pos, _neg = split(node.left)
        visit(node.right, merge(guarded, pos, node.left))
      when Prism::OrNode
        visit(node.left, guarded)
        _pos, neg = split(node.left)
        visit(node.right, merge(guarded, neg, node.left))
      when Prism::CallNode
        if node.receiver
          k = key_of(node.receiver)
          loc = node.location
          ml = node.message_loc || loc
          @hits << Hit.new(@path, loc.start_line, loc.start_column, node.name.to_s,
                           ml.start_line, ml.start_column, k, k && guarded[k])
        end
        node.compact_child_nodes.each { |c| visit(c, guarded) }
      when Prism::DefNode
        # メソッド境界でガードは引き継がない
        node.compact_child_nodes.each { |c| visit(c, {}) }
      else
        node.compact_child_nodes.each { |c| visit(c, guarded) }
      end
    end

    def visit_statements(stmts, guarded)
      g = guarded.dup
      stmts.each do |st|
        # 同じキーへの代入でガードを解除
        if (w = written_key(st))
          g.delete(w)
        end
        visit(st, g)
        # 早期脱出 `return if x.nil?` / `raise unless x` の後は、脱出しなかった側の条件が成り立つ
        if (exit_pred = early_exit(st))
          pred, kind = exit_pred
          pos, neg = split(pred)
          keys = kind == :if ? neg : pos
          keys.each { |k| g[k] = "early-exit: #{pred.slice.gsub(/\s+/, ' ')[0, 60]}" }
        end
      end
    end

    def merge(guarded, keys, pred)
      return guarded if keys.empty?
      g = guarded.dup
      keys.each { |k| g[k] = pred.slice.gsub(/\s+/, " ")[0, 60] }
      g
    end

    # 述語を「真なら非 nil と分かるキー」「偽なら非 nil と分かるキー」に分ける
    def split(pred)
      case pred
      when nil then [[], []]
      when Prism::ParenthesesNode
        body = pred.body
        body.is_a?(Prism::StatementsNode) && body.body.size == 1 ? split(body.body.first) : [[], []]
      when Prism::AndNode
        lp, = split(pred.left)
        rp, = split(pred.right)
        [lp + rp, []]
      when Prism::OrNode
        _, ln = split(pred.left)
        _, rn = split(pred.right)
        [[], ln + rn]
      when Prism::CallNode
        if pred.name == :! && pred.receiver
          pos, neg = split(pred.receiver)
          return [neg, pos]
        end
        k = key_of(pred.receiver)
        if k && pred.arguments.nil? && POSITIVE_PREDICATES.include?(pred.name)
          [[k], []]
        elsif k && pred.arguments.nil? && NEGATIVE_PREDICATES.include?(pred.name)
          [[], [k]]
        elsif k && pred.arguments && (pred.name == :is_a? || pred.name == :kind_of? || pred.name == :respond_to?)
          [[k], []]
        elsif k && pred.arguments&.arguments&.size == 1 && pred.arguments.arguments.first.is_a?(Prism::NilNode)
          case pred.name
          when :== then [[], [k]]
          when :!= then [[k], []]
          else [[], []]
          end
        elsif (k2 = key_of(pred))
          [[k2], []] # 真偽値としての `if x` / `if foo`
        else
          [[], []]
        end
      else
        k = key_of(pred)
        k ? [[k], []] : [[], []]
      end
    end

    # 受信者を同一視するためのキー。副作用がなさそうな式だけ対象にする
    def key_of(node)
      case node
      when Prism::InstanceVariableReadNode, Prism::LocalVariableReadNode,
           Prism::ClassVariableReadNode, Prism::GlobalVariableReadNode
        node.slice
      when Prism::SelfNode
        "self"
      when Prism::CallNode
        return nil if node.arguments || node.block || node.name.to_s.end_with?("=", "!")
        return nil if node.safe_navigation?
        if node.receiver.nil?
          node.name.to_s
        else
          r = key_of(node.receiver)
          r && "#{r}.#{node.name}"
        end
      when Prism::ParenthesesNode
        body = node.body
        body.is_a?(Prism::StatementsNode) && body.body.size == 1 ? key_of(body.body.first) : nil
      end
    end

    def written_key(st)
      case st
      when Prism::InstanceVariableWriteNode, Prism::LocalVariableWriteNode,
           Prism::InstanceVariableOperatorWriteNode, Prism::LocalVariableOperatorWriteNode,
           Prism::InstanceVariableOrWriteNode, Prism::LocalVariableOrWriteNode
        st.name.to_s
      end
    end

    # `return if cond` / `raise ... unless cond` のような、本体が脱出だけの条件文なら [pred, :if|:unless]
    def early_exit(st)
      case st
      when Prism::IfNode
        return nil if subsequent_of(st)
        [st.predicate, :if] if exits?(st.statements)
      when Prism::UnlessNode
        return nil if st.else_clause
        [st.predicate, :unless] if exits?(st.statements)
      end
    end

    def exits?(stmts)
      return false unless stmts.is_a?(Prism::StatementsNode) && stmts.body.size == 1
      s = stmts.body.first
      case s
      when Prism::ReturnNode, Prism::NextNode, Prism::BreakNode then true
      when Prism::CallNode then s.receiver.nil? && EXIT_CALLS.include?(s.name)
      else false
      end
    end

    def subsequent_of(node)
      node.respond_to?(:subsequent) ? node.subsequent : node.consequent
    end
  end
end
