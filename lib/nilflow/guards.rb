require "prism"
require "set"

module Nilflow
  # Syntactic nil-guard analysis.
  #
  # typeprof's narrowing only applies when x in `if x` is a local variable (the LocalVariableReadNode check in control.rb).
  # Guards common in Rails code (on ivars, by present?/blank?, on attr_reader calls) are decided here
  # from the Prism syntax tree alone, independently of types, and reported per call as "is the receiver guarded?".
  #
  # Only dominance is considered (not path-sensitive). The receiver "key" is the source text of an expression
  #   @ivar / local / bare_call / recv.bare_call ...
  # that looks side-effect free; equal keys are assumed to denote the same value.
  # An assignment to the same key in between cancels the guard for that key.
  class Guards
    Hit = Struct.new(:path, :line, :col, :mid, :mid_line, :mid_col, :key, :guarded_by)

    # Predicates whose truth implies "key is not nil"
    POSITIVE_PREDICATES = %i[present? is_a? kind_of? instance_of? respond_to? any? persisted?].freeze
    # Predicates whose truth means "key may be nil" (falsity implies not nil)
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

    # guarded: { key => guarded_by } (keys known not to be nil at this point)
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
        # Guards do not carry across method boundaries
        node.compact_child_nodes.each { |c| visit(c, {}) }
      else
        node.compact_child_nodes.each { |c| visit(c, guarded) }
      end
    end

    def visit_statements(stmts, guarded)
      g = guarded.dup
      stmts.each do |st|
        # An assignment to the same key cancels its guard
        if (w = written_key(st))
          g.delete(w)
        end
        visit(st, g)
        # After an early exit such as `return if x.nil?` / `raise unless x`, the non-exiting condition holds
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

    # Split a predicate into keys known non-nil when it is true, and keys known non-nil when it is false
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
          [[k2], []] # truthiness check such as `if x` / `if foo`
        else
          [[], []]
        end
      else
        k = key_of(pred)
        k ? [[k], []] : [[], []]
      end
    end

    # Key used to identify receivers. Only expressions that look side-effect free get a key
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

    # If st is a conditional whose body only exits, such as `return if cond` / `raise ... unless cond`, return [pred, :if|:unless]
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
