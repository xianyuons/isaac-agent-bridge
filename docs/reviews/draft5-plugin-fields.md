# draft.5 插件侧产出清单（t18）

> 依据：`docs/protocol.md` **1.0-draft.5**（t8 Claude 补审 + captain 产品取舍，commit `fb9e25c`）与 `docs/architecture.md` v1.0-draft.5。
> 范围：**DSH 插件侧必须产出/回显的字段**。mod 侧产出（state/event/applied、`actual_item_id`、气泡）不在此表。
> 分支：`agent/t18-draft5-fields`（基于 `agent/t13-plugin-defects` 并合入 t8 draft.5 文档）。测试：`plugin/tests/plugin.test.mjs`（156 项）。

---

## 0. 结论

- **已实现**：`decision.session_id` 回显、`plugin_status.json`（含任务要求的运行状态扩展）、draft.5 对 decision 的既有字段要求。
- **未实现（已知）**：`bridge.lock`（因此 `plugin_status.x_runtime.lock_held` 恒为 `false`，只代表“本插件未持锁”）、按 `(session_id, gen_level_key)` 的缓存/指纹、`applied.json` 回读、viewer 倾向接入、读路径 TOCTOU、模型流完全不返回时的强制取消。
- 测试：修复前（t13 代码）**117 passed / 39 failed**；修复后 **156 passed / 0 failed**。

---

## 1. `decision` 根字段

draft.5 §3.1 要求：

| 字段 | 状态 | 实现/测试 |
| --- | --- | --- |
| `protocol_version` | ✅ | 常量 `1.0`；所有 decision 自检 |
| `session_id` | ✅ **新增** | `makeDecisionDoc` 从 `state.session_id` 原样回显；`assertDecisionLegal` 校验格式与相等；测试 `decision echoes session_id` / `tool result echoes session_id` / `decision session mismatch rejected` |
| `request_id` | ✅ | 回显 state；既有闸门按 `(request_id, gen_level_key)` 判新旧 |
| `decision_id` | ✅ | 每次发布新值；不可复用 |
| `gen_level_key` | ✅ | 回显 state；`assertDecisionLegal` 校验 |
| `ts` | ✅ | 写盘时刻 epoch ms |
| `error_code` | ✅ | 五类或 null；non-null ⟹ fallback |
| `features` | ✅（空数组） | 插件当前不声明额外能力；draft.5 允许可选 |
| `requires` | ✅（空数组） | 插件对 mod 无额外硬要求；mod 侧 `requires` 按 §7.4 校验（t13 已实现） |
| `valid` | ✅ | 正常/兜底 true；拒绝 false |
| `decision.choice` | ✅ | item 必须在候选池；action 仅 `skip`（回调 62 不使用 `reroll`） |
| `decision.reason` | ✅ | 单行；**280 字符 + 1024 UTF-8 字节**双截断（t13 已修） |
| `decision.confidence` | ✅ | 0..1；模型缺省 0.6，规则 1.0 |
| `decision.fallback` | ✅ | 主路径 false；规则/安全跳过 true |
| `decision.source` | ✅ | `llm` / `rule` |
| `decision.provider_id` | ✅ | 前缀与 source 交叉校验 |
| `decision.reason_code` | ✅ | 注册表；`valid:false` 必填 |
| `decision.elapsed_ms` | ✅ | 0..60000 |

### 1.1 `session_id` 的缺失/非法降级

draft.5 §1.5：`session_id` 为**必填**，decision 必须回显；不一致 mod 拒绝（`session_mismatch`）。

插件策略（**不静默丢字段**）：

| 情况 | 行为 | 证据 |
| --- | --- | --- |
| state 有合法 `session_id` | 原样写入 decision 根 | `decision echoes session_id` |
| state 缺 `session_id` | `validateStateDoc` 返回 **fatal `missing_field`**；不写 decision（写了也会被 mod 拒绝）；`plugin_status.json` 记 `status:"refused"`、`error_code:"VALIDATION"`、`reason_code:"missing_field"`；工具结果 `ok:false, written:false` | `missing session_id fatal` / `reason` / `not written` / `ok=false`；`missing session status refused/error/reason/unavailable` |
| `session_id` 格式非法（长度/字符） | 同上，`missing_field` | `invalid session id format rejected` |
| decision 自检时 session 与 state 不一致 | 抛 `INTERNAL/internal_error`，拒绝发布 | `decision session mismatch rejected` |

> 为什么是 fatal 而不是写一份 `valid:false`：`valid:false` 仍需要合法的 `session_id` 回显，缺它连拒绝信封都不成立；mod 只能按超时兜底。fatal + status 是唯一显式且不伪造身份的路径。

---

## 2. `plugin_status.json`

draft.5 §1.11 定义（插件写、mod/QA 读，可选诊断，不替代 `applied.json`，不承载密钥）。

### 2.1 基础字段（draft.5 必填）

| 字段 | 状态 | 说明 |
| --- | --- | --- |
| `protocol_version` | ✅ | `1.0` |
| `plugin_version` | ✅ | 读 `PLUGIN_VERSION`（当前 `0.1.0`） |
| `ts` | ✅ | 每次写盘时刻 |
| `status` | ✅ | `ready` / `degraded` / `refused` |
| `error_code` | ✅ | 五类或 null；与 `status` 同步 |
| `reason_code` | ✅ | 最近失败原因；ready 为 null |
| `detail` | ✅ | `last: <reason_code>`；不写路径/密钥/弹幕 |

### 2.2 任务要求的运行状态（`x_runtime`，draft.5 §1.7 扩展）

```json
{
  "protocol_version": "1.0",
  "plugin_version": "0.1.0",
  "ts": 1793982600000,
  "status": "ready",
  "error_code": null,
  "reason_code": null,
  "detail": null,
  "x_runtime": {
    "available": true,
    "current_model": { "provider": "deepseek", "model": "deepseek-chat" },
    "last_success_ts": 1793982600100,
    "last_failure_ts": null,
    "error_code_counts": { "IO": 0, "TIMEOUT": 0, "VALIDATION": 0, "MODEL": 0, "INTERNAL": 0 },
    "bridge_dir": "C:\\Users\\<user>\\AppData\\Local\\IsaacAgent",
    "lock_held": false,
    "lock_mode": "process-local"
  }
}
```

| 扩展字段 | 含义 |
| --- | --- |
| `available` | `status !== "refused"`；degraded 仍可用（走规则/兜底） |
| `current_model` | 最近一次决策解析到的 provider/model；未知为 null |
| `last_success_ts` / `last_failure_ts` | 最近一次成功发布 / 失败时刻（epoch ms） |
| `error_code_counts` | 进程内累计五类错误计数（不清零，重启归零） |
| `bridge_dir` | 当前桥目录绝对路径（任务要求；仅本地诊断文件） |
| `lock_held` | 当前是否持有 `bridge.lock`；**本插件未实现 bridge.lock，恒 false** |
| `lock_mode` | `process-local`：用进程内写队列 + 发布闸门串行化 |

### 2.3 状态机与写入时机

| 事件 | `status` | `error_code` / `reason_code` | 计数 |
| --- | --- | --- | --- |
| 插件 `apply` 启动 | `ready` | null | 0 |
| 正常 llm decision | `ready` | null | 不变 |
| 安全跳过（`player_dead` / `no_candidate`，`error_code:null`） | `ready` | null | 不变 |
| 规则兜底（模型失败/超时/降级） | `degraded` | 兜底的 error_code / reason_code | 对应 +1 |
| `valid:false` 拒绝决策 | `refused` | `VALIDATION` / 具体 reason | `VALIDATION` +1 |
| 信封不可读（version major / 缺 session/request） | `refused` | `VALIDATION` / 具体 reason | `VALIDATION` +1 |
| 读 state IO 失败 | `degraded` | `IO` / `io_error` | `IO` +1 |
| 迟到/被新请求取代而丢弃 | 保持当前 status | 不变 | 不变（不是插件故障） |
| 后续成功 | `ready` | null | 历史计数保留 |

### 2.4 写入约束

- **原子写**：同目录 `plugin_status.json.tmp.<pid>.<nonce>` → `fsync` → `rename`；失败保留旧文件并清理 tmp。
- **路径白名单**：只允许 `state.json` / `decision.json` / `plugin_status.json`；仍走 `ensureRealBridgeDir` 的 realpath/junction 校验。
- **大小上限**：8 KiB；超限拒绝写。
- **无密钥**：不写 `SESSDATA`、token、cookie、API key；`detail` 不含路径/密钥。
- **不影响决策**：状态写失败只吞掉并保留工具结果；不得因为 status 写失败改变 decision。
- **不清理目录**：不删除/改写 `.isaac_agent_owner`；只写自己的 status/tmp。

### 2.5 mod 侧读取语义（draft.5 §6.3）

无决策可用时 mod **应该** 读一次 `plugin_status.json`：`refused`/`degraded` 时把其 `error_code`/`reason_code` 写进 `applied.json`；读不到才记 `TIMEOUT/no_fresh_decision`。本插件已按此产出，mod 侧由 t12 实现。

---

## 3. draft.5 其它“插件侧必须产出”的核对

| 要求 | 状态 | 说明 |
| --- | --- | --- |
| decision 必须回显 `session_id` | ✅ | 见 §1 |
| decision `reason` 280 字符 / 1024 字节 | ✅ | t13 D6 |
| `requires` 未知能力拒绝（state→plugin） | ✅ | t13 D5；`version_minor_feature` |
| `plugin_status.json` 基础字段 | ✅ | 见 §2 |
| 启动/降级/恢复更新 status | ✅ | `apply` + 每次工具调用 |
| `version_major` 时写 `refused/version_major` | ✅ | 测试 `major mismatch status refused/error/reason` |
| decision `features`/`requires` 保留 | ✅ | 输出空数组 |
| decision `provider_id` 前缀与 source 一致 | ✅ | t13 自检 |
| `bridge.lock` 单写者锁 | ❌ | 未实现；见 §4 |
| 按 `(session_id, gen_level_key)` 缓存/指纹 | ❌ | 未实现；只做发布闸门 |
| 读 `applied.json` 做消费确认 | ❌ | 插件不写/不读 applied |
| viewer 倾向权重接入 | ❌ | 当前 `viewer` 只接受 votes/note |
| 读路径 realpath 二次校验 | ❌ | 写路径已修；读路径仅启动校验 |
| 模型流完全不返回时强制取消 | ❌ | AbortSignal 不能强制结束不合作的迭代器 |

---

## 4. 已知未实现（明确不在 t18）

1. **`bridge.lock`**：插件按调用执行、非常驻；用进程内写队列 + 发布闸门。因此 `plugin_status.x_runtime.lock_held` 恒 `false`、`lock_mode="process-local"`。多 DSH 进程同时跑仍可能互写。
2. **§6.7 的 session 级缓存/指纹**：没有按 `(session_id, gen_level_key)` 合并/复用结果；只保证旧结果不覆盖新结果、同一 request 不重复发布。
3. **`applied.json` 回读**：插件不读取 mod 的消费回执；“消费一次即作废”是插件侧发布语义。
4. **viewer 倾向**：t5 设计已给出 `weights/label/sample_n`，尚未接入 `isaac_decide`。
5. **读路径 TOCTOU**：`isaac_state` 仍只在入口校验一次；父目录被换 junction 的读风险未消除（写路径已修）。
6. **模型流完全不返回**：若适配器既不 yield 也不结束，`for await` 无法被 AbortSignal 强制结束；需要可取消的流包装或宿主级超时。
7. **`capabilities`**：draft.4 已统一为 `features`；插件不读也不写 `state.capabilities`（旧字段忽略）。
8. **`actual_item_id`**：mod 的回执字段，插件不产出。

---

## 5. 测试对照

### 5.1 新增用例（相对 t13 的 111 项）

| 组 | 断言（示例） |
| --- | --- |
| session_id 回显 | `decision echoes session_id`、`tool result echoes session_id` |
| session_id 降级 | `missing session_id fatal/reason/not written/ok=false`、`missing session status refused/error/reason/unavailable`、`invalid session id format rejected` |
| decision 自检 | `decision session mismatch rejected` |
| status 基础 | `initial status write ok/ready/error null/bridge dir`、`status ready/protocol version/plugin version/available/current model/bridge dir/lock held/error counts/last success/size/no secret/no tmp` |
| status 降级/恢复 | `status degraded after fallback/error/reason/count/available`、`status ready after recovery/clears error/keeps historical count/last success` |
| status 拒绝 | `major mismatch status refused/error/reason/unavailable` |
| 路径白名单 | `unsafe status filename rejected` |

### 5.2 修复前/后

```text
# 修复前（t13 代码）
$ cmd /c "git show bfb0734:plugin/index.js > %TEMP%\isaac-t18-prefix.js"
$ set PLUGIN_ENTRY=%TEMP%\isaac-t18-prefix.js
$ node plugin/tests/plugin.test.mjs
117 passed, 39 failed

# 修复后
$ node --check plugin/index.js      # exit 0
$ node plugin/tests/plugin.test.mjs # 156 passed, 0 failed
```

39 条失败全部来自新增的 session_id / plugin_status 断言；原有 111 项仍全过。

---

## 6. 验证命令

```bash
node --check plugin/index.js
node plugin/tests/plugin.test.mjs
npm --prefix plugin test
python tools/mock_e2e.py
```

预期：`156 passed, 0 failed`；mock 4/4 场景 52/52 断言。
