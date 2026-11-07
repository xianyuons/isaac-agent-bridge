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
> Contract: `docs/protocol.md` **v1.1-draft.1** (wire version `1.0`). The Lua logic is
> covered by 106 offline assertions, the plugin by 111 offline assertions, and the JSON
> contract by `tools/mock_e2e.py` (4 scenarios / 52 assertions). The author's machine does
> not have REPENTOGON installed, so **no end-to-end run inside the actual game has been
> performed yet**. Treat this as a working prototype, not a polished release.

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

1. **Profile A only in v1:** when a room is entered (and again while waiting for a generation),
   the mod exports the run: player, items, room/floor/boss, and the **candidate pool**
   (max 64 ids). Profile B/C are not implemented in v1. Without Profile A (no
   `--luadebug`/REPENTOGON file API), the mod writes no bridge files and runs local rules
   only — this is called **local-only**, not Profile B.
2. The DSH plugin reads that state (or receives a full `StateDoc` inline), calls the model
   once with the candidate ids, validates the answer against the protocol, and atomically
   writes `decision.json`.
3. At item generation time the mod looks in memory for a still-fresh decision for the
   current `gen_level_key`. If there is one, it returns that `item_id` from callback 62.
   Otherwise it applies the same deterministic local rule as the plugin
   (heal when out of red hearts → damage when the run has no damage item → first
   candidate) and records the fallback.
4. `applied.json` (Profile A) records what actually happened (`applied_by: llm | provider |
   fallback | none`), so you never have to guess whether the agent or the fallback won. In
   local-only mode the same evidence goes to the bubble and the plugin's `plugin_status.json`.

`1500 ms` (or `5000–10000 ms` for boss-reward prefetch) is the **validity window of a
decision**, not a blocking wait. The mod never sleeps or polls inside a game callback.

Full contract: [docs/protocol.md](docs/protocol.md). Architecture and extension points:
[docs/architecture.md](docs/architecture.md).

**Chat / Bilibili danmaku** is designed but offline-only in v1: see
[docs/danmaku.md](docs/danmaku.md). It is off by default, opens no live connection, stores
no usernames or message text, and only contributes four aggregate tendency numbers to the
prompt — it never bypasses the candidate pool or the fallback path.

### Relationship to the reference implementation

The design was informed by studying a private Workshop mod, **AI Item Control v0.7**
(which targets REPENTOGON 1.0.12e). Only the *idea* of bridging the game to an external
model through a hook at item generation was borrowed. The protocol, the file formats, the
Lua implementation and the DSH plugin are original work; no code, assets, or text from
that mod is included in this repository. See [docs/reference-notes.md](docs/reference-notes.md)
for what was considered reusable and what was deliberately rejected.

---

## Profiles and launch flags (read this before installing)

v1 has **one live-bridge mode (Profile A)** and one non-bridge mode (**local-only**).
It does **not** implement the protocol's Profile B: "no bridge" is not B, and v1 does not
consume preset `decision.json` without a bridge. The full decision is in
[docs/reviews/decisions-m5-m7.md](docs/reviews/decisions-m5-m7.md).

| Mode | Who writes | Who reads | Status in this repo |
| --- | --- | --- | --- |
| **Profile A (v1 only bridge)** | mod writes `state/event/applied`; plugin writes `decision/plugin_status/lock` | both sides | **implemented**; requires file I/O (`--luadebug` or REPENTOGON file API) |
| **local-only (not a profile)** | plugin writes `decision/plugin_status/lock`; mod writes nothing | mod reads nothing | default without A; local rules + bubble; **cannot run the agent** |
| **Profile B (v1.1+)** | plugin writes `decision`; mod reads it and writes no state | mod | **not implemented**; needs a stable read API (t21) |
| **Profile C (v1.1+)** | SaveData relay | plugin-side feeder | **not implemented**; must not be claimed |

### Default without a bridge: local-only, no launch flags

Without `--luadebug` (or a REPENTOGON file API), the mod has no `io`: it cannot write
`state.json` and cannot read `decision.json`. It runs the **local rule** (heal / damage /
first candidate) and shows a bubble `桥接不可用（本地规则）` ("bridge unavailable — local
rules"). This is **local-only**, not Profile B; v1 does not consume preset decisions. It
never pretends the agent is available, and it never waits forever.

### Profile A: the only live bridge in v1 (requires `--luadebug`)

Profile A is the only mode that can run the agent on the live run. To let the mod write
`state.json` and read `decision.json`, the game must be launched with **`--luadebug`**
(Steam → The Binding of Isaac → Properties → Launch Options), or you must run on a
REPENTOGON build that exposes file APIs directly.

> **`--luadebug` opens `io`/`os` file access for *every* installed mod, not just this one.**
> Any mod you have enabled can then read and write files inside your user profile.
> This is not a zero-risk switch; only enable it if you trust every mod in your mods
> folder, and remove it when you are done. The mod's own safety limits (fixed file names,
> path whitelist, no network, no key) do not constrain *other* mods.

When the file probe succeeds you get `state.json` / `decision.json` in
`%LOCALAPPDATA%\IsaacAgent\` and the agent path becomes active. The mod itself never
requires DSH to be running: if the plugin is absent, decisions simply time out and the mod
falls back to local rules with an explicit bubble.

---

## Requirements

| Component | Requirement |
| --- | --- |
| Game | The Binding of Isaac: Repentance+ (Steam, Windows) |
| Mod loader | [REPENTOGON](https://repentogon.com/) — the reference target is **1.0.12e**; the mod does not hard-check a version |
| Bridge | **DSH** with a configured model (any provider already usable in DSH) |
| Plugin runtime | Node.js **>= 20** (DSH ships its own runtime; this matters only for offline tests) |
| Python (tests only) | **>= 3.10**, plus `lupa` for the Lua test runner (`python -m pip install lupa`) |

**Without REPENTOGON there is no graceful degradation.** The mod declares REPENTOGON as a
requirement and relies on its hook installation/timing. Under the stock Repentance+ loader
it may fail to load or register callbacks incorrectly; that configuration is unsupported.
There is no "vanilla fallback" build — install REPENTOGON first.

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
- **For agent mode:** add `--luadebug` to the game's Steam launch options to enable
  Profile A (see the warning above). Without it the mod runs local rules only
  (**local-only**, not Profile B).

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
$dshProfile = "$env:USERPROFILE\.dsh\profiles\<your-profile>"
$dest = "$dshProfile\node_modules\dsh-isaac-agent"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item .\plugin\* $dest -Recurse -Force
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

With the game running and a run loaded (**Profile A only** — without A there is no live
`state.json`; local-only writes nothing):

```text
# in DSH, ask the agent to call:
isaac_state          → should return the parsed state.json, mtime, and stale=false
isaac_decide         → should write decision.json and return a choice
```

In local-only mode there is no bridge to consume: `isaac_state` has no live data, and v1
does not read a pre-placed `decision.json`. You can still call `isaac_decide` with an
explicit `state` object to exercise the plugin, but that is not a live game export.

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
| No `state.json` in the bridge dir | No `--luadebug` (default sandbox has no file I/O); REPENTOGON not installed; mod disabled | Expected without Profile A. Enable the mod and add `--luadebug` for agent mode; check the game log for `无文件能力` |
| Bubble says `桥接不可用（本地规则）` | Same as above, or the bridge directory is not writable | Expected in local-only mode. For Profile A, create `%LOCALAPPDATA%\IsaacAgent` and confirm the game can write to it |
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
# 1) Lua mod logic — 106 assertions; runner supports Lua 5.1–5.4 via lupa
python tests/run_lua_test.py
$env:ISAAC_AGENT_LUA = "53"; python tests/run_lua_test.py   # game-like runtime

# 2) plugin regression — 111 assertions (no DSH process, no network)
node plugin/tests/plugin.test.mjs

# 3) end-to-end JSON contract — 4 scenarios, 52 assertions
python tools/mock_e2e.py

# 4) danmaku/viewer-tendency offline simulator (fixed fixture, no network)
python tools/danmaku_sim.py
python -m unittest discover -s tools/tests -p "test_*.py"
```

`tools/mock_e2e.py` simulates the game side (writes `state.json`), drives the real
`plugin/index.js` with a fake LLM stream, and validates the resulting `decision.json`
against `docs/protocol.md` for four cases: valid state, missing field, out-of-pool item id,
and expired state. It prints a per-assertion PASS/FAIL and a four-scenario conclusion;
exit code 0 means everything passed.

`tools/danmaku_sim.py` runs the fixed 32-message fixture through filtering and aggregation
and prints the four tendency weights; it never opens a network connection and never writes
viewer text to disk. See [docs/danmaku.md](docs/danmaku.md).

The plugin now ships its own regression suite: `node plugin/tests/plugin.test.mjs` (111 assertions, no DSH process or network needed).

---

## Repository layout

```text
docs/
  protocol.md          # the contract (state / decision / event / applied)
  architecture.md      # layering, extension points, timing
  standards.md         # coding rules and team process
  lessons.md           # pitfalls hit by the team
  reference-notes.md   # study of the reference implementation (concept only)
  danmaku.md           # Bilibili danmaku/viewer-tendency design (offline only, default off)
  reviews/             # third-party protocol review + M5/M7 decisions
mods/isaac_agent/      # game side: state export, decision consumer, local rules
plugin/                # DSH side: isaac_state / isaac_decide
protocol/examples/     # three byte-stable snapshots (success / fallback / timeout)
tests/                 # Lua logic tests + runner
tools/mock_e2e.py      # offline mod↔plugin contract test
tools/danmaku_sim.py   # offline viewer-tendency simulator (fixed fixture, no network)
tools/tests/           # danmaku simulator unit tests
```

## Security and red lines

- The mod does **not** access the network; the plugin reads `state.json` and writes only `decision.json`, `plugin_status.json`, and `bridge.lock`.
- **No API key in the game, the mod, the bridge files, the logs, or `reason` text.** Keys
  stay in DSH's credential store.
- The plugin accepts no model-supplied paths or code: only a `choice` and a short reason,
  validated against the candidate pool and a fixed action whitelist.
- File access is limited to `<bridge>/state.json`, `decision.json`, `plugin_status.json`,
  and `bridge.lock`; path
  traversal, symlinks/junctions, and relative paths are rejected.
- No input injection, no memory editing, no frame-by-frame automation: the mod only reads
  game state and uses the official generation point to apply a choice.
- `--luadebug` is a **global** capability increase for all mods; it is opt-in and
  documented as such.

## Limitations (v1, read before filing a feature request)

- **No third-party extension API.** The four extension points in `docs/architecture.md`
  (`DecisionProvider` / `EventSource` / `StateEnricher` / `Presenter`) are **conceptual
  design constraints**, not code interfaces. v1 has no registry, no `register*()`, no
  dependency injection; changing behavior requires editing `plugin/index.js` or
  `mods/isaac_agent/main.lua` and running the tests. A minimal interface layer is a v1.1
  roadmap item, not a v1 promise. See [decisions-m5-m7](docs/reviews/decisions-m5-m7.md).
- **Profile A only; no Profile B in v1.** A live bridge requires `--luadebug` (or a
  REPENTOGON file API). Without it the mod is **local-only**: it writes no bridge files,
  does not read `decision.json`, and runs local rules. Profile B (mod reads preset
  decisions, writes no state) is **not implemented**; Profile C (SaveData relay) is also
  v1.1+. "No bridge" must not be called Profile B.
- **Not smoke-tested in a real game.** All green results are offline/mock; the author's
  machine has no REPENTOGON install. Treat this as a working prototype.
- **No decision queue.** One active generation target, latest-wins; multi-pedestal rooms
  and fast rerolls may fall back to local rules.
- **No complete audit log.** `applied.json` / `event.json` are latest-wins receipts, not a
  full event history.
- **Danmaku/chat is offline-only.** No live room connection, no cookies, no message text
  on disk; it only produces aggregate tendency hints.
- **No network access from the mod; no API key in the game or bridge files.** Keys stay in
  DSH's credential store.

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

## 两种形态（v1：Profile A 或 local-only；B/C 未实现）

**v1 只有 Profile A 能实时跑 agent；没有桥接时叫 local-only，不叫 Profile B。** 协议 §1.4
和 [M5/M7 决策](docs/reviews/decisions-m5-m7.md) 写死了这个口径；不要再把“默认 B”写回来。

- **Profile A（v1 唯一桥接，需 `--luadebug`）**：给以撒加 `--luadebug` 启动参数（或
  REPENTOGON 暴露文件 API）后，mod 才能写 `state.json` 并读 `decision.json`，实时 agent
  链路才真正生效。
  ⚠️ **`--luadebug` 会放开所有 mod 的文件访问权限，不是零风险开关。** 只在你信任 mods
  目录里每一个 mod 时开启，用完可以移除。mod 自己的路径白名单/不联网/不碰 key 约束不了
  *别的* mod。
- **local-only（不加启动项 / 沙箱无 io）**：mod 不写任何桥文件、不读 `decision.json`，回调
  只走**本地规则兜底**（没红心先回血 → 没输出先补伤害 → 否则取第一个候选），气泡明确提示
  `桥接不可用（本地规则）`，并如实标成兜底。**不能拿当前这局实时问模型**，v1 也不消费预置
  `decision.json`；这不是 Profile B。
- **Profile B / C（v1.1+，未实现）**：B（mod 只读 decision、不写 state）需要稳定读文件 API，
  t21 待证；C（SaveData 中继）有类型/冲突/审计问题。v1 不得声称支持，也不得作为保底。

**没装 REPENTOGON 会怎样**：mod 把 REPENTOGON 声明为硬依赖（回调注册/时序都依赖它）。
在原生 Repentance+ 加载器下它可能加载失败或钩子行为不对；这种配置不受支持，也没有
"纯原版"降级版。请先装 REPENTOGON 再启用 mod。

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
python tests/run_lua_test.py     # Lua 逻辑 106 条断言
node plugin/tests/plugin.test.mjs # 插件回归 111 条断言（不需要 DSH 进程/网络）
python tools/mock_e2e.py         # 四种场景的 mock 联调，52 条断言
python tools/danmaku_sim.py      # 弹幕倾向离线模拟（固定 32 条样例，不联网）
python -m unittest discover -s tools/tests -p "test_*.py"
```

## 现实边界（如实说明）

- 本机没有安装 REPENTOGON，**没有在真实游戏里跑过端到端 smoke test**；目前的"通过"
  全部来自离线测试与 mock。第一次实机安装请先看游戏日志与气泡提示。
- **v1 不支持第三方扩展实现**：`DecisionProvider` / `EventSource` / `StateEnricher` /
  `Presenter` 是文档里的概念约束，不是代码接口；要改行为得改
  `plugin/index.js` / `mods/isaac_agent/main.lua` 并跑测试，不能热插拔。v1.1 才抽最小接口层。
- **v1 只支持 Profile A + local-only**：没有 `--luadebug`/文件 API 时走本地规则，**不叫
  Profile B**；B/C 均未实现，见协议 §1.4 与 [M5/M7 决策](docs/reviews/decisions-m5-m7.md)。
- `applied.json` / `event.json` 是 latest-wins 回执，不是完整审计日志。
- 同一时刻只服务一个生成目标；多底座房间、快速 reroll 会走本地规则，详见协议 §11。
- B 站弹幕/聊天只做到**设计与离线模拟**（`docs/danmaku.md`），默认关闭，未接真实直播间、
  不读 cookie、不落盘弹幕原文；它只产生提示词里的观众倾向，不改变候选池与兜底路径。

## 与参考实现的关系

只借鉴了"在道具生成钩子上桥接外部模型"这一思路（参考创意工坊的 AI Item Control v0.7，
其目标环境是 REPENTOGON 1.0.12e）。协议、文件格式、Lua 实现和 DSH 插件均为独立实现，
仓库内**没有**对方代码、素材或文本。可借鉴/不可借鉴清单见
[docs/reference-notes.md](docs/reference-notes.md)。

## 许可

[MIT](LICENSE)。



