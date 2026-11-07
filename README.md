# isaac-agent-bridge

An agent-driven item picker for **The Binding of Isaac: Repentance+**, split into two
independent halves:

- a **Lua mod** (`mods/isaac_agent/`, REPENTOGON) that describes the current run and
  consumes a decision;
- a **DSH plugin** (`plugin/`, TypeScript/ESM) that asks the current language model to
  choose one item from the candidate pool and writes `decision.json`.

The model/provider API key never touches the game or the bridge directory: it lives only
in DSH's credential store. The bridge is plain UTF-8 JSON on local disk, with no network
access from the mod.

> **Status: offline-verified, not smoke-tested on a real game install.**
> The Lua logic is covered by 74 offline assertions, the plugin by 68 offline assertions,
> and the JSON contract by `tools/mock_e2e.py` (4 scenarios / 51 assertions). The author's
> machine does not have REPENTOGON installed, so **no end-to-end run inside the actual
> game has been performed yet**. Treat this as a working prototype, not a polished release.

---

## How it works

```
┌──────────────────────────┐        state.json / event.json / applied.json
│ Isaac + REPENTOGON       │  ─────────────────────────────────────────────┐
│ mods/isaac_agent (Lua)   │                                               │
│                          │        decision.json                          ▼
│  MC_PRE_GET_COLLECTIBLE  │  ◀──────────────────────────────────  ┌──────────────┐
│  (callback 62) reads a   │                                      │ DSH plugin   │
│  cached choice or runs   │                                      │ isaac_decide │
│  local rules; never      │                                      │ → LLM        │
│  blocks, never does I/O  │                                      └──────────────┘
└──────────────────────────┘
```

1. When a room is entered (and again while waiting for a generation), the mod exports
   the run: player, items, room/floor/boss, and the **candidate pool** (max 64 ids).
2. The DSH plugin reads that state, calls the model once with the candidate ids, validates
   the answer against the protocol, and atomically writes `decision.json`.
3. At item generation time the mod looks in memory for a still-fresh decision for the
   current `gen_level_key`. If there is one, it returns that `item_id` from callback 62.
   Otherwise it applies the same deterministic local rule as the plugin
   (heal when out of red hearts → damage when the run has no damage item → first
   candidate) and records the fallback.
4. `applied.json` records what actually happened (`applied_by: llm | provider | fallback |
   none`), so you never have to guess whether the agent or the fallback won.

`1500 ms` (or `5000–10000 ms` for boss-reward prefetch) is the **validity window of a
decision**, not a blocking wait. The mod never sleeps or polls inside a game callback.

Full contract: [docs/protocol.md](docs/protocol.md). Architecture and extension points:
[docs/architecture.md](docs/architecture.md).

### Relationship to the reference implementation

The design was informed by studying a private Workshop mod, **AI Item Control v0.7**
(which targets REPENTOGON 1.0.12e). Only the *idea* of bridging the game to an external
model through a hook at item generation was borrowed. The protocol, the file formats, the
Lua implementation and the DSH plugin are original work; no code, assets, or text from
that mod is included in this repository. See [docs/reference-notes.md](docs/reference-notes.md)
for what was considered reusable and what was deliberately rejected.

---

## Profiles and launch flags (read this before installing)

The protocol defines three transport profiles (`docs/protocol.md` §1.4):

| Profile | Who writes | Who reads | Status in this repo |
| --- | --- | --- | --- |
| **A** | mod writes `state/event/applied`, plugin writes `decision` | both sides | implemented; requires file I/O in the Lua sandbox |
| **B** | plugin writes `decision` only; mod never writes | mod reads `decision` | intended fallback shape; also requires file **read** access |
| **C** | SaveData relay | plugin reads the save data | research only, disabled by default, **not implemented** |

### Default install: local rules, no launch flags

With no special launch options, the Isaac Lua sandbox exposes **neither `io` nor `os`** —
not even for reading. The mod probes this at `on_game_start` and switches to its
**local-rule fallback**: it still picks intelligently (heal / damage / first candidate),
prints a bubble that says `桥接不可用（本地规则）` ("bridge unavailable — local rules"),
and never pretends the agent is available. Nothing is written to disk, nothing is read
from disk, and the game cannot break because a file is missing.

### Profile A: the full bridge (optional, with a real security cost)

To let the mod write `state.json` and read `decision.json`, the game must be launched with
**`--luadebug`** (Steam → The Binding of Isaac → Properties → Launch Options), or you must
run on a REPENTOGON build that exposes file APIs directly.

> **`--luadebug` opens `io`/`os` file access for *every* installed mod, not just this one.**
> Any mod you have enabled can then read and write files inside your user profile.
> This is not a zero-risk switch; only enable it if you trust every mod in your mods
> folder, and remove it when you are done. The mod's own safety limits (fixed file names,
> path whitelist, no network, no key) do not constrain *other* mods.

When the file probe succeeds you get `state.json` / `decision.json` in
`%LOCALAPPDATA%\IsaacAgent\` and the agent path becomes active.

The mod itself never requires DSH to be running: if the plugin is absent, decisions simply
time out and the mod falls back to local rules with an explicit bubble.

---

## Requirements

| Component | Requirement |
| --- | --- |
| Game | The Binding of Isaac: Repentance+ (Steam, Windows) |
| Mod loader | [REPENTOGON](https://repentogon.com/) — the reference target is **1.0.12e**; the mod does not hard-check a version |
| Bridge | **DSH** with a configured model (any provider already usable in DSH) |
| Plugin runtime | Node.js **>= 20** (DSH ships its own runtime; this matters only for offline tests) |
| Python (tests only) | **>= 3.10**, plus `lupa` for the Lua test runner (`python -m pip install lupa`) |

---

## Installation

### 1. Install the Lua mod

Copy the folder so the game sees `mods/isaac_agent/`:

```text
<Documents>\My Games\Binding of Isaac Repentance+\mods\isaac_agent\
├─ main.lua
├─ metadata.xml
└─ data\item_tags.lua
```

- On older (non-`+`) Repentance installs the folder is
  `...\Binding of Isaac Repentance\mods\`; if Documents is redirected to OneDrive, use
  that path instead.
- Launch the game once, open **Mods**, and enable **isaac_agent**.
- Optional: add `--luadebug` to the game's Steam launch options if you want Profile A
  (see the warning above). Without it the mod runs local rules only.

### 2. Create the bridge directory

The plugin and the mod agree on `%LOCALAPPDATA%\IsaacAgent` by default. The plugin creates
it on first write, but creating it up front makes Profile A probing succeed on the first
try:

```powershell
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\IsaacAgent"
```

If you want a different directory, set `ISAAC_AGENT_DIR` as a **system/user environment
variable** (both processes read it) *and* set the same path in the plugin config. Changing
only one side means the two halves look at different folders.

### 3. Install the DSH plugin

Copy `plugin/` into your DSH profile as a local package (the folder name must match the
package name `dsh-isaac-agent`):

```powershell
$profile = "$env:USERPROFILE\.dsh\profiles\<your-profile>"
Copy-Item -Recurse .\plugin "$profile\node_modules\dsh-isaac-agent"
```

Then register it in that profile's `cordis.patch.yml` (merge the entry; do not replace the
file). The contents of `plugin/cordis.patch.yml` are:

```yaml
- insert:
    - id: isaac-agent
      name: 'dsh-isaac-agent'
```

With optional configuration:

```yaml
- insert:
    - id: isaac-agent
      name: 'dsh-isaac-agent'
      config:
        bridgeDir: 'C:\Users\<you>\AppData\Local\IsaacAgent'  # optional
        provider: deepseek                                    # optional, default = current session model
        model: deepseek-chat                                  # optional
```

- If your DSH version supports bundle patches (`package.json` → `dsh.bundle.patch`), the
  package can also be loaded without the manual entry; the manual entry is the reliable
  path across versions.
- Restart DSH (or reload the profile). Two tools should appear: **`isaac_state`** and
  **`isaac_decide`**.
- **Do not put an API key in `cordis.patch.yml`.** Keys stay in DSH's credential store;
  the plugin never reads, logs, or writes them.

### 4. Choose the model

By default `isaac_decide` uses the model of the current DSH session
(`agent.model.current()` → profile default). To pin a different one, set `provider` and
`model` in the plugin config as shown above. The plugin sends exactly one decision prompt
and validates the answer; it does not run an agent loop.

### 5. Verify

With the game running and a run loaded (**Profile A only** — in the default no-flag
profile there is intentionally no `state.json`):

```text
# in DSH, ask the agent to call:
isaac_state          → should return the parsed state.json, mtime, and stale=false
isaac_decide         → should write decision.json and return a choice
```

Check `%LOCALAPPDATA%\IsaacAgent\` for `state.json` and `decision.json`. If `state.json`
never appears, see Troubleshooting.

---

## Uninstall

1. In game: **Mods** → disable **isaac_agent** (or delete
   `...\mods\isaac_agent\`).
2. Remove the `isaac-agent` insert entry from your DSH profile's `cordis.patch.yml` and
   delete `node_modules\dsh-isaac-agent\`.
3. Delete `%LOCALAPPDATA%\IsaacAgent\` (contains only bridge JSON).
4. Remove `--luadebug` from the game's launch options if you added it for this project.
5. Restart DSH and the game.

No registry keys, services, scheduled tasks, or startup entries are created.

---

## Troubleshooting

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| No `state.json` in the bridge dir | No `--luadebug` (default sandbox has no file I/O); REPENTOGON not installed; mod disabled | This is the expected default. Enable the mod and add `--luadebug` for Profile A; check the game log for `无文件能力` |
| Bubble says `桥接不可用（本地规则）` | Same as above, or the bridge directory is not writable | Expected in the default profile. For Profile A, create `%LOCALAPPDATA%\IsaacAgent` and confirm the game can write to it |
| `isaac_state` returns `stale=true` | `state.json` is older than 30 s | Normal between rooms / while paused; if it persists, the mod is not refreshing state — check the game log |
| `isaac_decide` always returns a rule fallback | No model configured; budget already expired; DSH plugin not loaded | Check `error_code`/`reason_code` in the result. `TIMEOUT` = `state.ts` too old; `MODEL` = no model/stream failure |
| `decision.json` missing after `isaac_decide` | The state envelope is unreadable (e.g. missing `request_id`, wrong major version) | This is deliberate (`docs/protocol.md` §2.8): the plugin must not guess identity. Check the returned `reason_code` and the mod's state export |
| `decision.json` exists but the game ignores it | `gen_level_key`/`request_id` mismatch, decision expired, or callback 62 arrived before the file was read | Check the mod log for `level_mismatch`, `request_mismatch`, `late`, `no_fresh_decision` |
| `EPERM` / rename errors on Windows | Antivirus/indexer briefly locking the target | The plugin retries; keep the bridge on a local disk (not OneDrive/network) and add an exclusion if needed |
| Chinese bubble shows `?`/boxes | The official CJK font was not found | The mod falls back to ASCII text; this is cosmetic only |
| Tools not visible in DSH | Package folder name mismatch, missing `cordis.patch.yml` entry, or no restart | Folder must be `dsh-isaac-agent`, entry `name: 'dsh-isaac-agent'`, then restart DSH |

Logs: the plugin returns a human-readable `text` plus `error_code`/`reason_code` on every
call. The mod writes structured logs to the game log (`INFO/WARN` + `request_id`); it never
logs keys or full absolute paths.

---

## Testing (offline, no game required)

```powershell
# 1) Lua mod logic — 74 assertions, Lua 5.1/5.2/5.3/5.4 via lupa
python tests/run_lua_test.py
$env:ISAAC_AGENT_LUA = "53"; python tests/run_lua_test.py   # game-like runtime

# 2) end-to-end JSON contract — 4 scenarios, 51 assertions
python tools/mock_e2e.py
```

`tools/mock_e2e.py` simulates the game side (writes `state.json`), drives the real
`plugin/index.js` with a fake LLM stream, and validates the resulting `decision.json`
against `docs/protocol.md` for four cases: valid state, missing field, out-of-pool item id,
and expired state. It prints a per-assertion PASS/FAIL and a four-scenario conclusion;
exit code 0 means everything passed.

The 68-assertion plugin unit suite used during development lives outside this repository
(temporary harness); it is not part of the shipped tree.

---

## Repository layout

```text
docs/
  protocol.md          # the contract (state / decision / event / applied)
  architecture.md      # layering, extension points, timing
  standards.md         # coding rules and team process
  lessons.md           # pitfalls hit by the team
  reference-notes.md   # study of the reference implementation (concept only)
  reviews/             # third-party protocol review
mods/isaac_agent/      # game side: state export, decision consumer, local rules
plugin/                # DSH side: isaac_state / isaac_decide
protocol/examples/     # three byte-stable snapshots (success / fallback / timeout)
tests/                 # Lua logic tests + runner
tools/mock_e2e.py      # offline mod↔plugin contract test
```

## Security and red lines

- The mod does **not** access the network; the plugin only writes the two bridge files.
- **No API key in the game, the mod, the bridge files, the logs, or `reason` text.** Keys
  stay in DSH's credential store.
- The plugin accepts no model-supplied paths or code: only a `choice` and a short reason,
  validated against the candidate pool and a fixed action whitelist.
- File access is limited to `<bridge>/state.json` and `<bridge>/decision.json`; path
  traversal, symlinks/junctions, and relative paths are rejected.
- No input injection, no memory editing, no frame-by-frame automation: the mod only reads
  game state and uses the official generation point to apply a choice.
- `--luadebug` is a **global** capability increase for all mods; it is opt-in and
  documented as such.

## Contributing

Protocol changes, branch/commit rules and the review checklist are in
[CONTRIBUTING.md](CONTRIBUTING.md). In short: change the protocol first (with a version
and migration note), get the mod-side and plugin-side owners to agree, update the
examples and both implementations, then run the offline tests above.

## License

[MIT](LICENSE).

---

# 中文说明

## 这是什么

给《以撒的结合：忏悔+》做的 **agent 决策桥**：

- **Lua mod**（`mods/isaac_agent/`，需要 REPENTOGON）导出当前局面与候选道具池，并在
  道具生成时（回调 62，池抽取完成、底座生成之前）当帧给出选择；
- **DSH 插件**（`plugin/`）读取局面，调用**当前模型**从候选池里挑一个，按协议原子写入
  `decision.json`。

**API key 只存在于 DSH 的凭据存储里**：游戏侧、mod、桥目录、日志、`reason` 文本都不
会出现 key。游戏侧不联网，只读写本地 JSON。

## 两种形态（安装前必读）

- **默认形态（不加任何启动项）**：以撒的 Lua 沙箱不提供 `io`/`os`，连读文件都不行。
  mod 启动探针会检测到这一点，自动走**本地规则兜底**（没红心先回血 → 没输出先补伤害 →
  否则取第一个候选），气泡明确提示 `桥接不可用（本地规则）`，并如实标成兜底。这个形态
  不需要 DSH 也能玩，不会因为文件缺失卡住或报错。
- **Profile A（可选增强）**：给以撒加 `--luadebug` 启动参数后，mod 才能写 `state.json`
  并读 `decision.json`，agent 决策链路才真正生效。
  ⚠️ **`--luadebug` 会放开所有 mod 的文件访问权限，不是零风险开关。** 只在你信任 mods
  目录里每一个 mod 时开启，用完可以移除。mod 自己的路径白名单/不联网/不碰 key 约束不了
  *别的* mod。

协议里的 Profile B（插件写、mod 只读）是设计上的"不写盘"形态，但读文件同样需要文件
访问能力；在原生沙箱里没有这个能力，所以本版把"没有文件能力"直接当作本地规则处理，
不假装 agent 可用。Profile C（SaveData 中继）只做研究，默认关闭，本版未实现。

## 安装（三步）

1. 把 `mods/isaac_agent/` 整个目录复制到
   `文档\My Games\Binding of Isaac Repentance+\mods\isaac_agent\`（老版忏悔是
   `Binding of Isaac Repentance\mods\`），进游戏在 **Mods** 里启用。
2. 需要 agent 决策时，给游戏加 `--luadebug` 启动参数；桥目录默认
   `%LOCALAPPDATA%\IsaacAgent\`（建议先手动创建）。
3. 把 `plugin/` 复制到 DSH profile 的 `node_modules/dsh-isaac-agent\`，并在
   `cordis.patch.yml` 加入 `plugin/cordis.patch.yml` 里的 `insert` 条目，重启 DSH。
   模型默认跟随当前会话，也可以用 `provider`/`model` 固定；**不要在配置文件里写 key**。

详细步骤、卸载、排错见上面的英文部分（与中文一一对应）。

## 测试

```powershell
python tests/run_lua_test.py     # Lua 逻辑 74 条断言
python tools/mock_e2e.py         # 四种场景的 mock 联调，51 条断言
```

## 现实边界（如实说明）

- 本机没有安装 REPENTOGON，**没有在真实游戏里跑过端到端 smoke test**；目前的"通过"
  全部来自离线测试与 mock。第一次实机安装请先看游戏日志与气泡提示。
- `applied.json` / `event.json` 是 latest-wins 回执，不是完整审计日志。
- 同一时刻只服务一个生成目标；多底座房间、快速 reroll 会走本地规则，详见协议 §11。

## 与参考实现的关系

只借鉴了"在道具生成钩子上桥接外部模型"这一思路（参考创意工坊的 AI Item Control v0.7，
其目标环境是 REPENTOGON 1.0.12e）。协议、文件格式、Lua 实现和 DSH 插件均为独立实现，
仓库内**没有**对方代码、素材或文本。可借鉴/不可借鉴清单见
[docs/reference-notes.md](docs/reference-notes.md)。

## 许可

[MIT](LICENSE)。
