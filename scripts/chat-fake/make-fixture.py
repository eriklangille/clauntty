#!/usr/bin/env python3
"""Turn a recorded headless Claude session into the fake claude's replay file.

The recording has one JSON object per line, {"t": seconds, "dir": "in"|"out", "turn": n, "line": <stream-json event>}. The output
has one line per event Claude printed: turn, seconds to wait first, kind ("out", or "ask"
for a control_request the app must answer) and the event, with the session id as __SID__
and the recording machine's paths and user name replaced.

Usage: make-fixture.py RECORDING OUT [WORKDIR]  (WORKDIR: where the session ran)
"""
import getpass, json, os, sys

src, dst = sys.argv[1], sys.argv[2]
# This machine's paths and user name become the test container's
home, user = os.path.expanduser("~"), getpass.getuser()
replace = [(home, "/home/testuser"), (user.capitalize(), "Ada"), (user, "ada")]
if len(sys.argv) > 3:
    workdir = sys.argv[3]
    replace[:0] = [(os.path.realpath(workdir), "/home/testuser/demo"), (workdir, "/home/testuser/demo")]
skip = {("system", "hook_started"), ("system", "hook_response")}
rows, last = [], {}
for raw in open(src):
    r = json.loads(raw)
    turn = r["turn"]
    if r["dir"] == "in":
        # The app's answer: the next line's wait counts from here
        last[turn] = r["t"]
        continue
    o = r["line"]
    if (o.get("type"), o.get("subtype")) in skip or o.get("type") == "rate_limit_event":
        continue
    ev = o.get("event") or {}
    # Tool input as it streams: the app shows a tool once it's whole (and the pieces
    # split paths where the replacements can't find them)
    if ev.get("type") == "content_block_delta" and ev.get("delta", {}).get("type") == "input_json_delta":
        continue
    if o.get("subtype") == "init":
        # The recording machine's tools, servers, skills and plugins
        o = {k: v for k, v in o.items() if not isinstance(v, list) or k == "capabilities"}
    sid = o.get("session_id")
    text = json.dumps(o, separators=(",", ":"), ensure_ascii=False)
    if sid:
        text = text.replace(sid, "__SID__")
    for a, b in replace:
        text = text.replace(a, b)
    delay = max(0.0, r["t"] - last.get(turn, r["t"]))
    last[turn] = r["t"]
    kind = "ask" if o.get("type") == "control_request" else "out"
    rows.append(f"{turn}\t{delay:.3f}\t{kind}\t{text}")
open(dst, "w").write("\n".join(rows) + "\n")
print(f"{len(rows)} events, {len({r.split(chr(9))[0] for r in rows})} turns")
