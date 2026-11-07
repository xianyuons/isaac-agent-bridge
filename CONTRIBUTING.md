# 贡献指南（CONTRIBUTING）

本项目是 **mod（Lua/REPENTOGON）+ DSH 插件（ESM）+ 协议** 三端协作，任何一方单独改动都可能
让对端静默降级。提交前请先读 [docs/standards.md](docs/standards.md)、
[docs/protocol.md](docs/protocol.md) 与 [docs/lessons.md](docs/lessons.md)。

## 1. 目录与负责人

| 目录 | 内容 | 负责人 |
| --- | --- | --- |
| `docs/protocol.md`、`docs/architecture.md`、`protocol/examples/` | 契约与样例 | contract |
| `mods/isaac_agent/` | 游戏侧 Lua | mod-lua |
| `plugin/` | DSH 侧插件 | plugin-ts |
| `tests/`、`tools/mock_e2e.py`、README | 离线验证与文档 | qa |

- 只改自己负责的目录；跨目录改动（尤其协议、共享测试、README）**必须先取得负责人同意**，
  并在任务单里写明范围。
- **一个任务一个独立 worktree**（`E:\Yuki\工作\isaac-agent-<任务号>`），不要和别人共用工作树；
  提交前 `git status` 确认没有把别人的未提交改动卷进来。

## 2. 分支、提交与合并

- 分支：`agent/<任务号>-<主题>`，例如 `agent/t6-mock-docs`。
- 提交信息：`类型(scope): 描述`，类型用 `feat` / `fix` / `test` / `docs` / `refactor` / `chore`；
  scope 用 `lua` / `plugin` / `protocol` / `qa` / `docs`。例如：
  `fix(lua): 池成员 API 返回空集时回退全表候选`。
- **禁止强推共享分支**（`main`、已发布的任务分支）；需要改写历史时另开分支并说明原因。
- 合并顺序：先协议/文档，再 mod，再插件，最后集成与 QA。合并冲突时停止覆盖，由相关负责人
  确认保留方案，合并后重跑全部离线测试。
- 提交里不得包含密钥、token、二进制产物、临时文件或别人的产物。

## 3. 协议变更流程（强制）

协议是两端唯一的事实来源。**任何字段/语义/默认值/必填性/动作白名单的变化都算协议变更**，
必须走完下面六步，不允许"先改实现，文档回头补"。

### 第 1 步：提交提案（字段差异表）

在 PR/任务单里写清：

| 项目 | 内容 |
| --- | --- |
| 变更字段 | 文档 + 路径，例如 `state.player.max_red_hearts` |
| 现状 → 目标 | 类型、必填性、取值范围、默认值 |
| 兼容性 | 旧读者会怎样；旧写者会怎样 |
| 迁移方案 | 旧数据/旧版本如何降级；是否需要双写/兼容 reader |
| 影响面 | state / decision / event / applied 哪几份文档；mod / 插件 / 表现层 |
| 失败语义 | 新增或复用的 `error_code` / `reason_code` |

### 第 2 步：定版本策略

按 `docs/protocol.md` §7：

- **MAJOR**：删字段、改语义/类型/必填性、改动作语义 → 必须提供 codec 或明确拒绝策略。
- **MINOR**：只允许**可选**字段、可选能力、可选动作；不得新增必填字段。
- **PATCH**：措辞、示例、注释，不影响线上格式。

新行为必须由能力字符串（`features` / `requires`）门控，禁止用"版本号 ≥ x"隐式开启。

### 第 3 步：三端批准

- contract：确认协议自洽、版本与迁移方案成立；
- mod-lua：确认游戏侧能实现、回调时序不受影响；
- plugin-ts：确认插件能实现、超时/兜底路径不变；
- qa：确认契约测试与 mock 场景可覆盖（新增失败路径必须补测试）。

至少一名**非作者**评审通过后才能合并；作者不能批准自己的实现。

### 第 4 步：同批更新（缺一不可）

1. `docs/protocol.md` 对应章节 + `## 12. 变更记录` 加一行；
2. `protocol/examples/` 至少一份样例同步（字段、`ts` 固定值、期望 `applied_by`）；
3. mod 与插件两侧实现（先 codec/校验，再行为）；
4. 离线测试：
   - `python tests/run_lua_test.py`（Lua 5.4）与 `ISAAC_AGENT_LUA=53 python tests/run_lua_test.py`；
   - `python tools/mock_e2e.py`（四种场景）；
   - 插件侧 68 项离线断言（临时 harness，见任务记录）；
5. 安装/配置若变化，同步 README（英文 + 中文两段）。

### 第 5 步：验证失败路径

协议变更至少覆盖：坏 JSON、缺字段（信封 vs body 两类）、非法 id、超时/迟到、版本 major
不匹配、写盘失败。只测成功路径的 PR 不予合并。

### 第 6 步：合并与发布

- 按第 2 节的顺序合并；合并后在 `main` 上重跑上述测试；
- 发布说明写清：协议版本、兼容范围、已知取舍（协议 §11）、是否需要用户改启动参数。

## 4. 常见扩展怎么做

| 想加什么 | 是否需要改协议 | 做法 |
| --- | --- | --- |
| 新的 `reason_code` | 否（minor 容忍） | 加到 §3.6 注册表；旧读者保留原值并按 `error_code` 归类，不得整份拒绝 |
| 新的能力字符串 | 是（可选能力，minor） | 放进 `features`；硬依赖放 `requires`，对端不认识必须拒绝（`version_minor_feature`） |
| 新的 `action` | 是（minor + 白名单） | 先登记能力表与协议，再在两端实现；v1 只有 `skip`，`reroll` 仅限非回调 62 场景 |
| 新的 `event.type` / `custom` | 通常否 | `custom` 走扩展字段；正式事件类型加协议表 + mod 侧产生点 + 样例 |
| 新的 DecisionProvider（观众/预置/离线模型） | 通常否 | `source` 仍为 `rule`，渠道写 `provider_id`（`viewer:*` / `preset:*`）；前缀必须与 `source` 一致 |
| 新的 StateEnricher | 可能 | 只读已有 `state` 字段时无需改协议；需要游戏导出新数据时先扩展 state（minor）并写明 `requires` |
| 新的 Presenter（气泡/语音/OBS） | 否 | 只消费 `decision.json` / `applied.json`，不得改变决策语义 |

扩展点的边界见 [docs/architecture.md](docs/architecture.md)；任何"看着能插但需要新增必填
字段"的方案都按 v2 处理，不进 minor。

## 5. 完成定义（DoD）

一个 PR 只有同时满足以下条件才算完成：

- [ ] 范围与任务单一致，没有越界文件、密钥、二进制或临时文件；
- [ ] 正常路径 + 失败路径测试通过，命令与退出码记录在任务里；
- [ ] 协议/样例/README 已同步（若涉及）；
- [ ] 错误都归到五类错误码（`IO` / `TIMEOUT` / `VALIDATION` / `MODEL` / `INTERNAL`）；
- [ ] 日志不含 key、账号、完整绝对路径；
- [ ] 非作者评审通过；
- [ ] 合并后在 `main` 上重跑测试仍全绿。

## 6. 失败了怎么报

测试失败、超时或无法完成时，**不要标完成**。提交一份包含以下内容的报告并标阻塞：

- 任务号与提交号；
- 复现命令、预期结果、实际结果；
- 关键日志（脱敏）；
- 已改文件与未改文件；
- 阻塞原因与下一步。

## 7. 红线

- 禁止未经批准新增依赖；
- 禁止删除或跳过测试、把失败测试改成 `skip`；
- 禁止提交密钥/token/账号信息或二进制产物；
- 禁止强推共享分支、绕过评审；
- 禁止把模型/观众输出当代码、路径或系统指令执行；
- 禁止让游戏侧联网或读取 API key。
