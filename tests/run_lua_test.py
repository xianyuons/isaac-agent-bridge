"""用内嵌 Lua（lupa）运行 tests/lua_logic_test.lua。

用途：本机没有 lua.exe 时也能跑 mod 的离线逻辑测试（CI/无游戏环境）。
真正的测试逻辑全部在 Lua 里；本文件只负责找运行时、处理路径、清理临时映射并透传退出码。

两个环境坑（都在 docs/lessons.md 记过）：
1. 仓库路径可能含中文（如 E:\\Yuki\\工作\\isaac-agent），而 Lua 的 dofile/io.open 走
   Windows ANSI 文件 API，遇到非 ASCII 路径直接打不开 → 用 subst 映射到临时盘符。
2. Lua 用例里的 os.exit() 会直接终止 **Python 宿主进程**，finally 来不及执行 →
   subst 映射残留、盘符被占满。现在：
     · 由本脚本设置 ISAAC_AGENT_EMBEDDED=1，Lua 用例改为 return 退出码而不 os.exit；
     · 运行前先复用/清理指向同一仓库的旧映射，跑完在 finally 里解除映射。

用法：
    python tests/run_lua_test.py
    ISAAC_AGENT_LUA=53 python tests/run_lua_test.py     # 用 Lua 5.3（贴近游戏运行时）
前置：
    python -m pip install lupa
"""

from __future__ import annotations

import os
import string
import subprocess
import sys
from pathlib import Path

LUA_VARIANTS = {
    "51": ("lua51", "Lua 5.1"),
    "52": ("lua52", "Lua 5.2"),
    "53": ("lua53", "Lua 5.3"),
    "54": ("lua54", "Lua 5.4"),
}


def _is_ascii(path: str) -> bool:
    try:
        path.encode("ascii")
        return True
    except UnicodeEncodeError:
        return False


def _norm(path: str) -> str:
    return os.path.normcase(os.path.normpath(path.strip())).rstrip("\\")


def _subst_map() -> dict[str, str]:
    """解析 `subst` 输出：{'Y': 'E:\\...\\isaac-agent-t12'}。"""
    mapping: dict[str, str] = {}
    try:
        res = subprocess.run(["subst"], capture_output=True, text=True, timeout=10, check=False)
    except OSError:
        return mapping
    for line in (res.stdout or "").splitlines():
        if "=>" not in line:
            continue
        left, right = line.split("=>", 1)
        letter = left.strip()[:1].upper()
        target = right.strip()
        if letter and letter in string.ascii_uppercase and target:
            mapping[letter] = target
    return mapping


def _free_drive() -> str | None:
    for letter in reversed(string.ascii_uppercase):
        if letter in ("A", "B", "C"):
            continue
        if not os.path.exists(f"{letter}:\\"):
            return letter
    return None


def _ensure_mapping(root: Path) -> str | None:
    """把 root 映射到一个盘符：优先复用它已有的映射，其次找空闲盘符。返回盘符或 None。"""
    existing = _subst_map()
    chosen = None
    for letter, target in existing.items():
        if _norm(target) == _norm(str(root)):
            chosen = letter
            break
    # 同一个仓库可能残留多个映射（旧 runner 的 os.exit 坑），顺手清掉多余的
    for letter, target in existing.items():
        if _norm(target) == _norm(str(root)) and letter != chosen:
            subprocess.run(["subst", f"{letter}:", "/d"], check=False)

    if chosen is not None:
        return chosen

    drive = _free_drive()
    if drive is None:
        return None
    subprocess.run(["subst", f"{drive}:", str(root)], check=False)
    return drive if os.path.exists(f"{drive}:\\") else None


def _as_code(result: object) -> int:
    if isinstance(result, tuple):
        result = result[0] if result else 0
    try:
        return int(result) if result is not None else 0
    except (TypeError, ValueError):
        return 1


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    script = root / "tests" / "lua_logic_test.lua"
    if not script.is_file():
        print(f"找不到测试脚本：{script}", file=sys.stderr)
        return 2

    variant = os.environ.get("ISAAC_AGENT_LUA", "54")
    module_name, label = LUA_VARIANTS.get(variant, LUA_VARIANTS["54"])
    try:
        lua = __import__(f"lupa.{module_name}", fromlist=[module_name])
    except ImportError:
        print(
            f"缺少 lupa（或缺少 {label} 运行时 / 本机没有 lua.exe）。"
            "安装：python -m pip install lupa；或直接用 lua tests/lua_logic_test.lua 运行。",
            file=sys.stderr,
        )
        return 2

    runtime = lua.LuaRuntime(unpack_returned_tuples=True)
    os.environ["ISAAC_AGENT_EMBEDDED"] = "1"   # 让 Lua 用例 return 退出码，而不是 os.exit

    drive = None
    if not _is_ascii(str(root)):
        drive = _ensure_mapping(root)
        if drive is None:
            print("没有可用盘符做 subst，无法在非 ASCII 路径下运行 Lua 测试", file=sys.stderr)
            return 2
        script_path = f"{drive}:/tests/lua_logic_test.lua"
    else:
        script_path = script.as_posix()

    code = 1
    try:
        runtime.execute(f'arg = {{ [0] = [[{script_path}]] }}')
        # 注意必须写 return：只写 dofile(...) 的话返回值会被丢弃，失败会被当成成功
        result = runtime.execute(f"return dofile([[{script_path}]])")
        code = _as_code(result)
    except BaseException as exc:  # noqa: BLE001 - 原样透传 Lua 栈
        print(f"测试脚本异常：{exc}", file=sys.stderr)
        code = 1
    finally:
        if drive is not None:
            subprocess.run(["subst", f"{drive}:", "/d"], check=False)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
