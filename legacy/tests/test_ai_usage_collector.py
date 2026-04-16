from __future__ import annotations

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from ai_usage_collector import (
    CollectorError,
    build_error,
    classify_provider_screen,
    normalize_reset_label,
    is_stale,
    merge_blocker,
    merge_failure,
    merge_success,
    merge_unavailable,
    parse_claude,
    parse_codex,
    provider_template,
    render_summary,
    render_text,
)

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"
REFERENCE_NOW = datetime(2026, 4, 16, 14, 6, tzinfo=ZoneInfo("Asia/Seoul"))


class ParseTests(unittest.TestCase):
    def test_parse_claude_fixture(self) -> None:
        text = (FIXTURES / "claude_usage_sample.txt").read_text(encoding="utf-8")
        parsed = parse_claude(text, reference_now=REFERENCE_NOW)

        self.assertEqual(parsed["summary"]["primary_left"], 88)
        self.assertEqual(parsed["summary"]["secondary_left"], 67)
        self.assertEqual(parsed["metrics"]["five_hour"]["left"], 88)
        self.assertEqual(parsed["metrics"]["weekly"]["left"], 67)
        self.assertEqual(parsed["metrics"]["sonnet"]["left"], 100)
        self.assertEqual(parsed["metrics"]["five_hour"]["reset_at_label"], "Apr 16 at 6pm")
        self.assertEqual(parsed["metrics"]["five_hour"]["reset_at_source_label"], "6pm (Asia/Seoul)")
        self.assertEqual(parsed["metrics"]["weekly"]["reset_at_label"], "Apr 17 at 2pm")
        self.assertEqual(parsed["metrics"]["sonnet"]["reset_at_label"], "Apr 16 at 6pm")

    def test_parse_codex_fixture(self) -> None:
        text = (FIXTURES / "codex_status_sample.txt").read_text(encoding="utf-8")
        parsed = parse_codex(text, reference_now=REFERENCE_NOW)

        self.assertEqual(parsed["summary"]["primary_left"], 99)
        self.assertEqual(parsed["summary"]["secondary_left"], 94)
        self.assertEqual(parsed["metrics"]["five_hour"]["left"], 99)
        self.assertEqual(parsed["metrics"]["weekly"]["left"], 94)
        self.assertEqual(parsed["metrics"]["five_hour"]["reset_at_label"], "Apr 16 at 6:32pm")
        self.assertEqual(parsed["metrics"]["weekly"]["reset_at_label"], "Apr 17 at 3:04pm")
        self.assertEqual(parsed["metrics"]["weekly"]["reset_at_source_label"], "15:04 on 17 Apr")

    def test_parse_codex_inline_status_summary(self) -> None:
        text = """
        >_ OpenAI Codex
        model: gpt-5.4 xhigh
        directory: ~/Library/Application Support/AIUsageMenuBar/workdir
        /status
        gpt-5.4 xhigh · Context 100% left · 0 in · 0 out · 5h 93% · weekly 90%
        """
        parsed = parse_codex(text, reference_now=REFERENCE_NOW)

        self.assertEqual(parsed["summary"]["primary_left"], 93)
        self.assertEqual(parsed["summary"]["secondary_left"], 90)
        self.assertEqual(parsed["metrics"]["five_hour"]["left"], 93)
        self.assertEqual(parsed["metrics"]["weekly"]["left"], 90)
        self.assertIsNone(parsed["metrics"]["five_hour"]["reset_at_label"])

    def test_parse_claude_infers_missing_sonnet_reset(self) -> None:
        text = """
        Current session
        4% used
        Resets 7pm (Asia/Seoul)

        Current week (all models)
        44% used
        Resets 2pm (Asia/Seoul)

        Current week (Sonnet only)
        0% used
        """
        parsed = parse_claude(text, reference_now=REFERENCE_NOW)

        self.assertEqual(parsed["metrics"]["sonnet"]["reset_at_source_label"], "7pm (Asia/Seoul)")
        self.assertEqual(parsed["metrics"]["sonnet"]["reset_at_label"], "Apr 16 at 7pm")

    def test_normalize_reset_label_infers_date(self) -> None:
        expanded = normalize_reset_label("2pm (Asia/Seoul)", reference_now=REFERENCE_NOW)
        self.assertEqual(expanded, "Apr 17 at 2pm")


class MergeAndFreshnessTests(unittest.TestCase):
    def test_merge_success_resets_failure_state(self) -> None:
        previous = provider_template("claude")
        previous["enabled"] = True
        previous["consecutive_failures"] = 3
        previous["error"] = build_error("parse_failed", "old error")

        collected = {
            "summary": {
                "primary_left": 88,
                "secondary_left": 67,
                "primary_label": "5h",
                "secondary_label": "week",
            },
            "metrics": {
                "five_hour": {"left": 88, "reset_at_label": "6pm", "official_label": "Current session"},
                "weekly": {"left": 67, "reset_at_label": "Apr 17", "official_label": "Current week (all models)"},
            },
            "source": {"collector": "claude", "method": "interactive"},
        }

        merged = merge_success(previous, "claude", collected, "2026-04-15T20:00:00+09:00")
        self.assertEqual(merged["consecutive_failures"], 0)
        self.assertIsNone(merged["error"])
        self.assertEqual(merged["summary"]["primary_left"], 88)

    def test_merge_failure_preserves_existing_metrics(self) -> None:
        previous = provider_template("codex")
        previous["enabled"] = True
        previous["metrics"] = {
            "five_hour": {"left": 91, "reset_at_label": "18:32", "official_label": "5h limit"}
        }
        previous["summary"]["primary_left"] = 91

        merged = merge_failure(
            previous,
            "codex",
            CollectorError("capture_failed", "tmux session not found"),
            "2026-04-15T20:00:00+09:00",
        )

        self.assertEqual(merged["consecutive_failures"], 1)
        self.assertEqual(merged["metrics"]["five_hour"]["left"], 91)
        self.assertEqual(merged["summary"]["primary_left"], 91)
        self.assertEqual(merged["error"]["code"], "capture_failed")

    def test_merge_unavailable_clears_metrics(self) -> None:
        previous = provider_template("codex")
        previous["enabled"] = True
        previous["metrics"] = {
            "five_hour": {"left": 91, "reset_at_label": "18:32", "official_label": "5h limit"}
        }
        previous["summary"]["primary_left"] = 91

        merged = merge_unavailable(
            previous,
            "codex",
            CollectorError("startup_failed", "Codex installation is incomplete"),
            "2026-04-15T20:00:00+09:00",
        )

        self.assertEqual(merged["status"], "unavailable")
        self.assertEqual(merged["metrics"], {})
        self.assertIsNone(merged["summary"]["primary_left"])
        self.assertEqual(merged["error"]["code"], "startup_failed")

    def test_merge_blocker_preserves_existing_metrics(self) -> None:
        previous = provider_template("claude")
        previous["enabled"] = True
        previous["metrics"] = {
            "five_hour": {"left": 88, "reset_at_label": "6pm", "official_label": "Current session"}
        }
        previous["summary"]["primary_left"] = 88

        blocker = {
            "code": "trust_required",
            "message": "Claude needs workspace trust approval",
            "detected_at": "2026-04-15T20:00:00+09:00",
            "screen_excerpt": "trust this folder?",
        }

        merged = merge_blocker(previous, "claude", blocker, "2026-04-15T20:00:00+09:00")
        self.assertEqual(merged["status"], "blocked")
        self.assertEqual(merged["metrics"]["five_hour"]["left"], 88)
        self.assertEqual(merged["blocker"]["code"], "trust_required")
        self.assertIsNone(merged["error"])

    def test_is_stale_by_failure_count(self) -> None:
        provider = provider_template("claude")
        provider["enabled"] = True
        provider["last_success_at"] = datetime.now().astimezone().isoformat(timespec="seconds")
        provider["consecutive_failures"] = 2
        config = {"stale_after_seconds": 1800, "stale_after_failures": 2}
        self.assertTrue(is_stale(provider, config))

    def test_is_stale_by_age(self) -> None:
        provider = provider_template("codex")
        provider["enabled"] = True
        provider["last_success_at"] = (
            datetime.now().astimezone() - timedelta(hours=1)
        ).isoformat(timespec="seconds")
        provider["consecutive_failures"] = 0
        config = {"stale_after_seconds": 1800, "stale_after_failures": 2}
        self.assertTrue(is_stale(provider, config))

    def test_render_summary_respects_enabled_providers(self) -> None:
        data = {
            "providers": {
                "claude": {
                    "enabled": True,
                    "blocker": None,
                    "summary": {"primary_left": 88, "secondary_left": 67},
                },
                "codex": {
                    "enabled": False,
                    "blocker": None,
                    "summary": {"primary_left": 99, "secondary_left": 94},
                },
            }
        }
        self.assertEqual(render_summary(data), "Cl 88/67")

    def test_render_summary_prefixes_blocker_warning(self) -> None:
        data = {
            "providers": {
                "claude": {
                    "enabled": True,
                    "blocker": {"code": "trust_required"},
                    "summary": {"primary_left": 88, "secondary_left": 67},
                }
            }
        }
        self.assertEqual(render_summary(data), "! Cl 88/67")

    def test_render_summary_marks_unavailable_provider(self) -> None:
        data = {
            "providers": {
                "codex": {
                    "enabled": True,
                    "status": "unavailable",
                    "blocker": None,
                    "summary": {"primary_left": None, "secondary_left": None},
                }
            }
        }
        self.assertEqual(render_summary(data), "! Cdx --")

    def test_render_summary_marks_error_provider(self) -> None:
        data = {
            "providers": {
                "claude": {
                    "enabled": True,
                    "status": "error",
                    "stale": True,
                    "blocker": None,
                    "summary": {"primary_left": 44, "secondary_left": 56},
                }
            }
        }
        self.assertEqual(render_summary(data), "! Cl 44/56")


    def test_render_text_honors_display_settings(self) -> None:
        data = {
            "providers": {
                "claude": {
                    "enabled": True,
                    "status": "error",
                    "stale": False,
                    "blocker": None,
                    "summary": {"primary_left": 44, "secondary_left": 56},
                    "metrics": {
                        "five_hour": {"left": 44, "reset_at_label": "Apr 16 at 7pm", "reset_at_source_label": "7pm (Asia/Seoul)"},
                        "sonnet": {"left": 100, "reset_at_label": "Apr 16 at 7pm", "reset_at_source_label": "7pm (Asia/Seoul)"},
                    },
                    "error": {"message": "boom"},
                }
            }
        }
        config = {
            "show_sonnet_metric": False,
            "show_reset_labels": False,
            "show_error_details": False,
            "reset_label_style": "friendly",
        }

        rendered = render_text(data, config=config)

        self.assertIn("- 5h: 44% left", rendered)
        self.assertNotIn("sonnet", rendered)
        self.assertNotIn("reset:", rendered)
        self.assertNotIn("boom", rendered)

class ScreenClassifierTests(unittest.TestCase):
    def test_classify_claude_trust_prompt(self) -> None:
        screen = "Claude Code\nDo you trust this folder?\nPress Enter to continue"
        classified = classify_provider_screen("claude", screen)
        self.assertEqual(classified["state"], "blocked")
        self.assertEqual(classified["blocker"]["code"], "trust_required")

    def test_classify_codex_update_prompt(self) -> None:
        screen = "OpenAI Codex\nUpdate available\nPress Enter to continue"
        classified = classify_provider_screen("codex", screen)
        self.assertEqual(classified["state"], "blocked")
        self.assertEqual(classified["blocker"]["code"], "update_required")


if __name__ == "__main__":
    unittest.main()
