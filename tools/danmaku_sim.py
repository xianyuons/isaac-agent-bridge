"""弹幕倾向聚合的离线最小验证（不联网、不接真实直播间）。

把固定弹幕流按“爽 / 牢 / 求稳 / 贪”四个维度打分、过滤刷屏并按时间衰减，
输出 4 个归一化权重和主导标签。设计与阈值说明见 docs/danmaku.md。

隐私约束（与生产实现一致）：
- 用户名不进入本模块；uid 只在内存里做哈希后用于限频，输出不含 uid。
- 弹幕原文只在内存中参与打分，不落盘、不打印、不外发。
- 输出只有聚合权重、样本数与过滤计数。

用法：
    python tools/danmaku_sim.py
    python tools/danmaku_sim.py --json

退出码：0 = 自检通过；1 = 自检失败（固定样例被破坏或聚合结果非法）。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import unicodedata
from dataclasses import dataclass
from typing import Iterable, Sequence

FIXTURE_VERSION = "1"

WINDOW_MS = 30_000
EWMA_HALF_LIFE_MS = 10_000
MIN_SAMPLE_N = 5
MIN_SIGNAL_MASS = 3.0
DOMINANT_THRESHOLD = 0.45
MARGIN_THRESHOLD = 0.15
MIXED_MARGIN = 0.10

DIMENSIONS: tuple[str, ...] = ("shuang", "lao", "steady", "greedy")
DIMENSION_LABELS: dict[str, str] = {
    "shuang": "爽",
    "lao": "牢",
    "steady": "求稳",
    "greedy": "贪",
}
OPPOSITE: dict[str, str] = {
    "shuang": "lao",
    "lao": "shuang",
    "steady": "greedy",
    "greedy": "steady",
}

# 生产实现用轮换盐的 HMAC；模拟器用固定盐保证可复现。哈希只用于限频。
UID_HASH_SALT = "danmaku-sim-fixture-v1"
UID_HASH_LEN = 16

MAX_TEXT_CHARS = 50
MIN_TEXT_CHARS = 1
MAX_REPEAT_CHARS = 6
RATE_LIMIT_GAP_MS = 2_000
RATE_LIMIT_PER_MINUTE = 20
DUPLICATE_WINDOW_MS = 30_000
BURST_WINDOW_MS = 5_000
BURST_LIMIT = 60

BASE_TS = 1_700_000_000_000
NOW_MS = BASE_TS + 30_000

# (词, 维度, 基础权重)；最长匹配优先，避免“坐牢”再命中“牢”。
KEYWORDS: tuple[tuple[str, str, float], ...] = tuple(
    sorted(
        (
            ("爆杀", "shuang", 2.0),
            ("爽局", "shuang", 2.0),
            ("起飞", "shuang", 1.5),
            ("爽", "shuang", 1.5),
            ("伤害", "shuang", 1.2),
            ("输出", "shuang", 1.2),
            ("神", "shuang", 1.2),
            ("杀", "shuang", 1.0),
            ("强", "shuang", 1.0),
            ("冲", "shuang", 1.0),
            ("打", "shuang", 0.8),
            ("牢底坐穿", "lao", 2.5),
            ("坐大牢", "lao", 2.5),
            ("坐牢", "lao", 2.5),
            ("牢", "lao", 2.0),
            ("折磨", "lao", 1.8),
            ("白给", "lao", 1.8),
            ("难受", "lao", 1.5),
            ("崩", "lao", 1.5),
            ("寄", "lao", 1.5),
            ("恶心", "lao", 1.5),
            ("求稳", "steady", 2.0),
            ("保命", "steady", 2.0),
            ("别浪", "steady", 1.8),
            ("稳", "steady", 1.8),
            ("回血", "steady", 1.8),
            ("红心", "steady", 1.5),
            ("苟", "steady", 1.5),
            ("魂心", "steady", 1.2),
            ("防御", "steady", 1.2),
            ("护盾", "steady", 1.2),
            ("小心", "steady", 1.2),
            ("血", "steady", 1.0),
            ("恶魔房", "greedy", 2.0),
            ("梭哈", "greedy", 2.0),
            ("贪", "greedy", 2.0),
            ("赌", "greedy", 1.8),
            ("高风险", "greedy", 1.8),
            ("天使房", "greedy", 1.5),
            ("搏", "greedy", 1.5),
            ("值", "greedy", 1.2),
            ("赚", "greedy", 1.2),
            ("拿", "greedy", 0.8),
        ),
        key=lambda item: len(item[0]),
        reverse=True,
    )
)

NEGATORS: tuple[str, ...] = tuple(
    sorted(("不要", "不用", "没有", "别", "不", "甭", "勿", "没"), key=len, reverse=True)
)
INTENSIFIERS: tuple[str, ...] = tuple(
    sorted(("特别", "非常", "超级", "极其", "超", "巨", "太", "真", "贼", "死"), key=len, reverse=True)
)
WEAKENERS: tuple[str, ...] = tuple(sorted(("一点点", "稍微", "有点", "些许", "略"), key=len, reverse=True))

URL_RE = re.compile(r"(https?://|www\.|b23\.tv)", re.IGNORECASE)
MENTION_RE = re.compile(r"@\S+")
NUMBER_RE = re.compile(r"\d{6,}")
COMMAND_RE = re.compile(r"^[/#!.]")
REPEAT_RE = re.compile(r"(.)\1{%d,}" % MAX_REPEAT_CHARS, re.DOTALL)
PURE_PUNCT_RE = re.compile(r"^[\W_]+$", re.UNICODE)
SPACE_PUNCT_RE = re.compile(r"[\s，,。.!！?？~～、；;：:]+")


@dataclass(frozen=True)
class Message:
    """一条固定样例弹幕。uid 只用于限频，不会出现在输出里。"""

    uid: str
    text: str
    ts_ms: int


@dataclass(frozen=True)
class KeptMessage:
    uid_key: str
    text: str
    ts_ms: int


@dataclass
class FilterStats:
    too_short: int = 0
    too_long: int = 0
    url: int = 0
    mention: int = 0
    number: int = 0
    command: int = 0
    repeat_chars: int = 0
    pure_punct: int = 0
    rate_limited: int = 0
    duplicate: int = 0
    burst_limited: int = 0

    def as_dict(self) -> dict[str, int]:
        return {
            "too_short": self.too_short,
            "too_long": self.too_long,
            "url": self.url,
            "mention": self.mention,
            "number": self.number,
            "command": self.command,
            "repeat_chars": self.repeat_chars,
            "pure_punct": self.pure_punct,
            "rate_limited": self.rate_limited,
            "duplicate": self.duplicate,
            "burst_limited": self.burst_limited,
        }

    @property
    def total(self) -> int:
        return sum(self.as_dict().values())


def hash_uid(uid: str) -> str:
    """把 uid 变成短期可用的内存键；生产实现应改用轮换盐的 HMAC。"""
    digest = hashlib.sha256(f"{UID_HASH_SALT}:{uid}".encode("utf-8")).hexdigest()
    return digest[:UID_HASH_LEN]


def normalize_text(text: str) -> str:
    return unicodedata.normalize("NFKC", text).strip()


def _prefix(text: str, index: int, span: int = 4) -> str:
    return SPACE_PUNCT_RE.sub("", text[max(0, index - span) : index])


def _context_factor(text: str, index: int) -> tuple[float, bool]:
    """返回 (强度系数, 是否被否定)。先剥离程度词，再判断否定，避免“特别”里的“别”误判。"""
    prefix = _prefix(text, index)

    # “不太贪”是弱否定，不能按“太”加强成强烈否定。
    if prefix.endswith("不太"):
        return 0.5, True

    factor = 1.0
    remainder = prefix
    for word in INTENSIFIERS:
        if remainder.endswith(word):
            factor = 1.5
            remainder = remainder[: -len(word)]
            break
    else:
        for word in WEAKENERS:
            if remainder.endswith(word):
                factor = 0.6
                remainder = remainder[: -len(word)]
                break

    negated = any(remainder.endswith(word) for word in NEGATORS)
    return factor, negated


def score_text(text: str) -> dict[str, float]:
    """按词表给一条弹幕打分；一个词只计一次，长词优先。"""
    scores: dict[str, float] = {dimension: 0.0 for dimension in DIMENSIONS}
    consumed = [False] * len(text)

    for word, dimension, weight in KEYWORDS:
        start = 0
        while True:
            index = text.find(word, start)
            if index < 0:
                break
            end = index + len(word)
            if any(consumed[index:end]):
                start = index + 1
                continue
            for position in range(index, end):
                consumed[position] = True

            factor, negated = _context_factor(text, index)
            magnitude = weight * factor
            if negated:
                scores[dimension] -= magnitude
                scores[OPPOSITE[dimension]] += magnitude * 0.5
            else:
                scores[dimension] += magnitude
            start = end

    return scores


def filter_reason(message: Message) -> str | None:
    """单条消息的静态过滤；限频/重复/突发由 filter_messages 负责。"""
    text = normalize_text(message.text)
    length = len(text)
    if length < MIN_TEXT_CHARS:
        return "too_short"
    if length > MAX_TEXT_CHARS:
        return "too_long"
    if URL_RE.search(text):
        return "url"
    if MENTION_RE.search(text):
        return "mention"
    if NUMBER_RE.search(text):
        return "number"
    if REPEAT_RE.search(text):
        return "repeat_chars"
    if PURE_PUNCT_RE.search(text):
        return "pure_punct"
    if COMMAND_RE.search(text):
        return "command"
    return None


def filter_messages(messages: Iterable[Message]) -> tuple[list[KeptMessage], FilterStats]:
    """按时间顺序过滤；同一 uid 的限频键只保留在内存。"""
    stats = FilterStats()
    kept: list[KeptMessage] = []
    last_seen: dict[str, int] = {}
    recent_text: dict[str, tuple[str, int]] = {}
    accepted_ts: list[int] = []
    per_uid_ts: dict[str, list[int]] = {}

    ordered = sorted(messages, key=lambda item: item.ts_ms)
    for message in ordered:
        reason = filter_reason(message)
        if reason is not None:
            setattr(stats, reason, getattr(stats, reason) + 1)
            continue

        uid_key = hash_uid(message.uid)
        text = normalize_text(message.text)
        previous_ts = last_seen.get(uid_key)
        if previous_ts is not None and message.ts_ms - previous_ts < RATE_LIMIT_GAP_MS:
            stats.rate_limited += 1
            continue

        uid_ts = [ts for ts in per_uid_ts.get(uid_key, []) if message.ts_ms - ts < 60_000]
        if len(uid_ts) >= RATE_LIMIT_PER_MINUTE:
            stats.rate_limited += 1
            continue

        duplicate_key = f"{uid_key}:{text}"
        duplicate = recent_text.get(duplicate_key)
        if duplicate is not None and message.ts_ms - duplicate[1] < DUPLICATE_WINDOW_MS:
            stats.duplicate += 1
            continue

        recent_burst = [ts for ts in accepted_ts if message.ts_ms - ts < BURST_WINDOW_MS]
        if len(recent_burst) >= BURST_LIMIT:
            stats.burst_limited += 1
            continue

        last_seen[uid_key] = message.ts_ms
        uid_ts.append(message.ts_ms)
        per_uid_ts[uid_key] = uid_ts
        recent_text[duplicate_key] = (text, message.ts_ms)
        accepted_ts.append(message.ts_ms)
        kept.append(KeptMessage(uid_key=uid_key, text=text, ts_ms=message.ts_ms))

    return kept, stats


def aggregate(kept: Sequence[KeptMessage], now_ms: int) -> dict[str, object]:
    totals: dict[str, float] = {dimension: 0.0 for dimension in DIMENSIONS}
    sample_n = 0
    scored_n = 0

    for message in kept:
        age = now_ms - message.ts_ms
        if age < 0 or age > WINDOW_MS:
            continue
        sample_n += 1
        score = score_text(message.text)
        if any(value != 0 for value in score.values()):
            scored_n += 1
        decay = 0.5 ** (age / EWMA_HALF_LIFE_MS)
        for dimension, value in score.items():
            totals[dimension] += value * decay

    positives = {dimension: max(0.0, value) for dimension, value in totals.items()}
    signal_mass = sum(positives.values())
    weights = (
        {dimension: positives[dimension] / signal_mass for dimension in DIMENSIONS}
        if signal_mass > 0
        else {dimension: 0.0 for dimension in DIMENSIONS}
    )

    return {
        "weights": weights,
        "label": classify(weights, sample_n, signal_mass),
        "sample_n": sample_n,
        "scored_n": scored_n,
        "signal_mass": signal_mass,
        "raw_totals": totals,
    }


def classify(weights: dict[str, float], sample_n: int, signal_mass: float) -> str:
    if sample_n < MIN_SAMPLE_N or signal_mass < MIN_SIGNAL_MASS:
        return "neutral"
    ranked = sorted(weights.items(), key=lambda item: item[1], reverse=True)
    top_name, top_weight = ranked[0]
    second_weight = ranked[1][1] if len(ranked) > 1 else 0.0
    if top_weight >= DOMINANT_THRESHOLD and top_weight - second_weight >= MARGIN_THRESHOLD:
        return top_name
    if top_weight - second_weight < MIXED_MARGIN:
        return "mixed"
    return top_name


def prompt_hint(result: dict[str, object]) -> str:
    """只把数值倾向交给提示词，绝不携带弹幕原文或用户名。"""
    weights = result["weights"]
    assert isinstance(weights, dict)
    parts = " / ".join(
        f"{DIMENSION_LABELS[dimension]} {weights[dimension]:.2f}" for dimension in DIMENSIONS
    )
    label = DIMENSION_LABELS.get(str(result["label"]), "无明显倾向")
    return (
        "观众倾向（只作参考，不得改变候选池约束与兜底）："
        f"{parts}；主导={label}；样本={result['sample_n']}"
    )


def run(messages: Sequence[Message] = (), now_ms: int = NOW_MS) -> dict[str, object]:
    kept, stats = filter_messages(messages)
    aggregate_result = aggregate(kept, now_ms)
    return {
        "fixture_version": FIXTURE_VERSION,
        "window_ms": WINDOW_MS,
        "half_life_ms": EWMA_HALF_LIFE_MS,
        "received": len(messages),
        "kept": len(kept),
        "in_window": aggregate_result["sample_n"],
        "filtered": stats.as_dict(),
        "filtered_total": stats.total,
        "weights": aggregate_result["weights"],
        "label": aggregate_result["label"],
        "sample_n": aggregate_result["sample_n"],
        "scored_n": aggregate_result["scored_n"],
        "signal_mass": aggregate_result["signal_mass"],
        "raw_totals": aggregate_result["raw_totals"],
        "prompt_hint": prompt_hint(aggregate_result),
    }


def _fixture() -> tuple[Message, ...]:
    base = BASE_TS
    rows: tuple[tuple[str, str, int], ...] = (
        ("u01", "拿血！", 0),
        ("u02", "这局有点牢", 1_000),
        ("u03", "求稳，别贪", 2_000),
        ("u04", "爽！爆杀", 3_000),
        ("u05", "冲，贪一波", 4_000),
        ("u06", "别浪，回血", 5_000),
        ("u07", "https://example.com 快来", 6_000),
        ("u08", "@某某 拿", 7_000),
        ("u09", "拿拿拿拿拿拿拿拿", 8_000),
        ("u10", "牢", 9_000),
        ("u10", "牢", 9_200),
        ("u11", "这什么垃圾", 10_000),
        ("u12", "非常贪", 11_000),
        ("u13", "不牢", 12_000),
        ("u14", "稳一点，别赌", 13_000),
        ("u15", "爽局", 14_000),
        ("u16", "恶魔房走起", 15_000),
        ("u17", "回血回血", 16_000),
        ("u18", "有点贪", 17_000),
        ("u19", "别贪", 18_000),
        ("u20", "牢底坐穿", 19_000),
        ("u21", "冲", 20_000),
        ("u22", "拿", 21_000),
        ("u23", "保命", 22_000),
        ("u24", "爽", 23_000),
        ("u25", "这局太牢了", 24_000),
        ("u26", "贪", 25_000),
        ("u27", "稳", 26_000),
        ("u28", "别爽了", 27_000),
        ("u29", "test", 28_000),
        ("u30", "我手机13800138000", 29_000),
        ("u31", "拿", 30_000),
    )
    return tuple(Message(uid=uid, text=text, ts_ms=base + offset) for uid, text, offset in rows)


FIXTURE: tuple[Message, ...] = _fixture()


def verify(result: dict[str, object], messages: Sequence[Message]) -> None:
    received = result["received"]
    filtered_total = result["filtered_total"]
    kept = result["kept"]
    assert received == kept + filtered_total, "received != kept + filtered_total"
    assert kept > 0, "fixture must keep at least one message"

    weights = result["weights"]
    assert isinstance(weights, dict)
    assert set(weights) == set(DIMENSIONS), "weights must cover exactly four dimensions"
    total = sum(float(value) for value in weights.values())
    if float(result["signal_mass"]) > 0:
        assert abs(total - 1.0) < 1e-9, "weights must sum to 1"
    assert result["label"] in (*DIMENSIONS, "mixed", "neutral"), "unknown label"

    serialized = json.dumps(result, ensure_ascii=False, sort_keys=True)
    for message in messages:
        assert message.uid not in serialized, "uid leaked into output"
        if len(message.text) >= 4:
            assert normalize_text(message.text) not in serialized, "raw danmaku text leaked into output"
    assert "prompt_hint" in result and "观众倾向" in str(result["prompt_hint"])
    assert result["filtered"]["url"] > 0, "fixture must exercise URL filtering"
    assert result["filtered"]["mention"] > 0, "fixture must exercise mention filtering"
    assert result["filtered"]["rate_limited"] > 0, "fixture must exercise rate limiting"

    again = run(messages, NOW_MS)
    assert json.loads(serialized) == json.loads(json.dumps(again, ensure_ascii=False, sort_keys=True)), "run is not deterministic"


def print_human(result: dict[str, object]) -> None:
    print(f"fixture_version={result['fixture_version']} window={result['window_ms']}ms")
    print(
        f"received={result['received']} kept={result['kept']} "
        f"in_window={result['in_window']} filtered={result['filtered_total']}"
    )
    print("filtered_reasons=" + json.dumps(result["filtered"], ensure_ascii=False, sort_keys=True))
    weights = result["weights"]
    assert isinstance(weights, dict)
    print(
        "[weights] "
        + " ".join(f"{dimension}={weights[dimension]:.3f}" for dimension in DIMENSIONS)
    )
    print(
        f"[label] {result['label']} sample_n={result['sample_n']} "
        f"scored_n={result['scored_n']} signal_mass={float(result['signal_mass']):.2f}"
    )
    print("[prompt] " + str(result["prompt_hint"]))
    print("[raw_totals] " + json.dumps(result["raw_totals"], ensure_ascii=False, sort_keys=True))


def main(argv: Sequence[str] | None = None) -> int:
    # Windows 控制台默认代码页可能不是 UTF-8；显式固定输出编码，避免中文乱码。
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(encoding="utf-8")

    parser = argparse.ArgumentParser(description="离线弹幕倾向聚合模拟器")
    parser.add_argument("--json", action="store_true", help="只输出 JSON")
    args = parser.parse_args(argv)

    try:
        result = run(FIXTURE, NOW_MS)
        verify(result, FIXTURE)
    except AssertionError as error:
        print(f"ERROR: self-check failed: {error}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print_human(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
