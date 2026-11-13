#!/usr/bin/env python3
"""Minimal coding agent for Stage 2: an open LLM behind a local OpenAI-compatible server
(vLLM) fixes one task inside an offline Apptainer instance.

Normally this script runs INSIDE the sealed instance (`--net --network none`), started by
agent/in_container.sh with --exec-prefix '[]' and --base-url http://127.0.0.1:8000/v1 (the
forwarder to vLLM's socket). Fallback: it runs on the host with --base-url
unix:///path/vllm.sock:/v1 and an `apptainer exec ... instance://` prefix, so every tool
command still runs inside the instance. Either way the model's commands cannot reach the
internet.

Tools given to the model:
  bash(command, timeout)        run a shell command in /work/repo inside the instance
  str_replace(path, old, new)   replace one exact occurrence of text in a file
  write_file(path, content)     create or overwrite a file
  finish(summary)               stop; the workspace diff becomes candidate.patch

File edits also run inside the sandbox (through `cat`), with paths confined to the
repository and .git off limits. Uses only the Python standard library.

    python3 agent.py --base-url http://127.0.0.1:8000/v1 --model qwen3-coder-next \
        --exec-prefix '["apptainer","exec","--pwd","/work/repo","instance://rb_x"]' \
        --repo-dir /work/repo --problem problem_statement.md \
        --trajectory traj.jsonl [--max-steps 100] [--max-seconds 3600]
"""
from __future__ import annotations

import argparse
import http.client
import json
import socket
import os
import posixpath
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

SYSTEM_PROMPT = """You are an expert Java developer fixing a reported issue in a repository.

Environment:
- The repository is at /work/repo (your current directory). It is checked out at the commit
  where the issue was reported.
- There is NO internet access. Dependencies are already cached and the build tools are
  offline: use `mvn` (never ./mvnw) for Maven projects, and ./gradlew or gradle for Gradle
  projects. If a command tries to download something, it will fail; do not retry it.
- You act only through the provided tools. Each tool call returns its output.

Task:
- Understand the issue, find the cause in the source code, and change the main source code
  so the issue is resolved. Keep the change minimal and in the project's style.
- Hidden tests written by the maintainers will be run on your change. You may write or run
  tests to check your fix, but edits to existing test files may be overwritten.
- Do not stop until you have made a code change you believe fixes the issue; then call
  finish with a short summary.
"""

TOOLS = [
    {"type": "function", "function": {
        "name": "bash",
        "description": "Run a bash command in /work/repo inside the offline sandbox. Returns exit code and output (long output is truncated).",
        "parameters": {"type": "object", "properties": {
            "command": {"type": "string", "description": "The command to run."},
            "timeout": {"type": "integer", "description": "Seconds before the command is killed (default 300, max 1800)."}},
            "required": ["command"]}}},
    {"type": "function", "function": {
        "name": "str_replace",
        "description": "Replace exactly one occurrence of old_str with new_str in a file under the repository.",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string", "description": "Path relative to the repository root."},
            "old_str": {"type": "string"}, "new_str": {"type": "string"}},
            "required": ["path", "old_str", "new_str"]}}},
    {"type": "function", "function": {
        "name": "write_file",
        "description": "Create or overwrite a file under the repository with the given content.",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string", "description": "Path relative to the repository root."},
            "content": {"type": "string"}},
            "required": ["path", "content"]}}},
    {"type": "function", "function": {
        "name": "finish",
        "description": "Call when the fix is complete.",
        "parameters": {"type": "object", "properties": {"summary": {"type": "string"}},
                       "required": ["summary"]}}},
]

MAX_OUTPUT = 12000


def truncate(s: str, limit: int = MAX_OUTPUT) -> str:
    if len(s) <= limit:
        return s
    half = limit // 2
    return s[:half] + f"\n... [{len(s) - limit} characters truncated] ...\n" + s[-half:]


class Sandbox:
    """Runs everything through an exec prefix, e.g.
    ["apptainer", "exec", "--pwd", "/work/repo", "--env", "...", "instance://rb_x"].
    File edits also happen inside the sandbox (via cat), so the same code works for any
    runtime and never touches the host directly."""

    def __init__(self, exec_prefix: list[str], repo_dir: str):
        self.prefix, self.repo = exec_prefix, posixpath.normpath(repo_dir)

    def _run(self, args: list[str], timeout: int, data: bytes | None = None) -> subprocess.CompletedProcess:
        return subprocess.run([*self.prefix, *args], input=data, capture_output=True, timeout=timeout)

    def bash(self, command: str, timeout: int = 300) -> str:
        timeout = max(5, min(int(timeout or 300), 1800))
        try:
            r = self._run(["bash", "-lc", f"cd {shlex.quote(self.repo)} && {command}"], timeout)
            out = r.stdout.decode(errors="replace")
            err = r.stderr.decode(errors="replace")
            return f"[exit code {r.returncode}]\n" + truncate(out + (("\n[stderr]\n" + err) if err else ""))
        except subprocess.TimeoutExpired as e:
            out = (e.stdout or b"").decode(errors="replace")
            return f"[killed after {timeout}s]\n" + truncate(out)

    def _path(self, rel: str) -> str:
        rel = rel.strip()
        p = posixpath.normpath(rel if rel.startswith("/") else posixpath.join(self.repo, rel))
        if p != self.repo and not p.startswith(self.repo + "/"):
            raise ValueError(f"path outside the repository: {rel}")
        if ".git" in p[len(self.repo):].split("/"):
            raise ValueError("editing .git is not allowed")
        return p

    def _read(self, p: str) -> bytes | None:
        r = self._run(["cat", "--", p], 60)
        return r.stdout if r.returncode == 0 else None

    def _write(self, p: str, data: bytes) -> None:
        r = self._run(["bash", "-c", 'mkdir -p -- "$(dirname -- "$1")" && cat > "$1"', "_", p], 60, data)
        if r.returncode != 0:
            raise OSError(r.stderr.decode(errors="replace").strip() or "write failed")

    def str_replace(self, path: str, old_str: str, new_str: str) -> str:
        p = self._path(path)
        raw = self._read(p)
        if raw is None:
            return f"error: {path} does not exist"
        text = raw.decode("utf-8", errors="surrogateescape")
        n = text.count(old_str)
        if n != 1:
            return f"error: old_str occurs {n} times in {path}; it must occur exactly once"
        self._write(p, text.replace(old_str, new_str, 1).encode("utf-8", errors="surrogateescape"))
        return f"ok: edited {path}"

    def write_file(self, path: str, content: str) -> str:
        p = self._path(path)
        self._write(p, content.encode("utf-8"))
        return f"ok: wrote {path} ({len(content)} characters)"


class UnixHTTPConnection(http.client.HTTPConnection):
    """HTTP over a Unix domain socket: the model server runs with no network at all and
    listens on a socket file instead of a TCP port."""

    def __init__(self, socket_path: str, timeout: float):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self.socket_path)
        self.sock = s


def post_json(base_url: str, path: str, payload: dict, api_key: str, timeout: float = 900):
    """POST JSON to base_url + path. base_url is http(s)://host:port/v1 or
    unix:///path/to/socket[:/v1] (the socket path, then the URL prefix, default /v1)."""
    data = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"}
    if base_url.startswith("unix://"):
        rest = base_url[len("unix://"):]
        sock, _, prefix = rest.partition(":")
        conn = UnixHTTPConnection(sock, timeout)
        try:
            conn.request("POST", (prefix or "/v1").rstrip("/") + path, body=data, headers=headers)
            r = conn.getresponse()
            return r.status, r.read()
        finally:
            conn.close()
    req = urllib.request.Request(base_url.rstrip("/") + path, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def chat(base_url: str, payload: dict, api_key: str, retries: int = 3) -> dict:
    last = None
    for attempt in range(retries):
        try:
            status, body = post_json(base_url, "/chat/completions", payload, api_key)
            if status == 200:
                return json.loads(body)
            text = body.decode(errors="replace")
            if status == 400:
                raise RuntimeError(f"bad_request: {text[:500]}")
            last = f"HTTP {status}: {text[:300]}"
        except (urllib.error.URLError, OSError, TimeoutError, http.client.HTTPException) as e:
            last = str(e)
        time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"model_server_unavailable: {last}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--api-key", default=os.environ.get("RB_API_KEY", "EMPTY"))
    ap.add_argument("--exec-prefix", required=True,
                    help='JSON list: command prefix that runs one command in the sandbox')
    ap.add_argument("--repo-dir", default="/work/repo", help="repository path inside the sandbox")
    ap.add_argument("--problem", required=True, type=Path)
    ap.add_argument("--trajectory", required=True, type=Path)
    ap.add_argument("--result", type=Path, help="write a JSON summary here")
    ap.add_argument("--max-steps", type=int, default=100)
    ap.add_argument("--max-seconds", type=int, default=3600)
    ap.add_argument("--temperature", type=float, default=0.0)
    ap.add_argument("--max-tokens", type=int, default=4096)
    a = ap.parse_args()

    box = Sandbox(json.loads(a.exec_prefix), a.repo_dir)
    problem = a.problem.read_text(encoding="utf-8")
    messages = [{"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": "Fix this issue in the repository:\n\n" + problem}]
    traj = a.trajectory.open("w", encoding="utf-8")
    start, steps, idle, stop, summary = time.time(), 0, 0, "max_steps", ""
    usage = {"prompt_tokens": 0, "completion_tokens": 0}

    def log(kind: str, **kw):
        traj.write(json.dumps({"t": round(time.time() - start, 1), "step": steps, "kind": kind, **kw}) + "\n")
        traj.flush()

    while steps < a.max_steps:
        if time.time() - start > a.max_seconds:
            stop = "time_budget"
            break
        steps += 1
        try:
            resp = chat(a.base_url, {"model": a.model, "messages": messages, "tools": TOOLS,
                                     "tool_choice": "auto", "temperature": a.temperature,
                                     "max_tokens": a.max_tokens}, a.api_key)
        except RuntimeError as e:
            stop = "context_or_request_error" if str(e).startswith("bad_request") else "model_server_error"
            log("error", error=str(e))
            break
        for k in usage:
            usage[k] += (resp.get("usage") or {}).get(k, 0) or 0
        msg = resp["choices"][0]["message"]
        calls = msg.get("tool_calls") or []
        assistant = {"role": "assistant", "content": msg.get("content") or ""}
        if calls:
            assistant["tool_calls"] = calls
        messages.append(assistant)
        log("assistant", content=msg.get("content"), reasoning=msg.get("reasoning_content"), tool_calls=calls)
        if not calls:
            idle += 1
            if idle >= 3:
                stop = "no_tool_calls"
                break
            messages.append({"role": "user", "content": "Continue by calling a tool. Call finish when the fix is done."})
            continue
        idle = 0
        finished = False
        for c in calls:
            name = c["function"]["name"]
            try:
                args = json.loads(c["function"].get("arguments") or "{}")
            except json.JSONDecodeError:
                args, result = {}, "error: arguments were not valid JSON"
            else:
                try:
                    if name == "bash":
                        result = box.bash(args.get("command", ""), args.get("timeout", 300))
                    elif name == "str_replace":
                        result = box.str_replace(args["path"], args["old_str"], args["new_str"])
                    elif name == "write_file":
                        result = box.write_file(args["path"], args["content"])
                    elif name == "finish":
                        summary, finished, result = args.get("summary", ""), True, "ok"
                    else:
                        result = f"error: unknown tool {name}"
                except (KeyError, ValueError, OSError) as e:
                    result = f"error: {e}"
            log("tool", name=name, args=args, result=result)
            messages.append({"role": "tool", "tool_call_id": c.get("id", ""), "content": result})
        if finished:
            stop = "finished"
            break

    res = {"model": a.model, "stop_reason": stop, "steps": steps,
           "seconds": round(time.time() - start, 1), "usage": usage, "summary": summary}
    log("end", **res)
    traj.close()
    if a.result:
        a.result.write_text(json.dumps(res, indent=2) + "\n")
    print(json.dumps(res))
    return 0


if __name__ == "__main__":
    sys.exit(main())
