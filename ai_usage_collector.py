#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo


APP_ID = "AIUsageMenuBar"
SCHEMA_VERSION = 1
KNOWN_PROVIDERS = ("claude", "codex")

APP_SUPPORT_DIR = Path.home() / "Library" / "Application Support" / APP_ID
CONFIG_PATH = APP_SUPPORT_DIR / "config.json"
CACHE_PATH = APP_SUPPORT_DIR / "usage.json"
LOG_DIR = APP_SUPPORT_DIR / "logs"
LOG_PATH = LOG_DIR / "collector.log"
DEBUG_DIR = APP_SUPPORT_DIR / "debug"
WORKDIR_PATH = APP_SUPPORT_DIR / "workdir"
LOCK_PATH = APP_SUPPORT_DIR / "collector.lock"

DEFAULT_CONFIG: dict[str, Any] = {
    "enabled_providers": ["claude", "codex"],
    "refresh_interval_seconds": 900,
    "stale_after_seconds": 1800,
    "stale_after_failures": 2,
    "debug_captures": True,
    "reset_label_style": "friendly",
    "show_reset_labels": True,
    "show_sonnet_metric": True,
    "show_error_details": True,
}

CLAUDE_CMD = os.environ.get("CLAUDE_CMD", "claude")
CODEX_CMD = os.environ.get("CODEX_CMD", "codex")

TMUX_WIDTH = os.environ.get("AI_USAGE_TMUX_WIDTH", "160")
TMUX_HEIGHT = os.environ.get("AI_USAGE_TMUX_HEIGHT", "50")

CLAUDE_START_WAIT = float(os.environ.get("AI_USAGE_CLAUDE_START_WAIT", "5"))
CLAUDE_SCREEN_WAIT = float(os.environ.get("AI_USAGE_CLAUDE_SCREEN_WAIT", "5"))

CODEX_START_WAIT = float(os.environ.get("AI_USAGE_CODEX_START_WAIT", "8"))
CODEX_STATUS_WAIT_1 = float(os.environ.get("AI_USAGE_CODEX_STATUS_WAIT_1", "5"))
CODEX_STATUS_WAIT_2 = float(os.environ.get("AI_USAGE_CODEX_STATUS_WAIT_2", "6"))

UNAVAILABLE_ERROR_CODES = {"command_not_found", "startup_failed"}


class CollectorError(RuntimeError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


class BlockerDetected(CollectorError):
    def __init__(self, code: str, message: str, blocker: dict[str, Any]):
        super().__init__(code, message)
        self.blocker = blocker


class CollectorBusy(CollectorError):
    pass


@dataclass
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def ensure_runtime_dirs() -> None:
    APP_SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
    WORKDIR_PATH.mkdir(parents=True, exist_ok=True)


def log_line(message: str) -> None:
    ensure_runtime_dirs()
    with LOG_PATH.open("a", encoding="utf-8") as fh:
        fh.write(f"{now_iso()} {message}\n")


def atomic_write_json(path: Path, data: dict[str, Any]) -> None:
    try:
        ensure_runtime_dirs()
        tmp_path = path.with_suffix(path.suffix + ".tmp")
        tmp_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        tmp_path.replace(path)
    except Exception as exc:
        raise CollectorError("write_failed", f"Failed to write cache: {exc}") from exc


@contextmanager
def collector_lock():
    ensure_runtime_dirs()
    lock_file = LOCK_PATH.open("w", encoding="utf-8")
    try:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise CollectorBusy("busy", "Collector is already running") from exc
        lock_file.write(f"{os.getpid()}\n")
        lock_file.flush()
        yield
    finally:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        finally:
            lock_file.close()


def load_json_file(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise CollectorError("config_invalid", f"Failed to read JSON file {path}: {exc}") from exc


def load_cache() -> dict[str, Any]:
    if not CACHE_PATH.exists():
        return {"schema_version": SCHEMA_VERSION, "app_id": APP_ID, "providers": {}}
    try:
        return json.loads(CACHE_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {"schema_version": SCHEMA_VERSION, "app_id": APP_ID, "providers": {}}


def normalize_enabled_providers(value: Any) -> list[str]:
    if value is None:
        providers = list(DEFAULT_CONFIG["enabled_providers"])
    elif isinstance(value, str):
        providers = [part.strip().lower() for part in value.split(",") if part.strip()]
    elif isinstance(value, list):
        providers = [str(item).strip().lower() for item in value if str(item).strip()]
    else:
        raise CollectorError("config_invalid", "enabled_providers must be a list or comma-separated string")

    providers = [provider for provider in providers if provider in KNOWN_PROVIDERS]
    seen: set[str] = set()
    ordered: list[str] = []
    for provider in providers:
        if provider not in seen:
            ordered.append(provider)
            seen.add(provider)
    return ordered


def normalize_bool_option(value: Any, key: str) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, int) and value in {0, 1}:
        return bool(value)
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"true", "1", "yes", "on"}:
            return True
        if lowered in {"false", "0", "no", "off"}:
            return False
    raise CollectorError("config_invalid", f"{key} must be a boolean")


def normalize_reset_label_style(value: Any) -> str:
    if value is None:
        return str(DEFAULT_CONFIG["reset_label_style"])
    if not isinstance(value, str):
        raise CollectorError("config_invalid", "reset_label_style must be a string")
    normalized = value.strip().lower()
    if normalized not in {"friendly", "source"}:
        raise CollectorError("config_invalid", "reset_label_style must be 'friendly' or 'source'")
    return normalized


def load_config(config_path: Path | None) -> dict[str, Any]:
    config = dict(DEFAULT_CONFIG)
    path = config_path or CONFIG_PATH
    loaded: dict[str, Any] = {}
    if path.exists():
        loaded = load_json_file(path)
        config.update(loaded)
    config["enabled_providers"] = normalize_enabled_providers(config.get("enabled_providers"))
    if not config["enabled_providers"]:
        raise CollectorError("config_invalid", "No enabled providers configured")
    config["debug_captures"] = normalize_bool_option(config.get("debug_captures", DEFAULT_CONFIG["debug_captures"]), "debug_captures")
    config["show_reset_labels"] = normalize_bool_option(config.get("show_reset_labels", DEFAULT_CONFIG["show_reset_labels"]), "show_reset_labels")
    config["show_sonnet_metric"] = normalize_bool_option(config.get("show_sonnet_metric", DEFAULT_CONFIG["show_sonnet_metric"]), "show_sonnet_metric")
    config["show_error_details"] = normalize_bool_option(config.get("show_error_details", DEFAULT_CONFIG["show_error_details"]), "show_error_details")
    config["reset_label_style"] = normalize_reset_label_style(config.get("reset_label_style", DEFAULT_CONFIG["reset_label_style"]))
    if path == CONFIG_PATH and config != loaded:
        atomic_write_json(path, config)
    return config


def run_command(cmd: list[str], check: bool = True, timeout: float | None = None) -> CommandResult:
    try:
        cp = subprocess.run(
            cmd,
            check=False,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    except FileNotFoundError as exc:
        raise CollectorError("command_not_found", f"Command not found: {cmd[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise CollectorError("timeout", f"Command timed out: {' '.join(cmd)}") from exc

    if check and cp.returncode != 0:
        stderr = cp.stderr.strip() or cp.stdout.strip() or f"exit {cp.returncode}"
        raise CollectorError("command_failed", f"Command failed: {' '.join(cmd)} ({stderr})")

    return CommandResult(returncode=cp.returncode, stdout=cp.stdout, stderr=cp.stderr)


def tmux_has_session(name: str) -> bool:
    cp = run_command(["tmux", "has-session", "-t", name], check=False)
    return cp.returncode == 0


def tmux_kill_session(name: str) -> None:
    if tmux_has_session(name):
        run_command(["tmux", "kill-session", "-t", name], check=False)


def tmux_wrapped_command(command: str) -> str:
    shell_script = (
        f"{command}; rc=$?; "
        "if [ $rc -ne 0 ]; then "
        "printf '\n__AI_USAGE_CMD_EXIT__:%s\n' \"$rc\"; "
        "sleep 8; "
        "fi"
    )
    return f"/bin/sh -lc {shlex.quote(shell_script)}"


def tmux_new_session(name: str, command: str) -> None:
    tmux_kill_session(name)
    run_command(
        [
            "tmux",
            "new-session",
            "-d",
            "-c",
            str(WORKDIR_PATH),
            "-x",
            TMUX_WIDTH,
            "-y",
            TMUX_HEIGHT,
            "-s",
            name,
            tmux_wrapped_command(command),
        ]
    )


def tmux_send(name: str, keys: str) -> bool:
    if not tmux_has_session(name):
        return False
    cp = run_command(["tmux", "send-keys", "-t", name, keys, "Enter"], check=False)
    return cp.returncode == 0


def tmux_send_enter(name: str) -> bool:
    if not tmux_has_session(name):
        return False
    cp = run_command(["tmux", "send-keys", "-t", name, "Enter"], check=False)
    return cp.returncode == 0


def tmux_capture(name: str, lines: int = 250) -> str:
    if not tmux_has_session(name):
        raise CollectorError("capture_failed", f"tmux session not found: {name}")
    cp = run_command(["tmux", "capture-pane", "-pt", name, "-S", f"-{lines}"])
    return cp.stdout


def maybe_write_debug_capture(filename: str, text: str, enabled: bool) -> None:
    if not enabled:
        return
    ensure_runtime_dirs()
    (DEBUG_DIR / filename).write_text(text, encoding="utf-8")


def normalize_for_parse(text: str) -> str:
    text = text.replace("\u00a0", " ")
    normalized_lines = []
    for line in text.splitlines():
        line = re.sub(r"[ \t]+", " ", line).strip()
        if line:
            normalized_lines.append(line)
    return "\n".join(normalized_lines)


def normalized_lines(text: str) -> list[str]:
    return normalize_for_parse(text).splitlines()


def screen_excerpt(text: str, limit: int = 12) -> str:
    lines = normalized_lines(text)
    return "\n".join(lines[:limit])


def provider_session_name(provider: str) -> str:
    return f"ai_usage_{provider}"


def resolve_claude_command() -> str:
    fallback = Path.home() / ".local" / "bin" / "claude"
    if fallback.exists():
        return str(fallback)

    resolved = shutil.which(CLAUDE_CMD)
    if resolved:
        return resolved

    raise CollectorError("command_not_found", f"Claude command not found: {CLAUDE_CMD}")


def resolve_node_npm_runtime() -> tuple[Path, Path, Path]:
    npm_candidates = sorted(
        Path.home().glob('.nvm/versions/node/*/lib/node_modules/npm/bin/npm-cli.js'),
        reverse=True,
    )
    for npm_cli in npm_candidates:
        version_root = npm_cli.parents[4]
        node_path = version_root / 'bin' / 'node'
        if node_path.exists():
            return version_root, node_path, npm_cli

    npm_resolved = shutil.which('npm')
    node_resolved = shutil.which('node')
    if npm_resolved and node_resolved:
        return Path(node_resolved).parent.parent, Path(node_resolved), Path(npm_resolved)

    raise CollectorError("command_not_found", "Node/npm runtime for Codex was not found")


def resolve_codex_install() -> tuple[Path, Path, Path, Path]:
    version_root, node_path, npm_cli = resolve_node_npm_runtime()
    codex_dir = version_root / 'lib' / 'node_modules' / '@openai' / 'codex'
    if codex_dir.exists():
        return version_root, node_path, npm_cli, codex_dir

    raise CollectorError("command_not_found", f"Codex command not found: {CODEX_CMD}")


def resolve_codex_command() -> str:
    resolved = shutil.which(CODEX_CMD)
    if resolved:
        return resolved

    _version_root, node_path, _npm_cli, codex_dir = resolve_codex_install()
    codex_js = codex_dir / 'bin' / 'codex.js'
    return shlex.join([str(node_path), str(codex_js)])


def provider_launch_command(provider: str) -> str:
    if provider == "claude":
        return resolve_claude_command()
    if provider == "codex":
        return resolve_codex_command()
    raise CollectorError("config_invalid", f"Unknown provider: {provider}")


@dataclass
class ProviderTiming:
    start_wait: float
    capture_lines: int
    after_enter_wait: float


PROVIDER_TIMINGS: dict[str, ProviderTiming] = {
    "claude": ProviderTiming(
        start_wait=CLAUDE_START_WAIT,
        capture_lines=220,
        after_enter_wait=max(1.5, CLAUDE_SCREEN_WAIT / 2),
    ),
    "codex": ProviderTiming(
        start_wait=CODEX_START_WAIT,
        capture_lines=260,
        after_enter_wait=max(1.5, CODEX_STATUS_WAIT_1),
    ),
}
DEFAULT_PROVIDER_TIMING = ProviderTiming(start_wait=3.0, capture_lines=220, after_enter_wait=2.0)


def provider_start_wait(provider: str) -> float:
    return PROVIDER_TIMINGS.get(provider, DEFAULT_PROVIDER_TIMING).start_wait


def provider_capture_lines(provider: str) -> int:
    return PROVIDER_TIMINGS.get(provider, DEFAULT_PROVIDER_TIMING).capture_lines


def provider_after_enter_wait(provider: str) -> float:
    return PROVIDER_TIMINGS.get(provider, DEFAULT_PROVIDER_TIMING).after_enter_wait


def blocker_resolution_keys(provider: str, blocker_code: str, screen_text: str) -> str | None:
    lower = normalize_for_parse(screen_text).lower()

    if blocker_code == "update_required":
        if provider == "codex" and "skip until next version" in lower:
            return "3"
        if provider == "codex" and "skip" in lower:
            return "2"
        return "Enter"

    if blocker_code in {"trust_required", "selection_required"}:
        return "Enter"

    return None


def build_blocker(code: str, provider: str, message: str, text: str) -> dict[str, Any]:
    return {
        "code": code,
        "message": message,
        "detected_at": now_iso(),
        "screen_excerpt": screen_excerpt(text),
        "resolution": {
            "type": "resolve_command",
            "command": ["python3", "ai_usage_collector.py", "resolve", "--providers", provider],
        },
    }


TRUST_PATTERNS = [
    "trust this folder",
    "trust this workspace",
    "trust this directory",
    "do you trust",
    "workspace trust",
    "allow this folder",
]
UPDATE_PATTERNS = [
    "update available",
    "would you like to update",
    "new version available",
    "install update",
    "upgrade available",
    "update now",
]
SELECTION_PATTERNS = [
    "press enter to continue",
    "[y/n]",
    "(y/n)",
    "yes/no",
    "select an option",
    "choose an option",
]
CLAUDE_READY_PATTERNS = [
    "welcome back",
    "recent activity",
    "tips for getting started",
    "current session",
]
CODEX_READY_PATTERNS = [
    "tip: you can resume",
    "find and fix a bug",
    "model:",
    "directory:",
]


def _has_any_pattern(lower: str, patterns: list[str]) -> bool:
    return any(pattern in lower for pattern in patterns)


def _is_provider_ready(provider: str, lower: str, has_prompt: bool) -> bool:
    if provider == "claude":
        return "claude code" in lower and (has_prompt or _has_any_pattern(lower, CLAUDE_READY_PATTERNS))
    if provider == "codex":
        return "openai codex" in lower and _has_any_pattern(lower, CODEX_READY_PATTERNS)
    return False


def classify_provider_screen(provider: str, text: str) -> dict[str, Any]:
    norm = normalize_for_parse(text)
    lower = norm.lower()
    lines = normalized_lines(text)
    has_prompt = any(line == "❯" or line.startswith("❯ ") for line in lines)

    if _has_any_pattern(lower, TRUST_PATTERNS):
        return {
            "state": "blocked",
            "blocker": build_blocker("trust_required", provider, f"{provider.capitalize()} needs workspace trust approval", text),
        }

    if len(norm.strip()) < 40 or len(normalized_lines(text)) < 3:
        return {"state": "starting"}

    if _is_provider_ready(provider, lower, has_prompt):
        return {"state": "ready"}

    if _has_any_pattern(lower, UPDATE_PATTERNS):
        return {
            "state": "blocked",
            "blocker": build_blocker("update_required", provider, f"{provider.capitalize()} is showing an update prompt", text),
        }

    if _has_any_pattern(lower, SELECTION_PATTERNS):
        return {
            "state": "blocked",
            "blocker": build_blocker("selection_required", provider, f"{provider.capitalize()} is waiting for a confirmation prompt", text),
        }

    return {
        "state": "blocked",
        "blocker": build_blocker("unknown_prompt", provider, f"{provider.capitalize()} is showing an unknown startup prompt", text),
    }


def startup_error_from_capture(provider: str, text: str) -> CollectorError | None:
    lower = normalize_for_parse(text).lower()
    if "missing optional dependency @openai/codex-darwin-arm64" in lower:
        return CollectorError("startup_failed", "Codex installation is incomplete. Reinstall Codex to restore usage collection.")
    if "command not found" in lower:
        return CollectorError("command_not_found", f"{provider.capitalize()} command is not available in the collector runtime")
    if "__ai_usage_cmd_exit__" in lower:
        return CollectorError("startup_failed", f"{provider.capitalize()} exited during startup")
    return None


def start_provider_session(provider: str, debug_captures: bool) -> str:
    session = provider_session_name(provider)
    tmux_new_session(session, provider_launch_command(provider))
    time.sleep(provider_start_wait(provider))
    initial_capture = tmux_capture(session, provider_capture_lines(provider))
    maybe_write_debug_capture(f"{provider}_initial_capture.txt", initial_capture, debug_captures)
    startup_error = startup_error_from_capture(provider, initial_capture)
    if startup_error is not None:
        raise startup_error
    return session


def capture_provider_state(provider: str, session: str, debug_captures: bool) -> tuple[str, dict[str, Any]]:
    last_text = ""
    last_classification: dict[str, Any] = {"state": "starting"}
    for _ in range(3):
        last_text = tmux_capture(session, provider_capture_lines(provider))
        last_classification = classify_provider_screen(provider, last_text)
        if last_classification["state"] != "starting":
            break
        time.sleep(1.0)
    maybe_write_debug_capture(f"{provider}_initial_capture.txt", last_text, debug_captures)
    return last_text, last_classification


def extract_usage_block(lines: list[str], label: str, percent_pattern: str, sibling_labels: list[str]) -> tuple[int | None, str | None]:
    for index, line in enumerate(lines):
        if line != label:
            continue
        percent_value: int | None = None
        reset_label: str | None = None
        for lookahead in range(index + 1, min(index + 6, len(lines))):
            candidate = lines[lookahead]
            if candidate in sibling_labels:
                break
            match = re.search(percent_pattern, candidate, re.I)
            if match and percent_value is None:
                percent_value = int(match.group(1))
            reset_match = re.search(r"Resets\s+(.+)$", candidate, re.I)
            if reset_match and reset_label is None:
                reset_label = reset_match.group(1).strip()
        return percent_value, reset_label
    return None, None


def format_clock_label(dt: datetime) -> str:
    hour = dt.hour % 12 or 12
    suffix = "am" if dt.hour < 12 else "pm"
    if dt.minute == 0:
        return f"{hour}{suffix}"
    return f"{hour}:{dt.minute:02d}{suffix}"


def format_friendly_reset_label(dt: datetime) -> str:
    local_dt = dt if dt.tzinfo is not None else dt.astimezone()
    return f"{local_dt.strftime('%b')} {local_dt.day} at {format_clock_label(local_dt)}"


MONTH_LOOKUP: dict[str, int] = {
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
    "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
}


def _try_parse_absolute_12h(raw: str, now_local: datetime, local_tz: Any) -> str | None:
    """'Apr 17 at 2pm (Asia/Seoul)' format."""
    match = re.fullmatch(r"([A-Za-z]{3}) (\d{1,2}) at (\d{1,2})(?::(\d{2}))?(am|pm)(?: \(([^)]+)\))?", raw, re.I)
    if not match:
        return None
    month = MONTH_LOOKUP.get(match.group(1).lower())
    if month is None:
        return None
    day = int(match.group(2))
    hour = int(match.group(3)) % 12
    if match.group(5).lower() == "pm":
        hour += 12
    minute = int(match.group(4) or 0)
    tz_name = match.group(6)
    try:
        base_tz = ZoneInfo(tz_name) if tz_name else local_tz
        base_now = now_local.astimezone(base_tz)
        candidate = datetime(base_now.year, month, day, hour, minute, tzinfo=base_tz)
        if candidate < base_now - timedelta(days=30):
            candidate = candidate.replace(year=candidate.year + 1)
        return format_friendly_reset_label(candidate.astimezone(local_tz))
    except Exception:
        return None


def _try_parse_time_12h_tz(raw: str, now_local: datetime, local_tz: Any) -> str | None:
    """'6pm (Asia/Seoul)' format."""
    match = re.fullmatch(r"(\d{1,2})(?::(\d{2}))?(am|pm) \(([^)]+)\)", raw, re.I)
    if not match:
        return None
    hour = int(match.group(1)) % 12
    if match.group(3).lower() == "pm":
        hour += 12
    minute = int(match.group(2) or 0)
    tz_name = match.group(4)
    try:
        source_tz = ZoneInfo(tz_name)
        source_now = now_local.astimezone(source_tz)
        candidate = source_now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if candidate <= source_now:
            candidate += timedelta(days=1)
        return format_friendly_reset_label(candidate.astimezone(local_tz))
    except Exception:
        return None


def _try_parse_time_24h_date(raw: str, now_local: datetime) -> str | None:
    """'15:04 on 17 Apr' format."""
    match = re.fullmatch(r"(\d{1,2}):(\d{2}) on (\d{1,2}) ([A-Za-z]{3})", raw, re.I)
    if not match:
        return None
    month = MONTH_LOOKUP.get(match.group(4).lower())
    if month is None:
        return None
    day = int(match.group(3))
    hour = int(match.group(1))
    minute = int(match.group(2))
    try:
        candidate = now_local.replace(month=month, day=day, hour=hour, minute=minute, second=0, microsecond=0)
        if candidate < now_local - timedelta(days=30):
            candidate = candidate.replace(year=candidate.year + 1)
        return format_friendly_reset_label(candidate)
    except Exception:
        return None


def _try_parse_time_24h(raw: str, now_local: datetime) -> str | None:
    """'18:32' format."""
    match = re.fullmatch(r"(\d{1,2}):(\d{2})", raw)
    if not match:
        return None
    hour = int(match.group(1))
    minute = int(match.group(2))
    candidate = now_local.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if candidate <= now_local:
        candidate += timedelta(days=1)
    return format_friendly_reset_label(candidate)


def normalize_reset_label(label: str, reference_now: datetime | None = None) -> str:
    raw = label.strip()
    if reference_now is not None:
        now_local = reference_now if reference_now.tzinfo is not None else reference_now.astimezone()
    else:
        now_local = datetime.now().astimezone()
    local_tz = now_local.tzinfo

    return (
        _try_parse_absolute_12h(raw, now_local, local_tz)
        or _try_parse_time_12h_tz(raw, now_local, local_tz)
        or _try_parse_time_24h_date(raw, now_local)
        or _try_parse_time_24h(raw, now_local)
        or raw
    )


def capture_claude(debug_captures: bool) -> str:
    session = provider_session_name("claude")
    try:
        start_provider_session("claude", debug_captures)
        _, classification = capture_provider_state("claude", session, debug_captures)
        if classification["state"] != "ready":
            blocker = classification["blocker"]
            raise BlockerDetected(blocker["code"], blocker["message"], blocker)
        if not tmux_send(session, "/usage"):
            raise CollectorError("tmux_failed", "Failed to send /usage to Claude tmux session")
        time.sleep(CLAUDE_SCREEN_WAIT)
        out = tmux_capture(session, 220)
        maybe_write_debug_capture("claude_capture.txt", out, debug_captures)
        return out
    finally:
        tmux_kill_session(session)


def codex_detailed_status_visible(text: str) -> bool:
    lower = text.lower()
    return "5h limit:" in text and "weekly limit:" in lower and "resets" in lower


def capture_codex(debug_captures: bool) -> str:
    session = provider_session_name("codex")
    try:
        start_provider_session("codex", debug_captures)
        _, classification = capture_provider_state("codex", session, debug_captures)
        if classification["state"] != "ready":
            blocker = classification["blocker"]
            raise BlockerDetected(blocker["code"], blocker["message"], blocker)
        if not tmux_send(session, "/status"):
            raise CollectorError("tmux_failed", "Failed to send /status to Codex tmux session")
        time.sleep(CODEX_STATUS_WAIT_1)
        out = tmux_capture(session, 260)
        if not codex_detailed_status_visible(out) and tmux_has_session(session):
            tmux_send(session, "/status")
            time.sleep(CODEX_STATUS_WAIT_2)
            out = tmux_capture(session, 260)
        maybe_write_debug_capture("codex_capture.txt", out, debug_captures)
        return out
    finally:
        tmux_kill_session(session)


def _build_parse_result(metrics: dict[str, Any], collector: str) -> dict[str, Any]:
    return {
        "metrics": metrics,
        "summary": {
            "primary_left": metrics.get("five_hour", {}).get("left"),
            "secondary_left": metrics.get("weekly", {}).get("left"),
            "primary_label": "5h",
            "secondary_label": "week",
        },
        "source": {"collector": collector, "method": "interactive"},
    }


def parse_claude(text: str, reference_now: datetime | None = None) -> dict[str, Any]:
    lines = normalized_lines(text)
    labels = [
        "Current session",
        "Current week (all models)",
        "Current week (Sonnet only)",
    ]

    session_used, session_reset = extract_usage_block(lines, labels[0], r"(\d+)% used", labels)
    weekly_used, weekly_reset = extract_usage_block(lines, labels[1], r"(\d+)% used", labels)
    sonnet_used, sonnet_reset = extract_usage_block(lines, labels[2], r"(\d+)% used", labels)

    if session_used is None and weekly_used is None:
        raise CollectorError("parse_failed", "Could not parse Claude usage from capture")

    sonnet_reset = sonnet_reset or session_reset

    metrics: dict[str, Any] = {}
    if session_used is not None:
        metrics["five_hour"] = {
            "left": max(0, min(100, 100 - session_used)),
            "reset_at_label": normalize_reset_label(session_reset, reference_now=reference_now) if session_reset else None,
            "reset_at_source_label": session_reset,
            "official_label": labels[0],
        }
    if weekly_used is not None:
        metrics["weekly"] = {
            "left": max(0, min(100, 100 - weekly_used)),
            "reset_at_label": normalize_reset_label(weekly_reset, reference_now=reference_now) if weekly_reset else None,
            "reset_at_source_label": weekly_reset,
            "official_label": labels[1],
        }
    if sonnet_used is not None:
        metrics["sonnet"] = {
            "left": max(0, min(100, 100 - sonnet_used)),
            "reset_at_label": normalize_reset_label(sonnet_reset, reference_now=reference_now) if sonnet_reset else None,
            "reset_at_source_label": sonnet_reset,
            "official_label": labels[2],
        }

    return _build_parse_result(metrics, "claude")


def parse_codex(text: str, reference_now: datetime | None = None) -> dict[str, Any]:
    norm = normalize_for_parse(text)
    main = norm.split("GPT-5.3-Codex-Spark limit:")[0]

    five_hour_match = re.search(r"5h limit:.*?(\d+)% left.*?\(resets ([^)]+)\)", main, re.I | re.S)
    weekly_match = re.search(r"Weekly limit:.*?(\d+)% left.*?\(resets ([^)]+)\)", main, re.I | re.S)

    five_hour_left = int(five_hour_match.group(1)) if five_hour_match else None
    five_hour_reset = five_hour_match.group(2).strip() if five_hour_match else None

    weekly_left = int(weekly_match.group(1)) if weekly_match else None
    weekly_reset = weekly_match.group(2).strip() if weekly_match else None

    if five_hour_left is None:
        fallback = re.search(r"\b5h\s+(\d+)%", norm, re.I)
        if fallback:
            five_hour_left = int(fallback.group(1))
    if weekly_left is None:
        fallback = re.search(r"\bweekly\s+(\d+)%", norm, re.I)
        if fallback:
            weekly_left = int(fallback.group(1))

    if five_hour_left is None and weekly_left is None:
        raise CollectorError("parse_failed", "Could not parse Codex status from capture")

    metrics: dict[str, Any] = {}
    if five_hour_left is not None:
        metrics["five_hour"] = {
            "left": five_hour_left,
            "reset_at_label": normalize_reset_label(five_hour_reset, reference_now=reference_now) if five_hour_reset else None,
            "reset_at_source_label": five_hour_reset,
            "official_label": "5h limit",
        }
    if weekly_left is not None:
        metrics["weekly"] = {
            "left": weekly_left,
            "reset_at_label": normalize_reset_label(weekly_reset, reference_now=reference_now) if weekly_reset else None,
            "reset_at_source_label": weekly_reset,
            "official_label": "Weekly limit",
        }

    return _build_parse_result(metrics, "codex")


def collect_claude(config: dict[str, Any]) -> dict[str, Any]:
    return parse_claude(capture_claude(bool(config.get("debug_captures", True))))


def collect_codex(config: dict[str, Any]) -> dict[str, Any]:
    return parse_codex(capture_codex(bool(config.get("debug_captures", True))))


COLLECTORS = {
    "claude": collect_claude,
    "codex": collect_codex,
}


def build_error(code: str, message: str) -> dict[str, Any]:
    return {"code": code, "message": message, "at": now_iso()}


def provider_template(name: str) -> dict[str, Any]:
    return {
        "enabled": False,
        "status": "error",
        "last_attempt_at": None,
        "last_success_at": None,
        "consecutive_failures": 0,
        "stale": True,
        "blocker": None,
        "summary": {
            "primary_left": None,
            "secondary_left": None,
            "primary_label": "5h",
            "secondary_label": "week",
        },
        "metrics": {},
        "error": None,
        "source": {"collector": name, "method": "interactive"},
    }


def _base_merge(previous: dict[str, Any], name: str, status: str, attempted_at: str) -> dict[str, Any]:
    merged = provider_template(name)
    merged.update(previous or {})
    merged["enabled"] = True
    merged["status"] = status
    merged["last_attempt_at"] = attempted_at
    return merged


def merge_success(previous: dict[str, Any], name: str, collected: dict[str, Any], attempted_at: str) -> dict[str, Any]:
    merged = _base_merge(previous, name, "ok", attempted_at)
    merged["last_success_at"] = attempted_at
    merged["consecutive_failures"] = 0
    merged["summary"] = collected["summary"]
    merged["metrics"] = collected["metrics"]
    merged["error"] = None
    merged["blocker"] = None
    merged["source"] = collected["source"]
    return merged


def merge_failure(previous: dict[str, Any], name: str, error: CollectorError, attempted_at: str) -> dict[str, Any]:
    merged = _base_merge(previous, name, "error", attempted_at)
    merged["consecutive_failures"] = int(merged.get("consecutive_failures") or 0) + 1
    merged["error"] = build_error(error.code, error.message)
    merged["blocker"] = None
    merged.setdefault("source", {"collector": name, "method": "interactive"})
    return merged


def merge_unavailable(previous: dict[str, Any], name: str, error: CollectorError, attempted_at: str) -> dict[str, Any]:
    merged = _base_merge(previous, name, "unavailable", attempted_at)
    merged["consecutive_failures"] = int(merged.get("consecutive_failures") or 0) + 1
    merged["summary"] = {
        "primary_left": None,
        "secondary_left": None,
        "primary_label": "5h",
        "secondary_label": "week",
    }
    merged["metrics"] = {}
    merged["error"] = build_error(error.code, error.message)
    merged["blocker"] = None
    merged.setdefault("source", {"collector": name, "method": "interactive"})
    return merged


def merge_blocker(previous: dict[str, Any], name: str, blocker: dict[str, Any], attempted_at: str) -> dict[str, Any]:
    merged = _base_merge(previous, name, "blocked", attempted_at)
    merged["error"] = None
    merged["blocker"] = blocker
    merged.setdefault("source", {"collector": name, "method": "interactive"})
    return merged


def mark_disabled(previous: dict[str, Any], name: str) -> dict[str, Any]:
    merged = provider_template(name)
    merged.update(previous or {})
    merged["enabled"] = False
    merged["stale"] = False
    merged["error"] = None
    merged["blocker"] = None
    return merged


def is_stale(provider: dict[str, Any], config: dict[str, Any]) -> bool:
    if not provider.get("enabled"):
        return False

    failures = int(provider.get("consecutive_failures") or 0)
    if failures >= int(config["stale_after_failures"]):
        return True

    last_success_at = provider.get("last_success_at")
    if not last_success_at:
        return True

    try:
        last_success = datetime.fromisoformat(last_success_at)
    except ValueError:
        return True

    age_seconds = (datetime.now().astimezone() - last_success).total_seconds()
    return age_seconds > int(config["stale_after_seconds"])


def provider_summary_text(provider: dict[str, Any]) -> str:
    if provider.get("status") == "unavailable":
        return "--"
    summary = provider.get("summary", {})
    primary = summary.get("primary_left")
    secondary = summary.get("secondary_left")
    if primary is None and secondary is None:
        return "--"
    return f"{pct(primary)}/{pct(secondary)}"


def _needs_attention(provider: dict[str, Any]) -> bool:
    return (
        bool(provider.get("blocker"))
        or provider.get("status") in {"error", "blocked", "unavailable"}
        or bool(provider.get("stale"))
    )


def render_summary(data: dict[str, Any]) -> str:
    providers = data.get("providers", {})
    pieces: list[str] = []
    has_attention = False

    codex = providers.get("codex")
    if codex and codex.get("enabled"):
        pieces.append(f"Cdx {provider_summary_text(codex)}")
        has_attention = has_attention or _needs_attention(codex)

    claude = providers.get("claude")
    if claude and claude.get("enabled"):
        pieces.append(f"Cl {provider_summary_text(claude)}")
        has_attention = has_attention or _needs_attention(claude)

    summary_text = " · ".join(pieces) if pieces else "AI --"
    return f"! {summary_text}" if has_attention else summary_text


def pct(value: Any) -> str:
    return "?" if value is None else str(value)


def metric_visible(key: str, config: dict[str, Any]) -> bool:
    if key == "sonnet":
        return bool(config.get("show_sonnet_metric", True))
    return True


def metric_reset_display_label(metric: dict[str, Any], config: dict[str, Any]) -> str | None:
    style = str(config.get("reset_label_style", DEFAULT_CONFIG["reset_label_style"]))
    if style == "source":
        return metric.get("reset_at_source_label") or metric.get("reset_at_label")
    return metric.get("reset_at_label") or metric.get("reset_at_source_label")


def render_text(data: dict[str, Any], config: dict[str, Any] | None = None) -> str:
    effective_config = config or DEFAULT_CONFIG
    lines = [render_summary(data), ""]
    providers = data.get("providers", {})

    for name, title in (("codex", "Codex"), ("claude", "Claude")):
        provider = providers.get(name)
        if not provider or not provider.get("enabled"):
            continue

        lines.append(title)
        metrics = provider.get("metrics", {})
        for key, label in (("five_hour", "5h"), ("weekly", "week"), ("sonnet", "sonnet")):
            if not metric_visible(key, effective_config):
                continue
            metric = metrics.get(key)
            if not metric:
                continue
            lines.append(f"- {label}: {pct(metric.get('left'))}% left")
            if effective_config.get("show_reset_labels", True):
                reset_label = metric_reset_display_label(metric, effective_config) or "n/a"
                lines.append(f"  reset: {reset_label}")

        if provider.get("status") == "unavailable":
            lines.append("- status: unavailable")
        if provider.get("stale"):
            lines.append("- note: stale")
        if provider.get("blocker"):
            lines.append(f"- blocker: {provider['blocker'].get('message')}")
        if effective_config.get("show_error_details", True) and provider.get("error"):
            lines.append(f"- error: {provider['error'].get('message')}")
        lines.append("")

    return "\n".join(lines).strip() + "\n"


def parse_provider_override(arg_value: str | None) -> list[str] | None:
    if arg_value is None:
        return None
    providers = normalize_enabled_providers(arg_value)
    if not providers:
        raise CollectorError("config_invalid", "Override providers list is empty or invalid")
    return providers


def _load_command_context(args: argparse.Namespace) -> tuple[dict[str, Any], list[str]]:
    ensure_runtime_dirs()
    config = load_config(Path(args.config) if args.config else None)
    override = parse_provider_override(getattr(args, "providers", None))
    enabled_providers = override or list(config["enabled_providers"])
    return config, enabled_providers


def run_update(enabled_providers: list[str], config: dict[str, Any], *, retry_blocked: bool) -> tuple[dict[str, Any], int, int, int]:
    cache = load_cache()
    cache["schema_version"] = SCHEMA_VERSION
    cache["app_id"] = APP_ID
    cache.setdefault("providers", {})

    success_count = 0
    attempted_count = 0
    blocked_count = 0

    for provider_name in KNOWN_PROVIDERS:
        previous = cache["providers"].get(provider_name, provider_template(provider_name))
        if provider_name not in enabled_providers:
            cache["providers"][provider_name] = mark_disabled(previous, provider_name)
            continue

        if not retry_blocked and previous.get("status") == "blocked" and previous.get("blocker"):
            cache["providers"][provider_name] = previous
            blocked_count += 1
            log_line(f"[{provider_name}] collect skipped existing_blocker code={previous['blocker'].get('code')}")
            continue

        attempted_count += 1
        attempted_at = now_iso()
        try:
            log_line(f"[{provider_name}] collect start")
            collected = COLLECTORS[provider_name](config)
            cache["providers"][provider_name] = merge_success(previous, provider_name, collected, attempted_at)
            success_count += 1
            log_line(f"[{provider_name}] collect success")
        except BlockerDetected as exc:
            cache["providers"][provider_name] = merge_blocker(previous, provider_name, exc.blocker, attempted_at)
            blocked_count += 1
            log_line(f"[{provider_name}] collect blocked code={exc.code} message={exc.message}")
        except CollectorError as exc:
            if exc.code in UNAVAILABLE_ERROR_CODES:
                cache["providers"][provider_name] = merge_unavailable(previous, provider_name, exc, attempted_at)
            else:
                cache["providers"][provider_name] = merge_failure(previous, provider_name, exc, attempted_at)
            log_line(f"[{provider_name}] collect error code={exc.code} message={exc.message}")
        except Exception as exc:
            wrapped = CollectorError("command_failed", str(exc))
            cache["providers"][provider_name] = merge_failure(previous, provider_name, wrapped, attempted_at)
            log_line(f"[{provider_name}] collect unexpected_error message={exc}")

    for provider_name, provider in cache["providers"].items():
        provider["stale"] = is_stale(provider, config)

    cache["written_at"] = now_iso()
    atomic_write_json(CACHE_PATH, cache)

    return cache, attempted_count, success_count, blocked_count


def update_command(args: argparse.Namespace) -> int:
    with collector_lock():
        config, enabled_providers = _load_command_context(args)

        cache, attempted_count, success_count, blocked_count = run_update(enabled_providers, config, retry_blocked=False)

        print(render_summary(cache))
        print(f"attempted={attempted_count} succeeded={success_count} blocked={blocked_count} cache={CACHE_PATH}")

        if success_count > 0:
            return 0
        if blocked_count > 0 and attempted_count == 0:
            return 0
        if attempted_count == 0:
            return 2
        return 1


def resolve_provider(provider_name: str, config: dict[str, Any], *, auto_approve: bool = False) -> bool:
    debug_captures = bool(config.get("debug_captures", True))
    session = provider_session_name(provider_name)
    resolved = False
    try:
        log_line(f"[{provider_name}] resolve start")
        start_provider_session(provider_name, debug_captures)

        for _ in range(3):
            screen_text, classification = capture_provider_state(provider_name, session, debug_captures)
            if classification["state"] == "ready":
                print(f"{provider_name}: ready")
                log_line(f"[{provider_name}] resolve ready")
                resolved = True
                break

            blocker = classification["blocker"]
            print(f"{provider_name}: {blocker['message']}")
            excerpt = blocker.get("screen_excerpt")
            if excerpt:
                print(excerpt)
            resolution_keys = blocker_resolution_keys(provider_name, blocker["code"], screen_text)
            if resolution_keys is None:
                print(f"{provider_name}: manual attention required")
                log_line(f"[{provider_name}] resolve blocked code={blocker['code']}")
                break

            if not auto_approve:
                display_keys = "Enter" if resolution_keys == "Enter" else resolution_keys
                answer = input(f"Resolve {provider_name} by sending {display_keys}? [y/N]: ").strip().lower()
                if answer not in {"y", "yes"}:
                    log_line(f"[{provider_name}] resolve cancelled by user")
                    break

            if resolution_keys == "Enter":
                sent = tmux_send_enter(session)
            else:
                sent = tmux_send(session, resolution_keys)

            if not sent:
                log_line(f"[{provider_name}] resolve failed to send keys={resolution_keys}")
                break
            time.sleep(provider_after_enter_wait(provider_name))

        return resolved
    finally:
        tmux_kill_session(session)


def resolve_command(args: argparse.Namespace) -> int:
    with collector_lock():
        config, enabled_providers = _load_command_context(args)
        auto_approve = bool(getattr(args, "yes", False))

        for provider_name in enabled_providers:
            resolve_provider(provider_name, config, auto_approve=auto_approve)

        cache, attempted_count, success_count, blocked_count = run_update(enabled_providers, config, retry_blocked=True)
        print(render_summary(cache))
        print(f"attempted={attempted_count} succeeded={success_count} blocked={blocked_count} cache={CACHE_PATH}")

        if success_count > 0:
            return 0
        return 1


def repair_codex_install() -> None:
    version_root, node_path, npm_cli = resolve_node_npm_runtime()
    openai_dir = version_root / 'lib' / 'node_modules' / '@openai'
    codex_dir = openai_dir / 'codex'
    codex_bin = version_root / 'bin' / 'codex'

    log_line('[codex] repair start')

    for stale_dir in openai_dir.glob('.codex-*'):
        shutil.rmtree(stale_dir, ignore_errors=True)
    shutil.rmtree(codex_dir, ignore_errors=True)
    codex_bin.unlink(missing_ok=True)

    run_command(
        [str(node_path), str(npm_cli), 'install', '--global', '@openai/codex@latest'],
        timeout=300,
    )

    _version_root, _node_path, _npm_cli, _codex_dir = resolve_codex_install()
    log_line('[codex] repair success')


def repair_command(args: argparse.Namespace) -> int:
    with collector_lock():
        config, enabled_providers = _load_command_context(args)

        for provider_name in enabled_providers:
            if provider_name == 'codex':
                repair_codex_install()
            else:
                raise CollectorError('config_invalid', f'Repair is not supported for provider: {provider_name}')

        cache, attempted_count, success_count, blocked_count = run_update(enabled_providers, config, retry_blocked=True)
        print(render_summary(cache))
        print(f"attempted={attempted_count} succeeded={success_count} blocked={blocked_count} cache={CACHE_PATH}")
        return 0 if success_count > 0 else 1


def blocked_providers_from_cache(cache: dict[str, Any], enabled_providers: list[str]) -> list[str]:
    result: list[str] = []
    providers = cache.get("providers", {})
    for provider_name in enabled_providers:
        provider = providers.get(provider_name, {})
        if isinstance(provider, dict) and provider.get("status") == "blocked" and provider.get("blocker"):
            result.append(provider_name)
    return result


def _print_blockers_and_resolve(cache: dict[str, Any], blocked_names: list[str], config: dict[str, Any]) -> None:
    print(render_summary(cache))
    print("Some tools need one-time setup before usage can be collected.")
    for provider_name in blocked_names:
        provider = cache.get("providers", {}).get(provider_name, {})
        blocker = provider.get("blocker", {})
        if blocker:
            print(f"- {provider_name}: {blocker.get('message')}")
    print("")

    for provider_name in blocked_names:
        resolve_provider(provider_name, config)


def default_command(args: argparse.Namespace) -> int:
    with collector_lock():
        config, enabled_providers = _load_command_context(args)
        is_interactive = sys.stdin.isatty() and sys.stdout.isatty()

        existing_cache = load_cache()
        existing_blocked = blocked_providers_from_cache(existing_cache, enabled_providers)

        if existing_blocked and is_interactive:
            _print_blockers_and_resolve(existing_cache, existing_blocked, config)

        cache, attempted_count, success_count, blocked_count = run_update(
            enabled_providers,
            config,
            retry_blocked=is_interactive,
        )

        blocked_providers = blocked_providers_from_cache(cache, enabled_providers)

        if blocked_providers and is_interactive:
            _print_blockers_and_resolve(cache, blocked_providers, config)

            cache, attempted_count, success_count, blocked_count = run_update(
                enabled_providers,
                config,
                retry_blocked=True,
            )

        print(render_summary(cache))

        if success_count > 0:
            return 0
        if blocked_count > 0 and attempted_count == 0:
            return 0
        if attempted_count == 0:
            return 2
        return 1


def print_command(args: argparse.Namespace) -> int:
    config = load_config(Path(args.config) if args.config else None)
    data = load_cache()
    if not data.get("providers"):
        print("AI --")
        print("")
        print(f"Cache not found or empty: {CACHE_PATH}")
        return 0

    if args.format == "json":
        print(json.dumps(data, indent=2, ensure_ascii=False))
    else:
        print(render_text(data, config=config), end="")
    return 0


def doctor_command(args: argparse.Namespace) -> int:
    ensure_runtime_dirs()
    config = load_config(Path(args.config) if args.config else None)
    enabled_providers = list(config["enabled_providers"])

    print(f"App Support: {APP_SUPPORT_DIR}")
    print(f"Execution workdir: {WORKDIR_PATH}")
    print(f"Config path: {Path(args.config) if args.config else CONFIG_PATH}")
    print(f"Cache path: {CACHE_PATH}")
    print(f"Enabled providers: {', '.join(enabled_providers)}")

    missing: list[str] = []

    tmux_path = shutil.which("tmux")
    if tmux_path:
        print(f"[ok] tmux: {tmux_path}")
    else:
        print("[missing] tmux")
        missing.append("tmux")

    if "claude" in enabled_providers:
        try:
            print(f"[ok] claude: {resolve_claude_command()}")
        except CollectorError as exc:
            print(f"[missing] claude ({exc.message})")
            missing.append("claude")

    if "codex" in enabled_providers:
        try:
            print(f"[ok] codex: {resolve_codex_command()}")
        except CollectorError as exc:
            print(f"[missing] codex ({exc.message})")
            missing.append("codex")

    writable_targets = [APP_SUPPORT_DIR, LOG_DIR, DEBUG_DIR, WORKDIR_PATH]
    for target in writable_targets:
        try:
            target.mkdir(parents=True, exist_ok=True)
            probe = target / ".write_probe"
            probe.write_text("ok", encoding="utf-8")
            probe.unlink(missing_ok=True)
            print(f"[ok] writable: {target}")
        except Exception as exc:
            print(f"[missing] writable: {target} ({exc})")
            missing.append(str(target))

    return 0 if not missing else 1


def build_parser(*, include_internal: bool = False) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="ai-usage-collector")
    parser.add_argument("--providers", help="Comma-separated provider override, e.g. claude,codex")
    parser.add_argument("--config", help="Path to config.json")
    subparsers = parser.add_subparsers(dest="command")

    update_parser = subparsers.add_parser("update")
    update_parser.add_argument("--providers", help="Comma-separated provider override, e.g. claude,codex")
    update_parser.add_argument("--config", help="Path to config.json")
    update_parser.set_defaults(handler=update_command)

    if include_internal:
        resolve_parser = subparsers.add_parser("resolve")
        resolve_parser.add_argument("--providers", help="Comma-separated provider override, e.g. claude,codex")
        resolve_parser.add_argument("--config", help="Path to config.json")
        resolve_parser.add_argument("--yes", action="store_true", help=argparse.SUPPRESS)
        resolve_parser.set_defaults(handler=resolve_command)

        repair_parser = subparsers.add_parser("repair")
        repair_parser.add_argument("--providers", help="Comma-separated provider override, e.g. codex")
        repair_parser.add_argument("--config", help="Path to config.json")
        repair_parser.set_defaults(handler=repair_command)

    print_parser = subparsers.add_parser("print")
    print_parser.add_argument("--format", choices=("text", "json"), default="text")
    print_parser.add_argument("--config", help="Path to config.json")
    print_parser.set_defaults(handler=print_command)

    doctor_parser = subparsers.add_parser("doctor")
    doctor_parser.add_argument("--config", help="Path to config.json")
    doctor_parser.set_defaults(handler=doctor_command)

    return parser


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    else:
        argv = list(argv)

    include_internal = False
    if argv and argv[0] in {"prepare", "resolve", "repair"}:
        include_internal = True
        if argv[0] == "prepare":
            argv[0] = "resolve"

    parser = build_parser(include_internal=include_internal)
    args = parser.parse_args(argv)
    if not hasattr(args, "handler"):
        args.handler = default_command
    try:
        return int(args.handler(args))
    except CollectorBusy as exc:
        cache = load_cache()
        summary = render_summary(cache) if cache else "AI --"
        print(summary)
        log_line(f"[busy] message={exc.message}")
        return 0
    except CollectorError as exc:
        print(f"fatal: {exc.message}", file=sys.stderr)
        log_line(f"[fatal] code={exc.code} message={exc.message}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
