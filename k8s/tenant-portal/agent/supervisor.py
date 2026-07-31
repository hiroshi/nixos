#!/usr/bin/env python3
"""Per-tenant claude-code supervisor.

Runs as PID 1 of a tenant's claude-code pod and takes it from "empty PVC" to
"live Remote Control session" without any human on a terminal:

    logging_in -> starting -> running

`claude auth login` and `claude remote-control` are both interactive-only: they
read from stdin and (in the login case) render an Ink UI, so they have to be
driven through a pty with a real master fd to write answers back to. This module
is that driver, plus a tiny JSON API so the tenant-portal Rails app can show the
OAuth URL to the user and hand back the code they get from the browser.

API (see TenantAgentClient on the Rails side):
    GET  /status  -> {"phase": ..., "auth_url": ..., "session_url": ..., "error": ...}
    POST /code    -> body "code=<code>" or {"code": "<code>"}; accepted only
                     while phase == logging_in and an auth_url is available.

Deliberate details, each one a thing that broke during the manual experiments
that preceded this (see the repo's PR discussion for the full story):

  * The code is written to the pty as `code + b"\\r"` with NO bracketed-paste
    wrapping. `claude auth login` does not enable bracketed paste (no `?2004h`
    in its startup bytes), so the `ESC[200~` / `ESC[201~` bytes would be taken
    as literal input characters and corrupt the code, and the server answers
    400. Bracketed paste is *not* a universal fix -- it differs per subcommand
    of the same binary.

  * Enter is always a literal `\\r` (0x0D) written straight to the master fd.
    `\\n` is not recognised as submit by Ink's raw-mode input, and round-tripping
    `\\r` through a text-mode file mangles it to `\\n`, so the code never touches
    the filesystem -- it arrives over HTTP and stays in memory.

  * `~/.claude.json` is pre-seeded with the flags the first-run wizard would
    otherwise ask for interactively (theme/login/trust/remote-control dialogs),
    so `remote-control` can be started directly instead of driving a bare
    `claude` REPL through six screens first. PROMPT_RESPONSES below is the
    belt-and-braces fallback for when that isn't enough.
"""

import json
import os
import pty
import re
import select
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

HOME = os.environ.get("HOME", "/home/claude")
WORKSPACE = os.environ.get("CLAUDE_WORKSPACE", os.path.join(HOME, "workspace"))
CONFIG_PATH = os.path.join(HOME, ".claude.json")
CREDENTIALS_PATH = os.path.join(HOME, ".claude", ".credentials.json")
CAPACITY = os.environ.get("CLAUDE_CAPACITY", "4")
PORT = int(os.environ.get("PORT", "8080"))

AUTH_URL_RE = re.compile(rb"https://claude\.com/cai/oauth/authorize\?[^\s\x07\x1b\"']+")
SESSION_URL_RE = re.compile(rb"https://claude\.ai/code\?environment=[^\s\x07\x1b\"']+")
# OSC-8 hyperlinks, CSI sequences and bare ESC-prefixed pairs, so log lines and
# regex matches see plain text instead of terminal control bytes.
ANSI_RE = re.compile(rb"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[0-9A-Za-z]|\r")

# Prompts that should never appear once ~/.claude.json is seeded, but do appear
# if a future claude release adds a screen or renames a flag. Each entry fires at
# most once per child process, so a pattern that matches its own echoed answer
# can't loop.
PROMPT_RESPONSES = [
    (re.compile(rb"Enable Remote Control\?", re.I), b"y\r"),
    (re.compile(rb"I trust this folder", re.I), b"\r"),
    (re.compile(rb"full-screen renderer", re.I), b"\r"),
]

state_lock = threading.Lock()
state = {
    "phase": "starting",
    "auth_url": None,
    "session_url": None,
    "error": None,
    "code": None,
}


def set_state(**kwargs):
    with state_lock:
        state.update(kwargs)


def get_state():
    with state_lock:
        return dict(state)


def clean(raw: bytes) -> bytes:
    return ANSI_RE.sub(b"", raw)


def log(message: str):
    print(f"[supervisor] {message}", flush=True)


class Redactor:
    """Keeps the pasted OAuth code out of the pod log.

    The pty's slave side has ECHO on, so anything written to the master comes
    back out in the child's output stream -- including the code.
    """

    def __init__(self):
        self._secrets = []

    def add(self, secret: str):
        if secret and len(secret) >= 8:
            self._secrets.append(secret.encode())

    def apply(self, data: bytes) -> bytes:
        for secret in self._secrets:
            data = data.replace(secret, b"<redacted>")
        return data


class PtySession:
    """A child process on a pty, with line-buffered logging of its output."""

    def __init__(self, argv, redactor, label):
        self.argv = argv
        self.redactor = redactor
        self.label = label
        self.buf = b""
        self._log_buf = b""
        self._fired = set()
        self.master, slave = pty.openpty()
        log(f"starting {label}: {' '.join(argv)}")
        self.proc = subprocess.Popen(
            argv,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            cwd=WORKSPACE,
            start_new_session=True,
            close_fds=True,
        )
        os.close(slave)

    def send(self, data: bytes):
        os.write(self.master, data)

    def pump(self, timeout=0.5) -> bool:
        """Read whatever is available. Returns False once the child is gone."""
        readable, _, _ = select.select([self.master], [], [], timeout)
        if readable:
            try:
                chunk = os.read(self.master, 4096)
            except OSError:
                chunk = b""
            if chunk:
                self.buf += chunk
                self._emit(chunk)
            elif self.proc.poll() is not None:
                return False
        return self.proc.poll() is None or bool(readable)

    def _emit(self, chunk: bytes):
        self._log_buf += chunk
        while b"\n" in self._log_buf:
            line, self._log_buf = self._log_buf.split(b"\n", 1)
            line = self.redactor.apply(clean(line)).strip()
            if line:
                print(f"[{self.label}] {line.decode(errors='replace')}", flush=True)

    def answer_prompts(self):
        text = clean(self.buf)
        for index, (pattern, response) in enumerate(PROMPT_RESPONSES):
            if index in self._fired or not pattern.search(text):
                continue
            self._fired.add(index)
            log(f"{self.label}: auto-answering prompt /{pattern.pattern.decode()}/")
            self.send(response)

    def search(self, pattern):
        match = pattern.search(clean(self.buf))
        return match.group(0).decode() if match else None

    def terminate(self):
        if self.proc.poll() is None:
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                self.proc.terminate()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        try:
            os.close(self.master)
        except OSError:
            pass


def credentials_exist() -> bool:
    return os.path.exists(CREDENTIALS_PATH)


def claude_version() -> str:
    try:
        out = subprocess.run(
            ["claude", "--version"], capture_output=True, text=True, timeout=60
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    match = re.search(r"\d+\.\d+\.\d+", out)
    return match.group(0) if match else ""


def seed_config():
    """Write the flags the first-run wizard would otherwise ask for.

    Only keys observed in a real post-onboarding ~/.claude.json are written:
    `hasCompletedOnboarding` (theme + login-method screens),
    `remoteDialogSeen` (the `Enable Remote Control? (y/n)` prompt),
    `lastOnboardingVersion` (re-runs onboarding when it lags the binary) and
    per-project `hasTrustDialogAccepted` (the "Accessing workspace" dialog).
    """
    config = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH) as handle:
                config = json.load(handle)
        except (OSError, ValueError):
            log(f"{CONFIG_PATH} unreadable, recreating it")
            config = {}
    if not isinstance(config, dict):
        config = {}

    config["hasCompletedOnboarding"] = True
    config["remoteDialogSeen"] = True
    version = claude_version()
    if version:
        config["lastOnboardingVersion"] = version
    projects = config.setdefault("projects", {})
    if not isinstance(projects, dict):
        projects = config["projects"] = {}
    project = projects.setdefault(WORKSPACE, {})
    project["hasTrustDialogAccepted"] = True

    tmp_path = CONFIG_PATH + ".tmp"
    with open(tmp_path, "w") as handle:
        json.dump(config, handle, indent=2)
    os.replace(tmp_path, CONFIG_PATH)
    log(f"seeded {CONFIG_PATH} (claude {version or 'unknown'})")


def do_login() -> bool:
    """Drive `claude auth login` to completion. True once credentials exist."""
    set_state(phase="logging_in", auth_url=None, session_url=None, code=None)
    redactor = Redactor()
    session = PtySession(["claude", "auth", "login"], redactor, "auth-login")
    code_sent = False
    try:
        while True:
            alive = session.pump()
            if not get_state()["auth_url"]:
                url = session.search(AUTH_URL_RE)
                if url:
                    log("captured OAuth URL")
                    set_state(auth_url=url)
            if not code_sent:
                code = get_state()["code"]
                if code:
                    redactor.add(code)
                    session.send(code.encode() + b"\r")
                    code_sent = True
                    log("submitted code to auth login")
            session.answer_prompts()
            if not alive and session.proc.poll() is not None:
                break
    finally:
        session.terminate()

    if credentials_exist():
        log("login succeeded")
        return True
    text = clean(session.buf).decode(errors="replace")
    reason = "認証に失敗しました。もう一度お試しください。"
    if "status code 400" in text or "Login failed" in text:
        reason = "code が正しくないようです。新しい URL でやり直してください。"
    log(f"login did not produce credentials (exit={session.proc.poll()})")
    set_state(error=reason, auth_url=None, code=None)
    return False


def run_remote_control():
    """Run `claude remote-control` and stay in it until it dies."""
    set_state(phase="starting", session_url=None)
    session = PtySession(
        ["claude", "remote-control", f"--capacity={CAPACITY}"],
        Redactor(),
        "remote-control",
    )
    try:
        while True:
            alive = session.pump()
            session.answer_prompts()
            if not get_state()["session_url"]:
                url = session.search(SESSION_URL_RE)
                if url:
                    log("remote control connected")
                    set_state(phase="running", session_url=url, error=None)
            if not alive and session.proc.poll() is not None:
                break
    finally:
        session.terminate()
    log(f"remote-control exited (exit={session.proc.poll()})")
    set_state(phase="starting", session_url=None)


def supervise():
    os.makedirs(WORKSPACE, exist_ok=True)
    while True:
        if not credentials_exist():
            if not do_login():
                time.sleep(2)
                continue
        seed_config()
        run_remote_control()
        # remote-control exiting is not fatal (network blip, session ended, a
        # revoked token): loop back around, re-running login only if the
        # credentials are actually gone.
        time.sleep(2)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _respond(self, status: int, payload: dict):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path not in ("/status", "/"):
            self._respond(404, {"error": "not found"})
            return
        current = get_state()
        self._respond(
            200,
            {
                "phase": current["phase"],
                "auth_url": current["auth_url"],
                "session_url": current["session_url"],
                "error": current["error"],
                "awaiting_code": current["phase"] == "logging_in"
                and bool(current["auth_url"])
                and not current["code"],
            },
        )

    def do_POST(self):
        if self.path != "/code":
            self._respond(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        code = None
        if self.headers.get("Content-Type", "").startswith("application/json"):
            try:
                code = (json.loads(raw or b"{}") or {}).get("code")
            except ValueError:
                code = None
        else:
            values = parse_qs(raw.decode(errors="replace")).get("code")
            code = values[0] if values else None
        code = (code or "").strip()
        if not code:
            self._respond(400, {"error": "code is required"})
            return
        with state_lock:
            if state["phase"] != "logging_in" or not state["auth_url"]:
                self._respond(409, {"error": f"not awaiting a code (phase={state['phase']})"})
                return
            if state["code"]:
                self._respond(409, {"error": "a code was already submitted"})
                return
            state["code"] = code
            state["error"] = None
        log("received code from portal")
        self._respond(202, {"phase": "logging_in"})

    def log_message(self, fmt, *args):
        pass


def main():
    threading.Thread(target=supervise, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log(f"listening on :{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
