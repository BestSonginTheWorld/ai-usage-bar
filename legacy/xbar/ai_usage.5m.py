#!/usr/bin/env python3
import json
from pathlib import Path
import shlex


APP_SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "AIUsageMenuBar"
CACHE_PATH = APP_SUPPORT_DIR / "usage.json"
COLLECTOR_PATH = Path(__file__).resolve().parent / "ai_usage_collector.py"


def pct(value):
    return "?" if value is None else str(value)


def provider_summary(provider):
    summary = provider.get("summary", {}) if isinstance(provider, dict) else {}
    return pct(summary.get("primary_left")), pct(summary.get("secondary_left"))


def provider_metric(provider, key):
    if not isinstance(provider, dict):
        return {}
    metrics = provider.get("metrics", {})
    if not isinstance(metrics, dict):
        return {}
    value = metrics.get(key, {})
    return value if isinstance(value, dict) else {}


def has_blocker(provider):
    blocker = provider.get("blocker")
    return isinstance(blocker, dict) and bool(blocker.get("code"))


def blocker_heading(name, blocker):
    code = (blocker or {}).get("code")
    if code == "trust_required":
        return f"{name} setup required"
    if code == "update_required":
        return f"{name} needs attention"
    if code == "selection_required":
        return f"{name} needs confirmation"
    return f"{name} needs attention"


def blocker_action_label(name, blocker):
    code = (blocker or {}).get("code")
    if code == "trust_required":
        return f"Continue {name} setup in Terminal"
    if code == "update_required":
        return f"Continue {name} in Terminal"
    if code == "selection_required":
        return f"Confirm {name} in Terminal"
    return f"Open {name} in Terminal"


def all_blockers_action_label(providers):
    blocker_codes = {
        provider.get("blocker", {}).get("code")
        for provider in providers
        if isinstance(provider, dict) and has_blocker(provider)
    }
    if blocker_codes == {"trust_required"}:
        return "Continue setup in Terminal"
    return "Continue in Terminal"


def xbar_shell_action(label, command):
    command_str = shlex.join(command)
    print(
        f'{label} | bash=/bin/sh param1=-lc param2={shlex.quote(command_str)} terminal=true refresh=true'
    )


def load_cache():
    if not CACHE_PATH.exists():
        return None, f"Cache not found: {CACHE_PATH}"
    try:
        return json.loads(CACHE_PATH.read_text(encoding="utf-8")), None
    except Exception as exc:
        return None, f"Cache read error: {exc}"


def render_provider_block(name, provider):
    print(name)

    blocker = provider.get("blocker")
    if has_blocker(provider):
        print(blocker_heading(name, blocker))
        print(f"  details: {blocker.get('message')}")

    for key, label in (("five_hour", "5h"), ("weekly", "week"), ("sonnet", "sonnet")):
        metric = provider_metric(provider, key)
        if not metric:
            continue
        print(f"{label}: {pct(metric.get('left'))}% left")
        print(f"  reset: {metric.get('reset_at_label') or 'n/a'}")

    if provider.get("stale"):
        print("  note: stale")

    error = provider.get("error")
    if isinstance(error, dict) and error.get("message"):
        print(f"  error: {error['message']}")

    if has_blocker(provider):
        xbar_shell_action(
            blocker_action_label(name, blocker),
            ["python3", str(COLLECTOR_PATH), "resolve", "--providers", name.lower()],
        )


def main():
    data, error = load_cache()
    if error:
        print("AI --")
        print("---")
        print(error)
        return

    providers = data.get("providers", {})
    codex = providers.get("codex", {})
    claude = providers.get("claude", {})

    summary_parts = []
    has_any_blocker = False
    if codex.get("enabled"):
        p1, p2 = provider_summary(codex)
        summary_parts.append(f"Cdx {p1}/{p2}")
        has_any_blocker = has_any_blocker or has_blocker(codex)
    if claude.get("enabled"):
        p1, p2 = provider_summary(claude)
        summary_parts.append(f"Cl {p1}/{p2}")
        has_any_blocker = has_any_blocker or has_blocker(claude)

    summary = " · ".join(summary_parts) if summary_parts else "AI --"
    print(f"! {summary}" if has_any_blocker else summary)
    print("---")

    if has_any_blocker:
        xbar_shell_action(
            all_blockers_action_label([codex, claude]),
            ["python3", str(COLLECTOR_PATH), "resolve"],
        )
        print("---")

    if codex.get("enabled"):
        render_provider_block("Codex", codex)
        print("---")

    if claude.get("enabled"):
        render_provider_block("Claude", claude)
        print("---")

    print(f"Written: {data.get('written_at', 'n/a')}")


if __name__ == "__main__":
    main()
