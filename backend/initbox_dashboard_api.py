#!/usr/bin/env python3
"""InitBox React dashboard API.

This service intentionally uses only the Python standard library so the Pi can run
it offline without pip/npm runtime dependencies.
"""
from __future__ import annotations

import base64
import errno
import hashlib
import hmac
import http.cookies
import json
import mimetypes
import os
import secrets
import shutil
import socket
import subprocess
import threading
import time
import urllib.parse
import zipfile
from email import policy
from email.parser import BytesParser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

HOST = os.environ.get("INITBOX_DASHBOARD_HOST", "0.0.0.0")
PORT = int(os.environ.get("INITBOX_DASHBOARD_PORT", "8080"))
UI_DIR = Path(os.environ.get("INITBOX_DASHBOARD_UI_DIR", "/opt/initbox-dashboard/ui"))
AUTH_FILE = Path(os.environ.get("INITBOX_DASHBOARD_AUTH_FILE", "/etc/initbox/dashboard-auth.env"))
ROLE_FILE = Path(os.environ.get("ROLE_FILE", "/etc/pi_roles.conf"))
MODS_FILE = Path(os.environ.get("MODS_FILE", "/etc/initbox/dashboard-modules.env"))
ARCHIVE_DIR = Path(os.environ.get("INITBOX_ARCHIVE_DIR", "/tmp/initbox-dashboard-archives"))
ARCHIVE_FILE = ARCHIVE_DIR / "initbox-tracefiles.zip"
TRACE_DIR = Path(os.environ.get("INITBOX_TRACE_DIR", "/usr/tracefiles"))
CAN_TRC_UPLOAD_TARGET = Path(os.environ.get("INITBOX_CAN_TRC_UPLOAD_TARGET", "/usr/local/bin/CAN.trc"))
SESSION_COOKIE = "initbox_session"
SESSION_TTL_SECONDS = int(os.environ.get("INITBOX_SESSION_TTL_SECONDS", "43200"))
MAX_LOG_LINES = 400
MAX_ARCHIVE_FILE_BYTES = int(os.environ.get("INITBOX_MAX_ARCHIVE_FILE_BYTES", str(250 * 1024 * 1024)))
MAX_UPLOAD_FILE_BYTES = int(os.environ.get("INITBOX_MAX_UPLOAD_FILE_BYTES", str(250 * 1024 * 1024)))
SERVICE_STATUS_TIMEOUT_SECONDS = int(os.environ.get("INITBOX_SERVICE_STATUS_TIMEOUT_SECONDS", "3"))
STATS_TIMEOUT_SECONDS = int(os.environ.get("INITBOX_STATS_TIMEOUT_SECONDS", "5"))
LOG_TIMEOUT_SECONDS = int(os.environ.get("INITBOX_LOG_TIMEOUT_SECONDS", "10"))
STATUS_CACHE_TTL_SECONDS = float(os.environ.get("INITBOX_STATUS_CACHE_TTL_SECONDS", "2"))
FILE_SEND_CHUNK_BYTES = 1024 * 1024

_LOGIN_MAX_ATTEMPTS = 5
_LOGIN_WINDOW_SECONDS = 300
_LOGIN_LOCKOUT_SECONDS = 600

_login_lock = threading.Lock()
_login_attempts: dict[str, list[float]] = {}
_login_locked: dict[str, float] = {}

_status_cache_lock = threading.Lock()
_status_cache: dict[str, tuple[float, Any]] = {}

SERVICE_MAP = {
    "dashboard": "initbox-dashboard.service",
    "portal": "portal.service",
    "ttyd": "ttyd.service",
    "servsync": "pi-servsync.service",
    "isi": "isirunall.service",
    "sniffer": "wireshark-autostart.service",
    "bridge": "bridge-check.service",
    "fms": "fms.service",
    "hotspot": "hostapd.service",
    "dnsmasq": "dnsmasq.service",
    "rtc": "rtc-sync.service",
}

ALLOWED_ROLES = {"isi", "fms", "sniff", "wireshark", "sniffer", "sniffer-bridge", "ethsniffer"}

FILE_AREAS = {
    "trace": TRACE_DIR,
    "bin": Path("/usr/local/bin"),
}

TRACE_ARCHIVE_SUFFIXES = (".pcap", ".pcapng", ".pcap.gz", ".pcapng.gz")
TRACE_LIST_SUFFIXES = TRACE_ARCHIVE_SUFFIXES + (".zip",)

_CSP = (
    "default-src 'self'; "
    "script-src 'self'; "
    "style-src 'self' 'unsafe-inline'; "
    "img-src 'self' data:; "
    "font-src 'self'; "
    "connect-src 'self'; "
    "frame-src 'self' http://localhost:7681 http://*.wlan:7681; "
    "object-src 'none'; "
    "base-uri 'self';"
)


def _login_check(ip: str) -> bool:
    now = time.time()
    with _login_lock:
        expiry = _login_locked.get(ip, 0)
        if now < expiry:
            return False
        window_start = now - _LOGIN_WINDOW_SECONDS
        attempts = [t for t in _login_attempts.get(ip, []) if t >= window_start]
        _login_attempts[ip] = attempts
        return True


def _login_record_failure(ip: str) -> None:
    now = time.time()
    with _login_lock:
        attempts = _login_attempts.get(ip, [])
        attempts.append(now)
        _login_attempts[ip] = attempts
        if len(attempts) >= _LOGIN_MAX_ATTEMPTS:
            _login_locked[ip] = now + _LOGIN_LOCKOUT_SECONDS
            _login_attempts[ip] = []


def _login_record_success(ip: str) -> None:
    with _login_lock:
        _login_attempts.pop(ip, None)
        _login_locked.pop(ip, None)


def run_cmd(args: list[str], timeout: int = 15) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=False)
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "command timed out"
    except FileNotFoundError as exc:
        return 127, "", str(exc)


def read_env(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data

    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip("'").strip('"')
        data[key.strip()] = value

    return data


def parse_roles() -> list[str]:
    env = read_env(ROLE_FILE)
    role_text = env.get("ROLES", env.get("roles", ""))
    return [item for item in role_text.lower().replace("\r", " ").split() if item]


def write_roles(roles: list[str]) -> None:
    clean: list[str] = []
    for role in roles:
        role = role.strip().lower()
        if role in ALLOWED_ROLES and role not in clean:
            clean.append(role)

    ROLE_FILE.parent.mkdir(parents=True, exist_ok=True)
    ROLE_FILE.write_text(f'ROLES="{" ".join(clean)}"\n', encoding="utf-8")
    os.chmod(ROLE_FILE, 0o664)


def service_state(unit: str) -> dict[str, str]:
    rc, out, err = run_cmd(
        ["systemctl", "show", unit, "--property=ActiveState", "--property=UnitFileState", "--value"],
        timeout=SERVICE_STATUS_TIMEOUT_SECONDS,
    )

    if rc != 0:
        return {"unit": unit, "active": "unknown", "enabled": "unknown", "error": err or out or f"systemctl failed: {rc}"}

    lines = out.splitlines()
    active = lines[0].strip() if len(lines) >= 1 and lines[0].strip() else "unknown"
    enabled = lines[1].strip() if len(lines) >= 2 and lines[1].strip() else "unknown"
    return {"unit": unit, "active": active, "enabled": enabled}


def all_service_status() -> dict[str, dict[str, str]]:
    return {name: service_state(unit) for name, unit in SERVICE_MAP.items()}


def cached_all_service_status() -> dict[str, dict[str, str]]:
    now = time.time()
    with _status_cache_lock:
        cached = _status_cache.get("services")
        if cached and now - cached[0] <= STATUS_CACHE_TTL_SECONDS:
            return cached[1]

    data = all_service_status()

    with _status_cache_lock:
        _status_cache["services"] = (now, data)

    return data


def read_stats() -> dict[str, Any]:
    helper = "/usr/local/bin/pi-stats.sh"
    if not Path(helper).exists():
        return {"error": "pi-stats.sh not installed"}

    rc, out, err = run_cmd([helper], timeout=STATS_TIMEOUT_SECONDS)
    if rc != 0:
        return {"error": err or out or f"pi-stats.sh failed: {rc}"}

    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {"error": "invalid stats JSON", "raw": out[:500]}


def cached_read_stats() -> dict[str, Any]:
    now = time.time()
    with _status_cache_lock:
        cached = _status_cache.get("stats")
        if cached and now - cached[0] <= STATUS_CACHE_TTL_SECONDS:
            return cached[1]

    data = read_stats()

    with _status_cache_lock:
        _status_cache["stats"] = (now, data)

    return data


def auth_config() -> dict[str, str]:
    data = read_env(AUTH_FILE)
    return {
        "user": data.get("INITBOX_DASHBOARD_USER", "initbox"),
        "salt": data.get("INITBOX_DASHBOARD_PASSWORD_SALT", ""),
        "hash": data.get("INITBOX_DASHBOARD_PASSWORD_SHA256", ""),
        "secret": data.get("INITBOX_DASHBOARD_SESSION_SECRET", ""),
    }


def verify_password(username: str, password: str) -> bool:
    cfg = auth_config()
    if username != cfg["user"] or not cfg["salt"] or not cfg["hash"]:
        return False

    digest = hashlib.sha256((cfg["salt"] + password).encode("utf-8")).hexdigest()
    return hmac.compare_digest(digest, cfg["hash"])


def sign_session(username: str, now: int | None = None) -> str:
    cfg = auth_config()
    ts = str(now or int(time.time()))
    nonce = secrets.token_hex(8)
    payload = f"{username}:{ts}:{nonce}"
    sig = hmac.new(cfg["secret"].encode("utf-8"), payload.encode("utf-8"), hashlib.sha256).hexdigest()
    return base64.urlsafe_b64encode(f"{payload}:{sig}".encode("utf-8")).decode("ascii")


def verify_session(token: str) -> bool:
    cfg = auth_config()
    if not token or not cfg["secret"]:
        return False

    try:
        decoded = base64.urlsafe_b64decode(token.encode("ascii")).decode("utf-8")
        username, ts_text, nonce, sig = decoded.rsplit(":", 3)
        ts = int(ts_text)
    except Exception:
        return False

    if int(time.time()) - ts > SESSION_TTL_SECONDS:
        return False

    payload = f"{username}:{ts_text}:{nonce}"
    expected = hmac.new(cfg["secret"].encode("utf-8"), payload.encode("utf-8"), hashlib.sha256).hexdigest()
    return hmac.compare_digest(sig, expected)


def json_bytes(value: Any) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def safe_static_path(url_path: str) -> Path | None:
    rel = urllib.parse.unquote(url_path.lstrip("/")) or "index.html"
    if rel == "ui" or rel.startswith("ui/"):
        rel = rel[3:].lstrip("/") or "index.html"

    target = (UI_DIR / rel).resolve()

    try:
        target.relative_to(UI_DIR.resolve())
    except ValueError:
        return None

    if target.is_dir():
        target = target / "index.html"

    if not target.exists():
        target = UI_DIR / "index.html"

    return target


def safe_file_area(area: str) -> Path | None:
    root = FILE_AREAS.get(area)
    if root is None:
        return None
    return root


def file_has_suffix(path: Path, suffixes: tuple[str, ...]) -> bool:
    name = path.name.lower()
    return any(name.endswith(suffix) for suffix in suffixes)


def trace_file_allowed(path: Path, include_zip: bool = False) -> bool:
    suffixes = TRACE_LIST_SUFFIXES if include_zip else TRACE_ARCHIVE_SUFFIXES
    return file_has_suffix(path, suffixes)


def bin_file_allowed(path: Path) -> bool:
    return path.name.lower() == "can.trc" or path.name.lower().endswith(".trc")


def add_trace_files_to_zip(zip_handle: zipfile.ZipFile) -> tuple[int, int]:
    file_count = 0
    byte_count = 0

    if not TRACE_DIR.exists():
        return file_count, byte_count

    for item in sorted(TRACE_DIR.iterdir(), key=lambda p: p.name.lower()):
        if not item.is_file() or not trace_file_allowed(item, include_zip=False):
            continue

        try:
            stat = item.stat()
        except OSError:
            continue

        if stat.st_size > MAX_ARCHIVE_FILE_BYTES:
            continue

        zip_handle.write(item, item.name)
        file_count += 1
        byte_count += stat.st_size

    return file_count, byte_count


def latest_trace_zip() -> Path | None:
    """Return the newest InitBox ZIP stored in /usr/tracefiles."""
    if not TRACE_DIR.exists():
        return None

    candidates = [
        item for item in TRACE_DIR.iterdir()
        if item.is_file() and item.name.lower().startswith("initbox_") and item.name.lower().endswith(".zip")
    ]

    if not candidates:
        return None

    return max(candidates, key=lambda item: item.stat().st_mtime)


def trace_capture_candidates() -> list[Path]:
    """Return all packet-capture files that must be archived and then removed."""
    if not TRACE_DIR.exists():
        return []

    candidates: list[Path] = []
    for item in TRACE_DIR.iterdir():
        if not item.is_file():
            continue
        if trace_file_allowed(item, include_zip=False):
            candidates.append(item)

    return sorted(candidates, key=lambda item: item.name.lower())


def delete_trace_zips() -> list[str]:
    deleted: list[str] = []
    if not TRACE_DIR.exists():
        return deleted

    for item in sorted(TRACE_DIR.iterdir(), key=lambda p: p.name.lower()):
        if not item.is_file():
            continue
        if not (item.name.lower().startswith("initbox_") and item.name.lower().endswith(".zip")):
            continue
        try:
            item.unlink()
            deleted.append(item.name)
        except OSError:
            continue

    return deleted


def delete_trace_captures() -> list[str]:
    deleted: list[str] = []
    for item in trace_capture_candidates():
        try:
            item.unlink()
            deleted.append(item.name)
        except OSError:
            continue

    return deleted


def service_action(unit: str, action: str, timeout: int = 20) -> dict[str, Any]:
    rc, out, err = run_cmd(["systemctl", action, unit], timeout=timeout)
    return {"ok": rc == 0, "rc": rc, "output": out or err}


def kill_leftover_tshark() -> list[str]:
    """Stop tshark processes that are still writing under /usr/tracefiles."""
    killed: list[str] = []
    rc, out, _ = run_cmd(["pgrep", "-f", f"tshark.*{TRACE_DIR}"], timeout=5)
    if rc != 0 or not out:
        return killed

    for line in out.splitlines():
        pid = line.strip()
        if not pid.isdigit() or pid == str(os.getpid()):
            continue
        run_cmd(["kill", pid], timeout=5)
        killed.append(pid)

    time.sleep(1)

    rc, out, _ = run_cmd(["pgrep", "-f", f"tshark.*{TRACE_DIR}"], timeout=5)
    if rc != 0 or not out:
        return killed

    for line in out.splitlines():
        pid = line.strip()
        if not pid.isdigit() or pid == str(os.getpid()):
            continue
        run_cmd(["kill", "-9", pid], timeout=5)
        killed.append(f"{pid}:SIGKILL")

    return killed


def read_boxno() -> str:
    raw = Path("/etc/pi-boxno").read_text(encoding="utf-8", errors="replace").strip() if Path("/etc/pi-boxno").exists() else "1"
    if raw and all(ch.isalnum() or ch in "_-" for ch in raw):
        return raw
    return "1"


def prepare_archive(_areas: list[str] | None = None) -> dict[str, Any]:
    """Prepare a trace ZIP and enforce the required /usr/tracefiles lifecycle.

    Required final states:
      - After prepare: one new ZIP plus one newly restarted live PCAP.
      - After download: the ZIP is deleted, leaving only the live PCAP.

    This backend performs the cleanup directly so the dashboard cannot bypass
    the lifecycle by creating a separate archive somewhere else.
    """
    TRACE_DIR.mkdir(parents=True, exist_ok=True)

    unit = SERVICE_MAP["sniffer"]
    stop_result = service_action(unit, "stop", timeout=30)
    killed_pids = kill_leftover_tshark()
    time.sleep(1)

    deleted_old_zips = delete_trace_zips()
    files = trace_capture_candidates()

    boxno = read_boxno()
    stamp = time.strftime("%Y%m%d%H%M%S")
    archive_path = TRACE_DIR / f"initbox_{boxno}_{stamp}.zip"

    total_files = 0
    total_bytes = 0

    if files:
        with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as zip_handle:
            for item in files:
                try:
                    stat = item.stat()
                except OSError:
                    continue

                if stat.st_size > MAX_ARCHIVE_FILE_BYTES:
                    continue

                zip_handle.write(item, item.name)
                total_files += 1
                total_bytes += stat.st_size

        os.chmod(archive_path, 0o664)

    deleted_captures = delete_trace_captures()
    start_result = service_action(unit, "start", timeout=30)
    time.sleep(2)

    archive_size = archive_path.stat().st_size if archive_path.exists() else 0

    return {
        "ok": True,
        "name": archive_path.name if archive_path.exists() else "",
        "path": str(archive_path) if archive_path.exists() else "",
        "size": archive_size,
        "files": total_files,
        "sourceBytes": total_bytes,
        "source": str(TRACE_DIR),
        "stopped": stop_result,
        "started": start_result,
        "killedTsharkPids": killed_pids,
        "deletedOldZips": deleted_old_zips,
        "deletedCaptures": deleted_captures,
    }

def parse_multipart_file(content_type: str, body: bytes) -> tuple[str, bytes]:
    message_bytes = (
        f"Content-Type: {content_type}\r\n"
        "MIME-Version: 1.0\r\n"
        "\r\n"
    ).encode("utf-8") + body

    message = BytesParser(policy=policy.default).parsebytes(message_bytes)

    if not message.is_multipart():
        raise ValueError("request is not multipart/form-data")

    for part in message.iter_parts():
        disposition = part.get("Content-Disposition", "")
        if "form-data" not in disposition:
            continue

        field_name = part.get_param("name", header="content-disposition")
        if field_name != "file":
            continue

        filename = part.get_filename() or ""
        payload = part.get_payload(decode=True) or b""

        if not filename:
            raise ValueError("missing upload filename")

        if not payload:
            raise ValueError("uploaded file is empty")

        return Path(filename).name, payload

    raise ValueError("missing uploaded file field")


def save_can_trc_upload(original_filename: str, payload: bytes) -> dict[str, Any]:
    clean_name = Path(original_filename).name

    if clean_name.lower() != "can.trc":
        raise ValueError("only CAN.trc may be uploaded")

    if len(payload) > MAX_UPLOAD_FILE_BYTES:
        raise ValueError("uploaded file is too large")

    target = CAN_TRC_UPLOAD_TARGET.resolve()
    allowed_target = Path("/usr/local/bin/CAN.trc").resolve()

    if target != allowed_target:
        raise ValueError("upload target is not allowed")

    target.parent.mkdir(parents=True, exist_ok=True)

    temp_path = target.with_name(f".{target.name}.upload-{secrets.token_hex(8)}")
    temp_path.write_bytes(payload)
    os.chmod(temp_path, 0o664)
    os.replace(temp_path, target)

    stat = target.stat()
    return {
        "name": target.name,
        "path": str(target),
        "size": stat.st_size,
        "mtime": int(stat.st_mtime),
    }


def client_disconnected(exc: BaseException) -> bool:
    if isinstance(exc, (BrokenPipeError, ConnectionResetError, ConnectionAbortedError)):
        return True

    if isinstance(exc, OSError) and exc.errno in {errno.EPIPE, errno.ECONNRESET, errno.ECONNABORTED}:
        return True

    return False


class DashboardHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    block_on_close = False


class Handler(BaseHTTPRequestHandler):
    server_version = "InitBoxDashboard/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def log_error(self, fmt: str, *args: Any) -> None:
        return

    def handle_one_request(self) -> None:
        try:
            super().handle_one_request()
        except Exception as exc:
            if client_disconnected(exc):
                return
            raise

    def _safe_write(self, body: bytes) -> bool:
        try:
            self.wfile.write(body)
            return True
        except Exception as exc:
            if client_disconnected(exc):
                return False
            raise

    def _safe_send_body_response(
        self,
        body: bytes,
        status: int,
        content_type: str,
        extra_headers: dict[str, str] | None = None,
    ) -> bool:
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            if extra_headers:
                for key, value in extra_headers.items():
                    self.send_header(key, value)
            self._add_security_headers()
            self.end_headers()
            return self._safe_write(body)
        except Exception as exc:
            if client_disconnected(exc):
                return False
            raise

    def _add_security_headers(self) -> None:
        self.send_header("Content-Security-Policy", _CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "SAMEORIGIN")
        self.send_header("Referrer-Policy", "same-origin")

    def send_json(self, value: Any, status: int = 200) -> None:
        body = json_bytes(value)
        self._safe_send_body_response(body, status, "application/json; charset=utf-8")

    def send_file(self, path: Path, filename: str | None = None, delete_after: bool = False) -> None:
        if not path.exists() or not path.is_file():
            self.send_json({"ok": False, "error": "file not found"}, status=404)
            return

        content_type = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        size = path.stat().st_size
        sent_ok = False

        try:
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(size))
            if filename:
                self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
            self._add_security_headers()
            self.end_headers()

            with path.open("rb") as file_handle:
                while True:
                    chunk = file_handle.read(FILE_SEND_CHUNK_BYTES)
                    if not chunk:
                        break
                    if not self._safe_write(chunk):
                        return

            sent_ok = True
        except Exception as exc:
            if client_disconnected(exc):
                return
            raise
        finally:
            if delete_after and sent_ok:
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass
                except OSError:
                    pass

    def read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(min(length, 1024 * 1024))
        return json.loads(raw.decode("utf-8"))

    def read_limited_body(self, max_bytes: int) -> bytes | None:
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            self.send_json({"ok": False, "error": "invalid content length"}, status=400)
            return None

        if length <= 0:
            self.send_json({"ok": False, "error": "empty request body"}, status=400)
            return None

        if length > max_bytes:
            self.send_json({"ok": False, "error": "uploaded file is too large"}, status=HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
            return None

        return self.rfile.read(length)

    def cookie_value(self, name: str) -> str:
        cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        morsel = cookie.get(name)
        return morsel.value if morsel else ""

    def client_ip(self) -> str:
        return self.client_address[0] if self.client_address else "unknown"

    def authenticated(self) -> bool:
        return verify_session(self.cookie_value(SESSION_COOKIE))

    def require_auth(self) -> bool:
        if self.authenticated():
            return True
        self.send_json({"ok": False, "error": "unauthorized"}, status=HTTPStatus.UNAUTHORIZED)
        return False

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        if path == "/api/health":
            self.send_json({"ok": True, "service": "initbox-dashboard"})
            return

        if path == "/api/session":
            self.send_json({"authenticated": self.authenticated(), "user": auth_config()["user"]})
            return

        if path.startswith("/api/") and not self.require_auth():
            return

        if path == "/api/status":
            roles = parse_roles()
            self.send_json({
                "ok": True,
                "hostname": socket.gethostname(),
                "roles": roles,
                "moduleFlags": read_env(MODS_FILE),
                "services": cached_all_service_status(),
                "stats": cached_read_stats(),
                "ttydUrl": "/terminal/",
            })
            return

        if path == "/api/logs":
            unit = qs.get("unit", ["initbox-dashboard.service"])[0]
            lines = qs.get("lines", ["120"])[0]

            try:
                line_count = max(1, min(MAX_LOG_LINES, int(lines)))
            except ValueError:
                line_count = 120

            allowed_units = set(SERVICE_MAP.values()) | {
                "initbox-dashboard.service",
                "portal.service",
                "ttyd.service",
                "pi-servsync.service",
            }

            if unit not in allowed_units:
                self.send_json({"ok": False, "error": "unit not allowed"}, status=400)
                return

            rc, out, err = run_cmd(["journalctl", "-u", unit, "-n", str(line_count), "--no-pager"], timeout=LOG_TIMEOUT_SECONDS)
            self.send_json({"ok": rc == 0, "unit": unit, "output": out or err})
            return

        if path == "/api/files":
            area = qs.get("area", ["trace"])[0]
            root = safe_file_area(area)

            if root is None:
                self.send_json({"ok": False, "error": "area not allowed"}, status=400)
                return

            items = []
            if root.exists():
                for item in sorted(root.iterdir(), key=lambda p: p.name.lower())[:200]:
                    if not item.is_file():
                        continue

                    if area == "trace" and not trace_file_allowed(item, include_zip=True):
                        continue

                    if area == "bin" and not bin_file_allowed(item):
                        continue

                    try:
                        st = item.stat()
                    except OSError:
                        continue

                    items.append({
                        "name": item.name,
                        "type": "file",
                        "size": st.st_size,
                        "mtime": int(st.st_mtime),
                    })

            self.send_json({"ok": True, "area": area, "items": items})
            return

        if path == "/api/archive/download":
            archive_path = latest_trace_zip()
            if archive_path is None:
                self.send_json({"ok": False, "error": "no trace ZIP prepared"}, status=404)
                return

            self.send_file(archive_path, archive_path.name, delete_after=True)
            return

        target = safe_static_path(path)
        if target is None or not target.exists():
            self.send_error(404)
            return

        body = target.read_bytes()
        content_type = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        if target.suffix == ".js":
            content_type = "application/javascript; charset=utf-8"
        elif target.suffix == ".css":
            content_type = "text/css; charset=utf-8"
        elif target.suffix == ".html":
            content_type = "text/html; charset=utf-8"

        self._safe_send_body_response(body, 200, content_type)

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/api/login":
            ip = self.client_ip()
            if not _login_check(ip):
                self.send_json({"ok": False, "error": "too many login attempts; try again later"}, status=429)
                return

            try:
                body = self.read_json()
            except Exception:
                self.send_json({"ok": False, "error": "invalid JSON"}, status=400)
                return

            username = str(body.get("username", ""))
            password = str(body.get("password", ""))

            if not verify_password(username, password):
                _login_record_failure(ip)
                self.send_json({"ok": False, "error": "invalid credentials"}, status=403)
                return

            _login_record_success(ip)
            token = sign_session(username)
            body_bytes = json_bytes({"ok": True, "user": username})

            self._safe_send_body_response(
                body_bytes,
                200,
                "application/json; charset=utf-8",
                {"Set-Cookie": f"{SESSION_COOKIE}={token}; Path=/; HttpOnly; SameSite=Lax; Max-Age={SESSION_TTL_SECONDS}"},
            )
            return

        if path == "/api/logout":
            body_bytes = json_bytes({"ok": True})
            self._safe_send_body_response(
                body_bytes,
                200,
                "application/json; charset=utf-8",
                {"Set-Cookie": f"{SESSION_COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"},
            )
            return

        if not self.require_auth():
            return

        if path == "/api/files/upload-can-trc":
            content_type = self.headers.get("Content-Type", "")
            if not content_type.lower().startswith("multipart/form-data"):
                self.send_json({"ok": False, "error": "expected multipart/form-data"}, status=400)
                return

            raw_body = self.read_limited_body(MAX_UPLOAD_FILE_BYTES + 1024 * 1024)
            if raw_body is None:
                return

            try:
                original_filename, payload = parse_multipart_file(content_type, raw_body)
                uploaded = save_can_trc_upload(original_filename, payload)
            except ValueError as exc:
                self.send_json({"ok": False, "error": str(exc)}, status=400)
                return
            except OSError as exc:
                self.send_json({"ok": False, "error": f"failed to save CAN.trc: {exc}"}, status=500)
                return

            self.send_json({
                "ok": True,
                "message": "CAN.trc uploaded to /usr/local/bin/CAN.trc",
                "file": uploaded,
            })
            return

        if path == "/api/roles":
            body = self.read_json()
            roles = body.get("roles", [])
            if not isinstance(roles, list):
                self.send_json({"ok": False, "error": "roles must be a list"}, status=400)
                return

            write_roles([str(r) for r in roles])
            rc, out, err = run_cmd(["/usr/local/bin/pi-servsync.sh", "apply"], timeout=30)
            self.send_json({"ok": rc == 0, "roles": parse_roles(), "output": out or err})
            return

        if path == "/api/service-action":
            body = self.read_json()
            service = str(body.get("service", ""))
            action = str(body.get("action", ""))

            if service not in SERVICE_MAP:
                self.send_json({"ok": False, "error": "unknown service"}, status=400)
                return

            unit = SERVICE_MAP[service]
            if action == "restart":
                cmd = ["systemctl", "restart", unit]
            elif action == "enable-now":
                cmd = ["systemctl", "enable", "--now", unit]
            elif action == "disable-now":
                cmd = ["systemctl", "disable", "--now", unit]
            else:
                self.send_json({"ok": False, "error": "unknown action"}, status=400)
                return

            rc, out, err = run_cmd(cmd, timeout=30)
            self.send_json({
                "ok": rc == 0,
                "service": service,
                "unit": unit,
                "output": out or err,
                "state": service_state(unit),
            })
            return

        if path == "/api/system-action":
            body = self.read_json()
            action = str(body.get("action", ""))

            if action == "reboot":
                subprocess.Popen(["systemctl", "reboot"])
                self.send_json({"ok": True, "message": "Reboot command submitted"})
                return

            if action == "shutdown":
                subprocess.Popen(["systemctl", "poweroff"])
                self.send_json({"ok": True, "message": "Shutdown command submitted"})
                return

            self.send_json({"ok": False, "error": "unknown system action"}, status=400)
            return

        if path == "/api/archive/prepare":
            # Ignore client-supplied areas deliberately. The ZIP action is only
            # for ws-br0 packet captures from /usr/tracefiles.
            archive = prepare_archive()
            if not archive.get("ok", False):
                self.send_json({
                    "ok": False,
                    "message": "Trace ZIP preparation failed",
                    "archive": archive,
                }, status=500)
                return

            self.send_json({
                "ok": True,
                "message": "Trace ZIP prepared from /usr/tracefiles",
                "archive": archive,
            })
            return

        self.send_json({"ok": False, "error": "not found"}, status=404)


def main() -> None:
    if not AUTH_FILE.exists():
        print(f"Auth file missing: {AUTH_FILE}", flush=True)

    UI_DIR.mkdir(parents=True, exist_ok=True)
    ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)

    httpd = DashboardHTTPServer((HOST, PORT), Handler)
    print(f"InitBox dashboard API serving {UI_DIR} on {HOST}:{PORT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
