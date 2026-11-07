# 实现级评审（DeepSeek 第二线）

> **契约基线**：`fb9e25c`（`origin/agent/t8-claude-review`，protocol/architecture = `1.0-draft.5`）。
> **实现基线**：`7d4e102`（`origin/main`，其 `plugin/index.js` 与 `ba5e61c` 一致，t13 修复尚未落盘）+ `agent/t12-lua-defects`（Lua 侧已修 5 处缺陷，106 断言）。
> **GPT 线报告**：截至本版交付时尚未落盘，本版未做逐项对照；「与 GPT 线重合/分歧」对照节待补。
> **评审方式**：只读代码，只写本评审文件，不改任何实现。凡本机无法实际运行的检查，在对应条目后标注 `[静态]`。

---

## 0. 结论摘要

**评审结论：needs_revision（需要修订）**。存在两条 HIGH 级契约违背（`session_id` 系统性缺失、已删除的 `capabilities` 字段被复活），以及若干 MEDIUM 级缺陷（未知 `provider_id` 前缀被校验堵死、时间基准不统一、消费后未清空整层在途表、`bridge.lock` 未实现、四类扩展点无代码接口）。

已实际运行验证（非静态）：
- `python tests/run_lua_test.py`（Lua 5.4）：**106/106 通过**，exit 0。
- `ISAAC_AGENT_LUA=53 python tests/run_lua_test.py`（Lua 5.3）：**106/106 通过**，exit 0。
- `python tools/mock_e2e.py`（插件离线联调）：**4/4 场景、52/52 断言通过**，exit 0。
- `subst` 盘符无残留。

t12 已修的 5 处（消费后 outstanding、过期缓存、rename 丢旧文件、rejected 真值表、目录替换 TOCTOU）经核代码与测试确认已落地，**不重复计分**。

---

## 1. 必答六问

### Q1 契约遵循：发明字段、SHOULD 当 MUST、可选当必填

**H1 · `session_id`（draft.4 起必填，tri-party A26）系统性缺失 —— HIGH**

- 定位：
  - `plugin/index.js:940-963` `makeDecisionDoc`——`decision.json` 根信封只有 `protocol_version/request_id/decision_id/gen_level_key/ts/error_code/features/requires/valid/decision`，**没有 `session_id`**。
  - `mods/isaac_agent/main.lua:1694-1714` `build_applied_doc`——`applied.json` **没有 `session_id`**。
  - `mods/isaac_agent/main.lua:1761-1770` `emit_event`——`event.json` **没有 `session_id`**。
  - `plugin/index.js:384-533` `validateStateDoc` **不校验** `state.session_id`；`mods/isaac_agent/main.lua:1345-1474` `validate_decision` **不校验** `decision.session_id`；`tools/mock_e2e.py` 全文无 `session` 字样（其"符合 §3.1"的校验器同样漏检）。
- 严重度：HIGH。
- 应该改成什么：`decision/event/applied` 三份文档补齐 `session_id`（与 state 回显一致），两端校验器对 `session_id` 做 `^[A-Za-z0-9_-]{8,64}$` 校验，不一致拒绝（`session_mismatch`）；`mock_e2e.py` 的协议校验器同步补 `session_id`。
- 不改会怎样：`session_id` 是 draft.4 为"跨局/跨进程隔离、事件去重、缓存键"引入的硬约束（A26 采纳的 Claude P0）。两端都缺失意味着：旧局残留的 `decision.json` 无法靠 `session_id` 判废弃，只能碰运气靠 `request_id`（其内嵌 `boot` 随机值）兜底；协议宣称的隔离不变量没有代码兑现，属契约背离而非小瑕疵。

**H2 · 已删除的 `capabilities` 字段被复活 —— HIGH**

- 定位：
  - `mods/isaac_agent/main.lua:1230` `build_state_doc` 写 `capabilities = capabilities_list()`（与 `features` 同值）；draft.4 已删 `capabilities`、统一为 `features`（tri-party A29）。
  - `plugin/index.js:663` `buildStateSummary` 仍读 `state.capabilities`。
- 严重度：HIGH。
- 应该改成什么：mod 删除 `capabilities` 字段，只保留 `features`；plugin 把 `summary.capabilities` 改为读 `state.features`（或直接删，因为它只进 prompt 摘要）。
- 不改会怎样：A29 明确"留两份必然分叉"。今天两端恰巧同值还没炸，一旦 `features` 与 `capabilities` 语义分化，规则/能力门控会在两端算出不同结果，且没有测试能拦住（`mock_e2e` 不校验该字段）。

**M2 · 时间基准不统一 + `ts` 秒级粒度 —— MEDIUM**

- 定位：
  - `mods/isaac_agent/main.lua:124-128` `wall_ms()` 用 `os.time()*1000`——`os.time()` 只到**秒**，`ts` 永远是 1000 的倍数（亚秒信息丢失）。
  - `mods/isaac_agent/main.lua:115-121` `now_ms()` 用 `Isaac.GetTime()`（单调毫秒），mod 内部新鲜度判定（`decision_is_fresh`、`poll_decision` 的 `t - out.sent_ms`）走的是单调钟，而 `ts` 字段走的是 epoch 秒——**mod 内部与上报字段不是同一时钟**，与 A31"统一 `state.ts` 墙钟"相悖。
  - `plugin/index.js:970-981` `computeBudget` 用 `state.ts + validity_ms - 200 - Date.now()` 算预算，`state.ts` 秒级量化使 `remaining` 被低估最多约 999ms。
- 严重度：MEDIUM。
- 应该改成什么：`ts` 改用亚秒墙钟（或干脆两端约定用 `Isaac.GetTime()` 单调值 + 明确写清同机单调语义），消除秒级量化；预算计算要么对量化误差留裕量，要么改时钟源。
- 不改会怎样：`validity_ms=1500` 的近场场景下，`remaining` 可能被算到 200ms 以下（低于插件 `MIN_ATTEMPT_MS=250`），**该有模型预算的抽取被误判为无预算而直接规则兜底**，间歇性降级、且无日志能指出真因。`[静态]`（`os.time` 秒级是 Lua 语义事实；对真实游戏内误兜底比例的影响未在游戏内实测）。

**L1 · `trigger.event_seq` 写 0 —— LOW**

- 定位：`mods/isaac_agent/main.lua:1233` `event_seq = S.event_seq or 0`（首次请求时 `S.event_seq` 未初始化，落 `0`）。
- 严重度：LOW。
- 应该改成什么：协议 §2.1 `trigger.event_seq` 取值 `>= 1`；无事件时省略或 `null`，不要写 `0`。
- 不改会怎样：`plugin` 侧 `validateStateDoc` 对 `trigger.event_seq` 只做 `>=1` 校验（`index.js:428`），写 0 会被当 `out_of_range` 拒绝——但插件实际读到的是 `state.json`，只要 mod 总在 `emit_event` 之后才写 state 就不会撞上；这是"刚好没炸"的脆弱点。

**L2 · 头注释与实现/契约脱节；Profile B 实际未实现 —— MEDIUM**

- 定位：
  - `mods/isaac_agent/main.lua:11` 写"协议 1.0-draft.3"（契约已是 draft.5）。
  - `mods/isaac_agent/main.lua:17` 写"Profile A（目标）"（draft.5 产品口径是"默认 B"）。
  - `mods/isaac_agent/main.lua:762-804` `bridge_detect` 只有两个出口：`S.profile = "A"` 或 `S.profile = "none"`；`main.lua:764` 注释写"Profile B/本地规则"但实际落 `none`。**代码里没有 `"B"` 状态**。
- 严重度：MEDIUM（默认产品形态未被实现）。
- 应该改成什么：要么实现真·Profile B（只读 `decision.json`、不写 state/event/applied），要么在协议/README 把默认形态如实改为"无桥接（纯本地规则）"，删掉不可实现的"B 只读桥"表述。
- 不改会怎样：captain 在 t8 定稿"默认 B：mod 只读 decision、不需改启动项"，但 vanilla Isaac 沙箱**不提供 `io`**（连读 `decision.json` 都不行，`--luadebug` 才放开，而放开即等于 A）。当前代码下，玩家不改启动项得到的是 `none`（纯本地规则，气泡"桥接不可用"），与"B 只读桥"的文档描述不一致；文档承诺的能力在默认路径上不存在。`[静态]`（沙箱 `io` 缺失来自 t3 实测结论与 IsaacDocs，本机未起游戏复验）。

### Q2 五条失败路径：哪条只有代码没测试

五条失败路径的测试覆盖：

| 路径 | Lua 侧测试 | 插件侧测试 |
| --- | --- | --- |
| 超时 | T06 ✓ | mock_e2e 场景 4 ✓ |
| 非法 id | T04/T05 ✓ | mock_e2e 场景 3 ✓ |
| 版本不匹配 | T07（仅 major）✓ | **无**（mock_e2e 只测缺 `request_id` 信封，未测 `version_major`） |
| 写入失败 | T22（rename 失败保留旧文件）✓ | **无**（`writeDecisionAtomic`/`renameWithRetry` 的 EPERM/EBUSY 重试、失败保留旧文件无任何用例） |
| 迟到响应 | T10/T20 ✓ | 不适用（插件按需写、不判迟到） |

**M6 · 插件侧"版本不匹配"与"写入失败"两条路径只有代码没测试 —— MEDIUM**

- 定位：
  - `plugin/index.js:388-395` `validateStateDoc` 的 `version_major` 分支（fatal → 不写 decision）无测试。
  - `plugin/index.js:295-353` `renameWithRetry` / `writeDecisionAtomic` 的失败保留旧文件、清理 tmp 无测试。
  - `plugin/index.js:1453` 导出了 `__testing`（`validateStateDoc`/`computeBudget`/`normalizeDraft`/`writeDecisionAtomic` 等纯函数），但仓库内**没有 JS 单测文件**引用它；`mock_e2e.py` 是唯一插件测试且只覆盖 4 个 happy/fallback 场景。
- 严重度：MEDIUM。
- 应该改成什么：为插件补一个离线单测（Node 内置 `node:test` 即可，不新增依赖），至少覆盖：state major 不兼容不写 decision、rename 连续 EPERM 后旧 decision.json 字节不变、路径穿越/symlink 拒绝、模型输出非法两次后落 `source=rule` 兜底。
- 不改会怎样：插件的两个最危险失败路径（写盘原子性、版本拒绝）没有回归护栏，未来改动容易悄悄打破"失败保留旧文件"与"major 不兼容不写 decision"这两条硬约束。

补充：`requires`/minor 门控两端近乎死代码——`main.lua:1363-1370` 校验 `requires` 但 mod 自己恒写 `requires=arr({})`；`plugin/index.js` 的 `validateStateDoc` **根本不校验 `state.requires`**，且 `makeDecisionDoc` 恒写 `requires:[]`。`version_minor_feature` 这条契约路径既无数据也大概率无测试。

### Q3 并发与顺序

**M3 · 消费后未清空整层在途表，同 K 不同 request_id 可被复用 —— MEDIUM**

- 定位：`mods/isaac_agent/main.lua:1988-1994` `consume`——消费时只 `S.outstanding[doc.request_id] = nil` 并记 `consumed_requests[doc.request_id]`，**没有按 `gen_level_key` 清空其余同 K 请求**。
- 严重度：MEDIUM。
- 应该改成什么：消费发生后，遍历 `S.outstanding` 清掉所有 `gen_level_key == 当前 K` 的条目（协议 §6.7.1"生成发生后立即清空该 K 的未决项"）；`T20` 之外补一条"同 K 不同 request_id 的迟到决策在第二次生成时不得被复用"的用例。
- 不改会怎样：池级预取下同一房间多个底座共用同一个 K（`make_gen_level_key` 里 pedestal 恒 `-1`）。第一个底座消费掉 R2 的决策后，R1/R3 仍留在 `outstanding`；Boss 房 `validity=5000` 时，R1/R3 的迟到决策（指纹可能已随玩家掉血变化，但 mod 的 `gen_level_key` 不含玩家状态）仍落在窗口内，会被 `poll_decision` 接受并缓存，第二个底座复用它——违反 §6.7.5"消费后该 K 的其余决策全部作废"。t12 的 `consumed_requests` 只堵住了**同一 request_id** 的复用，没堵住**同 K 不同 request_id** 的复用。`[静态]`（代码路径推演，未在游戏内构造多底座房实测）。

**M4 · `bridge.lock`（协议 §1.10 MUST）未实现 —— MEDIUM**

- 定位：`plugin/index.js:280-293` `withWriteLock` 是**进程内** Promise 串行队列；注释（`index.js:280-282`）自认"本插件非常驻进程，用进程内串行队列代替 bridge.lock"。`bridge.lock` 文件从未被创建、校验、清理。
- 严重度：MEDIUM。
- 应该改成什么：要么按 §1.10 实现 `bridge.lock`（独占创建 + pid/启动时间 + 僵死清理），要么在协议里把"常驻宿主锁"降级为"调用级进程内串行 + 单写者说明"，不要让协议 MUST 与实际不符。
- 不改会怎样：`decision.json` 的唯一保护是单进程内队列；两个 DSH 进程/两处并发 `isaac_decide` 会交叉写同一 `decision.json`（都走 `tmp`+`rename`，不会写坏半份，但会互相覆盖、`decision_id` 竞态）。当前风险低（默认单 DSH 进程），但 §1.10 的跨进程单写者不变量没有被兑现。

### Q4 安全边界

**L3 · 插件路径校验是一次性的，写盘时存在 TOCTOU —— LOW（可接受但需记录）**

- 定位：`plugin/index.js:181-213` `resolveBridgeDir` 只在入口做一次 realpath/symlink 校验；`plugin/index.js:216-230` `safeFilePath` 写盘时只校验"文件不是 symlink"和路径包含关系，**不重验父目录 realpath**。若 `resolveBridgeDir` 之后、`writeDecisionAtomic` 的 `mkdir`/写盘之前，`<bridge>` 被换成 junction，写入会落到 junction 目标。
- 严重度：LOW。
- 应该改成什么：写盘前重验 `realpath(bridgeDir)` 与白名单一致（mod 侧用 `.isaac_agent_owner` 令牌防了同一类问题，插件侧缺对等防护）。
- 不改会怎样：需要攻击者已有同用户写 `%LOCALAPPDATA%` 的能力；且 `decision.json` 被 mod 读取后会再过一次候选池校验（非法 id 被拒），真正危险方向（恶意 `state.json` 注入 prompt）已被 `SYSTEM_PROMPT`（`index.js:75`）与 `validateStateDoc` 双重缓解。故 LOW。`[静态]`（未实际构造 junction 攻击验证）。

**模型输出未被当代码执行：符合红线 ✓**

- `plugin/index.js:707-739` `normalizeDraft` 只接受 `item_id`（整数、必须在候选池）或 `action`（白名单 `skip`），`reason` 走 `sanitizeReason`；`mods/isaac_agent/main.lua:1432-1452` `validate_decision` 同样只收候选池内 id 或 `skip`，`reroll` 被拒。无 `eval`、无路径拼接、无模型指定文件路径。此条通过，无需修改。

**L4 · owner 令牌（`.isaac_agent_owner`）无插件侧回归测试 —— LOW**

- 定位：`mods/isaac_agent/main.lua:574/585-592/725-739` 的 owner 令牌机制已实现并被 T24 测试；但插件侧没有任何测试或代码保证"未来改动不会误删/改写 `.isaac_agent_owner`"。
- 应该改成什么：在 `mock_e2e.py` 加一条断言——跑完场景后 `<bridge>/.isaac_agent_owner`（若 mod 探针写过）仍在且内容不变。
- 不改会怎样：插件若未来加"清理桥目录"逻辑，可能顺手删掉令牌，导致 mod 判定目录被替换、整体停写（Bridge 降级 none），且问题只会在真机出现。

### Q5 可读性

**L6 · main.lua 单文件 2342 行，超长函数 + 架构建议的模块化未落地 —— LOW**

- 定位：`mods/isaac_agent/main.lua` 整体 2342 行；`validate_decision`（1345-1474，约 130 行）、`build_state_doc`（1184-1262，约 80 行）、`bridge_write_raw`（606-687，约 80 行）、自实现 JSON codec（182-464，约 280 行）全部平铺在一个文件。架构 §3.2 列的 Lua table 契约（`BridgePort`/`EventSource`/`LocalRuleProvider`/`Presenter`）在代码里不存在，全是裸 `local function`。
- 严重度：LOW（可维护性）。
- 应该改成什么：至少把 JSON codec、Bridge（读写/探针/owner）、decision 校验三块拆成 `mods/isaac_agent/data/*.lua` 或子模块，与架构 §3.2 的 table 契约对齐。
- 不改会怎样：审阅与回归成本高；与架构文档承诺的"可插拔"结构对不上，后续加 EventSource/Presenter 只能继续在单文件里堆分支。

**L5 · `S.ped_index` 是抽取计数器，不是游戏底座索引 —— LOW**

- 定位：`mods/isaac_agent/main.lua:2106-2113` `on_pre_get_collectible` 用 `S.next_pedestal_index` 自增当 `ped`，再写进 `applied.pedestal_index`（`main.lua:2120`）。这是"第几次抽取"的计数，不是协议 §5.2 `pedestal_index`（目标底座 0..63）。池级预取下真实底座索引未知，应填 `null`。
- 严重度：LOW。
- 应该改成什么：池级预取（候选 `pedestal_index` 全 `null`）时，`applied.pedestal_index` 也写 `null`，或另行给 `x_draw_seq` 扩展字段记录抽取序号，别占 `pedestal_index` 的语义。
- 不改会怎样：`applied.json` 的 `pedestal_index` 字段对外声称"目标底座"，实际是抽取序号，QA/统计读它会得到错误语义。

### Q6 四类扩展点能否真的替换

**M5 · 四类扩展点在代码里没有接口/注册表，替换需改核心函数 —— MEDIUM**

- 定位：
  - DecisionProvider：`plugin/index.js:1074-1343` `runIsaacDecide` 是硬编码单路径（llm → 兜底规则），没有 `DecisionProvider` 接口、没有 `canHandle/decide/priority/role`、没有注册表。`viewer`/`intent` 参数（`index.js:1281-1282`）只是拼进 prompt 的只读上下文，**不是** `ViewerVoteProvider`/`PresetProvider`。
  - EventSource：插件**不读 `event.json`**（只有 `readStateFile`），没有 `FileEventSource`/`VoteAggregator`；mod 侧 `emit_event` 是裸函数。
  - StateEnricher：插件无 `enrich`、无 Enricher 链。
  - Presenter：mod 侧 `show_bubble`/`draw_bubble` 是裸函数；插件无 `voice`/`danmaku`/`overlay` 任何 Presenter。
- 严重度：MEDIUM。
- 应该改成什么：至少把 DecisionProvider 抽成注册表（`{id, source, role, priority, canHandle, decide}`），让 `llm:primary`/`rule:fallback`/`rule:guard`/未来的 `viewer:*`/`preset:*` 走同一 `Orchestrator` 依次尝试；EventSource/StateEnricher/Presenter 至少在插件侧留出接口占位。
- 不改会怎样：架构 §8 宣称"加新玩法只加实现、不改核心"，但现状下加一个 `viewer:*` provider 必须直接改 `runIsaacDecide` 的分支与 `makeDecisionDoc` 的 `providerId` 来源。tri-party 已在架构层标过"假扩展点"，本评审在**代码层**确认：这四处目前都不可替换。

---

## 2. 必修清单（按严重度排序）

| # | 严重度 | 条目 | 定位 |
| --- | --- | --- | --- |
| H1 | HIGH | `session_id` 在 decision/event/applied 三份文档缺失、两端不校验 | `plugin/index.js:940-963`、`main.lua:1694-1714`、`main.lua:1761-1770`、`index.js:384-533`、`main.lua:1345-1474` |
| H2 | HIGH | 已删除的 `capabilities` 字段被复活并仍在两端流通 | `main.lua:1230`、`index.js:663` |
| M1 | MEDIUM | 未知 `provider_id` 前缀被两端校验堵死（违反 §3.5/A34，锁死扩展点） | `main.lua:1333-1342`、`index.js:883-888` |
| M2 | MEDIUM | 时间基准不统一 + `ts` 秒级粒度导致预算误差 | `main.lua:115-135`、`index.js:970-981` |
| M3 | MEDIUM | 消费后未清空整层在途表，同 K 不同 request_id 可复用 | `main.lua:1988-1994` |
| M4 | MEDIUM | `bridge.lock`（§1.10 MUST）未实现，仅进程内队列 | `index.js:280-293` |
| M5 | MEDIUM | 四类扩展点无代码接口，替换需改核心 | `index.js:1074-1343`、`main.lua` 全局 |
| M6 | MEDIUM | 插件侧版本不匹配/写入失败无测试；插件纯函数无单测 | `index.js:295-353`、`index.js:388-395` |
| M7 | MEDIUM | Profile B 未实现（S.profile 只有 none/A），默认形态与文档不符 | `main.lua:762-804`、`main.lua:764` |
| L1 | LOW | `trigger.event_seq` 写 0 | `main.lua:1233` |
| L2 | LOW | 头注释 draft.3 / "Profile A 目标" 与 draft.5 脱节 | `main.lua:11,17` |
| L3 | LOW | 插件路径校验一次性，写盘时 TOCTOU | `index.js:181-213`、`index.js:216-230` |
| L4 | LOW | owner 令牌无插件侧回归测试 | `tools/mock_e2e.py` |
| L5 | LOW | `S.ped_index` 是抽取计数非底座索引 | `main.lua:2106-2113,2120` |
| L6 | LOW | main.lua 单文件 2342 行、超长函数、模块化未落地 | `main.lua` |

---

## 3. 与已修项的核对（不重复计分）

t12 已修 5 处，逐条核过代码与测试，确认落地：

1. 消费后 outstanding 未清 → `main.lua:1988-1994` + `consumed_requests` + T20。**已修**（但仍留同 K 未清空的 M3）。
2. 过期缓存压住刷新 → `decision_is_fresh`（`main.lua:1957-1966`）+ `on_update` 丢弃（`main.lua:2211-2215`）+ T21。**已修**。
3. rename 连败删旧文件 → `.bak` 回滚路径（`main.lua:634-686`）+ T22。**已修**。
4. rejected 回执真值表 → `main.lua:2179-2187` + T23。**已修**。
5. 目录替换 TOCTOU → `.isaac_agent_owner` 令牌 + `bridge_verify_dir` + T24。**已修**。

---

## 4. 验证记录

实际运行（exit 0）：

- `python tests/run_lua_test.py` → `lua_logic_test: 106/106 断言通过`。
- `ISAAC_AGENT_LUA=53 python tests/run_lua_test.py` → `106/106 断言通过`。
- `python tools/mock_e2e.py` → `4/4 场景通过（52/52 项断言）`。
- `subst` 无残留。

未实际运行、纯静态分析的条目：M2（游戏内误兜底比例）、M3（多底座房实测）、L3（junction 攻击验证）、M7（真机沙箱复验）、以及所有 REPENTOGON 运行时行为（回调 62 时序、Font API、`Isaac.GetTime` 单位、`IsCollectibleInPool` 签名）——均已在对应条目标 `[静态]`。

---

## 5. 修订历史

| revision | 日期 | 内容 |
| --- | --- | --- |
| r1 | 2026-11-07 | 初版（DeepSeek 第二线）。GPT 线报告未落盘，对照节待补。 |
