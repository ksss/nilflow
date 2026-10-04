#!/usr/bin/env ruby
# Run one task x one condition x one repetition, and save the transcript and metrics.
#
#   ruby eval/run.rb TASK_ID COND [REP]
#
#   COND: A grep only / B nilflow CLI docs only / C summaries injected by a PostToolUse hook /
#         D edits refused until nilflow is run (PreToolUse hook) / E hand-written "ideal" notes injected
#
# Environment: NILFLOW_MODEL (default claude-sonnet-5-5), PG_BIN (bin directory containing psql etc.),
#              NILFLOW_RUN_SPEC=0 to skip running the spec
#
# Output: eval/runs/<task>_<cond>_<rep>.jsonl (stream-json transcript)
#       eval/runs/<task>_<cond>_<rep>.metrics.json
require "yaml"
require "json"
require "fileutils"
require "open3"
require "shellwords"
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

EVAL = __dir__
NF = File.dirname(EVAL)
task_id, cond, rep = ARGV
rep = (rep || "1").to_i
abort "usage: run.rb TASK_ID A|B|C|D|E [REP]" unless task_id && %w[A B C D E].include?(cond)

task = YAML.load_file(File.join(EVAL, "tasks", "#{task_id}.yaml"))
wt = File.join(EVAL, "wt", task_id)
db = File.join(EVAL, "db", "#{task_id}.db")
abort "worktree missing: #{wt}" unless Dir.exist?(wt)
abort "db missing: #{db}" if cond != "A" && !File.exist?(db)
FileUtils.mkdir_p(File.join(EVAL, "runs"))
stem = File.join(EVAL, "runs", "#{task_id}_#{cond}_#{rep}")

# --- Reset the worktree (discard previous edits) -----------------------------------
system("git", "-C", wt, "checkout", "--", ".", out: File::NULL, err: File::NULL)
system("git", "-C", wt, "clean", "-fdq", "-e", ".gem_rbs_collection", "-e", "rbs_collection*.yaml", "-e", ".env.test", out: File::NULL, err: File::NULL)

# --- Prompt (identical for all conditions) ----------------------------------------
prompt = <<~PROMPT
  You are working in a checkout of a Rails application (Mastodon). A bug has been reported:

  #{task["symptom"].gsub(/^/, "  ")}

  Investigate the root cause and fix it by editing the source code.
  Constraints:
  - Do NOT run the test suite, rails, rake, or bundle commands. Investigate by reading code.
  - Keep the fix minimal.
  - Use at most 60 tool calls.
  When finished, end your reply with exactly this block:

  ROOT CAUSE: <file path>:<method name>
  FIX: <one sentence>
PROMPT

# --- nilflow wrapper (put on PATH for conditions B/D; logs every command) ----------
bin_dir = File.join(EVAL, "bin_#{task_id}")
FileUtils.mkdir_p(bin_dir)
nilflow_log = File.join(EVAL, "runs", "#{task_id}_#{cond}_#{rep}.nilflow.log")
File.delete(nilflow_log) if File.exist?(nilflow_log)
File.write(File.join(bin_dir, "nilflow"), <<~SH)
  #!/bin/bash
  echo "$@" >> #{nilflow_log.shellescape}
  # Run nilflow with its own bundle (not affected by the worktree's .ruby-version / Gemfile)
  cd #{NF.shellescape} && unset RBENV_VERSION BUNDLE_GEMFILE && NILFLOW_ROOT=#{wt.shellescape} exec bundle exec ruby exe/nilflow "$@" #{db.shellescape}
SH
FileUtils.chmod(0o755, File.join(bin_dir, "nilflow"))

nilflow_doc = <<~DOC
  A static analysis database of this codebase is available (built with typeprof; no annotations were needed).
  A CLI `nilflow` is on PATH. File paths may be relative to the repository root. Columns are 0-based.

    nilflow callers 'Klass#method'          call sites whose receiver type resolves to Klass#method, with the enclosing method
    nilflow callees app/x.rb:LINE           each call on that line: receiver type, resolved target(s), confidence
    nilflow type-at app/x.rb:LINE:COL       inferred type of the expression at that position
    nilflow why app/x.rb:LINE:COL           where a nil reaching that expression comes from (provenance tree)
    nilflow why app/x.rb:LINE:COL --type T  same for another type T (e.g. --type String)
    nilflow nil-receivers                   calls whose receiver may be nil and is not guarded

  Confidence: [resolved] all receiver types known, [partial] some paths untyped, [unknown] no type info.
  The analysis is flow-insensitive: "may be nil" means some path can produce nil, not that it does.
  The SQLite file is #{db} (tables: vertices, type_flow, call_sites, calls, methods, guards) if you prefer raw SQL via sqlite3.
DOC

# --- Run claude headless ----------------------------------------------------------
cmd = [
  "claude", "-p",
  "--output-format", "stream-json", "--verbose",
  "--tools", "Read,Grep,Glob,Bash,Edit,Write",
  "--permission-mode", "bypassPermissions",
  "--no-session-persistence",
  "--setting-sources", "project",   # do not inherit ~/.claude/CLAUDE.md or the output style
  "--max-budget-usd", "5",
  "--model", ENV.fetch("NILFLOW_MODEL", "claude-sonnet-5-5"),
]
inject_doc = <<~DOC
  Notes marked [nilflow] may be attached to tool results. They come from a static analysis of this codebase
  (typeprof-based, no annotations): per call site, the inferred receiver type, the resolved target method
  (file:line), a confidence tag, and whether a nil may reach the receiver unguarded. Confidence: [resolved] all
  receiver types known, [partial] some paths untyped, [unknown] no type info. The analysis is flow-insensitive.
DOC
force_doc = nilflow_doc + "\nYou MUST consult nilflow (type-at / why / callees) on the lines you intend to change before editing; edits are refused otherwise.\n"
oracle_note = File.join(EVAL, "oracle_notes", "#{task_id}.txt")
File.delete("#{oracle_note}.sent") if File.exist?("#{oracle_note}.sent")
hooks = {
  "E" => { "hooks" => { "PostToolUse" => [{ "matcher" => "Read|Bash", "hooks" => [{ "type" => "command", "command" => File.join(EVAL, "hooks", "inject_oracle.sh"), "timeout" => 30 }] }] } },
  "C" => { "hooks" => { "PostToolUse" => [{ "matcher" => "Read|Bash", "hooks" => [{ "type" => "command", "command" => File.join(EVAL, "hooks", "inject.sh"), "timeout" => 120 }] }] } },
  "D" => { "hooks" => { "PreToolUse" => [{ "matcher" => "Edit|Write", "hooks" => [{ "type" => "command", "command" => File.join(EVAL, "hooks", "require_nilflow.sh") }] }] } },
}
case cond
when "B" then cmd += ["--append-system-prompt", nilflow_doc]
when "C" then cmd += ["--append-system-prompt", inject_doc, "--settings", JSON.generate(hooks["C"])]
when "D" then cmd += ["--append-system-prompt", force_doc, "--settings", JSON.generate(hooks["D"])]
when "E" then cmd += ["--append-system-prompt", inject_doc.sub("[nilflow]", "[nilflow:oracle]"), "--settings", JSON.generate(hooks["E"])]
end
# rbenv's `exec` leaves RBENV_VERSION and versions/<v>/bin to children. To let each worktree's .ruby-version apply,
# drop versions/*/bin from PATH, put the shims first, and unset RBENV_VERSION.
rbenv_shims = File.expand_path("~/.rbenv/shims")
clean_path = [ENV["PG_BIN"], (rbenv_shims if Dir.exist?(rbenv_shims)),
              *ENV["PATH"].split(":").reject { _1.include?("/.rbenv/versions/") }].compact.uniq.join(":")
env = { "PATH" => (%w[B D].include?(cond) ? "#{bin_dir}:" : "") + clean_path,
        "RBENV_VERSION" => nil,
        "NILFLOW_DB" => db, "NILFLOW_ROOT" => wt, "NILFLOW_DIR" => NF, "NILFLOW_LOG" => nilflow_log,
        "NILFLOW_HOOK_LOG" => "#{stem}.hook.log", "NILFLOW_ORACLE_NOTE" => oracle_note }

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
out, err, status = Open3.capture3(env, *cmd, stdin_data: prompt, chdir: wt)
out = out.force_encoding(Encoding::UTF_8).scrub
wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
File.write("#{stem}.jsonl", out)
File.write("#{stem}.stderr", err)

# --- Verification and metrics ----------------------------------------------------
require_relative "metrics"
# Verification: put the fix commit's spec into the worktree and run it (if the environment allows)
if task["spec"] && ENV["NILFLOW_RUN_SPEC"] != "0"
  spec_src, = Open3.capture2("git", "-C", wt, "show", "#{task['fix_commit']}:#{task['spec']}")
  unless spec_src.empty?
    File.write(File.join(wt, task["spec"]), spec_src)
    spec_env = { "RAILS_ENV" => "test", "DB_NAME" => "mastodon_#{task_id}", "RBENV_VERSION" => nil, "PATH" => clean_path }
    so, = Open3.capture2e(spec_env, "bundle", "exec", "rspec", task["spec"], chdir: wt)
    File.write("#{stem}.spec.log", so)
  end
end

metrics = Metrics.compute(stem, task, wt).merge(cond: cond, rep: rep, wall_s: wall.round, exit: status.exitstatus)
File.write("#{stem}.metrics.json", JSON.pretty_generate(metrics))
puts JSON.pretty_generate(metrics.except(:final_tail, :nilflow_commands, :wrong_edit_files))
