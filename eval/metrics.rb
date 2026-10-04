# 生データ (jsonl transcript, hook.log, spec.log, nilflow.log) から指標を計算する。
# run.rb と report.rb の両方から使い、指標の定義を一箇所にまとめる。
require "json"
require "yaml"
require "set"

module Metrics
  EDIT_CMD = /sed\s+-i|open\([^)]*['"][wa]['"]\)|\btee\b|(?<![<>])>\s*\S+\.rb|File\.write|patch\b/

  def self.compute(stem, task, wt)
    out = File.read("#{stem}.jsonl", encoding: "UTF-8").scrub
    events = out.each_line.filter_map { |l| JSON.parse(l) rescue nil }
    tool_uses = events.select { _1["type"] == "assistant" }
                      .flat_map { _1.dig("message", "content") || [] }
                      .select { _1["type"] == "tool_use" }
    result = events.find { _1["type"] == "result" } || {}
    final_text = result["result"].to_s

    gt_files = task["ground_truth"].map { _1["file"] }
    gt_methods = task["ground_truth"].flat_map { _1["methods"] }
    rel = ->(p) { p.to_s.sub(%r{\A#{Regexp.escape(wt)}/?}, "") }
    rb_paths = ->(cmd) { cmd.scan(%r{(?:app|lib|spec|config)/[A-Za-z0-9_/.-]+\.rb}).uniq }

    reads = tool_uses.select { _1["name"] == "Read" }.map { rel.(_1.dig("input", "file_path")) }
    bash = tool_uses.select { _1["name"] == "Bash" }.map { _1.dig("input", "command").to_s }
    tool_edits = tool_uses.select { %w[Edit Write].include?(_1["name"]) }.map { rel.(_1.dig("input", "file_path")) }
    bash_edits = bash.select { _1.match?(EDIT_CMD) }.flat_map { rb_paths.(_1) }
    edits = tool_edits + bash_edits
    nilflow_calls = bash.select { _1.include?("nilflow ") || _1.include?("sqlite3") }
    first_gt_touch = tool_uses.index { |t| gt_files.any? { |g| JSON.generate(t["input"]).include?(g) } }
    wrong_edits = edits.reject { gt_files.include?(_1) }
    mentions_gt_method = gt_methods.any? { final_text.include?(_1) }
    edited_gt = edits.any? { gt_files.include?(_1) }
    localized = (gt_files.any? { final_text.include?(File.basename(_1)) } && mentions_gt_method) || (edited_gt && mentions_gt_method)

    hook_log = "#{stem}.hook.log"
    injected = File.exist?(hook_log) ? File.readlines(hook_log).count { _1.start_with?("OUT") && _1[/notes_chars=(\d+)/, 1].to_i > 0 } : 0

    # spec の合否は「本物の修正を当てた時の失敗集合」(eval/runs/<task>.oracle.log) を基準にする。
    # 環境要因で元から落ちる example は数えない。
    spec_pass = nil
    if File.exist?("#{stem}.spec.log")
      so = File.read("#{stem}.spec.log", encoding: "UTF-8").scrub
      if so.include?("bundler: failed") || so.include?("rbenv: version") || !so.match?(/\d+ examples?,/)
        spec_pass = nil # 環境エラーは判定不能
      else
        failing = ->(log) { log.scan(/^rspec (\S+:\d+)/).flatten.to_set }
        oracle = File.join(File.dirname(stem), "#{task['id']}.oracle.log")
        baseline = File.exist?(oracle) ? failing.(File.read(oracle, encoding: "UTF-8").scrub) : Set.new
        spec_pass = failing.(so).subset?(baseline) && !so.include?("error occurred")
      end
    end

    {
      task: task["id"], localized: localized, edited_gt: edited_gt, mentions_gt_method: mentions_gt_method,
      first_gt_touch_at: first_gt_touch && first_gt_touch + 1,
      tool_calls: tool_uses.size, reads: reads.size, files_read: reads.uniq.size,
      edits: edits.size, wrong_edits: wrong_edits.size, wrong_edit_files: wrong_edits.uniq,
      nilflow_calls: nilflow_calls.size, nilflow_commands: nilflow_calls, injected_notes: injected,
      spec_pass: spec_pass,
      num_turns: result["num_turns"], cost_usd: result["total_cost_usd"],
      is_error: result["is_error"], model: (result["modelUsage"] || {}).keys.join(","),
      final_tail: final_text[-400..] || final_text,
    }
  end
end
