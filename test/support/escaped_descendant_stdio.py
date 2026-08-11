#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import sys


mode = sys.argv[1]
pid_file = sys.argv[2] if len(sys.argv) > 2 else None


def spawn_escaped():
    child = subprocess.Popen(["/bin/sleep", "60"], start_new_session=True)
    if pid_file:
        with open(pid_file, "w", encoding="ascii") as file:
            file.write(str(child.pid))
    return child


if mode == "natural_exit":
    child = spawn_escaped()
    print(json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"pid": child.pid}}), flush=True)
elif mode == "late_exit":
    def on_term(_signum, _frame):
        spawn_escaped()
        sys.exit(0)

    signal.signal(signal.SIGTERM, on_term)
    print(json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"ready": True}}), flush=True)
    while True:
        signal.pause()
else:
    raise SystemExit(f"unknown mode: {mode}")
