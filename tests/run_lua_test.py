"""用内嵌 Lua 5.4（lupa）运行 tests/lua_logic_test.lua。

用途：本机没有 lua.exe 时也能跑 mod 的离线逻辑测试（CI/无游戏环境）。
真正的测试逻辑全部在 Lua 里；本文件只负责找一个 Lua 运行时、处理路径并把退出码透传。

为什么需要 subst：仓库路径可能含中文（如 E:\\Yuki\\工作\\isaac-agent），
而 Lua 的 dofile/io.open 走 Windows ANSI 文件 API，遇到非 ASCII 路径会直接打不开。
这里把仓库根映射到一个临时盘符（纯 ASCII），跑完再解除映射。

用法：
    python tests/run_lua_test.py
前置：
    python -m pip install lupa
"""

from __future__ import annotations

import os
import string
import subprocess
import sys
from pathlib import Path


def _free_drive() -> str | None:
    for letter in reversed(string.ascii_uppercase):
        if letter in ("A", "B", "C"):
            continue
        if not os.path.exists(f"{letter}:\\"):
            return letter
    return None


def _is_ascii(path: str) -> bool:
    try:
        path.encode("ascii")
        return True
    except UnicodeEncodeError:
        return False


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    script = root / "tests" / "lua_logic_test.lua"
    if not script.is_file():
        print(f"找不到测试脚本：{script}", file=sys.stderr)
        return 2

    try:
        from lupa import lua54
    except ImportError:
        print(
            "缺少 lupa（或本机没有 lua.exe）。安装：python -m pip install lupa；"
            "或直接用 lua tests/lua_logic_test.lua 运行。",
            file=sys.stderr,
        )
        return 2

    runtime = lua54.LuaRuntime(unpack_returned_tuples=True)

    # 非 ASCII 路径 → 临时 subst 盘符（Lua 的 C 文件 API 只认 ANSI）
    mapped = False
    drive = None
    if not _is_ascii(str(root)):
        drive = _free_drive()
        if drive is None:
            print("没有可用盘符做 subst，无法在非 ASCII 路径下运行 Lua 测试", file=sys.stderr)
            return 2
        subprocess.run(["subst", f"{drive}:", str(root)], check=False)
        mapped = os.path.exists(f"{drive}:\\")
        if not mapped:
            print(f"subst {drive}: 失败", file=sys.stderr)
            return 2
        script_path = f"{drive}:/tests/lua_logic_test.lua"
    else:
        script_path = script.as_posix()

    try:
        runtime.execute(f'arg = {{ [0] = [[{script_path}]] }}')
        runtime.execute(f"dofile([[{script_path}]])")
    except BaseException as exc:  # noqa: BLE001 - 原样透传 Lua 栈
        print(f"测试脚本异常：{exc}", file=sys.stderr)
        return 1
    finally:
        if mapped and drive is not None:
            subprocess.run(["subst", f"{drive}:", "/d"], check=False)

    # 正常情况下 Lua 侧已经 os.exit()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
