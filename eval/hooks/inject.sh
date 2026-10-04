#!/bin/bash
# 条件 C: PostToolUse (Read / Bash)。触ったファイルの nilflow 要約を additionalContext として添える。
# 環境変数: NILFLOW_DB, NILFLOW_ROOT (作業木), NILFLOW_DIR (nilflow のディレクトリ)
input=$(cat); [ -n "${NILFLOW_HOOK_LOG:-}" ] && echo "IN $(date +%T) ${input:0:300}" >> "$NILFLOW_HOOK_LOG"
python3 - "$input" <<'PY'
import json, re, subprocess, sys, os
d = json.loads(sys.argv[1]); tool = d.get("tool_name"); ti = d.get("tool_input") or {}
root = os.environ["NILFLOW_ROOT"]; db = os.environ["NILFLOW_DB"]; nf = os.environ["NILFLOW_DIR"]
targets = []  # (path, from, to)
if tool == "Read":
    fp = ti.get("file_path", "")
    if fp.endswith(".rb") and fp.startswith(root):
        off = ti.get("offset"); lim = ti.get("limit")
        rng = (int(off or 1), int(off or 1) + int(lim) - 1) if lim else None
        targets.append((fp, rng))
elif tool == "Bash":
    cmd = ti.get("command", "")
    for m in dict.fromkeys(re.findall(r"(?:app|lib)/[A-Za-z0-9_/.-]+\.rb", cmd)):
        p = os.path.join(root, m)
        if os.path.exists(p): targets.append((p, None))
    targets = targets[:3]
notes = []
for p, rng in targets:
    arg = p if not rng else f"{p}:{rng[0]}:{rng[1]}"
    try:
        out = subprocess.run(["bundle", "exec", "ruby", "exe/nilflow", "summary", arg, db], cwd=nf, capture_output=True, text=True, timeout=60,
                             env={**{k: v for k, v in os.environ.items() if k not in ("RBENV_VERSION", "BUNDLE_GEMFILE")}, "NILFLOW_ROOT": root}).stdout.strip()
        if out: notes.append(out)
    except Exception as e:
        notes.append(f"[nilflow] error: {e}")
log = os.environ.get("NILFLOW_HOOK_LOG")
if log:
    open(log, "a").write(f"OUT tool={tool} targets={len(targets)} notes_chars={sum(len(n) for n in notes)}\n")
if notes:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "\n".join(notes)}}))
PY
