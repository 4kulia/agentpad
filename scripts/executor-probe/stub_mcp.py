#!/usr/bin/env python3
"""Stand-in for `agentpad-cli run-tools`: the same tool, always refused.

The real tool asks the owner through the running AgentPad's socket; the
probe must not touch it, so this one answers as an owner who said no and
logs every call to the file named by argv[1].
"""
import json
import sys

LOG = sys.argv[1]


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        req = json.loads(line)
    except ValueError:
        continue
    method, rid = req.get("method"), req.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": req.get("params", {}).get("protocolVersion", "2024-11-05"),
            "capabilities": {"tools": {}}, "serverInfo": {"name": "agentpad-run", "version": "probe"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": rid, "result": {"tools": [{
            "name": "request_folder_access",
            "description": "Ask the owner of this Mac for access to a folder outside the ones you have.",
            "inputSchema": {"type": "object", "properties": {
                "path": {"type": "string"}, "reason": {"type": "string"}}, "required": ["path", "reason"]}}]}})
    elif method == "tools/call":
        with open(LOG, "a") as f:
            f.write(json.dumps(req.get("params", {})) + "\n")
        send({"jsonrpc": "2.0", "id": rid, "result": {
            "content": [{"type": "text", "text": "The owner declined access to this folder."}], "isError": True}})
    elif rid is not None:
        send({"jsonrpc": "2.0", "id": rid, "result": {}})
