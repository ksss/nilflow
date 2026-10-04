require "minitest/autorun"
require "tmpdir"
require "nilflow"

# example/ (Ruby 実装 Greeter と、RBS だけの Store) を解析して、来歴・呼び出し解決・nil 受信者を確かめる
class NilflowTest < Minitest::Test
  EXAMPLE = File.expand_path("../example", __dir__)
  GREETER = File.join(EXAMPLE, "lib/greeter.rb")

  def self.db
    @db ||= begin
      path = File.join(Dir.mktmpdir("nilflow"), "example.db")
      Nilflow::Exporter.new(Nilflow.analyze(EXAMPLE), path).run
      path
    end
  end

  def setup
    @q = Nilflow::Query.new(self.class.db)
  end

  def test_nil_receivers_are_the_two_unguarded_upcase_calls
    rows = @q.nil_receivers.map { [File.basename(_1["path"]), _1["line"], _1["mid"]] }
    assert_equal [["greeter.rb", 12, "upcase"], ["greeter.rb", 26, "upcase"]], rows.sort
  end

  def test_why_traces_nil_back_to_the_rbs_declaration
    out = StringIO.new
    @q.explain(GREETER, 12, 15, io: out)
    assert_match(/nil reaches: .*greeter\.rb:12:15/, out.string)
    assert_match(/SigTyOptionalNode @ store\.rbs:4/, out.string) # Store#fetch: (String) -> String?
  end

  def test_why_finds_nothing_after_narrowing
    out = StringIO.new
    @q.explain(GREETER, 18, 15, io: out) # safe_greet: `return ... unless n` の後
    assert_match(/no expression .* has a nil flowing into it/, out.string)
  end

  def test_callers_are_resolved_by_receiver_type
    rows, unresolved = @q.callers("Greeter#name_for")
    assert_equal [11, 16], rows.map { _1["line"] }.sort
    assert_equal 0, unresolved
  end

  def test_callees_resolve_to_rbs_declaration
    rows = @q.callees(GREETER, 7)
    fetch = rows.find { _1["mid"] == "fetch" }
    assert_match(/decl Store#fetch @ .*store\.rbs:4/, fetch["targets"])
  end

  def test_type_at
    v = @q.type_at(GREETER, 11, 4) # `n = name_for(id)` の代入式
    assert_equal "String?", v["types"]
    assert_equal "resolved", @q.confidence_of(v["types"])
  end
end
