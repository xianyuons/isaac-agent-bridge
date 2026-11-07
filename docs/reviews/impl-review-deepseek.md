# 实现级评审（DeepSeek 第二线）— revision r2

> **契约基线**：`fb9e25c`（`origin/agent/t8-claude-review`，protocol/architecture = `1.0-draft.5`）。
> **实现基线**（r1 时点）：`7d4e102`（`origin/main`，其 `plugin/index.js` 与 `ba5e61c` 一致，t13 修复尚未落盘）+ `agent/t12-lua-defects`（Lua 侧已修 5 处缺陷，106 断言）。
> **实现基线**（r2 时点）：`origin/main` = `ec4d49f`，已并入 t12（Lua 5 处）、t13（插件 R1/R2、junction TOCTOU、校验缺口）、t20（Lua 消费清整个 K + 回执改到核验后写，106→133 断言）；另有 t18（draft.5 字段：session_id/plugin_status/插件测试）、t21（capabilities/ts）、t24（m5/m7）三支修复分支在途未合 main。
> **GPT 线报告**：已落盘（`origin/agent/t10-gpt-review`，commit `bf56f39`，`docs/reviews/impl-review.md`，272 行）。本版已逐项对照，见 §7。
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

**r2 更新（2026-11-07）**：t20（`7223289`）已合入 main——`M3`（消费未清空整层在途表）与「核验迟到仍写成功回执」均已修（Lua 断言 106→133）。新增 4 条必修（§8）：8.1 `and/or` 陷阱写错 error_code、8.2 `make_key` 前 8 截断、8.3 未知 error_code 被接受、8.4 JSON 解码器容忍原始换行。GPT 线已对照（§7），我漏掉的 5 项（G04/G07/G11/G14/G15）已采纳。**§2 必修清单以 §7.4 / §8.6 的最新状态为准。**

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
| r1（续） | 2026-11-07 | t15：核验临时评审员 8 条发现并作为 §6 附录并入。 |
| r2 | 2026-11-07 | GPT 线报告落盘（bf56f39），补 §7「与 GPT 线重合/分歧/它提到而我漏掉的」；t16 核验第二批 5 条 Lua 发现作为 §8 附录；G01/M3/核验回执按 t20 更新为已修。 |

---

## 6. 附录：临时评审员 8 条发现核验（t15）

> 来源：一位临时评审员（未署名、报告未落盘）交来 8 条实测发现。本节由 reviewer-ds 对着当前代码逐条复核，判定「成立 / 已修 / 不成立」。基线：契约 `fb9e25c`（draft.5）；Lua 实现 `origin/agent/t12-lua-defects`；插件实现 `origin/main`（7d4e102，源码与 ba5e61c 一致）。临时评审员引用的行号（如 `main.lua L638-699`）是 t3 旧版行号，本节一律改用当前代码的真实行号。

### 6.1 Profile A 探测没有 --luadebug 门控 —— **成立（部分），并入 M7**

- 判定：**成立（部分）**。由临时评审员首次发现、reviewer-ds 复核。
- 证据：`mods/isaac_agent/main.lua:743-805` `bridge_detect` + `main.lua:704-740` `bridge_probe_dir`——只探测 `io_available()` / `os_available()`（`main.lua:550-558`），无任何 `--luadebug` 启动参数字符串检查；探测写 `.probe.tmp` 成功即 `S.profile = "A"`，失败即 `"none"`（`main.lua:762-804`）。
- 澄清与后果：协议 §1.8 明确"只有在玩家已用 `--luadebug` 启动时写探针才可能成功"，即"靠 io/os 探测判 `--luadebug`"是协议认可的机制，本身不算缺陷。**真正的问题是代码没有 Profile B 状态**（= 本报告 M7）：io/os 不可用时落 `"none"`（纯本地规则），而非文档说的"默认 B（mod 只读 decision）"。后果：captain 定的"默认 B"产品形态在代码里不存在；玩家不改启动项得到的是纯本地规则，文档承诺的"B 只读桥"落空。`[静态]`（沙箱 `io` 缺失来自 t3 实测结论，本机未起游戏复验）。
- 改法：见 M7——要么实现真·Profile B（只读 decision），要么协议/README 把默认形态如实改为"无桥接（本地规则）"。

### 6.2 rename 失败先删目标再重试 —— **已修，不计必修**

- 判定：**已修**。
- 证据：`mods/isaac_agent/main.lua:606-687` `bridge_write_raw` 已是 `.bak` 保底路径：`os.rename(target, bak)` → `os.rename(tmp, target)` → 失败回滚 `os.rename(bak, target)`，全程无 `os.remove(target)` 先行删除。`tests/lua_logic_test.lua:760-778` T22 patch `os.rename` 全失败后验证旧 state 字节不变、无 tmp/.bak 残留。t12 已修。

### 6.3 两端平局排序不一致 —— **不成立（两端结果一致）**

- 判定：**不成立**。
- 证据：draft.5 §6.5.6 已规定"非空 `pedestal_index` 升序 → 数组下标 → `item_id`"。Lua 侧 `first_matching` / `first_candidate`（`main.lua:1591-1617`）实现"pedestal_index 升序（null 靠后）→ ipairs 数组序"；TS 侧 `compareCandidates`（`index.js:540-556`）实现"pedestal_index 升序（null 靠后）→ index → item_id"。数组下标唯一，`item_id` 平票分支不可达，故两端**无实际分歧**。差异只在可读性：Lua 靠 ipairs 隐含序、TS 显式 `index`。建议 Lua 侧把"数组下标"显式化，并入 L6（可读性），非正确性缺陷。

### 6.4 插件缺跨进程锁 —— **成立，= 已有 M4**

- 判定：**成立**。由临时评审员首次发现、reviewer-ds 复核；与本报告 M4 为同一缺陷。
- 证据：`plugin/index.js:284-293` `withWriteLock` 是进程内 Promise 串行队列；注释（`index.js:280-282`）自认"非常驻进程，用进程内串行队列代替 bridge.lock"。§1.10 的 `bridge.lock` / 持有者存活检测未实现。多 DSH 进程并发仍可能互相覆盖 `decision.json`。
- 改法：见 M4。

### 6.5 路径校验薄弱 —— **成立，= 已有 L3，另补 UNC 子项**

- 判定：**成立**。由临时评审员首次发现、reviewer-ds 复核；与本报告 L3 为同一缺陷，另补 UNC 观察。
- 证据：`plugin/index.js:181-213` `resolveBridgeDir` 只对"第一个存在的祖先"做一次 realpath/symlink 校验；`plugin/index.js:216-230` `safeFilePath` 写盘时只 lstat 文件本身、不重验父目录 realpath，lstat 与后续 open/rename 之间有 TOCTOU。UNC 路径：`path.isAbsolute('\\\\server\\share\\...')` 返回 true，代码未对 UNC 明确纳入/排除根白名单，realpath 在 UNC 上的行为未验证 `[静态]`。
- 改法：见 L3 + 明确 UNC 处理策略（默认拒绝或显式白名单）。

### 6.6 未发现代码执行 —— **成立（正面结论）**

- 判定：**成立（已核实的正面结论）**。由临时评审员首次确认、reviewer-ds 复核。
- 证据：`plugin/index.js:707-739` `normalizeDraft` 只做 `JSON.parse` + 字段选择（`item_id` 整数且必须在候选池 / `action` 白名单 `skip`），`reason` 走 `sanitizeReason`；`mods/isaac_agent/main.lua:1432-1452` `validate_decision` 同样只收候选池内 id 或 `skip`，`reroll` 被拒。无 `eval` / `Function` / 子进程。协议 §9"不执行远端代码"红线满足。

### 6.7 五条失败路径的测试质量 —— **部分成立**

- 判定：**部分成立**，逐项：
  1. **超时（模型中途超时）——成立**：`tools/mock_e2e.py` 场景 4 用 `state["ts"] = now - 5000` 的"预先陈旧 state"测"预算已耗尽 → 不调模型"，未测 `plugin/index.js:745-758` `callModelOnce` 的 AbortController 中途超时路径（模型流挂住、`timer` 触发 → `TIMEOUT`）。
  2. **写入失败——成立（仅插件侧）**：`tools/mock_e2e.py` 无 rename/EPERM 场景；`plugin/index.js:295-353` `writeDecisionAtomic` / `renameWithRetry` 无任何测试。Lua 侧 T22 已覆盖 rename 失败，故"完全没有测试"仅对插件成立。
  3. **迟到响应——部分成立**：mock 无迟到场景（成立）；"Lua 也没有"不成立——`tests/lua_logic_test.lua:512-525` T10（clock+2000 → reject `late`）与 `tests/lua_logic_test.lua:700-724` T20（消费后同 request 再投 → `late`）都覆盖了迟到。
  4. **版本不匹配——成立**：Lua T07 有（major 不匹配 → `version_major`）；`tools/mock_e2e.py` 无 `version_major` 场景（场景 2 只测缺 `request_id` 信封）。
  5. **T06"没推进时钟、看起来测了"——不成立（指控）**：T06（`tests/lua_logic_test.lua:452-466`）确实只 `clear_decision()` 后立即 `draw`，测的是"无决策文件 → TIMEOUT"路径；但"时钟过期"路径由 T10（迟到）与 T21（过期缓存）覆盖，三者互补，不是漏测。
- 改法：为插件补 `callModelOnce` 中途超时、`writeDecisionAtomic` rename 失败、state major 不兼容三组离线测试（并入 M6）。

### 6.8 `python -m unittest discover -s tools/tests` 在 main 上失败 —— **不成立（当前 main 上）**

- 判定：**不成立**。
- 证据（复现）：`cd 仓库 && python -m unittest discover -s tools/tests` → `Ran 15 tests ... OK`（exit 0）。`tools/tests/test_danmaku_sim.py` 在 `origin/main`（7d4e102）存在，由 t5 合入（4c23f0a）带入；README 的 `python -m unittest discover -s tools/tests -p "test_*.py"` 与真实结构对齐。临时评审员大概率在旧 main（ba5e61c，t5 未合、tools/tests 尚未创建）上核的。
- 顺带（非本条，供 qa）：README/CONTRIBUTING 里"Lua 逻辑 74 条断言"是陈旧数字（t12 后为 106 条），可顺手更新。

---

## 7. 与 GPT 线重合 / 分歧 / 它提到而我漏掉的（r2 对照节）

> GPT 线报告：`origin/agent/t10-gpt-review` commit `bf56f39`，`docs/reviews/impl-review.md`（272 行），实现基线 `0e4d66f`（已含 t12/t13），独立评审、不互相覆盖。下表逐项给态度。

### 7.1 重合项（两边都提到，判定一致）

| GPT 编号 | 本报告编号 | 一致态度 | 现状 / 派任务 |
| --- | --- | --- | --- |
| G01 同 K 终态隔离 | M3 | 同意 | **已修(t20)**，见 §7.4 |
| G03 跨进程实例锁 | M4 | 同意 | 未修；无派单（待 t24 或后续） |
| G05 目录替换 TOCTOU | L3 | 同意 | **t13 已修父目录 realpath 重验**（我 r1 基线 7d4e102 未含 t13，故 r1 判"未修"）；t12 的 owner 令牌只护 mod 侧写，不护插件侧 |
| G06 rename 删旧文件 | （t12 已修项） | 同意 | 已修(t12, T22) |
| G10/D5-B 未知 provider 前缀被拒 | M1 | 同意 | 未修；t18/t21 未覆盖（需单独派） |
| G12 四接口无组装入口 | M5 | 同意 | 未修；t24（m5-m7）在途 |
| G13/D5-A 时钟 + session 四文档 | M2 + H1 | 同意 | session → t18 在途；ts 秒级粒度 → t21（capabilities-ts）在途 |
| D5-C 默认只读能力（Profile B） | M7 | 同意 | t24（m5-m7）在途 |

### 7.2 分歧项（两边判定不同，逐条裁决）

- **G01 / M3 的"同 K 全清"状态**：我 r1 判 M3「未修（只清单 request）」；GPT 判「已修(t12，同 request 子项)，同 K 其他 request 仍待复核」。两者其实同向——t12 确实只修了同 request，同 K 未清。**t20（7223289 `fix(lua): 消费清整个 K、兜底也清 K、回执改到核验之后写`）已把同 K 全清**（新增 `consume_generation(gen_key)`，见 §7.4），断言 106→133。故本条目两边统一更新为 **已修(t20)**。
- **G05 / L3**：GPT 判「已修(t13 父目录 realpath + t12 owner 令牌)」；我 r1 判 L3「未修」。差异源于基线：我 r1 的实现基线是 7d4e102（t13 未合），GPT 基线是 0e4d66f（含 t13 dbc5ddc）。**裁决：t13 确实修了插件侧"resolve→换 junction→write"的父目录 realpath 重验，L3 的插件侧部分已修；UNC 白名单未明确与"复制 owner 令牌绕过"两条仍开**。我采纳 GPT 的修正，L3 降为「t13 已修核心，剩 UNC 白名单」。
- **G07 冷缓存扫描**：我 r1 在 reasoning 里意识到 `ensure_candidates` 可能在回调 62 内冷缓存全量扫描（`build_candidates` O(maxId)），但**没有写进正式报告**；GPT 单列为 high。裁决：**同意 GPT，采纳为漏项**（见 §7.3）。

### 7.3 GPT 提到而我漏掉的（采纳，需补进必修清单）

| GPT 编号 | 内容 | 我的态度 | 是否已派任务 |
| --- | --- | --- | --- |
| G04 R1/R2 竞态覆盖 | 插件旧异步请求完成后覆盖新请求（decision.json 最终是旧 R1） | **同意，我漏了**（r1 插件基线 7d4e102 未含 t13，我未识别该竞态） | 已修(t13, dbc5ddc)，需复评"发布目标绑定"剩余 |
| G07 冷缓存扫描 + 池失败扩全表 | 回调 62 冷缓存 `build_candidates` 全量扫描、池 API 空集回退全表 | **同意，我漏了**（reasoning 有、报告没列） | 未派单 |
| G11 非合作上游取消 | `callModelOnce` 的 `for-await` 必须等流结束，忽略 signal 的上游会挂住工具 | **同意，我漏了** | 未派单 |
| G14 未知信息省略/null + max_red 规则 | 必填 name 为 nil 被编码器省略；可选非 nullable max/cid 发 null；两端把 max_red 未知当可回血 | **同意，我漏了**（部分在 reasoning 里，未正式列） | 未派单（t21 只覆盖 capabilities/ts，未覆盖 G14 的 null/规则） |
| G15 reason 清洗为 llm 成功 | 插件 `sanitizeReason` 把非法 reason 清洗而非拒绝，掩盖模型违约 | **同意，我漏了** | 已修(t13 reason 严格校验子项)，字节/空串/Unicode 控制范围需复评 |

### 7.4 G01/M3 与 t20 的对账（captain 指定核对）

- t20 提交 `7223289`：`fix(lua): 消费清整个 K、兜底也清 K、回执改到核验之后写`。
- 证据：`origin/main:mods/isaac_agent/main.lua:1976-1987` 新增 `consume_generation(gen_key)`——`for rid, rec in pairs(S.outstanding) do if rec.gen_level_key == gen_key then S.outstanding[rid] = nil; S.consumed_requests[rid] = true ...`，**按 gen_level_key 清空全部同 K 请求**（不再只清 `doc.request_id`）。
- 断言：`origin/main` `ec4d49f` 标题「Lua 断言 106→133」。G01 的"R1/R2→消费→R2/D2 迟到→第二次生成不得 llm"回归已由 t20 覆盖。
- **结论**：GPT 的细分（"同 request 分支已修、同 K 其他 request 待复核"）与 t20 的修复一致；t20 已把同 K 全清。**本报告 M3 与 GPT G01 统一更新为「已修(t20)」**。fallback 终态是否也一并终结，见 t20 提交"兜底也清 K"，我抽读 `consume` 路径确认 fallback 分支同样走 `consume_generation`（`main.lua` 当前版 fallback 兜底路径也清 K），故整项关闭。

---

## 8. 附录：第二批 5 条 Lua 发现核验（t16）

> 来源：同一名临时评审员（lupa 5.4 内存加载原实现 + 原 fixture）。本节由 reviewer-ds 对当前代码复核，判定「成立 / 已修 / 不成立」。基线：Lua 以 `origin/main`（`ec4d49f`，已含 t12+t20）为准；标注"t12 已修"仅指 t12 分支，t20 为后续修复。

### 8.1 `player_dead` 本地 guard 写出 `error_code=TIMEOUT` —— **成立（未修）**

- 判定：**成立**。由临时评审员首次发现、reviewer-ds 复核。是 Lua `a and nil or b` 陷阱。
- 证据：`mods/isaac_agent/main.lua:1948`（当前 main）`make_applied_local`：
  `error_code = guard_skip and nil or err_code`。
  Lua 里 `guard_skip and nil` 在 guard_skip 为真时返回 `nil`（假值），随后 `nil or err_code` 继续走到 `err_code`；guard_skip 为假时 `false or err_code` 也返回 `err_code`。**两种分支都返回 `err_code`（默认 `"TIMEOUT"`）**，与"安全跳过 error_code 应为 null"（协议 §5.4 行 4、§3.6 no_candidate/player_dead 归类 null）相悖。
- 后果：`player_dead` / `no_candidate` 的安全跳过，`applied.json` 里 `error_code` 被写成 `TIMEOUT` 而非 `null`，回执真值表对不上；统计会把安全跳过误计为超时失败。
- 改法：用显式 if/else，别用 and/or 当三元：
  ```lua
  local error_code = err_code
  if guard_skip then error_code = nil end
  ```
  并把 `rec.error_code` 改为 `error_code`（同时给该路径补一条断言：安全跳过时 `error_code == null`）。

### 8.2 候选第 9 项变化时 `make_key` 相同 —— **成立（未修）**

- 判定：**成立**。由临时评审员首次发现、reviewer-ds 复核。
- 证据：`mods/isaac_agent/main.lua:1175`（当前 main）`make_gen_level_key`：`for i = 1, math.min(#candidates, 8) do sig = (sig * 31 + candidates[i].item_id) % 4294967296 end`。签名只取**前 8 个候选** + `#candidates`（计数），第 9..64 个候选变化时签名不变。
- 后果：§1.5 要求 `gen_level_key` 覆盖"候选池内容签名、候选池重掷必须变化"。前 8 截断使"候选池变化检测"不完整。当前被 `cand_cache` 掩盖（候选按 floor 冻结、从不重采样），故暂不显式炸；但一旦做候选池重掷/移除，键不随内容变化，插件缓存/去重会误判"同一局面"。`[静态]`。
- 改法：签名纳入**全部**候选（`for i = 1, #candidates`），或至少纳入"候选集合的完整哈希"而非前 8 个。与 t20 的 `consume_generation` 无冲突，可单独修。

### 8.3 未知 `error_code`（如 `ALIEN`）的决策被接受 —— **成立（未修）**

- 判定：**成立**。由临时评审员首次发现、reviewer-ds 复核。
- 证据：`mods/isaac_agent/main.lua:1377-1382`（当前 main）`validate_decision`：对 `doc.error_code` 只做 `type(err) ~= "string"` 的类型检查，**没有对五类码（IO/TIMEOUT/VALIDATION/MODEL/INTERNAL）做枚举校验**。`error_code = "ALIEN"` 的非空字符串会通过，且真值表逻辑照常用它。
- 后果：§3.1 `error_code` 是封闭五值枚举（`string|null`）。mod 消费侧接受未知 error_code，与插件侧 `validateStateDoc`（`index.js:410-412` 用 `ERROR_CODES.has()`）不一致；含 `error_code:"ALIEN"` 的 decision 可能被执行或写进 applied，索引/统计失准。
- 改法：`validate_decision` 增加五类码白名单校验，未知值 → `VALIDATION` / `invalid_type`（与插件一致）。

### 8.4 严格 JSON 里的原始换行被接受 —— **成立（低危，未修）**

- 判定：**成立**。由临时评审员首次发现、reviewer-ds 复核。
- 证据：`mods/isaac_agent/main.lua:316-360`（当前 main）自写 `parse_string` 的 `else` 分支（`main.lua:355-358`）对任意字符（含原始换行 `0x0A`、制表 `0x09`）直接 `out[#out+1] = c` 追加，未按 RFC 8259 拒绝字符串内未转义的控制字符（U+0000–U+001F）。
- 后果：§1.1 要求"严格 JSON"。解析器比规范宽松。实际影响低：唯一写方（插件）用 `JSON.stringify` 恒输出转义后的合法 JSON；`reason` 里的控制字符也会在 `validate_decision`（`main.lua:1462`）被单独拦。故属"规范宽松边界"而非可利用漏洞。`[静态]`。
- 改法（二选一）：① 在 `parse_string` 对 `c < 0x20` 且非转义的字符 `fail("control char in string")`，按规范拒绝；② 若刻意放宽，在协议/README 明确"解码器容忍字符串内原始控制字符"的边界。推荐 ①。

### 8.5 `POST_PICKUP_INIT` 晚 3 帧到达时仍写 `phase=applied / applied_by=llm / actual=null` —— **已修（t20）**

- 判定：**已修（t20）**。
- 证据：当前 main 已改为"回执只在核验后写"：
  - `main.lua:63` `VERIFY_WINDOW_FRAMES = 5`（由 2 帧放宽到 5 帧，并注明"必须有界"）。
  - `main.lua:2129-2151` `finalize_pending_verify(actual_item_id, reason_code)`：把 pending 回执结算为 `phase=rejected / applied_by=none / source=nil / provider_id=nil / fallback=true / choice=nil / error_code=INTERNAL / reason_code=not_applied`，再 `write_applied`。
  - `main.lua:2167-2178` `on_pre_get_collectible`：命中 item 时**不再立即写 applied**，只入 `S.pending_verify`；仅 skip（item_id=nil）即时写。
  - `main.lua:2207-2210`（`on_pickup_init` 超窗）与 `main.lua:2241-2243`（`on_update` 超窗兜底）都调 `finalize_pending_verify(nil, "not_applied")`。
- 结论：临时评审员描述的"生成早已发生却按成功记 applied/llm/actual=null"已被 t20 消除；核验不到/超窗/被覆盖统一落 rejected/none + reason_code。不计必修。

---

### 8.6 本节小结

| 编号 | 判定 | 归属 |
| --- | --- | --- |
| 8.1 player_dead 的 `and/or` 陷阱 | 成立（未修） | 新增必修（建议列 MEDIUM，回执真值表被破） |
| 8.2 make_key 前 8 截断 | 成立（未修） | 新增必修（LOW，被 cand_cache 掩盖） |
| 8.3 未知 error_code 被接受 | 成立（未修） | 新增必修（MEDIUM，两端校验不一致） |
| 8.4 原始换行被 JSON 接受 | 成立（低危，未修） | 新增必修（LOW，规范宽松边界） |
| 8.5 核验迟到仍写成功回执 | 已修（t20） | 不计必修 |
