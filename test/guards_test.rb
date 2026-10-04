require "minitest/autorun"
require "tempfile"
require "nilflow/guards"

# Syntactic guard analysis: "is nil excluded from this call's receiver by a dominating guard?"
class GuardsTest < Minitest::Test
  # [method body, expected { "method name" => guarded? }]
  CASES = {
    "return if @x.nil?; @x.foo"                      => { "foo" => true },
    "return unless @x; @x.foo"                       => { "foo" => true },
    "raise 'e' if @x.blank?; @x.foo"                 => { "foo" => true },
    "@x.foo if @x.present?"                          => { "foo" => true },
    "@x.foo unless @x.nil?"                          => { "foo" => true },
    "@x && @x.foo"                                   => { "foo" => true },
    "@x.nil? || @x.foo"                              => { "foo" => true },
    "if @x.present? then @x.foo else @x.bar end"     => { "foo" => true, "bar" => false },
    "return if @x.nil?; @x = nil; @x.foo"            => { "foo" => false }, # reassignment cancels the guard
    "account.present? && account.foo"                => { "foo" => true },  # attr_reader-like call
    "m.r && m.r.foo"                                 => { "foo" => true },  # chained call
    "@x.foo"                                         => { "foo" => false },
    "if !@x.nil? then @x.foo end"                    => { "foo" => true },
    "@x.foo if @x == nil"                            => { "foo" => false },
    "@x.foo if @x != nil"                            => { "foo" => true },
    "[1].each { |v| next if v.nil?; v.foo }"         => { "foo" => true },
    "return if @x.nil?; [1].each { @x.foo }"         => { "foo" => true },  # extends into blocks
    "if @x.nil?; return; end; @x.foo"                => { "foo" => true },  # non-modifier form
  }

  CASES.each_with_index do |(body, expected), i|
    define_method("test_case_#{i}") do
      hits = scan("class C\n  def m\n    #{body}\n  end\nend\n")
      expected.each do |mid, guarded|
        hit = hits.find { _1.mid == mid } or flunk("no call .#{mid} in #{body.inspect}")
        assert_equal guarded, !hit.guarded_by.nil?, "#{body.inspect}: .#{mid} guarded_by=#{hit.guarded_by.inspect}"
      end
    end
  end

  def test_both_keys_guarded_by_compound_early_exit
    hits = scan("def m\n  return if @x.nil? || @y.nil?\n  @x.foo\n  @y.foo\nend\n")
    assert hits.select { _1.mid == "foo" }.all?(&:guarded_by)
  end

  def test_guard_does_not_cross_method_boundary
    hits = scan("def a\n  return if @x.nil?\nend\ndef b\n  @x.foo\nend\n")
    assert_nil hits.find { _1.mid == "foo" }.guarded_by
  end

  private

  def scan(src)
    Tempfile.create(["guard", ".rb"]) do |f|
      f.write(src)
      f.flush
      Nilflow::Guards.new(f.path).scan
    end
  end
end
