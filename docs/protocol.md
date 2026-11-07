# 桥接协议 v1.0（state / decision / event / applied）

> 状态：草案（draft）。实现方：Lua mod（REPENTOGON）与 DSH 插件（TypeScript）。
> 文档版本：`1.0-draft.5`（2026-11-07，t8 Claude 补审 + captain 产品取舍回写）。协议版本字段仍为 `1.0`；版本历史见 §12。
> 负责人：contract。配套文档：[架构](architecture.md)、[代码规范](standards.md)。
> 关键词：**必须**（MUST）、**不得**（MUST NOT）、**应该**（SHOULD）、**可以**（MAY）。

---

## 0. 结论先行

1. **四个文档、一个方向、一个关联键**：mod 产出 `state.json` / `event.json` / `applied.json`，插件产出 `decision.json`；请求与决策用 `request_id` 关联，逐条对账再用 `decision_id`。
2. **1500ms 是决策有效期与超时判定，不是 mod 的阻塞时长。** mod 永远不等待、不睡眠、不在游戏回调里做磁盘 I/O；它在道具生成前把决策预取到内存，`MC_PRE_GET_COLLECTIBLE`（回调 62，池抽取/底座生成前）**当帧**读内存并返回 id。
3. **决策只在候选池内生效**：agent/观众/规则都不得凭 id 凭空生成候选池之外的道具；非法 id 一律拒绝并兜底。
4. **失败必须显式**：任何失败都归到五类错误码之一（`IO` / `TIMEOUT` / `VALIDATION` / `MODEL` / `INTERNAL`），并同时给出更细的 `reason_code`；没有“静默默认”。
5. **“这次是 agent 还是兜底”只看一个字段**：`applied.json.applied_by`（`llm` / `provider` / `fallback` / `none`），不靠理由是否为空反推。
6. **对端比我新时必须保守**：major 不匹配且没有兼容 codec → 拒绝解析并走本地兜底；有兼容 codec 则按 §7.3 降级；minor 更新 → 忽略未知字段，只有出现在 `requires` 里的未知能力才拒绝。
7. **默认 Profile B，A 可选，C 推迟到 v1.1+。** 默认不要求玩家改启动项：mod 只读 `decision.json`，桥目录写入全在插件；代价是没有实时 state、实时 agent 不可用。实时 agent 需要 `--luadebug` 启用 Profile A——这会 **给所有 mod 放开文件访问**，不是单 mod 开关。SaveData 中继（Profile C）v1 不做。见 §1.4。

### 0.1 命名对照

| 任务书 / 参考实现 | 本协议 | 说明 |
| --- | --- | --- |
| `agent`（任务书里的决策来源） | `source: "llm"` | 协议统一用 `llm`；`agent` 仅作为插件内部类名保留 |
| `viewer`（观众投票） | `source: "rule"` + `provider_id: "viewer:<渠道>"` | `source` 固定二值，观众票数不污染“llm 还是兜底”的判定；细节见 §3.5 |
| `preSet` / 预置策略 | `source: "rule"` + `provider_id: "preset:<名字>"` | 预置策略是确定性规则，不是模型 |
| `decisionId` | `decision_id` | 每条决策唯一，用于逐条对账、防串 |
| `genLevelKey` | `gen_level_key` | 区分生成层（层/房间/底座/候选签名），防止拿上一层的决策用在这一层 |
| `valid=false` + `reasonCode` | `valid: false` + `reason_code` | 拒绝也是一份合法决策文档，不靠“choice 为空”表达 |
| `source` 由理由是否为空推断 | 禁止 | 来源永远显式写在 `source` / `provider_id` / `fallback` |

**为什么 `source` 只保留两值、把 viewer/preset 放进 `provider_id`（2026-11-07 与 captain 定稿）**：

- `source` 回答的是“这次决策是**模型产生**还是**非模型产生**”——这是**可靠性维度**；以后加十个 provider，也只有这两种可靠性来源。“非模型”不等于“兜底”：主路径规则/预置/观众都是 `rule + fallback:false`。
- `provider_id` 回答的是“谁给的”——这是**来源维度**，可以无限扩：`viewer:bilibili`、`preset:scripted`、`llm:local_small`。
- 两维分开，才能保住“每次抽取恰好落一个分类”的不变量；否则每加一个 provider 就要动 `source` 枚举，历史 `applied.json` 的统计口径全部作废。
- **误用警告**：实现方 **不得** 用 `provider_id` 判断“是否兜底”。兜底只看 `fallback` / `applied_by`；`provider_id` 只做来源标注与展示。

### 0.2 English Summary (protocol v1.0-draft.3)

This document defines the local file bridge between a REPENTOGON Lua mod (game side) and a
DSH plugin (agent side) for *The Binding of Isaac: Repentance+*. The game only describes
its situation; the agent only chooses from the game's candidate pool. Neither side may
invent state or bypass the contract.

**Documents and keys.** Four UTF-8, BOM-less, strict-JSON files live in one bridge
directory (default `%LOCALAPPDATA%\IsaacAgent`): `state.json` (mod → plugin), `event.json`
(mod → consumers, latest-wins notifications), `applied.json` (mod → consumers, the final
outcome) and `decision.json` (plugin → mod). `request_id` correlates a state with its
decision; `decision_id` identifies each decision for audit; `gen_level_key` pins both to one
generation context so a stale room/floor choice can never be reused.

**Timing.** `validity_ms` (default 1500; 5000–10000 for boss-reward prefetch) is the
decision's freshness window, *not* a blocking wait. The mod never sleeps or reads disk
inside a game callback. `MC_PRE_GET_COLLECTIBLE` (callback 62, after pool selection and
before the pedestal entity exists) must return in the same frame from memory: it either
returns a still-eligible decision's `item_id` or applies the deterministic local rule.

**Decision semantics.** A decision is executable only when `valid:true` and either
`source:"llm"` with `fallback:false,error_code:null`, or `source:"rule"` with
`fallback:true` and an error code (or a safe skip: `no_candidate` / `player_dead`).
`valid:false` is a refusal document: the mod must not execute its `skip`; it runs local
rules instead. `source` is exactly `llm` or `rule`; viewer votes and preset policies are
`rule` with a `provider_id` prefix (`viewer:*`, `preset:*`). Prefix/source mismatches are
rejected. Five error classes only: `IO`, `TIMEOUT`, `VALIDATION`, `MODEL`, `INTERNAL`, each
with a registered `reason_code`; unknown reason codes are tolerated rather than rejected.

**Fallback.** Every failure maps to exactly one outcome and leaves explicit evidence:
a fallback decision, an `applied.json` receipt (`applied_by`: `llm` / `provider` /
`fallback` / `none`), a readable reason, and an on-screen bubble. The local rule v1 is
shared by both ends: dead → skip; empty pool → skip; zero red hearts with a heal candidate →
heal; no damage item and a damage candidate → damage; otherwise the first candidate by
`pedestal_index`, then array order, then `item_id`. Silence is a protocol violation.

**Refresh and consumption.** Several requests (same `gen_level_key`, new `request_id`) may
be issued while waiting for generation (§6.7). A result computed for R1 may be published
against the newest request R2, but always with a new `decision_id`; if the situation
fingerprint changed, it must be recomputed. One generation consumes exactly one choice;
afterwards every decision for that key is void. Late decisions are dropped, never applied.

**Versioning.** `MAJOR.MINOR[.PATCH]`; major changes require a codec (current major or a
retained N−1 reader) or an explicit refusal, and a refusal must never guess identity. Minor
changes may only add optional fields/capabilities; behaviour is gated by `features` /
`requires`, never by version comparison. Both ends must ignore unknown fields.

**Security.** No network access from the mod; no API key in the game, bridge files, logs or
`reason` text (keys stay in DSH). Only local JSON in the bridge directory is read or
written; path traversal, symlinks and relative paths are rejected. Model output is data,
never code or a path; no input injection or memory editing. `reroll` is not allowed inside
callback 62.

**Out of scope in v1.** No decision queue (one active generation target, latest-wins), no
complete audit log (`applied.json` is the last receipt), no reliable event bus (file events
may be lost), no real-time agent in a read-only profile, and no map/enemy export. See §11
for the full list of known trade-offs and §10 for byte-stable examples.

---

## 1. 通用约定

### 1.1 编码与 JSON

- 文件编码 **必须** 是 UTF-8、**无 BOM**；**必须** 是严格 JSON：无注释、无尾逗号、无 `NaN` / `Infinity`。
- 所有文档根节点 **必须** 是对象；字段名 **必须** 用 `snake_case`。
- 读者 **必须** 忽略未知字段（前向兼容），**不得** 因为出现未知字段而拒绝整份文档。
- 写出方 **应该** 输出紧凑 JSON；**不得** 输出非整数形式的整数（`4.0`、`4e0` 不接受；解析方可以宽容，写出方必须规范）。
- 所有长度单位：字符数按 Unicode code point 计，字节数按 UTF-8 计。

### 1.2 目录与文件

默认桥目录（下称 `<bridge>`）：

```
%LOCALAPPDATA%\IsaacAgent\
├─ state.json      # Profile A: mod 写；Profile B: 不存在（不导出）
├─ event.json      # Profile A: mod 写；Profile B: 不存在
├─ applied.json    # Profile A: mod 写；Profile B: 不存在
├─ decision.json   # 插件写，mod 读（所有 Profile）
├─ plugin_status.json # 插件写，mod/QA 读（可选诊断，见 §1.11）
└─ bridge.lock     # 插件实例锁（插件写，防多写者，见 §1.10）
```

- 文件集合 **不得** 由模型或远端输入决定；路径 **不得** 接受模型输出。
- 测试与离线模拟 **可以** 用环境变量覆盖桥目录（`ISAAC_AGENT_DIR`），但插件 **必须** 校验：绝对路径、规范化后仍位于白名单根内、父目录 realpath 在白名单内、不是符号链接/junction 指向别处。校验失败 → `VALIDATION` / `io_error`，拒绝读写。
- `<bridge>` 由 **插件** 创建（Profile B 默认也由插件写）；mod 只在 Profile A 的写探针时尝试创建/写入。mod 不得假设目录可写。

### 1.3 原子写

每个文件同一时刻 **只允许一个写者**（见 §1.4）。写入流程：

1. 在同目录写唯一临时文件 `<name>.json.tmp.<pid>.<nonce>`；
2. `flush` 并 `close`；
3. 原子替换目标文件（POSIX `rename`；Node `fs.rename`；Lua 在 Windows 上 `os.rename` 对已存在目标可能失败，此时允许 `remove(dest)` 后 `rename`）；
4. 失败时 **必须** 保留旧文件、清理临时文件，并以 `IO` / `io_error` 记录；**不得** 写一半就发布。

读者 **必须** 把“目标文件短暂不存在”当作可重试状态，而不是空状态：先重试（指数退避 ≤ 200ms），超过窗口仍无文件才按缺失处理。读者 **不得** 读取 `*.tmp.*`。

### 1.4 谁写谁读（默认 B；A 可选；C 推迟到 v1.1+）

> **硬约束：任何实现都不得假设 mod 能写盘。** 下面的“写者”是条件式的；只有 Profile A 才由 mod 写 `state/event/applied`。Profile B 没有这三份文件，Profile C 在 v1 不实现。

“内容作者”与“文件写者”分开定义：`state/event/applied` 的内容 **只能由 mod 生成**；中继形态下可以由插件侧进程落盘，但 **不得** 增删改内容。

| 文件 | 内容作者 | Profile B（默认）写者 | Profile A（可选）写者 | Profile C（v1.1+）写者 |
| --- | --- | --- | --- | --- |
| `state.json` | mod | —（不导出） | mod | 插件侧 feeder（逐字节中继） |
| `event.json` | mod | — | mod | 插件侧 feeder |
| `applied.json` | mod | — | mod | 插件侧 feeder |
| `decision.json` | 插件 | **插件** | 插件 | 插件（v1.1+） |
| `plugin_status.json` | 插件 | 插件 | 插件 | 插件 |
| `bridge.lock` | 插件 | 插件 | 插件 | 插件 |

**Profile B — 单向只读（默认，产品形态）**
- 玩家 **不需要改启动项**；mod 只读 `decision.json`，桥目录所有写入由插件完成。
- **没有实时 state 导出**，所以实时 agent 不可用；只能：
  - 使用 **预置策略**（用户在 DSH 侧预先算好/写好决策），或
  - 纯本地规则（`source: "rule"`，气泡提示“桥接不可用”，`error_code: "IO"` / `bridge_unavailable`），或
  - 由外部把完整 StateDoc 交给插件（不是从游戏内实时导出）。
- Profile B **不得** 假装 agent 可用，也 **不得** 无限等待；生成时没有决策就本地兜底。

**Profile A — 双向文件桥（可选，高风险）**
- 前提：玩家以 **`--luadebug`** 启动，让 mod 能读写 `<bridge>`；启动探针通过后才启用（见 §1.8）。
- **这不是“给本 mod 开一个开关”**：`--luadebug` 会 **给所有 mod 放开文件访问**；必须原样告知玩家，不能包装成普通功能开关。
- 只有 A 才由 mod 写 `state/event/applied`；这是唯一能实时跑 agent 的形态。

**Profile C — SaveData 中继（推迟到 v1.1+，v1 不做）**
- 不在 v1 实现。把协议塞进 `Mod:SaveData` 会遇到数据类型受限、与存档写入/回滚机制冲突、审计困难；v1.1+ 再评估。
- 若未来实现：mod 把文档内容写进存档数据，插件侧 feeder 读取并原子落盘；feeder 缺失/存档不可读时等同 B。
- v1 的文档/实现都 **不得** 声称支持 C，也不得把 C 作为默认或保底路径。

> 共同不变量：**`decision.json` 是唯一必需的方向**；mod 永远不阻塞；Profile A 的失败显式落 `applied.json`，Profile B 用气泡 + `Isaac.DebugString` + 插件 `plugin_status.json`（见 §1.9/§1.11）。

### 1.5 身份、时间与有效期

- `request_id`：`^[A-Za-z0-9_-]{8,64}$`，mod 生成。格式建议 `r-<boot4>-<counter6>`；`boot4` 每次进程启动随机，避免重启后与旧决策撞号。**刷新请求也生成新 `request_id`**。
- `session_id`：`^[A-Za-z0-9_-]{8,64}$`，mod 每次启动/读档新生成，同一局内稳定。**必须**出现在 state / decision / event / applied 四类文档；decision 必须回显请求的 `session_id`，不一致 mod 直接拒绝（`session_mismatch`）。事件去重、决策缓存、跨局隔离都以 `(session_id, …)` 为键，不能只看 `event_seq` / `gen_level_key`。
- `decision_id`：`^[A-Za-z0-9_-]{8,64}$`，插件生成。同一请求即使重发决策，也 **必须** 是不同的 `decision_id`。
- `gen_level_key`：`^[A-Za-z0-9_.:-]{1,128}$`，mod 生成，标识“这一层生成上下文”。至少覆盖：层数、房间（或道具池）、目标底座（池级预取时为目标池）、候选池内容签名；候选池重掷 **必须** 变化。示例：`f2:r84:treasure:p0:9c1e`。
- `ts`：整数 Unix epoch 毫秒（UTC），是**唯一时间基准**。mod 与插件 **必须** 同机运行；有效期/迟到判定统一用 `state.ts` 与本地墙钟接收时刻，**不比较** `decision.ts`（写盘/排队延迟不计入对端时钟）。检测到墙钟跳变超过 5 秒 → 记 `INTERNAL` / `internal_error` 并降级，**不得** 静默继续。跨机部署不在 v1 支持范围。
- `validity_ms`：整数，`300..10000`，默认 `1500`。含义：**从该 `request_id` 发出时刻起，到实际生成使用为止的窗口**。判定分两步且两步都必须满足：① 决策必须在窗口内被接收；② 生成时 `now - request_sent_at <= validity_ms`。任一不满足即过期（`TIMEOUT` / `late` / `no_fresh_decision`）。它不是 mod 的阻塞时长。
- 插件计算预算时 **必须** 从 `state.ts` 起算：`remaining = state.ts + validity_ms - now - write_margin`（同机时钟），轮询与排队延迟因此计入；不得只按“插件收到 state 的时刻”重新给满 `validity_ms`。
- mod **应该** 在等待生成/等待决策期间以 `validity_ms / 2` 为间隔刷新请求（同一 `gen_level_key`，新 `request_id`），使慢响应也有新鲜决策；插件 **应该** 对同一 `gen_level_key` 的在途 agent 调用去重（见架构文档）。
- 同一请求收到多条有效决策时，mod 取 **接收时间最新** 的一条；旧决策被新决策覆盖。生成发生后到达的一律丢弃。

### 1.6 大小与数量上限

| 对象 | 上限 |
| --- | --- |
| `state.json` | 256 KiB |
| `decision.json` | 8 KiB |
| `event.json` | 16 KiB |
| `applied.json` | 16 KiB |
| `plugin_status.json` | 8 KiB |
| `reason` | 280 字符 / 1024 字节 |
| `items` | 1024 条 |
| `candidates` | 64 条 |
| `features` / `requires` | 各 32 条，单条 64 字符 |
| `enrichments` | 16 个键，单值 16 KiB，总计 64 KiB |
| `event.payload` | 16 KiB；`custom.payload.payload` 8 KiB |

超限即 `VALIDATION` / `out_of_range`，不得截断后继续（截断会让两端对同一请求理解不一致）。

### 1.7 扩展字段

- 协议字段之外的厂商扩展 **必须** 以 `x_` 前缀命名（顶层或对象内），值可以是任意 JSON，但受 §1.6 总量限制。
- 读者 **必须** 忽略所有 `x_` 字段；写出方 **不得** 让 `x_` 字段改变必需字段的含义。
- 正式的新增语义走 minor（§7），不得长期依赖 `x_`。

### 1.8 启动能力探针（Profile 判定）

**默认目标是 Profile B，不是 A。** mod 在 `on_game_start` 做一次只读探测；只有在玩家已用 `--luadebug` 启动时，写探针才可能成功：

1. 尝试读 `decision.json`（不存在视为“待创建”）；读不到 → 无桥接，纯本地规则。
2. 尝试创建 `<bridge>` 并写 `<bridge>\.probe.tmp`，关闭，重命名为 `.probe`，读回比对，最后删除。
3. 写探针失败是 **Profile B 的预期路径**，不记致命错误；仅记录 `transport:file_write=false`，继续以 B 运行。
4. 写 + 读都通过 → **Profile A**（说明启动项已放开文件权限）；结果随 `state.features` 上报。
5. 映射：
   - 读写都通过 → **Profile A**（可选、高风险）；
   - 只有读通过 → **Profile B**（默认；本地规则/预置策略；实时 agent 不可用）；
   - 读也不通过 → 无桥接，纯本地规则，气泡明确提示。

探针 **不得** 在帧回调中执行，只在启动/读档完成后一次；**不得** 主动提示/诱导玩家开 `--luadebug`，只能在其已开启时识别 A。

### 1.9 Profile B 的失败上报

Profile B 中 mod 写不了 `applied.json`，失败必须仍可见：

- 屏幕气泡显示 `[本地规则] <reason>`；
- 游戏日志 `Isaac.DebugString` 输出一行结构化日志（含 `request_id`（若有）、`error_code`、`reason_code`）；
- 插件 **应该** 在 `plugin_status.json` 标记 `degraded` 并给出原因（B 下 mod 不写盘，但插件可写）；
- 若后来写能力恢复，**不得** 补写伪造的 `applied.json`。

### 1.10 单写者锁

- 插件启动时 **必须** 以独占方式创建 `<bridge>/bridge.lock`，内容为 `{pid, started_at, plugin_version}`；创建失败说明已有实例。
- 锁存在时，插件 **必须** 检查持有进程是否仍存活（Windows 用 pid + 启动时间/句柄探测，不允许只看文件存在）；存活 → 拒绝启动并报 `IO` / `io_error`；僵死 → 允许清理后重建。
- mod **不得** 写/删 `bridge.lock`；它只读 `decision.json`。
- 崩溃后残留锁 **不得** 导致永久不可用：清理前必须确认旧进程已退出。

### 1.11 插件状态文件（可选诊断）

`<bridge>/plugin_status.json` 由插件原子写，用来把“插件为什么不给决策”暴露给 mod/QA。**不替代** `applied.json`，也不承载密钥。

```json
{
  "protocol_version": "1.0",
  "plugin_version": "0.1.0",
  "ts": 1793982600000,
  "status": "ready",
  "error_code": null,
  "reason_code": null,
  "detail": null
}
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `protocol_version` | string | 是 | 插件支持的协议版本 |
| `plugin_version` | string | 是 | 插件自身版本，仅诊断 |
| `ts` | integer | 是 | 写入时刻 |
| `status` | string | 是 | `ready` / `degraded` / `refused` |
| `error_code` | string \| null | 是 | 五类之一或 `null` |
| `reason_code` | string \| null | 是 | §3.6 注册表 |
| `detail` | string \| null | 否 | ≤280 字符，单行；不得含密钥/路径 |

- 插件启动、进入降级、拒绝解析（如 `version_major`）时 **应该** 更新；恢复 `ready` 时写回。
- mod 在“无决策可用”时 **应该** 读一次该文件：若 `status` 为 `refused`/`degraded`，把其 `error_code` / `reason_code` 写进 `applied.json`；读不到则仍记 `TIMEOUT` / `no_fresh_decision`。
- 该文件 **不得** 被当作决策来源；它只解释失败，不改变选择。

---

## 2. `state.json`

### 2.1 根信封

```json
{
  "protocol_version": "1.0",
  "session_id": "s-2f9a-0001",
  "request_id": "r-7f3a-000042",
  "gen_level_key": "f2:r84:treasure:p0:9c1e",
  "ts": 1793982600000,
  "validity_ms": 1500,
  "error_code": null,
  "reason_code": null,
  "features": ["transport:file_write", "hook:pre_get_collectible", "apply:prefetch", "action:reroll"],
  "requires": [],
  "trigger": {
    "type": "pedestal_spawn",
    "event_seq": 42,
    "pedestal_index": 0,
    "payload": { "item_id": 4 }
  },
  "state": { "...": "见 2.2–2.8" }
}
```

| 字段 | 类型 | 必填 | 取值范围 / 说明 |
| --- | --- | --- | --- |
| `protocol_version` | string | 是 | `^\d+\.\d+(\.\d+)?$`，本版 major 必须为 `1` |
| `session_id` | string | 是 | `^[A-Za-z0-9_-]{8,64}$`，mod 每次启动/读档新生成，同局稳定 |
| `request_id` | string | 是 | `^[A-Za-z0-9_-]{8,64}$`，每次写 state 都新生成 |
| `gen_level_key` | string | 是 | `^[A-Za-z0-9_.:-]{1,128}$`，同一生成上下文内稳定 |
| `ts` | integer | 是 | epoch ms，`0..9007199254740991` |
| `validity_ms` | integer | 是 | `300..10000`，默认 1500 |
| `error_code` | string \| null | 是 | 五类之一或 `null`；非 null 表示“局面降级”，见 §6.4 |
| `reason_code` | string \| null | 是 | §3.6 注册表；有 `error_code` 时 **应该** 给出具体原因，无错误为 `null` |
| `features` | string[] | 否 | 本端支持能力（协议/传输/钩子/动作），如 `transport:file_write`、`hook:pre_get_collectible`、`apply:prefetch`、`action:reroll`；用于可选能力门控与展示，硬依赖写 `requires` |
| `requires` | string[] | 否 | 本端要求对端具备的能力；对端缺任意一项 → 拒绝并兜底 |
| `trigger.type` | string | 是 | `pedestal_spawn` / `room_enter` / `boss_approach` / `reroll` / `custom` |
| `trigger.event_seq` | integer | 否 | `>= 1`，对应 `event.json.event_seq`；刷新请求沿用原事件序号 |
| `trigger.pedestal_index` | integer \| null | 是 | `0..63`；已知目标底座时填；**池级预取**（底座尚未存在）为 `null`。`room_enter` / `boss_approach` 通常为 `null`，除非已知奖励槽 |
| `trigger.payload` | object | 否 | ≤ 4 KiB；`custom` 必填 `{name, payload}`，见 §4.2 |
| `state` | object | 是 | 见 §2.2–§2.8 |

> **一次请求只服务一个生成目标（一个底座，或一个道具池）。** 同一房间多个底座时，mod 按 `pedestal_index` 串行发起请求（`state.json` latest-wins，同一时刻只有一个活跃请求），每个请求各自有 `request_id` / `decision_id`；`candidates` 只包含该目标（该底座或该道具池）的候选，不得混入别的池。池级预取时 `trigger.pedestal_index` 与所有 `candidates[].pedestal_index` 都为 `null`，且 `trigger.payload.pool` **必须** 写明道具池标识（如 `treasure` / `boss` / `devil`）；插件据此校验候选池一致性。

### 2.2 `state.player`

| 字段 | 类型 | 必填 | 取值范围 / 说明 |
| --- | --- | --- | --- |
| `red_hearts` | integer | 是 | `0..24`，单位 **半颗红心**（2 = 1 整颗） |
| `soul_hearts` | integer | 是 | `0..24`，单位 **半颗魂心**；黑心暂并入此值，v1 不单列 |
| `max_red_hearts` | integer | 否 | `0..24`，红心容器上限（半颗为单位）；缺省表示未知。为 `0` 表示该角色无法靠红心回复（Keeper/Blue Baby 等），规则不得把“红心为 0”当“缺红心” |
| `character_id` | integer | 否 | `0..255`，Isaac `PlayerType`；缺省表示未知。用于角色相关判断（Keeper/堕化/无红心角色） |
| `is_dead` | boolean | 否 | 默认 `false`；为 `true` 时只允许 `skip` |

> 不使用“红心容器数”字段，避免“半心/整颗”两种单位混用。`red_hearts` 超过当前红心容器数的部分（如有 mod）按实际值导出，不超过 24。

### 2.3 `state.items`（已持有的道具）

数组，元素：

| 字段 | 类型 | 必填 | 取值范围 / 说明 |
| --- | --- | --- | --- |
| `id` | integer | 是 | `1..2147483647`（原版 1..732；mod 道具以实际 `CollectibleType` 为准） |
| `name` | string \| null | 是 | `1..128` 字符；未知/无本地化名称时为 `null`，**不得** 空串 |
| `tags` | string[] | 否 | 见 §2.6 的标签表；`[]` 或缺省表示未分类 |
| `count` | integer | 否 | `1..999`，堆叠数量；缺省 `1` |

### 2.4 `state.room`

| 字段 | 类型 | 必填 | 取值范围 / 说明 |
| --- | --- | --- | --- |
| `type` | string | 是 | 枚举见下 |
| `is_boss_room` | boolean | 是 | 是否 Boss 房（Boss 标记） |
| `grid_index` | integer \| null | 否 | `0..168`（13×13 网格索引） |
| `is_clear` | boolean | 否 | 房间是否已清空 |

`type` 枚举（映射 Isaac `RoomType`，未知值映射 `unknown`，不得拒绝）：
`null`、`default`、`boss`、`shop`、`treasure`、`secret`、`super_secret`、`arcade`、`curse`、`challenge`、`library`、`sacrifice`、`devil`、`angel`、`dungeon`、`boss_rush`、`isaac`、`barren`、`chest`、`dice`、`black_market`、`planetarium`、`teleporter`、`teleporter_exit`、`secret_exit`、`blue`、`ultra_secret`、`ultra_secret_exit`、`deathmatch`、`home`、`boss_exit`、`unknown`。

### 2.5 `state.floor` 与 `state.boss`

| 字段 | 类型 | 必填 | 取值范围 / 说明 |
| --- | --- | --- | --- |
| `floor` | integer | 是 | `0..63`；`0` = 未知，原版 `1..13` |
| `boss` | object \| null | 是 | 无 Boss 时为 `null` |
| `boss.id` | integer | 是 | `>= 1`，Boss NPC id |
| `boss.name` | string \| null | 是 | `1..128` 字符或 `null` |
| `boss.hp` | integer | 否 | `>= 0`；未知时省略 |
| `boss.max_hp` | integer | 否 | `>= 1`；未知时省略 |

### 2.6 `state.candidates`（候选池）

数组，元素：

| 字段 | 类型 | 必填 | 取值范围 / 说明 |
| --- | --- | --- | --- |
| `pedestal_index` | integer \| null | 是 | `0..63` 或 `null`；非 `null` 时必须等于 `trigger.pedestal_index`；池级预取为 `null` |
| `item_id` | integer | 是 | `1..2147483647`；决策只能从这里选 |
| `name` | string \| null | 是 | `1..128` 字符或 `null` |
| `tags` | string[] | 否 | 标签表见下 |
| `quality` | integer | 否 | `0..4`（Isaac Quality），未知省略 |

标签表 v1（两端共用语义；缺省/未知一律按“无标签”处理）：
`heal`（回血/红心）、`damage`（输出）、`tear`（射速/弹幕）、`speed`、`defense`、`utility`、`familiar`、`active`。

> 标签由 mod 侧静态表 `data/item_tags.lua` 生成并写进 state；插件 **不得** 自己维护第二份标签表，避免两端判定分叉。未知 id 不给标签，规则会走默认分支。

### 2.7 `state.mod` / `state.enrichments`（可选）

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `mod.name` | string | 否 | 如 `isaac_agent` |
| `mod.version` | string | 否 | 语义版本，仅诊断 |
| `enrichments` | object | 否 | 键 `^[a-z][a-z0-9_]{1,31}$`；值任意 JSON；总量受 §1.6 限制。插件 StateEnricher 也可只在内存中补充，不要求写回 state |

### 2.8 校验与拒绝

- 插件收到 state 后 **必须** 依次校验：版本（§7）、必填字段、类型、范围、候选池与 `trigger` 一致性、大小限制。
- **信封可读（`protocol_version`、`request_id`、`gen_level_key` 可解析）但 body 不合法** → 插件 **必须** 发布一份 `valid:false` 的拒绝决策（`error_code: "VALIDATION"`，`reason_code` 指明具体项），而不是沉默。mod 收到拒绝后走本地规则。
- **信封都不可读**（坏 JSON、IO、被截断、连 `request_id` / `gen_level_key` 都取不到）→ 插件 **不得** 猜测身份，**不得** 写 decision；mod 到期后按 `TIMEOUT` 兜底。
- `state.error_code != null` 表示局面降级：插件 **不得** 调用 llm，只允许本地规则；具体见 §6.4。

---

## 3. `decision.json`

### 3.1 根信封

```json
{
  "protocol_version": "1.0",
  "session_id": "s-2f9a-0001",
  "request_id": "r-7f3a-000042",
  "decision_id": "d-9c1e-000001",
  "gen_level_key": "f2:r84:treasure:p0:9c1e",
  "ts": 1793982600900,
  "error_code": null,
  "features": [],
  "requires": [],
  "valid": true,
  "decision": {    "choice": { "type": "item", "item_id": 22 },
    "reason": "红心只剩 2 颗，先补红心更稳",
    "confidence": 0.72,
    "fallback": false,
    "source": "llm",
    "provider_id": "llm:primary",
    "reason_code": null,
    "elapsed_ms": 861
  }
}
```

| 字段 | 类型 | 必填 | 取值范围 / 说明 |
| --- | --- | --- | --- |
| `protocol_version` | string | 是 | 同 §2.1 |
| `session_id` | string | 是 | **必须**回显请求的 `session_id`；不一致拒绝（`session_mismatch`） |
| `request_id` | string | 是 | **必须**回显请求的 `request_id` |
| `decision_id` | string | 是 | 唯一；同一请求重发也必须是新值 |
| `gen_level_key` | string | 是 | **必须**与请求一致；不一致 mod 直接拒绝（`level_mismatch`） |
| `ts` | integer | 是 | epoch ms |
| `error_code` | string \| null | 是 | 五类之一或 `null`；非 null ⟹ `fallback = true` |
| `features` | string[] | 否 | 本端支持能力，供 `requires` 对照与展示；硬依赖写 `requires` |
| `requires` | string[] | 否 | 硬要求；mod 不认识任意一项 → 拒绝（`version_minor_feature`） |
| `valid` | boolean | 是 | `false` = “我无法给出可用决策”，mod 走本地兜底；`true` 才是可执行决策 |
| `decision.choice` | object | 是 | 见 §3.2；`valid:false` 时仍必须给 `skip` |
| `decision.reason` | string \| null | 否 | `1..280` 字符、单行、无控制字符；允许 **部分响应**（只给 choice 不给 reason），此时为 `null`/缺省 |
| `decision.confidence` | number | 是 | `0..1` 有限数；规则/兜底固定 `1.0` |
| `decision.fallback` | boolean | 是 | 是否由非主路径产生（见 §3.5） |
| `decision.source` | string | 是 | 固定二值：`llm` \| `rule` |
| `decision.provider_id` | string | 是 | `^[a-z][a-z0-9_.:-]{2,63}$`；如 `llm:primary`、`rule:low_hp`、`viewer:bilibili`、`preset:scripted` |
| `decision.reason_code` | string \| null | 否 | 机器可读原因，注册表见 §3.6；`valid:false` 时 **必须** 非 null |
| `decision.elapsed_ms` | integer | 否 | `0..60000`，插件内部耗时，仅诊断 |

### 3.2 `decision.choice`

判别联合，**必须** 恰好是下面一种：

```json
{ "type": "item",   "item_id": 22 }
{ "type": "action", "action": "skip" }
```

| `type` | 字段 | 类型 | 取值范围 |
| --- | --- | --- | --- |
| `item` | `item_id` | integer | `1..2147483647`，且 **必须** 属于当前 `state.candidates[].item_id` |
| `action` | `action` | string | 白名单：`skip`（唯一安全动作，默认）、`reroll`（仅当 `state.features` 含 `action:reroll`） |

- 扩展动作 **必须** 先登记到能力表并通过 minor 发布；v1 不得出现其它字符串。
- `skip` 的含义是“保持游戏状态不变”，不是“没想好”。
- `reroll` 的含义是“请 mod 用官方 API 重掷目标底座的候选池”；mod 不支持时 **不得** 自行模拟，直接拒绝并兜底（`VALIDATION` / `invalid_action`）。
- **`reroll` 不适用于生成回调（回调 62）**：该回调必须当帧返回 item id；在 `MC_PRE_GET_COLLECTIBLE` 里收到 `reroll` 一律按 `invalid_action` 拒绝，不执行。它只用于生成后的主动重掷阶段（若 mod 显式支持）。

### 3.3 合法性与约束

一份决策必须同时满足：

1. `valid:true` ⇒ `choice` 可执行、`confidence` 存在；`source:llm` ⇒ `fallback:false` 且 `error_code:null`。
2. `fallback:true` ⇒ `source == "rule"`，且 **要么** `error_code != null`，**要么** `reason_code` 是安全跳过（`no_candidate` / `player_dead`，此时 `error_code` 为 `null`）；`fallback:false` ⇒ `error_code == null`。
3. `valid:false` ⇒ `error_code != null`、`fallback:true`、`source:"rule"`、`reason_code != null`、`choice = {"type":"action","action":"skip"}`。
4. `error_code != null` ⇒ `fallback:true`（错误必须与兜底同时出现，不允许“带错误的正常决策”）。
5. `confidence` 有限且 `0 ≤ c ≤ 1`；`reason` 若有则单行、≤280 字符；`provider_id` 必须能看出渠道。
6. 决策 **不得** 包含任何密钥、账号、路径或可执行内容；`reason` 会直接显示在游戏内，**不得** 含任何控制字符（含换行/制表）。

违反任一条 → mod 拒绝（`VALIDATION` + 对应 `reason_code`），继续等刷新/本地兜底。

**`valid × fallback × error_code` 的执行真值表（两端必须一致）**：

| `valid` | `fallback` | `error_code` | mod 是否执行 `choice` | 说明 |
| --- | --- | --- | --- | --- |
| `true` | `false` | `null` | 是 | 正常 llm/主路径 |
| `true` | `true` | 非 null | 是 | 插件侧规则兜底，仍是一份可用决策 |
| `true` | `true` | `null` | 是（仅 `no_candidate`/`player_dead` 的 skip） | 安全跳过 |
| `false` | `true` | 非 null | **否** | 拒绝响应，mod 走本地规则，不执行其中的 skip |

### 3.4 部分响应

- 允许只有 `choice` + `confidence` + `source`/`fallback`/`provider_id`，没有 `reason`。
- 允许 `valid:false` 的“拒绝响应”：它只表达“别信我”，mod **不会** 执行其中的 `skip`，而是走自己的本地规则；`applied.json` 记录拒绝的 `decision_id` 与 `reason_code`。
- 不允许“半份 choice”（例如 `type:"item"` 但缺 `item_id`）——那不叫部分响应，叫非法文档。

### 3.5 `source` / `fallback` / `provider_id` 的判定

协议只认两个来源大类，避免“agent 还是兜底”的歧义：

| 实际生产者 | `source` | `fallback` | `provider_id` 示例 | `applied_by` |
| --- | --- | --- | --- | --- |
| LLM | `llm` | `false` | `llm:primary` | `llm` |
| 本地规则（主路径） | `rule` | `false` | `rule:low_hp` | `provider` |
| 预置策略 | `rule` | `false` | `preset:scripted` | `provider` |
| 观众投票 | `rule` | `false` | `viewer:bilibili` | `provider` |
| LLM 失败后的规则兜底 | `rule` | `true` | `rule:fallback` | `fallback` |
| 安全跳过（空池/已死亡） | `rule` | `true` | `rule:guard` | `fallback` |
| mod 自己的超时兜底 | `rule` | `true` | `rule:local` | `fallback` |
| 无法给出决策（拒绝） | `rule` | `true` | `rule:guard` | `fallback` |

- **禁止**用 `reason` 是否为空、`confidence` 高低、`choice` 类型去反推来源；来源只看 `source` + `fallback` + `provider_id`。
- **前缀交叉校验**：已知前缀必须匹配——`llm:*` ⇔ `source="llm"`；`rule:*` / `viewer:*` / `preset:*` ⇔ `source="rule"`；**已知前缀与 source 矛盾** → `VALIDATION` / `invalid_type`。未知前缀（如 `foo:*`）**允许**，记一条 WARN 并按 `source` 归类，**不得** 因此拒绝整份文档——否则每加一个 provider 都要改两端校验表，扩展点会被自己的校验堵死。
- 观众投票与预置策略都归 `rule`，因为它们是确定性聚合，不产生模型调用；渠道由 `provider_id` 保留，表现层可以显示“由 37 票选出”。
- 每条决策 **恰好落一个分类**：不能同时是 llm 决策和 fallback 决策；`applied_by` 也只有一个值。

### 3.6 `reason_code` 注册表

`reason_code` 是 `reason` 的机器可读补充；同一套值同时用于 decision 与 applied。

| `reason_code` | 归类到 `error_code` | 含义 |
| --- | --- | --- |
| `timeout` | `TIMEOUT` | 在有效期/生成时点前没拿到决策 |
| `no_fresh_decision` | `TIMEOUT` | 生成时无未过期决策 |
| `late` | `TIMEOUT` | 决策在生成/过期后才到，丢弃 |
| `request_mismatch` | `VALIDATION` | `request_id` 不属于当前任何在途请求 |
| `session_mismatch` | `VALIDATION` | `session_id` 与当前 mod 会话不符（旧局/旧进程） |
| `level_mismatch` | `VALIDATION` | `gen_level_key` 与当前生成层不符 |
| `version_major` | `VALIDATION` | major 不兼容 |
| `version_minor_feature` | `VALIDATION` | `requires` 含本端未知能力 |
| `missing_field` | `VALIDATION` | 必填字段缺失 |
| `invalid_type` | `VALIDATION` | 类型错误 |
| `out_of_range` | `VALIDATION` | 数值/长度越界 |
| `invalid_choice` | `VALIDATION` | choice 结构非法 |
| `invalid_id` | `VALIDATION` | 道具 id 不在候选池/不是合法 collectible |
| `invalid_action` | `VALIDATION` | 动作不在白名单或本端不支持 |
| `invalid_reason` | `VALIDATION` | reason 含控制字符/超长 |
| `state_invalid` | `VALIDATION` | 局面数据不合法，无法决策 |
| `no_candidate` | `null` | 候选池为空（安全跳过，不是错误） |
| `player_dead` | `null` | 玩家已死亡（安全跳过，不是错误） |
| `model_error` | `MODEL` | 模型调用失败/超时/输出不可解析 |
| `not_applied` | `INTERNAL` | 决策文书写明要生成 A，实际生成却不是 A（未真正生效） |
| `io_error` | `IO` | 文件/目录/权限/存档读写失败 |
| `bridge_unavailable` | `IO` | 桥不可用（Profile B/探针失败） |
| `internal_error` | `INTERNAL` | 其它未预期错误 |

未登记的 `reason_code` **不得** 导致整份文档被拒绝：读者保留原值、按 `error_code` 归类并记一条 WARN；只有结构/类型/范围非法才拒绝。这样 minor 增加原因码不会让旧端把新决策整份丢掉。

---

## 4. `event.json`

### 4.1 通用结构

```json
{
  "protocol_version": "1.0",
  "session_id": "s-2f9a-0001",
  "event_seq": 42,
  "ts": 1793982599980,
  "type": "pedestal_spawn",
  "request_id": "r-7f3a-000042",
  "payload": { "pedestal_index": 0, "item_id": 4, "item_name": "Cricket's Head" }
}
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `protocol_version` | string | 是 | 同 §2.1 |
| `session_id` | string | 是 | 产生事件的 mod 会话；消费者用 `(session_id, event_seq)` 去重，重启后 `event_seq` 归零不会被误判为重放 |
| `event_seq` | integer | 是 | `>= 1`，同一 `session_id` 内 monotonic；允许跳号（latest-wins 丢事件） |
| `ts` | integer | 是 | epoch ms |
| `type` | string | 是 | 见 §4.2 |
| `request_id` | string \| null | 否 | 与本次事件关联的 state 请求；纯通知事件为 `null` |
| `payload` | object | 是 | 按类型定义；≤ 16 KiB |

- `event.json` 是 **latest-wins** 的单文件，不保证每一条都送达；消费者 **必须** 容忍 `event_seq` 跳号，并以 `state.json` 为最终事实来源。
- 需要逐条可靠送达时走队列/管道传输（架构文档 §传输层），文件模式不承诺。

### 4.2 事件类型与 payload

| `type` | 触发时机（游戏侧） | payload 字段 |
| --- | --- | --- |
| `pedestal_spawn` | 候选底座生成/替换完成 | `pedestal_index` int 0..63；`item_id` int；`item_name` string\|null；可选 `room_type` |
| `room_enter` | 进入新房间（含读档后首次） | `room_type` string；`floor` int；`is_boss_room` bool；可选 `grid_index` |
| `boss_approach` | 进入 Boss 房/ Boss 生成 | `boss_id` int；`boss_name` string\|null；可选 `hp`、`max_hp` |
| `reroll` | 候选池被重掷（D4/骰子房/主动道具） | `pedestal_index` int\|null；`before` 数组 `{pedestal_index,item_id}`；`after` 同构；`gen_level_key` string |
| `custom` | 预留扩展 | `name` string（`^[a-z][a-z0-9_]{1,63}$`）；`payload` object ≤ 8 KiB |

`custom` 示例：

```json
{
  "protocol_version": "1.0",
  "session_id": "s-2f9a-0001",
  "event_seq": 43,
  "ts": 1793982599990,
  "type": "custom",
  "request_id": null,
  "payload": {
    "name": "bilibili_danmaku",
    "payload": { "user": "观众A", "text": "拿血！", "vote": 22 }
  }
}
```

> `custom.payload` 的内容由扩展方定义，必须自包含、可丢弃、无副作用；mod/插件不认识时 **必须** 忽略，不得报错。

### 4.3 事件与请求的关系

- `pedestal_spawn` / `reroll` 通常伴随一次 state 请求；`room_enter` / `boss_approach` 可以只通知、不请求。
- `trigger.type` 与最近一次事件一致；刷新请求沿用原 `trigger` 与 `event_seq`。
- 事件丢失不影响决策正确性；agent 的决策依据以 `state.json` 为准，不以事件流为准。

### 4.4 `custom` 的边界

- 不得借 `custom` 传递密钥/账号/可执行代码/文件路径；
- 不得借 `custom` 让 mod 执行任意动作；它只是通知与展示用；
- 观众弹幕接入只能通过插件侧的 EventSource 归一化为 `custom`，mod 不直连 B 站。

---

## 5. `applied.json`（应用回执）

### 5.1 作用

回答三个问题：**这次最后执行了什么**、**是 llm 还是兜底**、**为什么**。QA 与表现层只读这个文件即可还原结果，不需要猜 `decision.json` 是否被采纳。

> 统计边界：`applied.json` 是 latest-wins 的“最后回执”，不是完整事件日志；迟到丢弃、被覆盖的旧回执只在日志里。按 `source`/`provider_id` 做统计时 **必须** 注明“只覆盖有回执的抽取”，精确统计需要可靠回执通道。

### 5.2 结构

```json
{
  "protocol_version": "1.0",
  "session_id": "s-2f9a-0001",
  "request_id": "r-7f3a-000042",
  "gen_level_key": "f2:r84:treasure:p0:9c1e",
  "ts": 1793982601402,
  "phase": "applied",
  "decision_id": "d-9c1e-000001",
  "source": "llm",
  "provider_id": "llm:primary",
  "fallback": false,
  "applied_by": "llm",
  "error_code": null,
  "reason_code": null,
  "choice": { "type": "item", "item_id": 22 },
  "reason": "红心只剩 2 颗，先补红心更稳",
  "latency_ms": 900,
  "pedestal_index": 0,
  "actual_item_id": 22
}
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `protocol_version` | string | 是 | 同 §2.1 |
| `session_id` | string | 是 | 本回合的 mod 会话；与 state 一致 |
| `request_id` | string | 是 | 本回合最终采纳/兜底的请求；无请求时用最近一次 |
| `gen_level_key` | string | 是 | 当前生成层 |
| `ts` | integer | 是 | 回执写入时刻 |
| `phase` | string | 是 | `applied`（已执行）/ `rejected`（拒绝且未执行任何动作） |
| `decision_id` | string \| null | 是 | 被采纳或被拒绝的决策；纯本地兜底为 `null`。若引用被拒绝的决策，`source` / `provider_id` 仍描述 **实际生效** 的兜底路径 |
| `source` | string \| null | 是 | `llm` \| `rule` \| `null` |
| `provider_id` | string \| null | 是 | 实际生效的提供者 |
| `fallback` | boolean | 是 | 是否兜底路径 |
| `applied_by` | string | 是 | `llm` / `provider` / `fallback` / `none`；**唯一判定字段** |
| `error_code` | string \| null | 是 | 五类之一或 `null` |
| `reason_code` | string \| null | 是 | §3.6 注册表；无错误为 `null` |
| `choice` | object \| null | 是 | 实际执行的选择；`rejected` 时为 `null` |
| `reason` | string \| null | 是 | 实际展示理由；兜底时由 mod 生成 |
| `latency_ms` | integer \| null | 否 | 请求发出 → 决策接收的耗时；纯本地兜底为 `null` |
| `pedestal_index` | integer \| null | 是 | 目标底座 |
| `actual_item_id` | integer \| null | 是 | 底座生成后核验到的真实道具 id（`POST_PICKUP_INIT` 写入）；未生成/未核验为 `null`。§5.4 的判定依赖此字段，不能省略 |

### 5.3 “agent 还是兜底”的判定算法

```
if phase == "rejected":                 -> applied_by = "none"
elif fallback == true:                  -> applied_by = "fallback"
elif source == "llm":                   -> applied_by = "llm"
else:                                   -> applied_by = "provider"   # 预置/观众/规则主路径
```

- 表现层只有在 `applied_by == "fallback"` 时加 `[兜底]` 前缀；`provider` 是“配置好的主路径”，不是失败。
- `applied_by` **由生产端按上述算法推导**，消费端只校验、不自行重新分类；任何 `applied_by` 都必须与 `fallback` / `source` 一致；不一致视为 mod 实现 bug，QA 应报失败。
- **统计口径**：`reason_code` 为 `no_candidate` / `player_dead` 的安全跳过虽然按算法落 `fallback`，但统计“兜底率/失败率”时 **必须排除**；它们不是错误，也不是模型/规则失败。按 `provider_id` 统计时同理，`rule:guard` 单列。
- `actual_item_id != choice.item_id`（item 选择时）说明决策没有真正生效。若随后由本地规则/Morph 替换成功，`applied_by` **必须** 降级为 `fallback`；若没有任何替换生效（原版道具留下），按 §5.4 写 `phase:"rejected"`、`applied_by:"none"`。

### 5.4 应用结果与回执的完整规则

生成后 **必须** 按下表写唯一一份 `applied.json`，不允许出现“字段不知道该填什么”的空档：

| 实际结果 | `phase` | `applied_by` | `source` | `provider_id` | `decision_id` | `choice` | `fallback` | 说明 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 实际 id == 决策 id | `applied` | `llm` 或 `provider` | 随决策 | 随决策 | 该决策 | 实际 choice | 随决策 | 正常 |
| 决策被拒/过期，本地规则或 Morph 生效 | `applied` | `fallback` | `rule` | `rule:local`/`rule:fallback` | 最后被拒决策或 `null` | 实际生效 choice | `true` | 兜底成功 |
| 决策与实际不符，且 **没有** 任何替换生效（原版道具留下） | `rejected` | `none` | `null` | `null` | 最后被拒决策或 `null` | `null` | `true` | `error_code` 取失败原因；`reason_code` 用 `not_applied` / `no_fresh_decision` |
| 无候选/角色已死，安全跳过（无实际道具变化） | `applied` | `fallback` | `rule` | `rule:guard` | `null` | `{"type":"action","action":"skip"}` | `true` | `error_code:null`，`reason_code:no_candidate`/`player_dead` |

> 关键：`rejected` 不是“兜底成功”，它表示 **没有任何替换生效**；此时 `applied_by` 必须是 `none`，不能写 `fallback`。

---

## 6. 兜底与超时语义（核心）

### 6.1 时间预算

| 量 | 默认 | 含义 |
| --- | --- | --- |
| `validity_ms` | 1500 | 决策有效期；从请求发出算起 |
| 刷新间隔 | `validity_ms / 2` | 等待生成期间重复发请求（同 `gen_level_key`，新 `request_id`） |
| 插件落盘余量 | 200ms | 插件 **应该** 在 `validity_ms - 200ms` 前写完 decision |
| llm 超时 | `validity_ms - 400ms` | 插件内部给模型的上限，保证还来得及降级到规则 |

`validity_ms` **由 mod 按上下文选择**：近场/反应式用 1500ms；Boss 奖励等“长预取”用 5000–10000ms（上限 10000），刷新间隔随之取一半。不要把 Boss 战的整段时间压进 1500ms，否则决策在生成前就过期。

插件预算 **必须** 从 `state.ts` 起算，而不是从“插件收到文件”起算：

```
remaining = state.ts + validity_ms - now - write_margin
```

这样文件轮询、排队和传输延迟都被计入。若 `remaining <= 0`，插件 **不得** 调用 llm，只允许发布拒绝/规则兜底。

**mod 永不阻塞等待**：没有 sleep、没有 busy-wait、没有“等 1500ms 再继续”。1500ms 只用于判定“这份决策是否还新鲜”。

### 6.2 生成当帧的算法（池抽取 / 底座生成，`MC_PRE_GET_COLLECTIBLE`）

> 回调 62 发生在**道具池抽取完成、底座实体生成之前**，不是玩家走过去拿道具的时候；它要求当帧返回 id。玩家之后“拿不拿/什么时候拿”是另一条独立路径，不影响本算法。

```
eligible = 最近一条满足以下全部条件的决策:
  decision.valid == true
  decision.session_id == state.session_id
  decision.request_id ∈ outstanding_requests
  now - request_sent_at(decision.request_id) <= validity_ms
  received_at < generation_time
  decision.gen_level_key == current_gen_level_key
  decision.choice 合法（item 在 candidates / action 在白名单）

if eligible:
    返回 eligible.choice.item_id（item）或按 action 语义执行；不查盘、不调模型
else:
    用内存中的最近局面执行本地规则 v1（§6.5），返回结果或 nil
    不等待、不补问；结果标 fallback
```

- 回调内 **不得** 读文件、写文件、调 llm、打日志到磁盘、GC 等待；只查内存表。
- 本地规则只在“内存局面与当前 `gen_level_key` 匹配、候选列表可用”时生效；没有可用局面就返回 `nil`（原版），并在 `applied.json` 记 `phase: "rejected"`、`choice: null`、`applied_by: "none"`、`error_code: "TIMEOUT"` / `reason_code: "no_fresh_decision"`。
- 若内存里连局面都没有（Profile B/刚启动）→ 返回 `nil`（原版道具），`applied.phase: "rejected"`、`applied_by: "none"`，`error_code: TIMEOUT` / `no_fresh_decision`。
- **不推荐** 的备选实现：当帧返回 `nil` 让原版道具生成，下一帧再用 Morph 换成决策道具。它引入可见闪烁、可能触发两次拾取/成就判定，只在用户显式开启时使用（`apply:morph` 能力）。

**应用点有两种合法实现**，协议不规定必须用哪种，只要求“决策先于生成到达”：

1. **生成时返回 id（本节的默认路径，推荐）**：`MC_PRE_GET_COLLECTIBLE(62)` 返回缓存中的 `item_id`；底座实体随后按该 id 生成，显示与拾取天然一致。
2. **生成时替换**：决策到达后用官方 API 直接生成/替换目标底座；此时 `MC_PRE_GET_COLLECTIBLE` 可以返回 `nil` 走原版（因为底座上已经是决策道具）。该路径更适合“写回生成道具”的产品表述，但要求决策在底座可见前到达；没赶上时仍按本节兜底。

### 6.3 情况表

| 情况 | 检测点 | mod 行为 | `error_code` | `reason_code` |
| --- | --- | --- | --- | --- |
| 无响应（插件没启动/崩溃） | 生成时无 eligible | 本地规则 v1 | `TIMEOUT` | `no_fresh_decision` |
| 决策晚于有效期 | 收到时 `now - sent > validity_ms` | 丢弃，继续等刷新 | `TIMEOUT` | `late` |
| 决策晚于生成 | 生成后才收到 | 丢弃，不改已执行结果 | `TIMEOUT` | `late` |
| 非法道具 id | 收到时校验 | 拒绝；继续等刷新；生成时本地规则 | `VALIDATION` | `invalid_id` |
| id 合法但不在候选池 | 收到时校验 | 同上 | `VALIDATION` | `invalid_choice` |
| 非法动作/不支持的动作 | 收到时校验 | 同上 | `VALIDATION` | `invalid_action` |
| 缺必填字段 | 收到时校验 | 拒绝该决策 | `VALIDATION` | `missing_field` |
| 类型/范围错误 | 收到时校验 | 拒绝该决策 | `VALIDATION` | `invalid_type` / `out_of_range` |
| `valid:false` 拒绝决策 | 收到时 | 不执行其 `skip`；本地规则 | 拒绝里的 code | 拒绝里的 reason_code |
| 版本 major 不匹配 | 收到时 | 丢弃；本地规则 | `VALIDATION` | `version_major` |
| `requires` 含未知能力 | 收到时 | 丢弃；本地规则 | `VALIDATION` | `version_minor_feature` |
| `gen_level_key` 不匹配 | 收到时 | 丢弃（跨层/跨底座） | `VALIDATION` | `level_mismatch` |
| `request_id` 不在在途表 | 收到时 | 丢弃（旧回合/别家） | `VALIDATION` | `request_mismatch` |
| `session_id` 不匹配 | 收到时 | 丢弃（旧局/旧进程） | `VALIDATION` | `session_mismatch` |
| state 不合法 | 插件侧 | 拒绝并写 `valid:false` | `VALIDATION` | `state_invalid` |
| state 降级（`error_code != null`） | 插件侧 | 不调 llm，只跑规则 | 沿 state | 沿 state |
| 读写失败/权限 | mod/插件 | 保留旧文件；本地规则 | `IO` | `io_error` |
| 桥不可用（Profile B） | mod 启动探针 | 纯本地规则 + 气泡提示 | `IO` | `bridge_unavailable` |
| 未预期异常 | 任意 | 捕获、记 `INTERNAL`、本地规则 | `INTERNAL` | `internal_error` |

> **本表不写 `applied_by`**：它是结果字段，唯一推导来源是 §5.3 算法；本表只描述“发生了什么、走哪条兜底”。这样不会出现 §6.3 说 `fallback`、§5.3 却判 `none` 的两套口径。
>
> **失败原因可见**：无决策可用时，mod **应该** 读一次 `plugin_status.json`（§1.11）；若插件标记 `refused`/`degraded`，用其 `error_code` / `reason_code` 写 `applied.json`（例如 `version_major`），而不是一律记 `TIMEOUT`。文件不存在/不可读才回 `TIMEOUT`。

> **Morph 模式例外**：只有显式启用 `apply:morph` 时，mod 才可以在生成后用 Morph 替换底座。此时“消费点”是 **Morph 成功或玩家拿起**，不是池抽取；在底座存续期内到达且未过期的决策仍可用，`late` 从玩家拿起/底座销毁后算。默认预取模式不启用这个例外。

### 6.4 state 降级的处理

- `state.error_code != null` 表示 mod 自己知道局面不完整（例如某个读取失败）。此时插件 **必须**：
  1. 不调用 llm（避免基于坏数据做昂贵决策）；
  2. 若 body 仍满足规则所需字段，跑本地规则并发布 `fallback:true`、`error_code` / `reason_code` 沿用 state 的值；
  3. 若 body 不足以跑规则，发布 `valid:false` + `reason_code: "state_invalid"`。
- mod 收到后按普通兜底处理；表现层显示 `[兜底]` 与降级原因（`reason_code`）。

### 6.5 本地规则 v1（两端必须一致）

两端（mod 的 `rule:local` 与插件的 `rule:fallback`）使用同一套规则，**只读 state 里的标签**，不维护第二套 id 表：

1. `player.is_dead == true` → `{"type":"action","action":"skip"}`，`reason_code: "player_dead"`，`confidence: 1.0`。
2. `candidates` 为空 → `{"type":"action","action":"skip"}`，`reason_code: "no_candidate"`，`confidence: 1.0`。
3. `player.red_hearts == 0` 且 `player.max_red_hearts` **存在且 > 0**，且存在 `tags` 含 `heal` 的候选 → 取 **pedestal_index 最小** 的 heal 候选；`max_red_hearts` 缺省（未知）或 `0` 的角色（Keeper/Blue Baby 等）跳过本规则，不得把“未知”当“可回血”。
4. 已持有道具中没有任何 `tags` 含 `damage`，且存在 `tags` 含 `damage` 的候选 → 取 pedestal_index 最小的 damage 候选。
5. 否则 → 取 pedestal_index 最小的候选（默认分支）；池级预取的候选全为 `null` 时，按 `candidates` **数组下标升序**，再按 `item_id` 升序。
6. 平票时一律按“非空 `pedestal_index` 升序 → 数组下标 → `item_id`”排序，保证两端确定性；规则输出的 `confidence` 固定 `1.0`，`reason` 用简体中文短句。

> 规则只做“安全且可解释”的选择，不假装懂道具强度。更强的选择交给 llm/观众；规则只负责“绝不卡住、绝不越界”。

### 6.6 禁止静默

- 任何兜底 **必须** 同时具备：`applied.json`（Profile A；C 在 v1.1+）、`error_code`（安全跳过为 `null`）+ `reason_code`、可读 `reason`、屏幕提示（`[兜底]`）。
- 不允许“默认拿第一个候选”但不记录；不允许 reason 为空且无 reason_code。
- 日志 **必须** 含 `level`（debug/info/warn/error）、`module`、`request_id` / `decision_id`、`error_code` / `reason_code`；同类错误限频；**不得** 输出密钥。

### 6.7 刷新、缓存与消费契约（R1 → R2）

同一次生成会发出多个刷新请求（同一 `gen_level_key`、不同 `request_id`）。为避免“旧结果串到新请求 / 同一决策被用两次”，两端 **必须** 遵守：

1. **身份**：每次写 state 生成新 `request_id`；`session_id` 在同一局内稳定、重启/读档变化；`gen_level_key` 在同一生成目标内不变。mod 维护 `outstanding` 表（`(session_id, request_id) → sent_at`），请求在 `sent_at + validity_ms` 后过期，生成发生后立即清空该 K 的未决项。
2. **插件去重与指纹**：可按 `(session_id, gen_level_key)` 合并同一生成目标的在途 llm 调用；缓存键 **必须** 包含“局面指纹”。指纹字段固定为：`session_id`、`gen_level_key`；`player.red_hearts` / `soul_hearts` / `max_red_hearts` / `character_id` / `is_dead`；`items[].id` + `count`（按 id 升序）；`candidates[].item_id`（按数组顺序）。任意一项变化 → 指纹变化 → **不得** 复用旧结果，必须按新请求重算。
3. **结果归属**：为 R1 算出的结果可以在 R2 到达后发布，但只能绑定到 **发布时最新的请求**（R2），并使用 **新的 `decision_id`**；若指纹已变，丢弃旧结果，按 R2 重算。`decision_id` 永远不得复用；不要求“R1 的结果只能叫 R1”。
4. **接收**：mod 接受任何 `request_id ∈ outstanding`、未过期、`gen_level_key` 匹配的决策；同一 K 多条时取 **接收时间最新** 的一条；旧决策被覆盖。生成已结束后到达的按 `late` 丢弃。
5. **消费**：一次生成 **恰好消费一个** choice；消费后该 K 的其余决策全部作废，**不得** 留给下一次生成复用。`applied.json` 只记录被消费/最终兜底的那一次。
6. **重复投递**：相同 `decision_id` 重复到达 → 忽略；相同 `request_id`、不同 `decision_id` → 允许，按接收时间取最新。
7. **两段式临时决策**：插件可先发规则临时决策，合法组合是 `valid:true, source:"rule", fallback:true, error_code:"TIMEOUT", reason_code:"timeout"`（表示“模型尚未就绪”）；后续 llm 决策在生成前到达可覆盖它，生成后到达则丢弃。
8. **缓存边界**：插件缓存必须有界（按 K 保留少量条目 + TTL = `validity_ms` + 宽限 5000ms），K 变化 / 生成完成 / 对端离线时清理。

**R1 → R2 → 生成 → 迟到** 的规范时序（两端状态机必须能跑出同一结果）：

| 时刻 | 事件 | 必须的结果 |
| --- | --- | --- |
| 0 | mod 发 R1（K，指纹 F1） | 插件开始一次 llm 调用 |
| 700 | mod 刷新 R2（同 K，指纹仍 F1） | 插件不重复调用；记录“最新请求 = R2” |
| 900 | llm 返回 | 指纹仍 F1 → 发布为 **R2** 的决策，`decision_id=D2`；**不存在 D1** |
| 1000 | mod 收到 D2 | 缓存；R2 未过期，D2 可用 |
| 1200 | mod 刷新 R3 | 最新请求 = R3；D2 仍可按“R2 未过期 + K 匹配”被接受 |
| 5000 | 生成发生 | 消费 D2；`applied.json` 记 D2；清空 K 的未决项 |
| 5200 | 为 R3 算出的结果到达 | 生成已结束 → `late` 丢弃，不改 applied |

> 如果 700ms 时指纹变成 F2（例如玩家掉了红心），插件 **必须** 丢弃 R1 的在途结果，不能“反正候选没变就复用”；R2 重新算。生成前没有可用决策就按 §6.2 本地兜底。

---

## 7. 版本兼容

### 7.1 版本号

`MAJOR.MINOR[.PATCH]`，只比较 major/minor：

- **MAJOR**：不兼容变更（字段删除/改义/改类型/改必需性/改动作语义）。
- **MINOR**：只允许 **可选** 字段、可选能力、可选动作；不得新增必填字段。
- **PATCH**：文档/措辞/示例修正，不影响线上格式。

### 7.2 minor 规则

- 新字段一律可选；旧读者忽略，新读者对缺失给默认值。
- 新行为由能力字符串门控（`features` / `requires`），不得靠“版本号 ≥ x”隐式开启。
- 若新字段会改变决策正确性（例如新增 `candidate_pool_weights`），必须同时放进 `requires`，让旧对端明确拒绝而不是误用。

### 7.3 major 规则

处理顺序 **先选 codec，再判断是否拒绝**（避免“允许兼容 reader”与“major 不同就拒绝”互相打架）：

1. 按 `peer.major` 查本端 codec 注册表；有对应 codec（当前 major，或保留的 N-1 兼容 reader）→ 用该 codec 解码，进入 §7.4 的 minor 判断。
2. 没有对应 codec → 拒绝解析：插件 **不得** 猜测 state、**不得** 写 decision；但 **应该** 在 `plugin_status.json` 写 `status:"refused"`、`error_code:"VALIDATION"`、`reason_code:"version_major"`，让 mod/QA 看到原因。mod **不得** 尝试解析 decision，直接本地兜底，`reason_code: "version_major"`（若 status 可读则沿用）。
3. 兼容 reader 降级时 **必须保留**：`session_id`、`request_id`、`decision_id`、`gen_level_key`、`error_code`、`reason_code`、`valid`、`source`、`provider_id`、`fallback`、`requires`、`choice`；新 major 的专有可选字段可以丢弃并记日志，但不得改变上述字段语义。`requires` 不得丢：丢掉它会让需要新能力的决策被旧端当“无要求”执行。
4. 跨 major 的“拒绝信封”是 **可选** 的：无法确认对方 schema 时，沉默 + 超时兜底是安全路径；若实现选择写拒绝信封，只允许使用双方冻结的最小字段集，且失败仍要落到日志/applied。
5. 对端 major 更低时，若兼容 reader 存在则降级读+降级写；否则同样拒绝并兜底。兼容层至少保留一个发布周期，并有契约测试（§7.5）。

### 7.4 “对端比我新”的识别

比较顺序：

1. 先按 `peer.major` 选 codec（§7.3）；没有对应 codec → 不兼容，拒绝解析并兜底。
2. `peer.minor > mine.minor` → 视为“对端更新”：忽略未知字段；若 `peer.requires` 含本端未知能力 → 拒绝（`version_minor_feature`）；否则可以正常处理，并记一条 INFO“peer newer minor”。
3. `peer.minor < mine.minor` → 视为“对端更旧”：按旧字段读，缺失的可选字段用默认值；缺必需字段 → `missing_field` 拒绝。
4. `peer.minor == mine.minor` → 正常处理；仍按 `requires` 校验。

### 7.5 契约测试矩阵（三端共用）

| ID | 场景 | 期望 |
| --- | --- | --- |
| V-01 | 同版本成功 | 正常应用，`applied_by:llm` |
| V-02 | 出现未知可选字段 | 忽略并成功 |
| V-03 | 对端 minor 更新 + 未知可选字段 | 成功，日志 INFO |
| V-04 | `requires` 含未知能力 | 拒绝，`version_minor_feature` |
| V-05 | state major 更新 | 插件不写 decision，mod 超时兜底 |
| V-06 | decision major 不匹配 | 丢弃，`version_major`，本地兜底 |
| V-07 | 缺必填字段 | 拒绝，`missing_field` |
| V-08 | 数值越界/类型错 | 拒绝，`out_of_range` / `invalid_type` |
| V-09 | id 不在候选池 | 拒绝，`invalid_choice`，生成时兜底 |
| V-10 | 超时无决策 | `TIMEOUT` / `no_fresh_decision` |
| V-11 | 迟到决策 | 丢弃，不改状态 |
| V-12 | 其它请求的决策 | 丢弃，`request_mismatch` |
| V-13 | `fallback:false` + `error_code != null` | 拒绝，`VALIDATION` |
| V-14 | reason 超长/含控制字符 | 拒绝，`invalid_reason` |
| V-15 | `valid:false` 拒绝响应 | 不执行 skip，本地规则，`fallback` |
| V-16 | state `error_code != null` | 不调 llm，规则兜底 |
| V-17 | 进程重启后旧 decision | 丢弃，`request_mismatch` |
| V-18 | 残留 `.tmp` 文件 | 忽略并清理，不读半成品 |
| V-19 | `gen_level_key` 不匹配 | 丢弃，`level_mismatch` |
| V-20 | 空候选池 | `skip`，`no_candidate`，不报错 |

---

## 8. 失败必须显式

### 8.1 一次请求的状态机

```
IDLE
 └─(事件/刷新)→ REQUESTED(state.json 已落盘)
      ├─(收到合法决策且未过期)→ DECISION_READY
      ├─(收到非法决策)→ REJECTED_DECISION（记录 reason_code，继续等）
      ├─(收到 valid:false)→ REFUSED（走本地规则）
      └─(生成时仍无 eligible)→ TIMEOUT（走本地规则）
DECISION_READY
 └─(生成)→ ELIGIBLE_CHECK
      ├─(仍有效)→ APPLIED（applied_by=llm/provider）
      └─(已过期/不匹配)→ EXPIRED（本地规则）
```

每个终态 **必须** 写一次 `applied.json`（Profile A；C 在 v1.1+）或结构化日志 + 气泡（Profile B）。

### 8.2 三种失败的归类

| 失败形态 | `error_code` | `reason_code` | 显式证据 |
| --- | --- | --- | --- |
| **缺字段/结构不对** | `VALIDATION` | `missing_field` / `invalid_type` | state 缺字段 → 插件写 `valid:false`；decision 缺字段 → mod 拒绝并写 `applied.json`（`reason_code` 留痕） |
| **超时/无新鲜决策** | `TIMEOUT` | `timeout` / `no_fresh_decision` / `late` | `applied.json` 的 `fallback:true` + `reason` |
| **非法值（id/动作/范围）** | `VALIDATION` | `invalid_id` / `invalid_action` / `out_of_range` | 拒绝日志 + 生成时的兜底回执 |

### 8.3 不可接受的失败表达

- 静默使用默认值；
- `error_code` 缺失（必须显式 `null` 或五类之一）；
- 用 `reason` 字符串包含/不包含某词来判定来源；
- 拒绝后不记录 `decision_id`；
- 兜底后 `applied_by` 仍写 `llm`。

---

## 9. 安全与红线

- **不联网**：默认构建不发起任何外网连接；mod 不联网；HTTP/WS 适配器只允许绑定 `127.0.0.1`，远程模式必须显式开启且不进入默认构建。
- **不读 key**：mod 永不读取/写入任何 API key；插件 **不得** 把 key 写入协议文件、日志、`reason`、`provider_id` 或模型提示。key 只存在于 DSH 侧的凭据存储与调用层。
- **不做帧级操作**：不注入输入、不操纵玩家移动/射击、不改内存、不做逐帧脚本化操作；只读游戏状态，只通过官方 API 在决策生效点替换/生成道具。
- **不碰账号凭证**：不读 Steam 账号/token/存档账号信息；协议不携带任何账号字段。
- **默认不放宽 mod 文件权限**：Profile B 下 mod 不写盘；Profile A 必须由玩家显式以 `--luadebug` 启动。文档/安装向导必须原样说明：`--luadebug` 不是“给本 mod 开一个开关”，而是 **给所有 mod 放开文件访问**。
- **不执行远端代码**：模型/观众输出只作为 `choice`/`reason` 校验后的数据，不能当代码或路径。
- **路径白名单**：所有文件读写限制在 `<bridge>`；拒绝路径穿越、符号链接逃逸、模型指定路径。
- **大小上限**：见 §1.6；超限拒绝，不截断。
- **日志脱敏**：不打印 key、cookie、账号、完整绝对路径（可打印桥目录相对名）。

---

## 10. 完整示例

三份可直接用于契约测试的完整快照（含时间线、四个文件内容、日志）：

- [01-success.json](../protocol/examples/01-success.json)：Boss 战前预取 llm 决策，生成时命中，`applied_by: "llm"`。
- [02-fallback-invalid-id.json](../protocol/examples/02-fallback-invalid-id.json)：插件给了候选池外的 id，拒绝后本地规则在生成当帧兜底。
- [03-timeout-late.json](../protocol/examples/03-timeout-late.json)：生成时无决策，本地规则兜底；迟到决策被丢弃。

> 每个示例是自包含快照：`files` 下是线上文档原文（`state.json` / `decision.json` / `event.json` / `applied.json`），`timeline` 是毫秒级时序，`logs` 是预期日志。QA 可直接取 `files.*` 做契约测试。示例里的 `ts` 是固定值，便于逐字节比对；运行时用当前时间。

---

## 11. 已知取舍（v1 明确不做/不保证）

1. **单生成目标 + latest-wins，没有决策队列。** 同一时刻只有一个活跃请求；多底座房、快速 reroll、房间加载时抽取只能串行或吃 `nil`/本地规则。要“每个底座都由 agent 决定”，需要池级预取/队列，属于 v2，不在 v1 承诺；Claude 补审建议的“房间级池预取/水位”同样不写进 v1，理由见 tri-party §4.5。
2. **`applied.json` / `event.json` 是 latest-wins 回执，不是完整审计日志。** 迟到、被覆盖、被拒绝的历史主要在日志里；精确统计需要可靠回执通道。
3. **EventSource 是通知适配器，不是可靠事件总线。** 文件模式丢事件后不能补齐；`custom` 只做通知/展示，不能驱动新玩法；新增正式事件仍需 mod 改动 + minor。
4. **默认 Profile B，实时 agent 需显式启用 A。** B 不导出实时 state，只能预置策略/本地规则/外部 StateDoc；不要把它当“降级后还能问模型”。A 需要 `--luadebug`，代价是给所有 mod 放开文件访问，不是单 mod 开关。
5. **跨 major 不强制写拒绝信封，但提供可选 `plugin_status.json`。** 没有可读 codec 时插件不写 decision，但 **应该** 把 `refused/version_major` 写进状态文件；mod 无决策时读它，把原因写进 `applied.json`。文件缺失/不可读时才显示为 `TIMEOUT`。
6. **v1 不导出地图/敌人数据。** `MapEnricher` / `EnemyEnricher` 只有在 mod 通过可选 `state` 字段导出对应数据后才成立；否则它们只是“看着能插”的占位，接入前需要 minor 扩展 state。
7. **角色与血量上限是可选字段。** 缺省时规则按“未知”处理，可能降低选择质量；不阻塞主流程。
8. **`source` 固定两值（llm/rule），来源细分放 `provider_id`。** 这是 captain 批准的取舍；代价是读文档的人可能把 `rule` 误当兜底，已用 §0.1 与 §3.5 的误用警告约束。
9. **Profile C（SaveData 中继）推迟到 v1.1+，v1 不做。** 理由：把协议塞进存档会遇到数据类型受限、与存档写入/回滚机制冲突、审计困难；v1 不实现、不默认、不作为保底。等 B/A 的真实使用数据后再设计。

---

## 12. 变更记录

| 版本 | 日期 | 变更 |
| --- | --- | --- |
| 1.0-draft.1 | 2026-11-07 | 首版：四文档、三种 Profile、`gen_level_key`/`decision_id`/`valid`/`reason_code`、决策有效期而非阻塞等待、五类错误码与兜底矩阵 |
| 1.0-draft.2 | 2026-11-07 | 吸收 t2 参考实现发现：明确回调 62 的生成时序、`source` 固定 `llm`/`rule`、`valid=false` + `reason_code`、允许部分响应、每次抽取恰好一个分类；`viewer`/`preset` 用 `provider_id` 表达 |
| 1.0-draft.3 | 2026-11-07 | 吸收 t7 评审：`state.reason_code`、角色/血量上限可选字段、validity 双阶段判定、刷新/缓存/消费契约、`reroll` 禁止在回调 62 使用、provider_id 前缀交叉校验、未知 reason_code 容忍、跨 major codec-first、应用结果回执真值表、已知取舍清单 |
| 1.0-draft.4 | 2026-11-07 | 吸收 t8 Claude 补审：必填 `session_id`、池标识必填、`actual_item_id` 必填、删除 `capabilities` 统一 `features`、`DecisionDoc` 对齐、统一 `state.ts` 时间基准、§6.3 删除 `applied_by` 列、降级白名单补 `requires`/`provider_id`、未知 provider 前缀 WARN、`max_red_hearts` 未知跳过、新增可选 `plugin_status.json`；architecture 同步 v1.0-draft.4 |
| 1.0-draft.5 | 2026-11-07 | captain 产品取舍：默认 Profile B、Profile A 需 `--luadebug` 且会放开所有 mod 文件权限、Profile C 推迟 v1.1+、目录统一 `mods/<mod名>/`、契约条件化（不得假设 mod 可写）；architecture 同步 v1.0-draft.5 |
