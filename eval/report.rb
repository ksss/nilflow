#!/usr/bin/env ruby
# eval/runs/*.jsonl から指標を再計算して集計する (metrics.json は wall_s/cond/rep の参照に使う)
require "json"
require "yaml"
require_relative "metrics"
rows = Dir[File.join(__dir__, "runs", "*.metrics.json")].map do |f|
  m = JSON.parse(File.read(f))
  stem = f.sub(".metrics.json", "")
  task = YAML.load_file(File.join(__dir__, "tasks", "#{m['task']}.yaml"))
  wt = File.join(__dir__, "wt", m["task"])
  Metrics.compute(stem, task, wt).transform_keys(&:to_s).merge("cond" => m["cond"], "rep" => m["rep"], "wall_s" => m["wall_s"])
end
abort "no runs" if rows.empty?
cols = %w[localized edited_gt first_gt_touch_at tool_calls edits wrong_edits nilflow_calls injected_notes spec_pass cost_usd wall_s]
printf "%-26s %-4s %-3s %s\n", "task", "cond", "rep", cols.join(" ")
rows.sort_by { [_1["task"], _1["cond"], _1["rep"].to_i] }.each do |r|
  printf "%-26s %-4s %-3s %s\n", r["task"], r["cond"], r["rep"], cols.map { |c| v = r[c]; v.nil? ? "-" : (v == true ? "yes" : v == false ? "no" : v.is_a?(Float) ? v.round(2) : v) }.join(" ")
end
puts
%w[A B C D E].each do |c|
  rs = rows.select { _1["cond"] == c }
  next if rs.empty?
  avg = ->(k) { vals = rs.map { _1[k] }.compact.grep(Numeric); vals.empty? ? "-" : (vals.sum.to_f / vals.size).round(1) }
  rate = ->(k) { vals = rs.map { _1[k] }.compact; vals.empty? ? "-" : "#{vals.count(true)}/#{vals.size}" }
  puts "cond #{c}: n=#{rs.size} localized=#{rate.('localized')} spec_pass=#{rate.('spec_pass')} first_gt_touch=#{avg.('first_gt_touch_at')} tool_calls=#{avg.('tool_calls')} edits=#{avg.('edits')} wrong_edits=#{avg.('wrong_edits')} nilflow_calls=#{avg.('nilflow_calls')} injected=#{avg.('injected_notes')} cost=#{avg.('cost_usd')}"
end
