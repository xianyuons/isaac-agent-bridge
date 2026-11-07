# Profile B 可行性 spike（默认启动下 mod 能否读文件）

> 任务：t25 ｜ 基线：`a4114b6`（main，含 t24 的 A/local-only 口径）｜ 日期：2026-11-07
> 实验代码：`spike/profile_b_probe/`（可复现探针）｜ 本机**无 REPENTOGON**，游戏未启动
>
> **证据等级**（全文逐条标注）：
> - `[实测-本机文件]`：直接读取了本机磁盘上的真实产物（不是推断）
> - `[源码]`：读了 REPENTOGON / 游戏随包脚本的具体行
> - `[文档]`：官方或项目文档
> - `[未实机验证]`：静态推断/文档结论，尚未在跑起来的游戏里复验

---

## 0. 结论（TL;DR）

1. **默认启动（不加 `--luadebug`）下，`io` 不存在**；装了 REPENTOGON 时 `os` 存在但被裁到 4 个函数（`date/time/clock/difftime`），**没有 `rename/remove/getenv`**。〔源码+文档〕
2. **但 `Mod:LoadData()` / `Mod:SaveData()` 本身就是文件读写**，固定落在 `<游戏目录>/data/<mod 文件夹>/save<槽位>.dat`，内容是**纯文本原文**（本机 `just_gambling/save1.dat` 就是一段 JSON）。〔源码 + 实测-本机文件〕
3. 所以“**mod 读文件**”不是不可能，只是**不能读任意路径**：它只能读自己（或任意 mod）数据文件夹里的 `saveN.dat`。
4. **纯 Profile B（mod 只读、插件写）单独不成立**——只读解决不了“mod 把局面导出给插件”。可行形态是 **Profile C：分享同一份 mod 数据文件做中继**（mod 写 state、插件写 decision，用 epoch/turn 栅栏防互相覆盖）。参考实现 AI Item Control 走的正是这条路。
5. **版本差异**（关键，已按 tag 核对）：
   - 任意 REPENTOGON（含 1.0.12e）：只有 `Mod:SaveData(str)` / `Mod:LoadData()` → 单文件共享，**Profile C**。
   - **REPENTOGON ≥ 1.1.2e**（1.1.3 是当前最新发布，2026-09-15）：新增 `Isaac.LoadModDataFromFolder(folder)`，可读**另一个** mod 数据文件夹的 `saveX.dat` → 能做“双文件”拆分（更干净）。已在 `1.1.3` tag 的 `LuaIsaac.cpp` 里核实存在。
   - **REPENTOGON 当前 main（changelog 第 1 行 `v1.1.x`，未发布，排在 `v1.1.3` 之上）：**`Mod:LoadData(filename)` / `Mod:SaveData(data, filename)` 支持任意文件名 → 最干净（无槽位问题）。⚠️ **1.1.3（最新发布）里没有它**：tag `1.1.3` 的 `main_ex.lua` 查不到 `ModReference_SaveModFile`，changelog 也把它放在 `v1.1.3` 之上的未发布段。所以 **v1.1 不要依赖它**；探针可确认所装版本是否支持。
6. **对 t24 结论的影响**：v1 仍建议按 A / local-only 发（默认安装没有桥）。**v1.1 可以把 C 做出来**：共享文件方案不依赖 `--luadebug`、不依赖 1.1.3，代价是 ~2.5–3 人日 + 真机联调；最大风险是**存档覆盖**与**实时可见性**（后者需真机确认）。

---

## 1. 路 1：原生 `io` / `os`

### 1.1 结论：**不可行**

| 项 | 默认启动 | 证据 |
| --- | --- | --- |
| `io` | 不存在（`type(io) == "nil"`） | `[文档]` IsaacDocs《Standard-Library》表：`io`、`os`、`package` 仅 `--luadebug` 可用；游戏的随包脚本里**没有任何**恢复 `io` 的代码（grep `resources/scripts/main.lua`、REPENTOGON `main_ex.lua` 均为 0 命中） |
| `os` | **存在但被裁剪**：REPENTOGON 在 `main_ex.lua:2061-2069` 里 `os = { date, time, clock, difftime }` | `[源码]` `repentogon/resources/scripts/main_ex.lua:2061` |
| `debug` / `dofile` / `loadfile` / `load` / `arg` | 置 nil | `[源码]` 游戏随包 `resources/scripts/main.lua:1185-1191`（`if not _LUADEBUG then ... end`） |

结论：默认启动下**没有任何原生文件 I/O**；`os` 只剩时间函数，连 `os.rename/os.remove` 都没有——这也是我们的原子写方案在默认启动下必然降级的原因。

### 1.2 探针代码与预期输出

探针完整代码见 `spike/profile_b_probe/main.lua`（可直接丢进 `mods/` 跑）。核心片段：

```lua
Isaac.DebugString("[PROBE] type(io)=" .. type(io))              -- 预期 nil
Isaac.DebugString("[PROBE] type(os)=" .. type(os))              -- 预期 table
local names = {}; for k in pairs(os or {}) do names[#names+1] = k end
table.sort(names)
Isaac.DebugString("[PROBE] os fields=" .. table.concat(names, ","))  -- 预期 clock,date,difftime,time
Isaac.DebugString("[PROBE] type(package)=" .. type(package))    -- 预期 nil
```

**预期输出**（`log.txt` 里 `[PROBE]` 开头）：

```
[PROBE] type(io)=nil
[PROBE] type(os)=table
[PROBE] os fields=clock,date,difftime,time
[PROBE] type(package)=nil
[PROBE] type(jit)=nil
```

> `[未实机验证]`：本机没装 REPENTOGON，游戏未启动，以上是“文档 + 随包脚本 + REPENTOGON 源码”的推断值。**要落成实测，跑一次 `spike/profile_b_probe` 即可**（步骤见该目录 README）。

---

## 2. 路 2：REPENTOGON 暴露的文件 API

### 2.1 结论：**可行**（但按版本分三档，且只能操作 mod 数据文件夹）

| API | 引入版本 | 能做什么 | 证据 |
| --- | --- | --- | --- |
| `Mod:SaveData(data)` / `Mod:LoadData()` / `HasData()` / `RemoveData()` | vanilla（Rebirth 起） | 读写**自己**数据文件夹的 `save<槽位>.dat` | `[源码]` REPENTOGON `main_ex.lua:2089-2092` 转发到 `Isaac.SaveModData(...)`；`[实测-本机文件]` `data/aisaac/save1.dat`、`data/just_gambling/save1.dat` 存在且是明文 |
| `Mod:SaveData(data, filename)` / `LoadData(filename)` / `HasData(filename)` / `RemoveData(filename)` | **当前 main**（changelog `v1.1.x` 未发布段，第 1 行；`v1.1.3` 之上的新增；tag 1.1.3 的 `main_ex.lua` 无此重载） | 读写自己数据文件夹里的**任意文件名**（无子目录） | `[源码]` `main_ex.lua:2011-2041` 的 `rawset` 重载 + `_Internals.cpp:71-124`（`std::ofstream/ifstream`）+ `_Internals.cpp:141-150`（文件名正则） |
| `Isaac.LoadModDataFromFolder(folderName)` | **1.1.2e**（已发布；1.1.3 是当前最新） | 读**任意 mod 数据文件夹**的 `saveX.dat`（即使该 mod 未启用） | `[源码]` `LuaIsaac.cpp:966-1005`（当前 main）；`1.1.3` tag 的 `LuaIsaac.cpp` 含 `LoadModDataFromFolder`（3 处命中）；`[文档]` changelog `v1.1.2e` 段 |

### 2.2 路径与限制（源码级）

- 路径：`mod._dataDirectory / filename`（`_Internals.cpp:37-40`）。`_dataDirectory` 是游戏给每个 mod 的数据目录，实测布局是 `<游戏目录>/data/<mod 文件夹名>/`（本机 `.../The Binding of Isaac Rebirth/data/aisaac/save1.dat`）。
- `LoadModDataFromFolder` 拼的是 `"../data/%s/save%d.dat"`（`LuaIsaac.cpp:991`），并用 `g_Manager->_currentSaveSlot` 取槽位（**槽位 0 会被当 1**，`LuaIsaac.cpp:982-989`）。
- 文件名限制：正则 `[^\x00-\x1F"*/:<>?\\|]+`（`_Internals.cpp:143-145`）——**不能带子目录、不能带控制字符**；没有长度上限但有 `luaL_argerror`。
- 没有“任意绝对路径”的 API：`[文档]` REPENTOGON 的 `Isaac.md` 只列出 `LoadModDataFromFolder`；`[源码]` 全仓 grep `fopen|std::ifstream|std::ofstream` 命中的都是 REPENTOGON 自己实现功能用（房间配置、ESSM、ImGui、SaveSyncing），**没有一个是暴露给 Lua 的通用读写**。

### 2.3 最小示例（1.1.3-unstable）

```lua
-- 写（自己数据文件夹/data/isaac_agent/decision.json）
mod:SaveData('{"valid":true}', "decision.json")
-- 读
local text = mod:LoadData("decision.json")   -- 不存在返回 nil
```

---

## 3. 路 3：`Mod:LoadData` / `SaveData` 中继（Profile C）

### 3.1 文件与格式 `[实测-本机文件]`

本机真实产物（没有起游戏，但文件是历史运行时写下的）：

```
E:\Steam\steamapps\common\The Binding of Isaac Rebirth\data\aisaac\save1.dat        23 B   -> "FTTTTTTTTTTT22222222222"
E:\Steam\steamapps\common\The Binding of Isaac Rebirth\data\just_gambling\save1.dat 570 B  -> {"D":{"Pools":[],...
```

结论：**`saveN.dat` 就是一段纯文本原文**（无二进制头、无长度前缀、无压缩）。这意味着：
- 插件可以直接把 JSON 文本写进这个文件，`Mod:LoadData()` 读出来就是那段文本；
- 反之 mod `SaveData(json)` 写下去，插件读到的也是明文。

### 3.2 读写的时机：**每次调用都开文件** `[源码]` + `[未实机验证]`

- `Isaac.LoadModData` 的实现不在 REPENTOGON 里（是游戏本体），但 REPENTOGON 在 `LuaIsaac.cpp:993` 写了一句注释：**“Could have used a std::ifstream or something instead, but who knows maybe the consistency with Isaac.LoadModData means something”**——即它特意模仿 `Isaac.LoadModData`，而它的实现是**每次调用 `file.OpenRead` 读整份文件**（`LuaIsaac.cpp:994-999`）。
- 参考实现（AI Item Control）用 `Mod:SaveData`/`LoadData` 当 5Hz 文件桥，sidecar 写文件后几秒内就能被读到——这是第三方**实机**行为证据（我们是读它的源码与注释得出的，未复现）。
- 结论：**实时中继在原理上成立**；`[未实机验证]`：真实游戏里 `LoadData` 是否每次读盘、游戏是否在存档/退出时覆盖该文件，需要在真机上跑一次探针（`spike/profile_b_probe` 已包含 `LoadData` 前后对比）。

### 3.3 槽位问题（必须处理）

- 文件名是 `save<slot>.dat`，`slot = g_Manager->_currentSaveSlot`（0 当 1），所以玩家用 1/2/3 号存档时读到的是不同文件。
- 插件侧要么**同时写 save1/2/3 三个文件**（每个 ~1 KB，代价可忽略），要么让玩家在插件配置里指定槽位。

### 3.4 最小可行方案（推荐给 v1.1 的形态）

**方案 C1：单文件共享 + epoch/turn 栅栏（兼容 1.0.12e，任何 REPENTOGON）**

```
<游戏目录>/data/isaac_agent/save<slot>.dat   ← 唯一共享文档（明文 JSON）
{
  "v": 1, "epoch": 7, "turn": 42, "writer": "mod" | "plugin",
  "state": { ...state.json 的内容... },
  "decision": { ...decision.json 的内容... } | null
}
```

- mod：`Mod:SaveData(json)` 写入 `writer="mod"` 的文档（带新 turn），每 `validity/2` 一次；
- 插件：读文件 → 只在 `epoch/turn` 匹配时写回 `decision`（保留 state 原样）→ 写前校验、写时**临时文件 + rename**（插件有完整文件权限）；
- mod：`Mod:LoadData()` 每 6 帧读一次，校验 `decision.session_id/request_id/gen_level_key` 后消费；读到半截（JSON 解析失败）就丢弃重试。
- 栅栏规则（沿用参考实现的经验）：只有 mod 能 `epoch++`；插件写回前校验 epoch/turn 未变；双方都容忍对方覆盖（last-writer-wins + 校验）。

**方案 C2：双文件（REPENTOGON ≥ 1.1.2e，更干净）**

- mod → 插件：`mod:SaveData(state_json)` 写自己的 `save<slot>.dat`；
- 插件 → mod：插件写 `data/isaac_agent_bridge/save<slot>.dat`，mod 用 `Isaac.LoadModDataFromFolder("isaac_agent_bridge")` 读；
- 两个文件不会互相覆盖，**不需要 epoch 栅栏**，失败面小很多；代价是要依赖 1.1.2e（已发布）。

**方案 C3：任意文件名（仅当探针实测确认版本支持）**：`mod:LoadData("decision.json")` 直接读 `data/isaac_agent/decision.json`，无槽位问题。**不要在未确认的版本上依赖它**（1.1.3 的公开脚本里没检到这个重载）。

### 3.5 失败兜底（无论哪个方案）

- **读不到/解析失败/字段不合法** → 当“没有决策”，走本地规则（现有逻辑已经是这样，不需要改判定）。
- **写失败**（`SaveData` 返回 false / 插件写盘失败） → 保留旧文件、记 `IO`、下一帧重试；绝不写半截。
- **不可接受的失败模式：把 mod 的存档数据写坏**。我们的 mod 不存任何其它数据，但仍要：
  1) 用**独立文件名**（C2/C3）或**只写自己这份**（C1）；
  2) 插件侧写盘必须先写 `.tmp` 再 `rename`，失败保留旧文件；
  3) 文档里带 `v` 版本字段，读不懂就整份丢弃，不做“尽力修补”；
  4) 首次启用时由 mod 先写一份合法空文档（`SaveData`），确保目录/文件存在，插件再开始写。

### 3.6 工作量（粗估）

| 部分 | 内容 | 估时 |
| --- | --- | --- |
| mod 侧 | 共享文档编解码复用现有 json、SaveData 写入、LoadData 轮询、epoch/turn 栅栏、session 校验（已有）、失败降级 | 1–1.5 人日 |
| 插件侧 | 发现数据目录（游戏安装路径 + mod 文件夹 + 槽位）、读/写合并、原子写、栅栏校验、单测 | 1 人日 |
| 联调 | 真机跑通“进房→写 state→插件回 decision→生成道具”与四种失败路径 | 0.5–1 人日（**需要装了 REPENTOGON 的机器**） |

---

## 4. 路 4：LuaJIT FFI / `package.loadlib`

### 4.1 结论：**不可行**

- 这游戏**不是 LuaJIT**：运行时是 Lua 5.3（`Lua5.3.3r.dll` / `Lua5.3.3f.dll`），因此没有 `jit`、没有 `ffi`。`[源码/文件清单]`
- `package` / `package.loadlib`：`[文档]` IsaacDocs《Standard-Library》表把它们列在“仅 `--luadebug`”一栏；随包脚本与 REPENTOGON 都没有恢复 `package`（grep 0 命中）。`[源码]`
- `loadfile`/`load` 在默认启动下被置 nil（`resources/scripts/main.lua:1185-1191`），REPENTOGON 还额外把 `debug` 置 nil（`main_ex.lua:2061`）。`[源码]`
- 探针里加了 `type(jit)` / `type(package)` / `type(debug)` 三项，预期全为 `nil`（见 §1.2）。`[未实机验证]`

---

## 5. 对产品的影响（给 captain 的决策输入）

1. **“装上就用”不是完全没路**，但路不是 `io`，而是 `Mod:LoadData/SaveData` 中继（C）。它不需要 `--luadebug`、不需要玩家改启动项。
2. **纯 B 没有意义**：只读不写，插件拿不到局面；真正能落地的默认形态是 **C**。t24 的“M7 选 A”在**当前 v1 范围**仍然成立（v1 不实现 C）；但文档里“Profile B 不可能”应改成更准确的表述：**“B 单独不可行；C 可行，推迟到 v1.1”**。
3. **版本门槛**：
   - 现在就能做（兼容 1.0.12e）：C1 单文件共享；
   - 更干净：C2（需 1.1.2e+，已发布；1.1.3 是最新稳定版）；
   - 最干净：C3（任意文件名，仅当前 main 有；**1.1.3 没有**，不依赖）。
4. **必须真机验证的两件事**（决定 C 是否真的“实时”）：
   a. `Mod:LoadData()` 是否每次调用都读盘（而不是开局缓存）；
   b. 游戏在存档/退出时会不会覆盖 `save<slot>.dat`（若会，插件的写入会被冲掉，需要重新设计写入时机）。
   两项都可以用 `spike/profile_b_probe` 一次跑完（探针会打印 `LoadData` 前后内容与 `SaveData` 后的回读结果）。
5. 建议：**v1 按 A / local-only 发**（与 t24 一致，不改 README）；把 C 作为 **v1.1 的头号候选**，先做 C1（兼容面最大）或直接 C2（若确认用户 REPENTOGON ≥ 1.1.2e）。

---

## 附录 A：探针 mod

`spike/profile_b_probe/`（`main.lua` + `metadata.xml` + `README.md`）。装上后进一次游戏，`log.txt` 里搜 `[PROBE]`，一次性回答：

- `io/os/package/jit/debug` 的实际存在性；
- `Mod:LoadData()` 的原始内容（判断是否每次读盘、文件是否被覆盖）；
- `Mod:LoadData(filename)` / `Isaac.LoadModDataFromFolder` 是否可用（版本门槛）。

## 附录 B：证据清单

| # | 证据 | 位置 |
| --- | --- | --- |
| 1 | 标准库白名单（io/os/package 仅 --luadebug） | https://github.com/wofsauge/IsaacDocs/blob/main/docs/tutorials/Standard-Library.md |
| 2 | 默认启动清空 debug/dofile/loadfile/load | 游戏随包 `resources/scripts/main.lua:1185-1191` |
| 3 | REPENTOGON 裁剪 os（只剩 4 个函数） | REPENTOGON `repentogon/resources/scripts/main_ex.lua:2061-2069` |
| 4 | `Mod:SaveData/LoadData` 支持 filename 的重载 | 同上 `main_ex.lua:2011-2041`、`2089-2092` |
| 5 | 文件名正则（禁子目录/控制字符） | `repentogon/LuaInterfaces/_Internals.cpp:141-150` |
| 6 | 读写实现（整个文件、二进制、即时） | `_Internals.cpp:71-124` |
| 7 | 数据目录 = `mod._dataDirectory` | `_Internals.cpp:37-40` |
| 8 | `LoadModDataFromFolder` 路径 `../data/%s/save%d.dat`、槽位 0→1 | `LuaIsaac.cpp:966-1005` |
| 9 | 版本门槛：filename 重载只在 `v1.1.x`（未发布，changelog 第 1 行，在 `v1.1.3` 之上）；`LoadModDataFromFolder` 在 `v1.1.2e` | `changelog.txt:1`、`:26-31`、`:189`/`:203`；`1.1.3` tag 的 `LuaIsaac.cpp`（含该函数）、`main_ex.lua`（无 filename 重载） |
| 10 | `saveN.dat` 是明文（JSON/纯文本） | 本机 `data/just_gambling/save1.dat`、`data/aisaac/save1.dat` |
| 11 | REPENTOGON 最新发布 = 1.1.3（2026-09-15） | GitHub Releases API `releases/latest` → tag_name `1.1.3` |
