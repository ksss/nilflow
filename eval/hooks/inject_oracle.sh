#!/bin/bash
# 条件 E: 正解ファイルに触れたら、人手で書いた「理想の注」(事実のみ) を一度だけ添える。
input=$(cat); [ -n "${NILFLOW_HOOK_LOG:-}" ] && echo "IN $(date +%T) ${input:0:200}" >> "$NILFLOW_HOOK_LOG"
python3 - "$input" <<'PY'
import json, re, sys, os
d = json.loads(sys.argv[1]); tool = d.get("tool_name"); ti = d.get("tool_input") or {}
root = os.environ["NILFLOW_ROOT"]; note_file = os.environ["NILFLOW_ORACLE_NOTE"]; log = os.environ.get("NILFLOW_HOOK_LOG")
note = open(note_file).read()
gt = re.search(r"\] (\S+) ", note).group(1)  # 注の 1 行目にある対象ファイル
touched = []
if tool == "Read": touched = [ti.get("file_path", "")]
elif tool == "Bash": touched = re.findall(r"(?:app|lib)/[A-Za-z0-9_/.-]+\.rb", ti.get("command", ""))
hit = any(t.endswith(gt) for t in touched)
marker = note_file + ".sent"
if log: open(log, "a").write(f"OUT tool={tool} hit={hit} notes_chars={len(note) if hit and not os.path.exists(marker) else 0}\n")
if hit and not os.path.exists(marker):
    open(marker, "w").write("1")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": note}}))
PY
