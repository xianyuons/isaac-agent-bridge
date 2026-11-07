# 三方评审记录（t7）

> 对象：[docs/protocol.md](../protocol.md) 与 [docs/architecture.md](../architecture.md)（t1 产出，回写前 v1.0-draft.2）。
> 日期：2026-11-07。负责人：contract。
> 方式：同一份提纲（五问 + Q6）。DeepSeek 由当前会话模型按提纲直接评审；GPT 为 tokenshop 独立进程调用，只接收文档与提纲，未接收其他评审内容；Claude 因 ginka 上游不可用，**本节待补**（见 §2），未采信任何替代模型意见。
> 本文件 revision r1：DeepSeek + GPT 两节 + 回写记录；Claude 补齐后由 t8 追加 revision r2。

## 0. 结论摘要

- 两家都认为 **“刷新/缓存/消费”没有闭合契约** 是最值钱的问题：GPT 把它列为 P0（Q5），DeepSeek 把它列为 P0 的近邻（预取覆盖/多目标队列）。已在 protocol 新增 §6.7（含 R1→R2 时序表、指纹字段、结果归属、消费与迟到规则）。
- 两家都指出 **规则平票/池级 `pedestal_index=null`** 会让 Lua 与 TS 合法地选出不同道具；已改成“非空 pedestal_index 升序 → 候选数组下标 → item_id”。
- 两家都指出 **`validity_ms` 的起算点语义不清**；已明确为“发出→使用”的双阶段窗口，插件预算从 `state.ts` 起算。
- 对“哪个是假扩展点”两家 **没有共识**：DeepSeek 认为 EventSource 最假（通知适配器，不是可靠总线），GPT 认为 StateEnricher 对地图/敌人是假扩展（v1 state 没有输入）。两份意见都部分采纳，见 §4.1，不强行合并成“只有一个假扩展点”。
- Claude 节未完成，因此本文件 **不代表三方一致**；t8 补齐前，任何“三方已同意”的表述都无效。

---

## 1. DeepSeek（当前会话模型：deepseek-flash）

### 1.1 原文要点（按提纲）

**Q1 字段缺失/多余**
- P1：缺角色与红心上限。protocol §2.2 只有 `red_hearts`/`soul_hearts`；Keeper/Blue Baby/堕化角色下“缺红心优先回血”会误判。建议补 `character_id` 与 `max_red_hearts`。
- P1：缺多目标承载。§2.1 规定一次请求只服务一个生成目标，但多底座房、连续 reroll、房间加载时抽取需要队列；协议没有 `pending_targets`/队列深度，latest-wins 会覆盖。
- P1：`applied.phase` 只有 `applied`/`rejected`；§6.3 的 `late`/`request_mismatch` 只进日志，QA 无法只读文件审计迟到丢弃。
- P2：`valid`/`error_code`/`fallback`/`reason_code` 四个分类字段有重叠，建议给机器可校验真值表。

**Q2 假扩展点**
- P1：`EventSource` 最像假扩展点。mod 侧事件来自固定游戏钩子，新增正式事件仍要改 mod + minor；文件模式 latest-wins 丢事件不能补；`custom` 只做通知，不能驱动玩法。
- P2：`Presenter` 的气泡通道是半假扩展点。voice/overlay/danmaku 可在插件侧替换；气泡必须 mod 实现，插件换不了。

**Q3 兜底歧义**
- P1：`validity_ms` 起算点两端不一致：§1.5 说“发出后多久内被接收”，§6.2 又在生成时检查 `now - request_sent_at <= validity_ms`；“接收及时但生成较晚”的决策会一边有效一边过期。
- P1：插件不知道窗口已被消耗多少；文件轮询/写盘延迟没有计入预算。
- P1：`valid:false` 的 skip 不执行，`valid:true + fallback + no_candidate` 的 skip 会执行；语义不同，建议真值表。
- P1：`reroll` 在回调 62 内无法执行（必须当帧返回 item id），协议没规定“返回 nil 再 reroll”还是拒绝。
- P2：`applied.decision_id` 可指向被拒绝的决策，而 `source/provider_id` 描述实际兜底，统计容易把被拒的 llm 决策算成实际来源。

**Q4 版本兼容**
- P1：major 不匹配插件沉默，mod 只能记 `TIMEOUT`/`no_fresh_decision`；`version_major` 只进日志，`applied.json` 看不到“对端太新”。
- P2：`features` 只是 informative，没有校验，容易变成装饰。
- P2：event/applied 的 major 兼容未定义。

**Q5 第三天最可能推倒重来**
- **预取调度与多目标覆盖**。一次一个生成目标 + latest-wins，遇到多底座房、快速 reroll、房间加载时抽取，会持续吃 `nil`/本地规则；要让每个底座都由 agent 决定，需要池级预取/决策队列，会同时改 transport、mod 状态机、插件调度。

**Q6 provider_id / source**
- 可读性：两维基本成立，但 §0.1 “模型给的还是规则兜的”与 §3.5“本地规则主路径 fallback=false”读起来矛盾；应改成“模型产生/非模型产生”。
- 校验：缺前缀交叉约束；`source:llm + provider_id:rule:x` 能通过。
- 统计：两维拆分正确，但 applied 是 latest-wins、Profile B 没有 applied，统计样本不完整。

### 1.2 采纳判断

采纳：`character_id`/`max_red_hearts`、`items.count`（GPT 也提）、`validity_ms` 双阶段、插件预算从 ts 起算、skip 真值表、`reroll` 禁止在回调 62 使用、`applied.decision_id` 语义、source 措辞、provider_id 前缀校验、统计边界、§6.7 契约、§11 已知取舍。
不采纳（v1）：`pending_targets`/队列字段、`applied.phase="discarded"`、强制跨 major 拒绝信封/`plugin_status.json`；原因见 §6。

---

## 2. Claude 节：待补（上游不可用）

> **本节未采信任何替代模型的意见。** 不用 opus、GPT、本地模型或任何“同家族”输出冒充 Claude。t8 在 ginka 恢复后补跑同一提纲，追加到本节并标 revision r2。

### 2.1 任务要求与实测

- 任务指定：provider `ginka`，model `claude-sonnet-5-5`。
- 实测一：`https://api.ginka.asia/v1/models`（带 key）返回的模型只有：
  `claude-opus-4-6`、`claude-opus-4-7`、`claude-opus-4-8`、`claude-opus-5-5`；**没有 `claude-sonnet-5-5`**。
- 实测二：`claude-sonnet-5-5` 请求返回
  `503 {"code":"model_not_found","message":"No available channel for model claude-sonnet-5-5 under group Claude-AWSQ (distributor)"}`。
- 实测三：改用 `claude-opus-5-5`（及 4-6/4-7/4-8）返回
  `502 {"message":"Upstream service temporarily unavailable","type":"upstream_error","param":"","code":null}`。
- 覆盖范围：`api.ginka.asia` 与 `api.ginka.cloud` 两个 host；直连与 `HTTPS_PROXY=http://127.0.0.1:10090` 代理；流式与非流式；`curl` 与 DSH headless 两条调用路径。
- 时间窗：2026-11-07 08:40–09:10（GMT+8），多轮重试（含连续 5 次探测）无一次成功；`/v1/models` 可通，chat completions 持续 502。
- 结论：这是 **上游渠道不可用 + 指定模型不在该 key 的模型列表**，不是本地配置错误；在拿到可用渠道前无法产出 Claude 评审。

### 2.2 待补内容

t8 补齐时必须：
1. 用同一份提纲（本文件 §1 的五问 + Q6）调用 Claude；
2. 原文要点追加到本节，不改写、不与其他两家对齐；
3. 若 Claude 与已采纳项冲突，新增“冲突点”条目并重新评估回写，不得静默覆盖；
4. 标 revision r2 并记录实际 provider/model/时间窗。

---

## 3. GPT（tokenshop / gpt-6.1-sol，走代理）

### 3.1 原文要点（按提纲）

**Q1 字段缺失/多余**
- P1：`state` 降级时 §6.3 要求“`error_code` 沿 state”，但 §2.1 只有 `error_code`、没有 `reason_code`；插件无法区分同为 `IO` 的读取失败与桥不可用。
- P1：protocol §2.3 有 `items[].count`，architecture §3.1 的 `GameState.items` 没有；解码后无法区分一件与多件。
- P2：`applied_by` 被称为“唯一判定字段”，但 §5.3 又由 `phase/fallback/source` 推导；应明确“生产端推导、消费端校验”。

**Q2 假扩展点**
- P1：`StateEnricher` 对地图/敌人是假扩展。architecture §4.3 承诺 `MapEnricher` 提供网格/已探索房间/门位置，但 `EnrichInput` 只有 `state`/`trigger`/`requestId`，`GameState` 没有这些数据，决策层又禁止碰游戏内存；实时增强无法兑现，静态预测才可以。

**Q3 兜底歧义**
- **P0**：规则未定义完整排序。§2.1 池级预取时 `pedestal_index` 全为 `null`，§6.5 却要求“平票按 pedestal_index 升序”，同目标多个候选可被两端合法地选出不同道具。
- P1：有效期有两种含义：§1.5 “接收截止” vs §6.2 “生成时 `now - sent <= validity_ms`” 的“使用截止”。
- P1：应用失败后的回执无法唯一填写：实际生成原版道具时没有规则 Provider 生效，§5.2 的 `provider_id`/`choice` 没有对应写法。

**Q4 版本兼容**
- P1：minor 允许新增“可选动作”，但 §3.6 规定未登记 `reason_code` → `VALIDATION`，新版只新增一个错误原因就可能让旧端拒绝整份决策。
- P1：跨 major 入口互相冲突：§7.3 允许兼容 reader “降级读+降级写”，§7.4 第一步却“major 不同就拒绝”；architecture §6 又要求按 major 选 codec。

**Q5 第三天最可能推倒重来**
- **P0：刷新、缓存与一次性消费之间没有闭合契约。** §1.5 每次刷新新 `request_id`，architecture §7 按 `gen_level_key` 去重，§6.2 又要求决策的 request_id 属于在途集合。文档没有规定：R1 的模型调用未完成时收到 R2，结果回显哪个请求；R1 何时移除；缓存能否重封装给 R2；同一池再次抽取是否已消费。影响请求管理器/缓存/消费端，不能靠某个 Provider 补救。

**Q6 provider_id / source**
- P1 可读性：会误导。§0.1 说 `source` 回答“模型给的还是规则兜的”，但 §3.5 明列“本地规则主路径”是 `rule + fallback:false`；应改成“模型产生/非模型产生”。
- P1 校验：两维不能识别主备角色；Provider 接口只有 id/source/priority，没有 role；两段式临时规则也没给合法组合。
- P1 统计：`applied_by` 可做单条回执分类，但不能据此声称统计覆盖每次抽取（latest-wins + Profile B 没有 applied）。

### 3.2 采纳判断

采纳：`state.reason_code`、`items.count`、`applied_by` 权威说明、StateEnricher 输入边界、P0 排序、validity 双阶段、应用失败回执、未知 reason_code 容忍、codec-first、§6.7 刷新/缓存/消费契约（重点扩写）、source 措辞、Provider `role`、两段式合法组合、统计边界。
不采纳：把 StateEnricher 直接判死（保留并注明“需 mod 导出 state 后才成立”，v1 只保留 NextFloorPreview/ItemPool）；跨 major 强制拒绝信封（保持可选）。

---

## 4. 冲突点（不抹平）

### 4.1 “哪个是假扩展点”没有共识

- DeepSeek：**EventSource** 最假（固定游戏钩子 + latest-wins，新增事件仍要改 mod；`custom` 不驱动玩法）。
- GPT：**StateEnricher** 最假（地图/敌人没有输入，实时增强无法兑现）。
- 处理：两处都回写为“条件性可插拔”，但 **不合并成单一结论**：
  - EventSource 在 architecture §4.2 明确为“通知适配器，不是可靠事件总线”；
  - StateEnricher 在 §4.3 明确“只能看 state/trigger/外部静态数据；Map/Enemy 需 mod 先导出，否则是占位”；
  - 气泡在 §4.4 明确“固定在 mod 侧，插件换不了”。
- 结论：v1 没有“完全可插拔”的 EventSource/StateEnricher；DecisionProvider 与 voice/danmaku/overlay 是真扩展点。

### 4.2 “第 3 天推倒重来”的两种诊断

- DeepSeek：**预取覆盖/多目标队列**（房间加载时抽取、多底座房，latest-wins 覆盖）。
- GPT：**刷新/缓存/消费契约**（R1/R2 身份、结果归属、消费失效）。
- 两者是同一块地基的两层：没有队列会覆盖/漏；没有契约会串号/重复消费。处理：
  - v1 先把 GPT 的契约闭合（§6.7 + 时序表），这是可实现的；
  - DeepSeek 的队列/池级预取写进 §11.1 已知取舍，列为 v2；
  - 不宣称“两个都解决了”；v1 仍不保证每个底座都由 agent 决定。

### 4.3 版本降级：拒绝信封 vs codec-first

- DeepSeek 倾向允许跨 major 的最小拒绝信封，避免 `version_major` 只留在日志。
- GPT 要求先统一 codec 选择与拒绝顺序，避免 §7.3/§7.4 自相矛盾；并容忍未知 `reason_code`。
- 处理：采纳 GPT 的 codec-first 与未知原因容忍；拒绝信封保持**可选**（§7.3），`plugin_status.json` 不引入（§11.5）。理由：跨 major 写任何信封都可能被误读；超时兜底是安全路径，但代价是信息丢失。

### 4.4 回执审计：discarded 字段 vs 回执完整性

- DeepSeek 希望 `applied.phase` 增加 `discarded`，让迟到丢弃可审计。
- GPT 要求把“实际生成原版道具、没有替换生效”写成完整回执，避免 `applied_by` 与 `provider_id` 冲突。
- 处理：采纳 GPT 的 §5.4 真值表（含 `rejected` / `none`）；不新增 `discarded` phase，迟到仍只进日志，写进 §11.2。理由：`applied.json` 是 latest-wins 单回执，新增 phase 仍会被后续回执覆盖，不能解决审计完整性；要审计得加独立日志/队列。

---

## 5. 采纳清单

| ID | 来源 | 意见 | 决定 | 回写位置 |
| --- | --- | --- | --- | --- |
| A1 | GPT | state 降级缺 `reason_code` | 采纳 | protocol §2.1/§6.4，examples |
| A2 | GPT | TS `items.count` 缺失 | 采纳 | architecture §3.1 |
| A3 | DeepSeek | 缺角色/红心上限 | 采纳 | protocol §2.2、§6.5 R3 |
| A4 | GPT | 池级 `pedestal_index=null` 的排序不定 | 采纳 | protocol §6.5 |
| A5 | GPT+DS | `validity_ms` 接收/使用语义冲突 | 采纳 | protocol §1.5、§6.1 |
| A6 | GPT | 刷新/缓存/消费契约未闭合（P0） | 采纳 | protocol §6.7（含时序表/指纹/归属/消费/迟到） |
| A7 | GPT | 应用失败回执无法唯一填写 | 采纳 | protocol §5.4 |
| A8 | GPT | 未知 `reason_code` 让旧端拒绝整份决策 | 采纳（容忍未知） | protocol §3.6 |
| A9 | GPT | 跨 major codec 选择与拒绝顺序冲突 | 采纳（codec-first） | protocol §7.3/§7.4、architecture §6 |
| A10 | DeepSeek | `reroll` 不能在回调 62 执行 | 采纳（禁止） | protocol §3.2 |
| A11 | 两家 | `source` 措辞“规则兜的”误导 | 采纳 | protocol §0.1 |
| A12 | DeepSeek | `provider_id` 前缀与 source 无交叉校验 | 采纳 | protocol §3.5、architecture §3.1 |
| A13 | GPT | Provider 缺主备 `role` | 采纳 | architecture §3.1/§4.1 |
| A14 | GPT | 两段式临时决策缺合法组合 | 采纳 | architecture §4.1 |
| A15 | GPT | StateEnricher 地图/敌人是假扩展 | 部分采纳（注明依赖 mod 导出） | architecture §4.3/§4.3 表、protocol §11.6 |
| A16 | DeepSeek | EventSource 是通知不是总线 | 采纳（澄清边界） | architecture §4.2、protocol §11.3 |
| A17 | DeepSeek | 气泡是半假扩展点 | 采纳（澄清固定实现） | architecture §4.4 |
| A18 | 两家 | 统计边界被夸大 | 采纳 | protocol §5.1、architecture §5 |
| A19 | DeepSeek | 被拒决策的 decision_id 统计歧义 | 采纳（§5.4 定义） | protocol §5.2/§5.4 |
| A20 | GPT | `features` 只是装饰 | 采纳（改为非硬依赖） | protocol §2.1/§3.1 |
| A21 | DeepSeek | 增加 pending_targets/队列 | 不采纳（v1） | protocol §11.1（v2） |
| A22 | DeepSeek | `applied.phase="discarded"` | 不采纳（v1） | protocol §11.2 |
| A23 | DeepSeek | 跨 major 强制拒绝信封 / plugin_status | 不采纳 | protocol §7.3（可选）、§11.5 |
| A24 | DeepSeek | v1 实时导出地图/敌人 | 不采纳（超出 t1/t3 范围） | protocol §11.6 |
| A25 | 两家 | 增加完整审计日志/可靠回执 | 不采纳（v1 用日志） | protocol §11.2 |

---

## 6. 不采纳与已知取舍

1. **v1 不做决策队列/池级预取**（A21）。一次一个生成目标、latest-wins 是刻意限制；多底座/房间加载时抽取覆盖有限。理由：队列会同时改 transport、mod 状态机、插件调度，超出 v1；写入 §11.1。
2. **不增加 `discarded` phase**（A22）。`applied.json` 是 latest-wins 单回执，新增 phase 也会被覆盖；迟到只进日志。要精确审计需独立日志/队列。
3. **不强制跨 major 拒绝信封、不引入 `plugin_status.json`**（A23）。跨 major 写任何文档都可能被误读；沉默 + 超时兜底是安全路径，代价是 `version_major` 只在日志、applied 显示 TIMEOUT。
4. **v1 不实时导出地图/敌人**（A24）。Map/Enemy Enricher 先作为占位，等 mod 用可选 state 字段导出后再启用；当前不承诺“改核心？否”的实时能力。
5. **不做完整审计/可靠回执**（A25）。文件模式 event/applied 都是 latest-wins；精确统计需要 pipe/HTTP 队列或独立日志。
6. **不引入 `pending_targets` 字段**：同上，队列属 v2；v1 只保证单目标路径正确。

---

## 7. 回写记录与版本

- protocol：新增 §6.7（刷新/缓存/消费契约 + R1→R2 时序表）、§5.4（应用回执真值表）、§11（已知取舍）；修改 §0.1、§1.5、§2.1–§2.3、§3.2–§3.6、§5.1–§5.3、§6.1–§6.5、§7.3–§7.4、§12 变更记录；版本 `1.0-draft.3`。
- architecture：标题/版本改为 `v1.0-draft.3`；修改 §3.1（GameState 字段 + source/provider 两维说明）、§3.1/§4.1（Provider `role` + 两段式合法组合）、§4.2（EventSource 边界）、§4.3（Enricher 输入边界）、§4.4（气泡固定）、§5（统计边界）、§6（codec-first）、§7（指向 §6.7）。
- examples：三个 state 增加 `reason_code:null`、`player.character_id`/`max_red_hearts`，与回写后的必填/可选字段一致。
- 版本：protocol `1.0-draft.3`；architecture `v1.0-draft.3`。
- 未完成项：Claude 节（t8）。本文件 revision r1 **只覆盖 DeepSeek + GPT 两家**；t8 追加后标 r2。

---

## 8. t8 待办

1. ginka 恢复后，用同一提纲调用 Claude（优先 `claude-sonnet-5-5`；若仍无该模型，先在任务里报告，不擅自换模型）。
2. 将原文要点写入 §2；若与 A1–A25 冲突，新增“冲突点”条目并重新评估回写，不得静默改判。
3. 追加 revision r2，记录实际 provider/model/时间窗；保持 §0 结论标注“三方”还是“两家”。
