#!/usr/bin/env python3
"""离线的 mod ↔ 插件 mock 联调（不启动游戏、不访问网络、不调用真实模型）。

它模拟游戏侧写出 `state.json`，用一个**假的 DSH LLM 流**驱动 `plugin/index.js` 的
`isaac_decide`，再按 `docs/protocol.md`（draft.5）校验插件写出的 `decision.json` 与
`plugin_status.json`。

四个场景（`docs/protocol.md` §2.8 / §3.3 / §6.1 / §6.3）：

1. valid        合法 state + 模型返回候选池内的 id → 期望 llm 决策。
2. missing      缺字段：
   2a 缺 `state.items`（body 非法）→ 插件必须写 `valid:false` 的拒绝决策；
   2b 缺 `request_id`（信封不可读）→ 插件不得写 decision，已有旧文件保持原样。
3. invalid_id   模型两次都返回候选池外的 id → 兜底规则决策，`invalid_id` 留痕。
4. timeout      state 已过有效期 → 不调模型，直接规则兜底，`TIMEOUT` 留痕。

每个场景还做 draft.5 的严格校验：
- `decision.session_id` 必填，且必须回显 `state.session_id`；
- `plugin_status.json` 存在、≤ 8 KiB、`status ∈ {ready,degraded,refused}`、
  `x_runtime.error_code_counts` 五类齐全且为非负整数。

输入是固定样例（`protocol/examples/01-success.json` 中的 state 文档）加当前墙钟，
没有随机数；退出码 0 表示全部通过，1 表示有场景失败，2 表示环境/参数错误。

用法（在仓库根目录）：

    python tools/mock_e2e.py
    python tools/mock_e2e.py --keep                    # 保留临时桥目录，便于查文件
    python tools/mock_e2e.py --plugin <index.js>       # 指定被测插件（旧版本“红测试”）

前置：Node.js >= 20（插件要求），Python >= 3.10。不需要 DSH 进程、不需要 API key。
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
PLUGIN_PATH = REPO_ROOT / "plugin" / "index.js"
EXAMPLE_PATH = REPO_ROOT / "protocol" / "examples" / "01-success.json"

PROTOCOL_MAJOR = 1
ERROR_CODES = {"IO", "TIMEOUT", "VALIDATION", "MODEL", "INTERNAL"}
SAFE_REASON_CODES = {"no_candidate", "player_dead"}

REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
DECISION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
GEN_LEVEL_KEY_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
PROTOCOL_VERSION_RE = re.compile(r"^\d+\.\d+(\.\d+)?$")
PROVIDER_ID_RE = re.compile(r"^[a-z][a-z0-9_.:-]{2,63}$")
CONTROL_CHAR_RE = re.compile(r"[\u0000-\u001f\u007f-\u009f]")

# draft.5 的可选诊断文件（插件写、mod/QA 读）。
PLUGIN_STATUS_FILE = "plugin_status.json"
MAX_STATUS_BYTES = 8 * 1024
STATUS_VALUES = {"ready", "degraded", "refused"}

# 测试用假模型必须“看起来像”合法的 DSH 选择，方便断言写盘结果。
LLM_MODEL = "mock-model"
MOCK_OK_ID = 22  # 与 01-success 示例一致：Breakfast（heal）
MOCK_BAD_ID = 999  # 不在候选池内

# Node 侧 harness：把插件的 `__testing.runIsaacDecide` 当成 DSH 工具来调用。
# 单进程 + 单次调用，所以不需要真实 DSH 的 cordis 上下文。
HARNESS_SOURCE = r"""
import { promises as fsp } from 'node:fs'
import { pathToFileURL } from 'node:url'

const [, , pluginPath, inputPath] = process.argv
const request = JSON.parse(await fsp.readFile(inputPath, 'utf8'))

const { __testing: T } = await import(pathToFileURL(pluginPath).href)
const responses = Array.isArray(request.responses) ? request.responses : []

let llmCalls = 0
const llm = {
  stream() {
    const text = responses[Math.min(llmCalls, Math.max(responses.length - 1, 0))] ?? ''
    llmCalls += 1
    return (async function* () {
      if (text) yield { type: 'text-delta', text }
      yield { type: 'finish', reason: { kind: 'stop' } }
    })()
  },
}

const ctx = {
  get(name) {
    if (name === 'llm') return llm
    if (name === 'agentDefaultModel') {
      return { currentSelection: () => ({ provider: 'mock', model: 'mock-model' }) }
    }
    return undefined
  },
}

const exec = {
  agent: { model: { current: () => ({ provider: 'mock', model: 'mock-model' }) } },
}

let payload
try {
  const result = await T.runIsaacDecide({
    config: { bridgeDir: request.bridgeDir },
    ctx,
    args: {},
    exec,
  })
  const stateResult = await T.runIsaacState({ config: { bridgeDir: request.bridgeDir } })
  payload = { result, llm_calls: llmCalls, state_read: stateResult }
} catch (error) {
  payload = {
    harness_error: String(error?.stack ?? error),
    llm_calls: llmCalls,
  }
}

console.log(`MOCK_RESULT ${JSON.stringify(payload)}`)
"""


def load_example_state() -> dict[str, Any]:
    """取版本化样例里的 state.json，避免 mock 自己手写一份会漂移的协议文档。"""
    example = json.loads(EXAMPLE_PATH.read_text(encoding="utf-8"))
    state = copy.deepcopy(example["files"]["state.json"])
    return state


def make_state(now_ms: int, request_id: str) -> dict[str, Any]:
    state = load_example_state()
    state["ts"] = now_ms
    state["validity_ms"] = 1500
    state["request_id"] = request_id
    return state


def run_plugin(
    harness: Path,
    plugin_path: Path,
    bridge_dir: Path,
    state: dict[str, Any],
    responses: list[str],
) -> dict[str, Any]:
    """写 state.json，跑一次 Node harness，返回插件结果与 llm 调用次数。"""
    bridge_dir.mkdir(parents=True, exist_ok=True)
    state_path = bridge_dir / "state.json"
    state_path.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")

    request_path = bridge_dir / ".mock-request.json"
    request_path.write_text(
        json.dumps(
            {
                "bridgeDir": str(bridge_dir),
                "responses": responses,
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    completed = subprocess.run(
        ["node", str(harness), str(plugin_path), str(request_path)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=60,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            "Node harness 失败：\n"
            f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
        )

    marker = "MOCK_RESULT "
    for line in completed.stdout.splitlines():
        if line.startswith(marker):
            return json.loads(line[len(marker):])
    raise RuntimeError(f"Node harness 没有输出结果行：\n{completed.stdout}\n{completed.stderr}")


def read_decision(bridge_dir: Path) -> dict[str, Any] | None:
    path = bridge_dir / "decision.json"
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def read_plugin_status(bridge_dir: Path) -> dict[str, Any] | None:
    path = bridge_dir / PLUGIN_STATUS_FILE
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def expect_plugin_status(
    checker: Checker,
    bridge_dir: Path,
    scenario: str,
    expected_status: str,
) -> dict[str, Any] | None:
    """校验 draft.5 §1.11 的 plugin_status.json（存在/大小/枚举/x_runtime 计数键）。"""
    path = bridge_dir / PLUGIN_STATUS_FILE
    exists = path.is_file()
    checker.ok(f"[{scenario}] plugin_status.json 已写出", exists)
    if not exists:
        return None

    size = path.stat().st_size
    checker.ok(
        f"[{scenario}] plugin_status.json ≤ 8 KiB",
        size <= MAX_STATUS_BYTES,
        f"{size} bytes",
    )
    try:
        doc = read_plugin_status(bridge_dir)
    except json.JSONDecodeError as exc:
        checker.ok(f"[{scenario}] plugin_status.json 可解析", False, str(exc))
        return None
    checker.ok(f"[{scenario}] plugin_status.json 可解析", isinstance(doc, dict))
    if not isinstance(doc, dict):
        return None

    status = doc.get("status")
    checker.ok(
        f"[{scenario}] status 在 ready/degraded/refused 内",
        status in STATUS_VALUES,
        f"status={status!r}",
    )
    checker.ok(
        f"[{scenario}] status={expected_status}",
        status == expected_status,
        f"actual={status!r}",
    )

    runtime = doc.get("x_runtime")
    counts = runtime.get("error_code_counts") if isinstance(runtime, dict) else None
    checker.ok(
        f"[{scenario}] x_runtime.error_code_counts 五类齐全",
        isinstance(counts, dict) and all(code in counts for code in ERROR_CODES),
        f"keys={sorted(counts) if isinstance(counts, dict) else counts!r}",
    )
    checker.ok(
        f"[{scenario}] error_code_counts 均为非负整数",
        isinstance(counts, dict)
        and all(isinstance(counts.get(code), int) and counts.get(code) >= 0 for code in ERROR_CODES),
        f"counts={counts!r}",
    )
    return doc


def tmp_leftovers(bridge_dir: Path) -> list[str]:
    return sorted(p.name for p in bridge_dir.glob("decision.json.tmp.*"))


def validate_decision(doc: Any, state: dict[str, Any]) -> list[str]:
    """按 docs/protocol.md §3.1/§3.2/§3.3/§3.5 校验一份 decision.json。"""
    errors: list[str] = []

    def need(condition: bool, message: str) -> None:
        if not condition:
            errors.append(message)

    if not isinstance(doc, dict):
        return ["decision.json 不是 JSON 对象"]

    version = doc.get("protocol_version")
    need(isinstance(version, str) and bool(PROTOCOL_VERSION_RE.match(version or "")),
         "protocol_version 缺失或格式非法")
    if isinstance(version, str) and PROTOCOL_VERSION_RE.match(version):
        need(int(version.split(".")[0]) == PROTOCOL_MAJOR, "protocol_version major 不是 1")

    need(doc.get("request_id") == state.get("request_id"), "request_id 没有回显 state")
    session_id = doc.get("session_id")
    need(isinstance(session_id, str) and bool(SESSION_ID_RE.match(session_id or "")),
         "session_id 缺失或格式非法（draft.5 必填）")
    need(session_id == state.get("session_id"), "session_id 没有回显 state.session_id")
    need(isinstance(doc.get("decision_id"), str) and bool(DECISION_ID_RE.match(doc["decision_id"])),
         "decision_id 缺失或格式非法")
    need(doc.get("gen_level_key") == state.get("gen_level_key"), "gen_level_key 与 state 不一致")
    need(isinstance(doc.get("ts"), int) and doc["ts"] >= 0, "ts 缺失或不是非负整数")

    error_code = doc.get("error_code", "__missing__")
    need(error_code is None or error_code in ERROR_CODES, f"error_code 非法：{error_code!r}")
    need(isinstance(doc.get("valid"), bool), "valid 缺失或不是布尔值")
    valid = doc.get("valid")
    error_is_set = isinstance(error_code, str) and error_code in ERROR_CODES

    decision = doc.get("decision")
    if not isinstance(decision, dict):
        return errors + ["decision 缺失或不是对象"]

    choice = decision.get("choice")
    if not isinstance(choice, dict):
        errors.append("decision.choice 缺失或不是对象")
    else:
        choice_type = choice.get("type")
        if choice_type == "item":
            item_id = choice.get("item_id")
            candidate_ids = {
                candidate.get("item_id")
                for candidate in state.get("state", {}).get("candidates", [])
                if isinstance(candidate, dict)
            }
            need(isinstance(item_id, int) and item_id in candidate_ids,
                 f"choice.item_id={item_id!r} 不在候选池 {sorted(candidate_ids)}")
        elif choice_type == "action":
            need(choice.get("action") == "skip", f"未知 action：{choice.get('action')!r}（v1 只允许 skip）")
        else:
            errors.append(f"choice.type 非法：{choice_type!r}")

    confidence = decision.get("confidence")
    need(isinstance(confidence, (int, float)) and not isinstance(confidence, bool)
         and 0 <= float(confidence) <= 1, f"confidence 非法：{confidence!r}")

    fallback = decision.get("fallback")
    need(isinstance(fallback, bool), "decision.fallback 缺失或不是布尔值")
    source = decision.get("source")
    need(source in {"llm", "rule"}, f"source 非法：{source!r}")

    provider_id = decision.get("provider_id")
    need(isinstance(provider_id, str) and bool(PROVIDER_ID_RE.match(provider_id or "")),
         f"provider_id 非法：{provider_id!r}")
    if isinstance(provider_id, str) and PROVIDER_ID_RE.match(provider_id):
        prefix = provider_id.split(":")[0]
        if source == "llm":
            need(prefix == "llm", f"source=llm 但 provider_id 前缀是 {prefix!r}")
        elif source == "rule":
            need(prefix in {"rule", "viewer", "preset"},
                 f"source=rule 但 provider_id 前缀是 {prefix!r}")

    reason = decision.get("reason")
    if reason is not None:
        need(isinstance(reason, str), "reason 不是字符串或 null")
        if isinstance(reason, str):
            need(len(reason) <= 280, "reason 超过 280 字符")
            need(not CONTROL_CHAR_RE.search(reason), "reason 含控制字符（必须单行）")

    reason_code = decision.get("reason_code")
    need(reason_code is None or isinstance(reason_code, str), "reason_code 类型非法")

    # §3.3 真值表
    if valid is False:
        need(error_is_set, "valid:false 但 error_code 为 null")
        need(fallback is True, "valid:false 但 fallback 不是 true")
        need(source == "rule", "valid:false 但 source 不是 rule")
        need(isinstance(reason_code, str) and reason_code != "", "valid:false 但缺 reason_code")
        need(isinstance(choice, dict) and choice.get("type") == "action" and choice.get("action") == "skip",
             "valid:false 但 choice 不是 skip")
    elif valid is True:
        if source == "llm":
            need(fallback is False, "source=llm 但 fallback 不是 false")
            need(not error_is_set, "source=llm 却带 error_code")
        if error_is_set:
            need(fallback is True, "带 error_code 却不是 fallback")
        if fallback is True and not error_is_set:
            need(reason_code in SAFE_REASON_CODES,
                 f"安全跳过之外的兜底缺 error_code（reason_code={reason_code!r}）")
        if fallback is False:
            need(not error_is_set, "fallback:false 却带 error_code")

    return errors


def write_harness(directory: Path) -> Path:
    harness = directory / "harness.mjs"
    harness.write_text(HARNESS_SOURCE, encoding="utf-8")
    return harness


class Checker:
    """收集断言，统一打印 PASS/FAIL，最后决定退出码。"""

    def __init__(self) -> None:
        self.results: list[tuple[str, bool, str]] = []

    def ok(self, label: str, condition: bool, detail: str = "") -> None:
        self.results.append((label, bool(condition), detail))
        status = "PASS" if condition else "FAIL"
        print(f"  {status}  {label}" + (f" — {detail}" if detail else ""))

    def section(self, title: str) -> None:
        print(f"\n== {title} ==")

    @property
    def failed(self) -> int:
        return sum(1 for _, condition, _ in self.results if not condition)


def expect_decision(
    checker: Checker,
    bridge_dir: Path,
    state: dict[str, Any],
    scenario: str,
) -> dict[str, Any] | None:
    """读取并为本次场景的 decision.json 做通用校验，返回文档（不存在返回 None）。"""
    decision = read_decision(bridge_dir)
    checker.ok(f"[{scenario}] decision.json 已写出", decision is not None)
    if decision is None:
        return None
    violations = validate_decision(decision, state)
    checker.ok(
        f"[{scenario}] decision.json 符合协议 §3.1/§3.3",
        not violations,
        "; ".join(violations) if violations else "无违规项",
    )
    checker.ok(
        f"[{scenario}] 没有残留 .tmp 文件",
        not tmp_leftovers(bridge_dir),
        ", ".join(tmp_leftovers(bridge_dir)),
    )
    return decision


def main() -> int:
    parser = argparse.ArgumentParser(description="isaac-agent 离线 mock 联调（四种场景）")
    parser.add_argument("--keep", action="store_true", help="保留临时桥目录，便于检查文件")
    parser.add_argument(
        "--plugin",
        default=str(PLUGIN_PATH),
        help="被测插件入口（默认仓库自带的 plugin/index.js；用于旧版本对照的“红测试”）",
    )
    args = parser.parse_args()

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")

    plugin_path = Path(args.plugin).resolve()
    if shutil.which("node") is None:
        print("找不到 node；请安装 Node.js >= 20", file=sys.stderr)
        return 2
    for required in (plugin_path, EXAMPLE_PATH):
        if not required.is_file():
            print(f"缺少文件：{required}（请在仓库根目录运行）", file=sys.stderr)
            return 2

    print("isaac-agent mock e2e：state.json → isaac_decide → decision.json（离线）")
    print(f"仓库：{REPO_ROOT}")
    print(f"被测插件：{plugin_path}")

    checker = Checker()
    work_dir = Path(tempfile.mkdtemp(prefix="isaac-mock-e2e-"))
    harness = write_harness(work_dir)
    now_ms = int(time.time() * 1000)
    print(f"临时目录：{work_dir}（--keep 可保留）")

    try:
        # ── 场景 1：合法 state → llm 决策 ────────────────────────────────
        checker.section("场景 1/4：合法 state → 期望 llm 决策")
        state = make_state(now_ms, "r-mock-valid-0001")
        bridge = work_dir / "bridge-valid"
        responses = [json.dumps(
            {"item_id": MOCK_OK_ID, "reason": "红心告急，先补红心", "confidence": 0.72},
            ensure_ascii=False,
        )]
        payload = run_plugin(harness, plugin_path, bridge, state, responses)
        result = payload.get("result", {})
        print(f"  插件结果：ok={result.get('ok')} written={result.get('written')} "
              f"source={result.get('source')} choice={result.get('choice')}")
        checker.ok("插件返回 ok=true", result.get("ok") is True)
        checker.ok("插件报告 written=true", result.get("written") is True)
        checker.ok("llm 只被调用 1 次", payload.get("llm_calls") == 1,
                   f"llm_calls={payload.get('llm_calls')}")

        decision = expect_decision(checker, bridge, state, "valid")
        if decision is not None:
            body = decision["decision"]
            checker.ok("source=llm", body.get("source") == "llm")
            checker.ok("fallback=false", body.get("fallback") is False)
            checker.ok("error_code=null", decision.get("error_code") is None)
            checker.ok(
                f"choice.item_id={MOCK_OK_ID}",
                body.get("choice", {}).get("item_id") == MOCK_OK_ID,
                f"actual={body.get('choice')}",
            )

        # isaac_state 能读到刚写的 state，且未过期
        state_read = payload.get("state_read", {})
        checker.ok("isaac_state 读取成功", state_read.get("ok") is True)
        checker.ok("isaac_state 未标记 stale", state_read.get("stale") is False,
                   f"stale={state_read.get('stale')}")
        expect_plugin_status(checker, bridge, "valid", "ready")

        # ── 场景 2：缺字段 ──────────────────────────────────────────────
        checker.section("场景 2/4：缺字段")
        # 2a：body 缺 state.items（信封可读）→ 必须写 valid:false 拒绝决策
        print("  [2a] 缺 state.items → 期望 valid:false 拒绝决策")
        state_2a = make_state(now_ms, "r-mock-missing-0002")
        del state_2a["state"]["items"]
        bridge_2a = work_dir / "bridge-missing-body"
        payload = run_plugin(harness, plugin_path, bridge_2a, state_2a, responses)
        result = payload.get("result", {})
        print(f"  插件结果：ok={result.get('ok')} written={result.get('written')} "
              f"valid={result.get('valid')} reason_code={result.get('reason_code')}")
        checker.ok("[2a] 仍返回 ok=true（拒绝也是一份决策）", result.get("ok") is True)
        checker.ok("[2a] written=true", result.get("written") is True)
        checker.ok("[2a] valid=false", result.get("valid") is False)
        checker.ok("[2a] reason_code=missing_field", result.get("reason_code") == "missing_field",
                   f"actual={result.get('reason_code')}")
        checker.ok("[2a] 没有调用模型", payload.get("llm_calls") == 0,
                   f"llm_calls={payload.get('llm_calls')}")
        decision_2a = expect_decision(checker, bridge_2a, state_2a, "missing-body")
        if decision_2a is not None:
            body = decision_2a["decision"]
            checker.ok("[2a] choice 是 skip", body.get("choice", {}).get("action") == "skip")
            checker.ok("[2a] error_code=VALIDATION", decision_2a.get("error_code") == "VALIDATION")
            checker.ok("[2a] reason_code=missing_field", body.get("reason_code") == "missing_field",
                       f"actual={body.get('reason_code')}")
        expect_plugin_status(checker, bridge_2a, "missing-body", "refused")

        # 2b：信封缺 request_id → 不得写 decision，旧文件原样保留
        print("  [2b] 缺 request_id → 期望不写 decision、旧文件不动")
        state_2b = make_state(now_ms, "r-mock-missing-0003")
        del state_2b["request_id"]
        bridge_2b = work_dir / "bridge-missing-envelope"
        bridge_2b.mkdir(parents=True, exist_ok=True)
        sentinel = bridge_2b / "decision.json"
        sentinel_text = '{"sentinel":"keep-me"}'
        sentinel.write_text(sentinel_text, encoding="utf-8")
        payload = run_plugin(harness, plugin_path, bridge_2b, state_2b, responses)
        result = payload.get("result", {})
        print(f"  插件结果：ok={result.get('ok')} written={result.get('written')} "
              f"reason_code={result.get('reason_code')}")
        checker.ok("[2b] ok=false", result.get("ok") is False)
        checker.ok("[2b] written=false", result.get("written") is False)
        checker.ok("[2b] error_code=VALIDATION", result.get("error_code") == "VALIDATION")
        checker.ok("[2b] reason_code=missing_field", result.get("reason_code") == "missing_field",
                   f"actual={result.get('reason_code')}")
        checker.ok("[2b] 旧 decision.json 保持原样",
                   sentinel.read_text(encoding="utf-8") == sentinel_text)
        checker.ok("[2b] 没有调用模型", payload.get("llm_calls") == 0,
                   f"llm_calls={payload.get('llm_calls')}")
        expect_plugin_status(checker, bridge_2b, "missing-envelope", "refused")

        # ── 场景 3：非法 id → 两次失败后规则兜底 ────────────────────────
        checker.section("场景 3/4：模型返回候选池外的 id → 重试一次 → 规则兜底")
        state = make_state(now_ms + 10, "r-mock-badid-0004")
        bridge = work_dir / "bridge-invalid-id"
        bad = json.dumps({"item_id": MOCK_BAD_ID, "reason": "编造的 id", "confidence": 0.9},
                         ensure_ascii=False)
        payload = run_plugin(harness, plugin_path, bridge, state, [bad, bad])
        result = payload.get("result", {})
        print(f"  插件结果：ok={result.get('ok')} written={result.get('written')} "
              f"source={result.get('source')} error_code={result.get('error_code')} "
              f"choice={result.get('choice')}")
        checker.ok("插件返回 ok=true", result.get("ok") is True)
        checker.ok("插件报告 written=true", result.get("written") is True)
        checker.ok("模型被调用 2 次（一次重试）", payload.get("llm_calls") == 2,
                   f"llm_calls={payload.get('llm_calls')}")
        decision = expect_decision(checker, bridge, state, "invalid-id")
        if decision is not None:
            body = decision["decision"]
            checker.ok("source=rule（兜底）", body.get("source") == "rule")
            checker.ok("fallback=true", body.get("fallback") is True)
            checker.ok("error_code=VALIDATION", decision.get("error_code") == "VALIDATION")
            checker.ok("reason_code=invalid_id", body.get("reason_code") == "invalid_id",
                       f"actual={body.get('reason_code')}")
            checker.ok("choice 是本地规则选出的 item",
                       body.get("choice", {}).get("type") == "item",
                       f"actual={body.get('choice')}")
            checker.ok("选的不是模型编造的 id",
                       body.get("choice", {}).get("item_id") != MOCK_BAD_ID)
        expect_plugin_status(checker, bridge, "invalid-id", "degraded")

        # ── 场景 4：超时 → 不调模型，规则兜底 ──────────────────────────
        checker.section("场景 4/4：state 已过有效期 → 不调模型，规则兜底")
        timeout_now = int(time.time() * 1000)
        state = make_state(timeout_now, "r-mock-timeout-0005")
        state["ts"] = timeout_now - 5000  # validity_ms=1500，早已过期
        bridge = work_dir / "bridge-timeout"
        payload = run_plugin(harness, plugin_path, bridge, state, responses)
        result = payload.get("result", {})
        print(f"  插件结果：ok={result.get('ok')} written={result.get('written')} "
              f"source={result.get('source')} error_code={result.get('error_code')} "
              f"reason_code={result.get('reason_code')}")
        checker.ok("插件返回 ok=true", result.get("ok") is True)
        checker.ok("插件报告 written=true", result.get("written") is True)
        checker.ok("没有调用模型", payload.get("llm_calls") == 0,
                   f"llm_calls={payload.get('llm_calls')}")
        decision = expect_decision(checker, bridge, state, "timeout")
        if decision is not None:
            body = decision["decision"]
            checker.ok("source=rule（兜底）", body.get("source") == "rule")
            checker.ok("fallback=true", body.get("fallback") is True)
            checker.ok("error_code=TIMEOUT", decision.get("error_code") == "TIMEOUT")
            checker.ok("reason_code=timeout", body.get("reason_code") == "timeout",
                       f"actual={body.get('reason_code')}")
            checker.ok("choice 是 item", body.get("choice", {}).get("type") == "item",
                       f"actual={body.get('choice')}")
        expect_plugin_status(checker, bridge, "timeout", "degraded")

    except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
        print(f"\n[ERROR] mock 执行失败：{exc}", file=sys.stderr)
        if not args.keep:
            shutil.rmtree(work_dir, ignore_errors=True)
        return 1
    finally:
        if not args.keep and work_dir.exists():
            shutil.rmtree(work_dir, ignore_errors=True)

    total = len(checker.results)
    passed = total - checker.failed
    print("\n" + "-" * 64)
    if checker.failed == 0:
        print(f"结论：4/4 场景通过（{passed}/{total} 项断言）；插件行为符合 docs/protocol.md")
        if not args.keep:
            print("临时桥目录已清理（--keep 可保留）")
        return 0
    print(f"结论：{checker.failed} 项断言失败（{passed}/{total} 通过）")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
