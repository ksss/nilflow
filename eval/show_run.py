#!/usr/bin/env python3
# Extract tool calls and the final answer from a transcript (claude -p --output-format stream-json)
#   python3 eval/show_run.py eval/runs/<task>_<cond>_<rep>.jsonl
import json
import os
import sys

WT_PREFIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "wt") + "/"


def one_line(s, n):
    return s[:n].replace("\n", "⏎")


for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    t = e.get("type")
    if t == "assistant":
        for b in e["message"]["content"]:
            if b["type"] != "tool_use":
                continue
            i = b.get("input", {})
            target = (i.get("pattern") or i.get("command") or i.get("file_path", "")).replace(WT_PREFIX, "")
            edit = f" old={one_line(i['old_string'], 70)} new={one_line(i['new_string'], 90)}" if "old_string" in i else ""
            print("TOOL", b["name"], target + edit)
    elif t == "result":
        print("RESULT:", e.get("result", "")[-500:].replace("\n", " | "))
