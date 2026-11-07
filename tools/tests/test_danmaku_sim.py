"""danmaku_sim 的离线单元测试（不联网、不读真实弹幕）。

运行：
    python -m unittest discover -s tools/tests -v
"""

from __future__ import annotations

import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import danmaku_sim as sim  # noqa: E402  (路径注入后再导入)


class FilterTests(unittest.TestCase):
    def test_static_filters(self) -> None:
        cases = {
            "https://example.com": "url",
            "@某人 拿": "mention",
            "电话13800138000": "number",
            "/roll": "command",
            "拿拿拿拿拿拿拿拿": "repeat_chars",
            "！！！": "pure_punct",
            "": "too_short",
            "长" * 51: "too_long",
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.assertEqual(sim.filter_reason(sim.Message("u", text, 0)), expected)

    def test_rate_limit_same_uid(self) -> None:
        messages = [
            sim.Message("u1", "拿", 0),
            sim.Message("u1", "拿", 200),
            sim.Message("u2", "稳", 400),
        ]
        kept, stats = sim.filter_messages(messages)
        self.assertEqual(len(kept), 2)
        self.assertEqual(stats.rate_limited, 1)

    def test_duplicate_after_rate_window(self) -> None:
        messages = [
            sim.Message("u1", "拿", 0),
            sim.Message("u1", "拿", sim.RATE_LIMIT_GAP_MS + 1),
        ]
        kept, stats = sim.filter_messages(messages)
        self.assertEqual(len(kept), 1)
        self.assertEqual(stats.duplicate, 1)


class ScoreTests(unittest.TestCase):
    def test_plain_keyword(self) -> None:
        score = sim.score_text("贪")
        self.assertEqual(score["greedy"], 2.0)

    def test_negation_crosses_dimension(self) -> None:
        score = sim.score_text("别贪")
        self.assertEqual(score["greedy"], -2.0)
        self.assertEqual(score["steady"], 1.0)

    def test_intensifier_and_weakener(self) -> None:
        self.assertEqual(sim.score_text("非常贪")["greedy"], 3.0)
        self.assertEqual(sim.score_text("有点贪")["greedy"], 1.2)

    def test_not_too_greedy_is_weak_negation(self) -> None:
        score = sim.score_text("不太贪")
        self.assertEqual(score["greedy"], -1.0)
        self.assertEqual(score["steady"], 0.5)

    def test_longest_keyword_wins(self) -> None:
        score = sim.score_text("坐牢")
        self.assertEqual(score["lao"], 2.5)
        self.assertEqual(score["shuang"], 0.0)


class AggregateTests(unittest.TestCase):
    def test_fixture_is_stable(self) -> None:
        result = sim.run(sim.FIXTURE, sim.NOW_MS)
        self.assertEqual(result["received"], len(sim.FIXTURE))
        self.assertEqual(result["received"], result["kept"] + result["filtered_total"])
        self.assertEqual(set(result["weights"]), set(sim.DIMENSIONS))
        self.assertAlmostEqual(sum(result["weights"].values()), 1.0)
        self.assertEqual(result["label"], "steady")

    def test_deterministic(self) -> None:
        first = sim.run(sim.FIXTURE, sim.NOW_MS)
        second = sim.run(sim.FIXTURE, sim.NOW_MS)
        self.assertEqual(
            json.loads(json.dumps(first, sort_keys=True)),
            json.loads(json.dumps(second, sort_keys=True)),
        )

    def test_privacy_no_uid_or_text_in_output(self) -> None:
        result = sim.run(sim.FIXTURE, sim.NOW_MS)
        serialized = json.dumps(result, ensure_ascii=False, sort_keys=True)
        self.assertNotIn("u01", serialized)
        self.assertNotIn("拿血", serialized)
        self.assertNotIn("这局有点牢", serialized)
        self.assertIn("prompt_hint", result)

    def test_empty_stream_is_neutral(self) -> None:
        result = sim.run((), sim.NOW_MS)
        self.assertEqual(result["kept"], 0)
        self.assertEqual(result["label"], "neutral")
        self.assertEqual(sum(result["weights"].values()), 0.0)


class MainTests(unittest.TestCase):
    def test_main_exit_zero_json(self) -> None:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = sim.main(["--json"])
        self.assertEqual(code, 0)
        payload = json.loads(buffer.getvalue())
        self.assertEqual(payload["fixture_version"], sim.FIXTURE_VERSION)
        self.assertIn("prompt_hint", payload)

    def test_thresholds_are_ordered(self) -> None:
        self.assertLess(sim.MIN_SAMPLE_N, 10)
        self.assertGreater(sim.DOMINANT_THRESHOLD, sim.MARGIN_THRESHOLD)
        self.assertGreater(sim.MARGIN_THRESHOLD, sim.MIXED_MARGIN)


if __name__ == "__main__":
    unittest.main()
