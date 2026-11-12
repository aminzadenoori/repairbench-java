#!/usr/bin/env python3
"""A scripted OpenAI-compatible /v1/chat/completions server for tests/e2e_fake.sh.

It plays a model that inspects the demo repo, fixes Calc.add, and calls finish. It also
checks that every request carries the tools and that tool results come back.
    python3 model_server.py <port>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SCRIPT = [
    ("bash", {"command": "cat src/main/java/demo/Calc.java && git log --oneline | head"}),
    ("bash", {"command": "mvn -q test -Dtest=CalcTest || true"}),
    ("str_replace", {"path": "src/main/java/demo/Calc.java",
                     "old_str": "return a - b;", "new_str": "return a + b;"}),
    ("finish", {"summary": "Calc.add subtracted instead of adding."}),
]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert body.get("tools"), "tools missing"
        step = sum(1 for m in body["messages"] if m["role"] == "assistant")
        name, args = SCRIPT[min(step, len(SCRIPT) - 1)]
        msg = {"role": "assistant", "content": "",
               "tool_calls": [{"id": f"call_{step}", "type": "function",
                               "function": {"name": name, "arguments": json.dumps(args)}}]}
        resp = {"choices": [{"message": msg, "finish_reason": "tool_calls"}],
                "usage": {"prompt_tokens": 100, "completion_tokens": 10}}
        data = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
