#!/usr/bin/env python3
"""
server.py - HTTP API for the AssessingAgents engine.

Routes:
  POST /runs                      start a run
  GET  /runs/<run>                status + file listing
  GET  /runs/<run>/files/<path>   raw artifact content

State lives on disk under ENGINE_DIR/runs/<run>/. Auth is a shared secret
checked against the X-API-Key header.

Environment variables:
  INFRA_API_KEY   required. Shared secret every request must present.
  ENGINE_DIR      path to the cloned AssessingAgents repo. Default: ./engine
  HOST            default: 0.0.0.0
  PORT            default: 8080
"""

import hmac
import json
import os
import re
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
ENGINE_DIR = Path(os.environ.get("ENGINE_DIR", SCRIPT_DIR / "engine")).resolve()
RUNS_DIR = ENGINE_DIR / "runs"
API_KEY = os.environ.get("INFRA_API_KEY")

RUN_ID_RE = re.compile(r"^[A-Za-z0-9_-]+$")
FILENAME_RE = re.compile(r"^[A-Za-z0-9_.\-]+$")


def _next_run_id() -> str:
    """Pick the next free integer run id by looking at what's on disk."""
    if not RUNS_DIR.exists():
        return "1"
    existing = [int(p.name) for p in RUNS_DIR.iterdir() if p.name.isdigit()]
    return str(max(existing, default=0) + 1)


def _run_dir(run_id: str) -> Path:
    return RUNS_DIR / run_id


def _exit_code_file(run_id: str) -> Path:
    return _run_dir(run_id) / ".exit_code"


def _watch_process(proc: subprocess.Popen, run_id: str) -> None:
    """Wait for run_engine.sh to finish and record its exit code."""
    exit_code = proc.wait()
    _exit_code_file(run_id).write_text(str(exit_code))


def _start_run(payload: dict) -> dict:
    client_instruction = payload.get("client_instruction")
    location = payload.get("location", client_instruction)
    data_files = payload.get("data_files", {})
    run_id = str(payload.get("run") or _next_run_id())

    if not RUN_ID_RE.match(run_id):
        raise ValueError("invalid run id")
    if not client_instruction:
        raise ValueError("client_instruction is required")
    if not isinstance(data_files, dict):
        raise ValueError("data_files must be an object of filename -> content")

    run_dir = _run_dir(run_id)
    if run_dir.exists():
        raise ValueError(f"run '{run_id}' already exists")
    run_dir.mkdir(parents=True)

    (run_dir / "client_instruction.txt").write_text(client_instruction)

    for filename, content in data_files.items():
        if not FILENAME_RE.match(filename):
            raise ValueError(f"invalid data file name: {filename}")
        (run_dir / filename).write_text(content)

    log_path = run_dir / "api_log.txt"
    with open(log_path, "wb") as log_file:
        proc = subprocess.Popen(
            [
                str(SCRIPT_DIR / "run_engine.sh"),
                "--run", run_id,
                "--location", location,
            ],
            cwd=str(ENGINE_DIR),
            stdout=log_file,
            stderr=subprocess.STDOUT,
        )

    threading.Thread(target=_watch_process, args=(proc, run_id), daemon=True).start()

    return {"run": run_id, "status": "started"}


def _run_status(run_id: str) -> dict:
    run_dir = _run_dir(run_id)
    if not run_dir.exists():
        raise FileNotFoundError(run_id)

    exit_code_file = _exit_code_file(run_id)
    if exit_code_file.exists():
        exit_code = exit_code_file.read_text().strip()
        status = "succeeded" if exit_code == "0" else "failed"
    else:
        status = "running"

    files = sorted(
        str(p.relative_to(run_dir))
        for p in run_dir.rglob("*")
        if p.is_file() and p.name != ".exit_code"
    )
    return {"run": run_id, "status": status, "files": files}


def _run_file(run_id: str, rel_path: str) -> Path:
    run_dir = _run_dir(run_id).resolve()
    target = (run_dir / rel_path).resolve()
    if run_dir not in target.parents and target != run_dir:
        raise PermissionError("path escapes run directory")
    if not target.is_file():
        raise FileNotFoundError(rel_path)
    return target


class Handler(BaseHTTPRequestHandler):
    server_version = "AssessingAgentsInfra/0.1"

    def _authenticated(self) -> bool:
        supplied = self.headers.get("X-API-Key", "")
        return bool(API_KEY) and hmac.compare_digest(supplied, API_KEY)

    def _send_json(self, code: int, body: dict) -> None:
        payload = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _send_text(self, code: int, text: str, content_type="text/plain") -> None:
        payload = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", f"{content_type}; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if not self._authenticated():
            self._send_json(401, {"error": "unauthorized"})
            return

        parsed = urlparse(self.path)
        if parsed.path != "/runs":
            self._send_json(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
            result = _start_run(payload)
            self._send_json(202, result)
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:  # noqa: BLE001
            self._send_json(500, {"error": str(e)})

    def do_GET(self):
        if not self._authenticated():
            self._send_json(401, {"error": "unauthorized"})
            return

        parsed = urlparse(self.path)
        parts = [p for p in parsed.path.split("/") if p]

        try:
            if len(parts) == 2 and parts[0] == "runs":
                self._send_json(200, _run_status(parts[1]))
                return

            if len(parts) >= 3 and parts[0] == "runs" and parts[2] == "files":
                run_id = parts[1]
                rel_path = "/".join(parts[3:])
                target = _run_file(run_id, rel_path)
                content_type = "text/csv" if target.suffix == ".csv" else "text/plain"
                self._send_text(200, target.read_text(), content_type)
                return

            self._send_json(404, {"error": "not found"})
        except FileNotFoundError:
            self._send_json(404, {"error": "not found"})
        except PermissionError as e:
            self._send_json(403, {"error": str(e)})
        except Exception as e:  # noqa: BLE001
            self._send_json(500, {"error": str(e)})

    def log_message(self, fmt, *args):  # quieter default logging
        pass


def main():
    if not API_KEY:
        raise SystemExit("INFRA_API_KEY environment variable must be set")

    RUNS_DIR.mkdir(parents=True, exist_ok=True)

    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8080"))

    server = ThreadingHTTPServer((host, port), Handler)
    print(f"AssessingAgents API listening on {host}:{port}, engine at {ENGINE_DIR}")
    server.serve_forever()


if __name__ == "__main__":
    main()
