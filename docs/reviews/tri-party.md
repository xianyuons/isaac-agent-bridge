# 三方评审记录（t7 + t8）

> 对象：[docs/protocol.md](../protocol.md) 与 [docs/architecture.md](../architecture.md)。
> 日期：2026-11-07。负责人：contract。
> 方式：同一份提纲（五问 + Q6）。DeepSeek 由当前会话模型按提纲直接评审；GPT 为 tokenshop 独立进程调用；Claude 为 ginka 独立进程调用（t8 补审）。三家都只接收文档与提纲，未接收其他评审内容。
> **快照不对称（必须注明）**：DeepSeek / GPT 评审的是回写前 `v1.0-draft.2`；Claude 补审的是已吸收前两家回写的 `v1.0-draft.3`。因此 Claude 的若干 P0 是对“回写后文档”的再检查，不是同一快照的三方对照；不能把三份意见当成对同一版本的同时投票。
> 本文件 revision r2：DeepSeek + GPT（r1）+ Claude 补审（t8）+ 回写记录（protocol/architecture `v1.0-draft.5`，含 t8 期间 captain 产品取舍）。
> **t24/t25 更新**：t24 把 v1 表述修正为「只支持 Profile A + local-only，B/C v1.1+」；t25 spike 进一步确认 **B 单独不可行、C（共享 SaveData 中继）可行但 v1.1+**。本文中“默认 B”的历史描述以 [decisions-m5-m7](decisions-m5-m7.md) 与 protocol 1.1-draft.2 为准。

## 0. 结论摘要

- 三家都把 **预取 / 刷新 / 消费的生命周期** 视为最大风险，但诊断层次不同：GPT 指“刷新/缓存/消费契约未闭合”（P0）；DeepSeek 指“多目标覆盖/队列缺失”；Claude 指“决策必须早于池抽取 + 不做水位”导致主场景覆盖不足。v1 先闭合 GPT 的契约（§6.7），队列/池级预取仍列为 v2，不宣称已解决覆盖问题。
- Claude 在补审中抓到三处 **回写后仍存在的 P0 自相矛盾**，均已修复：
  1. `DecisionDoc` 缺 `features` / `requires`，TS 编码器会永远不写 `requires`；
  2. 时钟基准：§1.5 “单调时钟”与 §6.1 “`state.ts` 墙钟”冲突；
  3. `applied_by` 三套口径：§5.3 算法 / §6.2 `none` / §6.3 表 `fallback` 互相打架。
- 三家都指出 **扩展点有条件性**，但没有共识：DeepSeek 指 EventSource，GPT 指 StateEnricher，Claude 指 StateEnricher 且追加“votes 数据链断头、Presenter 拆成两半”。处理见 §4.1，不强行合并成“只有一个假扩展点”。
- Claude 还抓出 **session 隔离缺失**（`event_seq` 重启归零、跨局缓存复用）、**池标识是 SHOULD**、**`actual_item_id` 可选但被核心判定依赖**、**`features`/`capabilities` 重复**、**降级白名单丢 `requires`/`provider_id`**、**未知 provider 前缀被校验堵死**、**`max_red_hearts` 未知被当可回血**。这些已进入 r2 回写。
- 三方并未达成“完全一致”：Claude 对 Q5 的判断（预取时序是根因、需要房间级池预取）比另外两家更激进；我们只采纳其“文档必须承认覆盖缺口”，不把房间级池预取写成 v1 承诺，见 §4.5 与 §6。

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
不采纳（v1）：`pending_targets`/队列字段、`applied.phase="discarded"`、强制跨 major 拒绝信封；`plugin_status.json` 原先不采纳，t8 Claude 补审后改为 **可选采纳**（A41），见 §6。原因见 §6。

---

## 2. Claude（ginka / claude-sonnet-5-5）

### 2.1 本次补审用了什么模型、什么时间、什么证据

- **实际模型**：`claude-sonnet-5-5`（ginka）。任务要求优先 sonnet；t8 开始时 ginka `/v1/models` 已重新出现 `claude-sonnet-5-5`（t7 的 08:40–09:10 窗口内没有），因此 **没有** 退到 opus。
- **前置验证（09:22）**：
  - `GET https://api.ginka.asia/v1/models` 返回包含 `claude-sonnet-5-5`、`claude-opus-5-5`、`claude-opus-4-6/4-7/4-8` 等；
  - 16-token 测试请求（`claude-sonnet-5-5`）返回 `HTTP 200`，正文 `OK`，响应 `model` 字段为 `claude-sonnet-5-5`（request id `msg_011CgnhDigVt9lT95b8T13US`）。
- **完整评审（09:26–09:27）**：DSH headless + ginka，同一份提纲（五问 + Q6），输入为当时文档全文（protocol/architecture `v1.0-draft.3`，98976 B），输出 9940 B。
- **快照说明**：DeepSeek / GPT 评审的是 `v1.0-draft.2`；Claude 评审的是已吸收两家回写的 `v1.0-draft.3`。**不是同一快照**；Claude 的 P0 中有三处正是回写后仍存在的矛盾，见 §2.3。
- **t7 历史（本轮已恢复）**：08:40–09:10 期间 `claude-sonnet-5-5` 返回 503 `model_not_found`（`/v1/models` 当时无 sonnet）；`claude-opus-4-6/4-7/4-8/5-5` 返回 502 `Upstream service temporarily unavailable`，asia/cloud 两个 host、直连/代理、流式/非流式均失败。t7 因前置条件不满足留空，未采信替代模型。
- 未使用替代模型；未把其他模型意见归到 Claude 名下。

### 2.2 原文要点（按提纲）

**Q1 字段缺失 / 多余 / 两端不对齐**
- P2：版本标识不清：protocol 正文标 `v1.0`、变更记录到 `draft.3`，architecture 标 `draft.3`，冻结基线没写清。
- P1：缺 `session_id`。`event_seq` 是进程内单调（§4.1），mod 重启归零；architecture §4.2 的 `FileEventSource` 只比较 `eventSeq`，重启后事件会被当重放全部丢弃。§6.7.8 缓存以 `gen_level_key` 为键，两局同层同房同候选时指纹相同，会复用上一局决策，且 `decision_id` 是新的，V-17 测不出。
- P1：池级预取的池标识只是 SHOULD（§2.1），但候选池一致性是硬校验，插件不能拿 SHOULD 字段做硬判断。
- P1：`actual_item_id` 标“非必填”，但 §5.4 的核心判定依赖它。
- P1：`features` 与 `capabilities` 同值同义（都含 `transport:file_write`），留两份必然分叉。
- **P0：两端 schema 不对齐**：protocol §3.1 的 `decision.json` 有 `features` / `requires`，architecture §3.1 的 `DecisionDoc` 没有；TS 编码器照接口写盘 → `requires` 永不出现 → mod 的 `version_minor_feature` 分支永远不触发。

**Q2 假扩展点**
- **StateEnricher 最假**：architecture §3.1 自认地图/敌人字段不存在；§11.6 又说 Map/Enemy 只是占位。即便 v1 可成立的 `item_pool` / `next_floor_preview`，输出也只进 `ProviderContext.enrichments`，`DecisionDoc` 没有 enrichments 字段，mod 侧不可见；Enricher 改不了任何“两端必须一致”的判定。
- **EventSource 第二假**：`BilibiliDanmakuSource` 归一化为 `custom`，但 `ProviderContext.votes` 的来源全文未定义，`DecisionOrchestrator.decide(request)` 只吃 `StateDoc`；§8 却称“B 站观众投票｜改协议？否｜改核心？否”。
- Presenter 是“真扩展点但拆成两半”（气泡固定 mod 侧）；DecisionProvider 是唯一真扩展点，但 `role`/`priority` 与 mode 组装表写死，加 provider 仍要改组装代码。

**Q3 兜底语义（两处 P0）**
- **P0 · 时钟基准矛盾**：§1.5 说“一律使用本机单调时钟的接收时刻，不比较 `ts`”；§6.1 却说 `remaining = state.ts + validity_ms - now`。单调时钟与 epoch 不同源，两进程 `now` 也不同源；同一决策 mod 按接收时刻判新鲜、插件按 `state.ts` 判过期。
- **P0 · `applied_by` 三套口径**：§5.3 算法 → `phase=rejected` 时 `none`；§6.2 无局面时 `rejected/none`；§6.3 表却把“桥不可用”写成 `fallback`，把 `valid:false` 也写 `fallback`。按 §6.3 实现的 mod 必被 §5.3 判 bug。
- P1：§6.3 的 `applied_by` 列有“生成时回退/保持原结果”等非枚举值。
- P1：§1.5 “多条有效决策取接收时间最新”与 §6.7.4 “接受任何 outstanding 决策”并存，但 `decision.json` 是单文件覆盖写，多条只存在于 mod 内存，边界未定义。
- P1：§6.5 规则 3 把 `max_red_hearts` 缺省（未知）当可回血，与 §2.2 的谨慎基调不符。

**Q4 版本兼容**
- §0 结论 6 “major 不一致 → 拒绝解析”与 §7.3 “先选 codec，有兼容 reader 就解码”冲突；V-05 又写“state major 更新 → 插件不写 decision”。一件事三种说法。
- 降级白名单不含 `requires`：带新能力的决策经 N-1 reader 降级后被当“无要求”执行，绕开 §7.2 的能力门控。也不含 `provider_id`，而降级路径要产 `applied.json` 必填字段。
- §11.5 自认跨 major 只显示 `TIMEOUT`，使 `version_major` 永不出现在回执，与 §8.2 “失败必须显式”冲突。

**Q5 第三天最可能推倒重来**
- 问题不在字段，在时序：“决策必须早于池抽取” + “不做水位”。architecture §0.1 自认 `room_enter` 对本房间底座通常太晚，第一个底座可能只能 `nil`/Morph；§9 又明确不做 16 池/水位。两条合起来，v1 主动放弃覆盖主要场景；第一次真机跑 Boss 奖励就会落 Morph → 闪烁 + 双重判定 → 重写生成链路。
- 次要：时钟基准（改两行可对齐，不够“推倒”）。

**Q6 `provider_id` × `source`**
- 可读性：`source:"rule" + fallback:false + provider_id:"viewer:bilibili"` 三个字段才读得出一件事，而 §5.2 又说 `applied_by` 是“唯一判定字段”。
- 校验（最严重）：§0.1 说 `provider_id` 可无限扩，§3.5 却对未知前缀直接 `VALIDATION`；新增 provider 必须同时改两端校验表，扩展点被自己的校验堵死。
- 统计：同一套规则可落 `rule:local` / `rule:fallback` / `rule:low_hp`，`fallback` 可 true/false，`applied_by` 可 fallback/provider；按 provider_id 统计“兜底率”是三行两类噪声；`rule:guard` 的安全跳过也被记成 fallback，抬高兜底率。
- 建议：`rule:guard` 归 `provider`；未知前缀降 WARN，不拒整份文档。

### 2.3 对回写的影响

已采纳并回写：
- 新增必填 `session_id`（state/decision/event/applied），事件去重与缓存键改为 `(session_id, …)`；V-17 语义改为“新 session 的旧决策必须丢弃”。
- 池级预取 `trigger.payload.pool` 从 SHOULD 改为 **必须**；`actual_item_id` 改为必填（可为 null）。
- 删除 `capabilities`，统一用 `features`；`DecisionDoc` 补 `features` / `requires`。
- 统一时间基准为 `state.ts` 墙钟，删除“单调时钟”表述；检测跳变 >5s 降级。
- §6.3 删除 `applied_by` 列，只保留 §5.3 为唯一推导；安全跳过统计口径单列。
- 降级白名单补 `session_id` / `provider_id` / `requires`。
- `provider_id` 已知前缀与 `source` 矛盾才拒绝，未知前缀 WARN 放行。
- `max_red_hearts` 未知时不再触发“缺红心优先回血”。
- 新增 `VoteAggregator` 数据链；明确 Enricher 只影响插件侧 Provider，不写回 state/decision。
- 版本标识写清（protocol `1.0-draft.4`、architecture `v1.0-draft.4`）。

未采纳：
- Claude 建议把房间级池预取/水位写进 v1：**不采纳为 v1 承诺**，只写进已知取舍（§6.2 / protocol §11.1），理由见 §4.5。
- Claude 建议把 `rule:guard` 归 `provider`：不采纳；保留 `fallback` 但在统计口径里排除安全跳过（§5.3），避免改变“是否兜底”的既有定义。
- Claude 建议删掉 `source`/`fallback` 中冗余字段、只留 `applied_by`：不采纳；`source`/`fallback` 是生产端对决策本身的描述，`applied_by` 是消费端结果，二者职责不同，删掉会让 decision.json 无法独立表达来源。

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
- Claude：**StateEnricher 最假**（与 GPT 同向，但理由更狠：Map/Enemy 没有输入；连 item_pool/next_floor 的输出也只进插件 `enrichments`，`DecisionDoc` 无字段、mod 不可见），**EventSource 第二假**（`ProviderContext.votes` 的数据来源全文未定义，B 站弹幕投票链断头），Presenter “拆成两半”、DecisionProvider 也需改组装代码。
- 处理：三处都回写为“条件性可插拔”，但 **不合并成单一结论**：
  - EventSource 在 architecture §4.2 明确为“通知适配器，不是可靠事件总线”；
  - StateEnricher 在 §4.3 明确“只能看 state/trigger/外部静态数据；Map/Enemy 需 mod 先导出，否则是占位”，并补“输出只影响插件 Provider、不写回 state/decision”；
  - 新增 `VoteAggregator` 数据链接通 `custom → votes`；
  - 气泡在 §4.4 明确“固定在 mod 侧，插件换不了”。
- 结论：v1 没有“完全可插拔”的 EventSource/StateEnricher；DecisionProvider 与 voice/danmaku/overlay 是真扩展点，但加 provider 仍要改组装配置。

### 4.2 “第 3 天推倒重来”的三种诊断

- DeepSeek：**预取覆盖/多目标队列**（房间加载时抽取、多底座房，latest-wins 覆盖）。
- GPT：**刷新/缓存/消费契约**（R1/R2 身份、结果归属、消费失效）。
- Claude：**时序根因**——决策必须早于池抽取，而不做房间级池预取/水位，导致 `room_enter` 对本房间底座通常太晚；“第一次真机跑 Boss 奖励就会落 Morph → 闪烁 + 双重判定 → 重写生成链路”。
- 三者是同一块地基的三层：Claude 指“预取窗口不够”，DeepSeek 指“多目标没排队”，GPT 指“有窗口时身份/消费没闭合”。处理：
  - v1 先把 GPT 的契约闭合（§6.7 + 时序表），这是可实现的；
  - DeepSeek 的队列/池级预取写进 §11.1 已知取舍，列为 v2；
  - Claude 的“房间级池预取”只采纳为 **文档必须承认覆盖缺口 + 允许池级预取字段**，不写成 v1 承诺（见 §4.5）；
  - 不宣称“三个都解决了”；v1 仍不保证每个底座都由 agent 决定。

### 4.3 版本降级：拒绝信封 vs codec-first

- DeepSeek 倾向允许跨 major 的最小拒绝信封，避免 `version_major` 只留在日志。
- GPT 要求先统一 codec 选择与拒绝顺序，避免 §7.3/§7.4 自相矛盾；并容忍未知 `reason_code`。
- 处理：采纳 GPT 的 codec-first 与未知原因容忍；拒绝信封保持**可选**（§7.3）；`plugin_status.json` 由 Claude 补审后采纳为 **可选诊断**（A41），用于把 `version_major` 暴露给 mod/QA，而不是写跨 major decision。理由：跨 major 写 decision 仍可能被误读；状态文件只描述失败，风险低。

### 4.4 回执审计：discarded 字段 vs 回执完整性

- DeepSeek 希望 `applied.phase` 增加 `discarded`，让迟到丢弃可审计。
- GPT 要求把“实际生成原版道具、没有替换生效”写成完整回执，避免 `applied_by` 与 `provider_id` 冲突。
- 处理：采纳 GPT 的 §5.4 真值表（含 `rejected` / `none`）；不新增 `discarded` phase，迟到仍只进日志，写进 §11.2。理由：`applied.json` 是 latest-wins 单回执，新增 phase 仍会被后续回执覆盖，不能解决审计完整性；要审计得加独立日志/队列。
- Claude 的批评更直接：`applied_by` 在 §5.3/§6.2/§6.3 有三套口径，按 §6.3 实现的 mod 必被 §5.3 判 bug。处理：**删除 §6.3 的 `applied_by` 列**，只保留 §5.3 算法为唯一推导；`phase=rejected` 一律 `none`（§5.4 表同步）。这比“补一个 discarded”更根治。

### 4.5 房间级池预取：Claude 建议 vs v1 范围

- Claude 的 Q5 最小修改建议第 1 条：把“提前问一次”改成“换层 / `MC_POST_NEW_ROOM` 后对该房间所有可能生成的道具池做一次池级预取”，并把“不做水位”改成“不做 16 池目录，但允许 1 个房间级池预取”。
- DeepSeek 也要求覆盖多目标；但 t7 已把队列/池级预取列为 v2。**不采纳 Claude 的 v1 承诺**，理由：
  1. 房间生成/底座生成与 `MC_POST_NEW_ROOM` 的先后关系尚未实机验证（t2 只证明回调 62 在池抽取后、底座生成前，没有证明 `POST_NEW_ROOM` 早于本房间底座生成）；
  2. 加房间级池预取会改 mod 生成链路与插件调度，超出 t3/t4 当前范围，且没有真机数据证明收益；
  3. 未验证的时序写进 v1 会把“可能”包装成“保证”，比承认缺口更危险。
- 采纳的部分：protocol 允许池级预取（`pedestal_index=null` + `trigger.payload.pool` 必填），architecture §0.1/§7 明确承认 `room_enter` 通常太晚、首底座可能 nil/Morph；§11.1 明写“v1 不保证每个底座都由 agent 决定”。这是“承认问题”，不是“解决问题”。
- **注意**：Claude 的 Q5 以“Profile A 可写、实时 agent 可用”为前提；captain 在 t8 后续把默认改为 Profile B（实时 agent 需 `--luadebug` opt-in）。因此 Q5 是 **A 模式下的风险**，不是默认路径的风险；A 模式下仍需正视。

### 4.6 三方“同时成立”的 P0：回写后遗留的自相矛盾

Claude 对 `v1.0-draft.3` 抓到的三处 P0（`DecisionDoc` 缺 `features`/`requires`、时钟基准冲突、`applied_by` 三套口径）**不是与前两家的分歧**，而是 r1 回写留下的缺陷。处理：全部修复并升 `v1.0-draft.4`。这也说明“三方评审”不能只看三家意见的交集，还要看后审者对前次回写的回归检查。

### 4.7 `rule:guard` 是否算兜底

- Claude：`rule:guard` 的安全跳过被记成 `applied_by:"fallback"` 会抬高兜底率，建议归 `provider`。
- DeepSeek：指出 `applied_by` 的统计歧义；GPT：统计边界。
- 处理：**不改变 `applied_by` 定义**（安全跳过仍是非主路径 → `fallback`），改在统计口径上排除 `no_candidate`/`player_dead`，并把 `rule:guard` 单列（protocol §5.3）。理由：把 guard 归 `provider` 会让“provider”同时表示“主路径”和“什么都没做”，语义更差；统计问题应在统计层解决。

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
| A23 | DeepSeek | 跨 major 强制拒绝信封 | 不采纳（保持可选） | protocol §7.3（可选）、§11.5 |
| A24 | DeepSeek | v1 实时导出地图/敌人 | 不采纳（超出 t1/t3 范围） | protocol §11.6 |
| A25 | 两家 | 增加完整审计日志/可靠回执 | 不采纳（v1 用日志） | protocol §11.2 |
| A26 | Claude | 缺 `session_id` 导致事件重放/跨局缓存 | 采纳 | protocol §1.5/§2.1/§3.1/§4.1/§5.2/§6.7/§7.3、architecture §3.1、examples |
| A27 | Claude | 池级 `trigger.payload.pool` 只是 SHOULD | 采纳（改必填） | protocol §2.1 注 |
| A28 | Claude | `actual_item_id` 非必填却被 §5.4 依赖 | 采纳（改必填） | protocol §5.2 |
| A29 | Claude | `features` 与 `capabilities` 重复 | 采纳（删 capabilities） | protocol §2.1/§3.2、architecture §3.1、examples |
| A30 | Claude | `DecisionDoc` 缺 `features`/`requires`（P0） | 采纳 | architecture §3.1 |
| A31 | Claude | 时钟基准 §1.5 vs §6.1 矛盾（P0） | 采纳（统一 state.ts 墙钟） | protocol §1.5/§6.1 |
| A32 | Claude | `applied_by` 三套口径（P0） | 采纳（删 §6.3 列，§5.3 唯一） | protocol §5.3/§6.3 |
| A33 | Claude | 降级白名单缺 `requires`/`provider_id` | 采纳 | protocol §7.3.3 |
| A34 | Claude | 未知 `provider_id` 前缀被校验堵死 | 采纳（未知 WARN 放行） | protocol §3.5、architecture §3.1 |
| A35 | Claude | `max_red_hearts` 未知被当可回血 | 采纳（未知跳过 R3） | protocol §6.5 |
| A36 | Claude | votes 数据链断头 / Enricher 对 mod 不可见 | 采纳（VoteAggregator + 可见范围） | architecture §3.1/§4.2/§4.3 |
| A37 | Claude | 版本标识不清 / §0 与 §7.3 冲突 | 采纳 | protocol 头部/§0、architecture 头部、§7.3 |
| A38 | Claude | 房间级池预取进 v1 | 不采纳（v2；见 §4.5） | protocol §11.1、architecture §0.1 |
| A39 | Claude | `rule:guard` 归 `provider` | 不采纳（统计口径排除） | protocol §5.3/§11.2 |
| A40 | Claude | 删掉 `source`/`fallback` 冗余字段 | 不采纳（生产端/消费端职责不同） | protocol §0.1/§3.5 |
| A41 | Claude | `version_major` 永不出现在回执，失败不显式 | 采纳（可选 `plugin_status.json`） | protocol §1.11/§6.3/§7.3/§11.5、architecture §3.1 |

---

## 6. 不采纳与已知取舍

1. **v1 不做决策队列/池级预取**（A21）。一次一个生成目标、latest-wins 是刻意限制；多底座/房间加载时抽取覆盖有限。理由：队列会同时改 transport、mod 状态机、插件调度，超出 v1；写入 §11.1。
2. **不增加 `discarded` phase**（A22）。`applied.json` 是 latest-wins 单回执，新增 phase 也会被覆盖；迟到只进日志。要精确审计需独立日志/队列。
3. **不强制跨 major 拒绝信封**（A23）。跨 major 写 decision 仍可能被误读；采纳 Claude 的可选 `plugin_status.json`（A41）解释 `version_major`，mod 无决策时读它并写进 `applied.json`，避免“只在日志里”。
4. **v1 不实时导出地图/敌人**（A24）。Map/Enemy Enricher 先作为占位，等 mod 用可选 state 字段导出后再启用；当前不承诺“改核心？否”的实时能力。
5. **不做完整审计/可靠回执**（A25）。文件模式 event/applied 都是 latest-wins；精确统计需要 pipe/HTTP 队列或独立日志。
6. **不引入 `pending_targets` 字段**：同上，队列属 v2；v1 只保证单目标路径正确。
7. **不把房间级池预取写成 v1 承诺**（A38）。Claude 指出的覆盖缺口真实存在，但 `MC_POST_NEW_ROOM` 与本房间底座生成的先后未实机验证；加池预取会改 mod 生成链路，超出本轮范围。v1 只承认缺口、允许池级字段、首底座可能 nil/Morph（§4.5）。
8. **不把 `rule:guard` 归 `provider`**（A39）。安全跳过仍按 `fallback` 归类；“兜底率”统计时排除 `no_candidate`/`player_dead`，`rule:guard` 单列（protocol §5.3）。这样不改变“是否兜底”的既有定义，也避免 provider 同时表示“主路径”和“什么都没做”。
9. **不删 `source`/`fallback`**（A40）。`source`/`fallback` 是生产端对 decision 本身的描述，`applied_by` 是消费端对最终结果的分类；删掉会让 `decision.json` 无法独立表达来源，也会让“拒绝响应”失去分类依据。

---

## 7. 回写记录与版本

- **r1（t7，DeepSeek + GPT）**：protocol 新增 §6.7、§5.4、§11；architecture 加 Provider role、Enricher 边界、EventSource/气泡边界、统计边界、codec-first；版本 `1.0-draft.3` / `v1.0-draft.3`。
- **r2（t8，Claude 补审）**：
  - protocol：头部加显式 `文档版本: 1.0-draft.5`；新增必填 `session_id`（§1.5/§2.1/§3.1/§4.1/§5.2），事件去重与 §6.7 缓存键改为 `(session_id, …)`；`trigger.payload.pool` 改必填；`actual_item_id` 改必填；删除 `capabilities`、统一 `features`；`DecisionDoc` 补 `features`/`requires`（architecture）；统一时间基准为 `state.ts` 墙钟；§6.3 删除 `applied_by` 列，§5.3 唯一推导；降级白名单补 `session_id`/`provider_id`/`requires`；未知 provider 前缀 WARN 放行；`max_red_hearts` 未知跳过 R3；新增 `VoteAggregator`、Enricher 可见范围、可选 `plugin_status.json`；已知取舍补 A38–A41。
  - architecture：`StateDoc`/`DecisionDoc`/`AppliedDoc`/`GameEvent` 补 `sessionId`；`DecisionDoc` 补 `features`/`requires`；`FileEventSource` 按 `(sessionId,eventSeq)` 去重；新增 `VoteAggregator`；版本 `v1.0-draft.5`。
  - examples：三个文件补 `session_id`、删除 `capabilities`、保留 `reason_code`/`character_id`/`max_red_hearts`；时序仍为可复现的预取路径。
- **版本**：protocol `1.0-draft.5`；architecture `v1.0-draft.5`（`draft.4` 为 Claude 补审回写；`draft.5` 为 t8 期间 captain 追加的产品取舍，见下）。
- **t8 期间 captain 追加的产品取舍（不属于三家评审意见）**：
  1. **默认 Profile B**：mod 只读 decision，桥目录写入全在插件；不需要玩家改启动项，但也没有实时 state、实时 agent 不可用。
  2. **Profile A 可选、高风险**：需要 `--luadebug`；这不是“给本 mod 开一个开关”，而是 **给所有 mod 放开文件访问**；安装说明必须原样写。
  3. **Profile C 推迟到 v1.1+**：v1 不做；理由为类型受限、与存档机制冲突、审计困难。
  4. **目录统一 `mods/<mod名>/`**：游戏侧按游戏要求布局；`dsh/`、`python/`、`protocol/`、`docs/` 不变。
  5. **契约条件化**：任何地方不得假设 mod 能写盘；`state/event/applied` 仅 Profile A 由 mod 写。
- **三方齐全**：本文件 revision r2 覆盖 DeepSeek + GPT + Claude；但三家评审快照不同（前两家 draft.2，Claude draft.3），见头部说明。

---

## 8. 本次补审的模型、时间与证据

- **模型**：`claude-sonnet-5-5`（provider `ginka`）。t8 开始时（09:22）ginka `/v1/models` 已重新出现 `claude-sonnet-5-5`，16-token 测试返回 `HTTP 200` + `OK`，响应 `model` 字段为 `claude-sonnet-5-5`；没有退到 opus。
- **时间**：2026-11-07 09:22 前置验证；09:26–09:27 完整评审；输出 9940 B。
- **输入**：同一份提纲（五问 + Q6），文档全文 `v1.0-draft.3`（98976 B）。
- **证据**：tri-party §2.1 记录了 `/v1/models` 清单、16-token 测试的 `HTTP 200` 与 response id、完整评审的输出大小；t7 的 08:40–09:10 失败记录保留在 §2 的历史说明中（本轮未重复）。
- **未采信替代模型**：没有使用 opus/GPT/本地模型冒充 Claude；opus 只在 t7 作为“渠道是否恢复”的探测对象，未被当作评审。

## 9. 修订历史

| revision | 日期 | 内容 |
| --- | --- | --- |
| r1 | 2026-11-07 | DeepSeek + GPT 两节；Claude 待补；回写 protocol/architecture draft.3 |
| r2 | 2026-11-07 | t8 补跑 Claude（claude-sonnet-5-5）；三节齐全；冲突点/采纳清单扩展；Claude 回写 draft.4；随后 captain 产品取舍回写 draft.5 |
