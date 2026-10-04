#!/bin/bash
# 条件 D: PreToolUse (Edit / Write)。編集対象ファイルについて nilflow をまだ実行していなければ拒否する。
# NILFLOW_LOG には wrapper が実行した nilflow コマンドが 1 行ずつ追記されている。
input=$(cat)
python3 - "$input" <<'PY'
import json, os, sys
d = json.loads(sys.argv[1]); fp = (d.get("tool_input") or {}).get("file_path", "")
log = os.environ.get("NILFLOW_LOG", "")
seen = open(log).read() if log and os.path.exists(log) else ""
base = os.path.basename(fp)
if fp.endswith(".rb") and base not in seen:
    reason = (f"Before editing {base}, you must consult the static analysis for the location you intend to change: "
              f"run `nilflow type-at {base}:LINE:COL` and `nilflow why {base}:LINE:COL` (or `nilflow callees {base}:LINE`) "
              f"on the relevant lines, read the output, then retry the edit.")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}))
PY
