# 插件侧缺陷修复对照（t13）

> 范围：`plugin/index.js` 的两处实测缺陷（GPT 线实现评审 `needs_revision`）。
> 分支：`agent/t13-plugin-defects`（基于 `main` ba5e61c）。测试：`plugin/tests/plugin.test.mjs`。
> 结论：两条缺陷均已修；新增回归测试在修复前代码上失败，修复后通过；原有 68 项离线断言全部保留并通过。

---

## 1. 缺陷 → 修复 → 测试 对照

| # | 缺陷 | 根因 | 修复 | 回归测试（修复后通过 / 修复前失败） |
| --- | --- | --- | --- | --- |
| D1 | **R1/R2 竞态**：R1 慢、R2 快时，R1 的旧结果最后写入，覆盖 R2 | `runIsaacDecide` 算完就直接 `writeDecisionAtomic`；没有“当前请求是否仍是最新”的判定 | 新增发布闸门 `registerRequest()` + `evaluatePublishGate()`：写锁内比对最新请求（`request_id` / `gen_level_key` / `ts`）与**局面指纹**；旧结果在指纹不变时可绑定最新请求发布（§6.7 #3），新请求已有决策/指纹变/换层才丢弃 | `R1/R2 final request is R2`、`R1/R2 final item is R2 choice`、`R1/R2 old result discarded`、`R1/R2 old result not written`、`R1/R2 new result written`、`rebind result written`、`rebind result request`、`rebind decision request` |
| D1a | 换层后旧层结果覆盖新层 | 同上；只按 `request_id` 判断不够 | 闸门同时比较 `gen_level_key`；不一致记 `level_changed`，拒绝写入 | `level change final key is K2`、`level change old discarded`、`level change old reason` |
| D1b | mod 已写 R2 到 `state.json`，插件还没登记 R2，R1 仍会覆盖 | 只靠进程内登记不够 | 文件模式下写前重读 `state.json`；磁盘 `ts >= 本请求 ts` 且请求不同 → 指纹不变则绑定磁盘最新请求发布，指纹变/换层才丢弃 | `disk rebind written`、`disk rebind result request`、`disk rebind decision request`、`fingerprint change discarded`、`fingerprint change reason` |
| D2 | **发布≠消费**：t13 把 publish 当成 consume，禁止同一 `request_id` 再发 | 误读 §6.7；消费发生在 mod 侧（生成时），插件无法知道 | 撤销 `publishState.consumed`；去重只按 `decision_id`（同 id 忽略）；相同 `request_id`、不同 `decision_id` 允许（§6.7 #6）；消费仍由 mod 的 outstanding/applied 表达 | `same request first written`、`same request second allowed`、`same request second not discarded`、`same request new decision id`、`same request latest wins in file`、`duplicate decision ignored`、`duplicate decision reason` |
| D3 | **路径校验后父目录被换成 junction（TOCTOU）**：校验通过 → 父目录被替换 → 实际写到白名单外 | `resolveBridgeDir` 只校验一次；后续用原路径 `mkdir`/`open`/`rename` | `ensureRealBridgeDir()`：每次写入前 `mkdir → realpath → 与白名单路径逐字比对`，junction/symlink 一律拒绝；用**真实目录**拼 tmp/dest；open 后 `realpath(tmp)` 再确认落在真实目录内；rename 前再次 `realpath(realDir)` 复核 | `junction write rejected`、`junction outside untouched`、`junction not reported as written`、`junction owner token untouched` |
| D4 | **模型忽视 AbortSignal → 调用悬挂**：只做到“迟到不写”，模型永不返回时调用方一直挂着 | 等待模型只用 AbortSignal/内部超时，没有与 validity 挂钩的外部硬截止 | `withDeadline()` 用 `Promise.race` 在 `deadlineAt`（`state.ts + validity_ms - 200ms`）硬切；到点立即走规则兜底（`source=rule, fallback=true, error_code=TIMEOUT`）并放弃等待；迟到结果即使后来到达也不落盘 | `late result returns before model resolves`、`late result fallback written/source/flag/error/reason_code`、`late result decision source/error`、`late result does not overwrite fallback`、`never-resolving model does not hang`、`never-resolving model returns near deadline`、`never-resolving fallback ...` |
| D5 | **校验太松**：`requires` 未知能力、`pool=null`、池级候选 `pedestal_index` 非空都通过 | `requires`/`features` 只校验“数组/字符串”；`trigger.payload` 未校验 `pool`；候选一致性只挡“非空不相等”，没挡“池级应为 null / 指定底座应为同值” | 新增 `checkCapabilityList`：`requires` 未知 → `version_minor_feature`；`features` 仅形状校验；`trigger.payload.pool` 必须非空字符串；池级候选必须全 `null`，指定底座候选必须等于 `trigger.pedestal_index` | `unknown requires rejected`、`unknown requires reason`、`unknown requires publishes rejection`、`unknown requires rejection reason`、`unknown requires rejection written`、`known requires accepted`、`unknown features ignored`、`pool candidate must be null`、`null pool payload rejected`、`specific pedestal candidate must match`、`pedestal index range checked` |
| D5b | **根节点不是对象时崩成 INTERNAL**：`state=null` → `Cannot read properties of null (reading 'request_id')` | `validateStateDoc(null)` 返回非 fatal，随后拒绝决策路径读 `state.request_id` | 非对象文档改为 `fatal('invalid_type')`；`runIsaacDecide` 直接返回 `written:false`，不进入拒绝决策路径 | `null root is fatal`、`null root reason`、`null root not written`、`null root not internal` |
| D6 | **reason 超长仍发布**：280 个 emoji = 1120 字节，超过协议 1024 字节 | t13 错把“上限”当“可截断”；§1.6/§9 明确超限拒绝、不得截断 | `sanitizeReason` 只做单行化，不再截断；`normalizeDraft` 超限抛 `invalid_reason`，模型重试后走规则兜底；兜底句固定短句，不截断用户文本；`assertDecisionLegal` 仍校验字符+字节 | `overlong reason rejected`、`overlong reason fallback`、`overlong reason error`、`overlong reason code`、`overlong reason fallback source`、`overlong fallback reason chars/bytes` |

### D1 / D2 的时序（修复后）

```text
R1 开始（慢） → registerRequest(R1)            latest=R1
R2 开始（快） → registerRequest(R2)            latest=R2
R2 算完       → publishDecision(R2)            gate: latest==R2 → 写盘；consumed+=R2
R1 算完       → publishDecision(R1)            gate: latest==R2 → discarded(superseded)
```

- 闸门与写盘在**同一个写锁**里执行，所以 R1 不可能在 R2 写完之后再写 `decision.json`。
- R1 被丢弃时不写盘、不标 consumed；R2 的 `decision_id` 是唯一被发布的。
- 同一 `request_id` 的第二次调用命中 `already_consumed`，文件保持第一次的 `choice`。

### D3 的防线（修复后）

1. `ensureRealBridgeDir`：`realpath(bridgeDir)` 必须与白名单路径一致；任何 junction/symlink 都会让二者不同 → 拒绝。
2. 所有 tmp/目标路径都基于**真实目录**，不再基于可能被替换的入口路径。
3. `open(tmp)` 后立刻 `realpath(tmp)`，确认临时文件真的在真实目录内；不在则关闭 + 清理 + 拒绝。
4. `rename` 前再次 `realpath(realDir)`，替换窗口内被换掉就拒绝。

> 残余窗口：`realpath` 校验与 `rename` 之间仍有理论上的极小窗口；这是 Node 没有 `openat/renameat` 时的已知限制，已记录在 §4。测试覆盖的是“校验后、写入前”被替换的主路径。

---

## 2. 回归测试证据

### 2.1 修复后（当前 HEAD）

```text
$ node --check plugin/index.js
exit 0

$ node plugin/tests/plugin.test.mjs
111 passed, 0 failed
exit 0
```

111 = 原有 68 项 + 新增 43 项（D1 5 + D1a 3 + D1b 3 + D2 4 + D3 4 + D4 6 + D5 11 + D5b 4 + D6 3）。原有断言未删改语义，只把重复使用的 `request_id` 改成每次唯一（`freshState()`），避免新的一发即作废规则误伤测试。

### 2.2 修复前（HEAD 的 `plugin/index.js`）

```text
$ cmd /c "git show HEAD:plugin/index.js > %TEMP%\isaac-t13-prefix.js"
$ set PLUGIN_ENTRY=%TEMP%\isaac-t13-prefix.js
$ node plugin/tests/plugin.test.mjs
80 passed, 31 failed
```

31 条失败正好对应本任务的全部缺陷（任务书两条 + 追加三条 + 根节点崩溃）：

| 失败断言 | 修复前实际值 | 说明 |
| --- | --- | --- |
| `R1/R2 final request is R2` | `r-race-000001` | 旧 R1 覆盖 R2 |
| `R1/R2 final item is R2 choice` | `4`（R1 的选择） | 同上 |
| `R1/R2 old result discarded` | `undefined` | 旧代码没有 discard 语义 |
| `R1/R2 old result not written` | `true` | 旧代码照写 |
| `consume second discarded` / `reason` | `undefined` | 同一 request 可重复发布 |
| `consume file keeps first choice` | `4`（第二次的选择） | 第二次覆盖第一次 |
| `level change final key is K2` | `f1:r1:treasure:p0:aaaa` | 旧层覆盖新层 |
| `level change old discarded` / `reason` | `undefined` | 无换层判定 |
| `disk supersede discarded` / `reason` | `undefined` | 不重读 state.json |
| `disk supersede not written` | `true` | 照写 |
| `junction write rejected` | `true` | 跟随 junction 写成功 |
| `junction outside untouched` | `1`（白名单外出现 decision.json） | TOCTOU 实际发生 |
| `junction not reported as written` | `true` | 谎报成功 |
| `late model result discarded` / `reason` | `undefined` | 用完 AbortSignal 就信，迟到的结果照写 |
| `late model result error` | `TIMEOUT` | 虽报超时，但 `written=true` |
| `late model result not written` | `true` | 过期 fallback 仍落盘 |
| `late model result leaves no decision` | `true`（decision.json 存在） | 缺陷 A 的实际表现 |
| `unknown requires rejected` / `reason` | `ok=true` / `undefined` | 未知能力被放行 |
| `unknown requires publishes rejection` / `rejection reason` | `valid=true` / `null` | 当成正常请求调模型 |
| `pool candidate must be null` | `undefined` | 池级候选 `pedestal_index=1` 被放行 |
| `null pool payload rejected` | `undefined` | `pool:null` 被放行 |
| `specific pedestal candidate must match` | `undefined` | 指定底座候选为 `null` 被放行 |
| `null root is fatal` | `false` | 非对象文档走非 fatal 路径 |
| `null root not internal` | `true` | 随后崩成 `INTERNAL/internal_error` |
| `reason bytes capped` | `1120` | 280 个 emoji 未按字节截断 |

> 复现命令（PowerShell）：先 `git show HEAD:plugin/index.js` 导出修复前文件，设 `PLUGIN_ENTRY` 指向它，再跑同一测试文件。`PLUGIN_ENTRY` 只用于回归对照，正常测试不需要。

### 2.3 独立评审脚本（修复后）

把 `E:\Temp\isaac-review-deepseek.mjs` 的 `repo` 指向本分支后原样运行（脚本本身不改实现）：

| 评审用例 | 修复后结果 |
| --- | --- |
| `unknown-requires` | `ok:false`，`version_minor_feature` |
| `pool-target-mismatch` | `ok:false`，`state_invalid` |
| `unknown-red-capacity` | `choice.item_id=22`（非缺陷；protocol §6.5 缺省 `max_red_hearts` 仍优先 heal） |
| `malformed-root` | `fatal:true`，`runIsaacDecide` 返回 `written:false`，不再 INTERNAL |
| `reason-byte-limit` | `chars=256`、`bytes=1024`（原 280/1120） |
| `ignored-model-abort` | `elapsed=912ms`、`validity=600ms`、`written:false` |
| `older-call-overwrites-newer` | `afterNew=r-new-0002`、`afterOld=r-new-0002`（旧 R1 不再覆盖） |
| `junction-swap-after-validation` | `written:false`、`outsideDecision:false` |

> A 的边界：`requireFresh` 只加在**模型成功 / 模型失败兜底**两条路径；如果 state 在请求前就已过期、根本没有调用模型，仍按原行为写 `TIMEOUT` 兜底（t6 mock 场景 4 依赖该行为，且会被 mod 按 `late` 丢弃）。若要把“过期一律不写”扩展到无模型路径，需要同步改 t6 的期望。

---

## 3. 与 t12 所有者令牌的兼容

t12 在 mod 侧新增了桥目录所有者令牌 `.isaac_agent_owner`（mod 写入前后各校验一次，不一致则判定目录被替换并停写）。t13 的修复**不删除、不改写、不清空**该文件：

- `ensureRealBridgeDir` 只做 `mkdir` / `realpath` / `lstat`；不遍历、不清理目录内容。
- 写入只碰 `state.json`（读）、`decision.json`（原子替换）与自己的 `decision.json.tmp.*`（失败时清理）。
- 测试模拟“原目录被整体挪走 + junction 顶替”，断言 `bridge-old/.isaac_agent_owner` 内容原样保留。
- 代码注释已引用该约束（`ensureRealBridgeDir` 头注释），避免后续维护者加目录清理逻辑。

> 不使用“重写/清空目录”来防 TOCTOU，正是为了避免把 mod 的令牌清掉导致永久停写。

---

## 4. 与独立评审证据 / `impl-review.md` 的对账

**截至 2026-11-07 09:55，`docs/reviews/impl-review.md` 未落盘**：

- `main` / `agent/t8-claude-review` 的 `docs/reviews/` 只有 `tri-party.md`；
- 工作区 `E:\Yuki\工作\*` 下递归查找 `impl-review.md` 无结果；
- t10（GPT 主评 + DeepSeek 复评）仍在进行中，尚未提交评审文档。

另有一份独立评审证据已落盘在仓库外：`E:\Temp\isaac-review-ds-x4yoFH\results.json`（复现脚本 `E:\Temp\isaac-review-deepseek.mjs`，未改实现）。本任务已对账其中全部插件侧条目：

| 评审条目 | 结论 | 对应测试 |
| --- | --- | --- |
| `unknown-requires` | 已修（D5） | `unknown requires rejected` / `reason` / `publishes rejection` / `rejection reason` |
| `pool-target-mismatch` | 已修（D5） | `pool candidate must be null` |
| `malformed-root` | 已修（D5b，原为 INTERNAL 崩溃） | `null root is fatal` / `reason` / `not written` / `not internal` |
| `reason-byte-limit` | 已修（D6） | `reason chars capped` / `bytes capped` |
| `ignored-model-abort` | 已修（D4） | `late model result discarded` / `reason` / `error` / `not written` |
| `older-call-overwrites-newer` | 已修（D1） | `R1/R2 final request is R2` / `final item` / `old result discarded` |
| `junction-swap-after-validation` | 已修（D3） | `junction write rejected` / `outside untouched` / `owner token untouched` |
| `pool=null`（任务书追加） | 已修（D5） | `null pool payload rejected` |
| `unknown-red-capacity` | **非缺陷**：protocol §6.5 明确“`max_red_hearts` 缺省视为未知，红心为 0 时仍优先 heal”，返回 22 是正确行为 | 无（保持现状） |

以下为**已知未修**（明确超出 t13 范围，不在本次改动内）：

| 已知未修 | 影响 | 备注 |
| --- | --- | --- |
| 未实现 `bridge.lock`（protocol §1.10） | 多个 DSH 进程同时跑时，进程内锁挡不住跨进程写 | on-demand 工具用进程内写队列 + 发布闸门；常驻宿主接入时需补锁与 pid 存活探测 |
| 未实现 §6.7 的局面指纹缓存/去重 | 同一 `gen_level_key` 的多次刷新仍会各算一次；只保证旧结果不覆盖新结果 | 新增闸门解决“覆盖”，未解决“重复调用模型” |
| `isaac_state` 读路径未做写入侧的 realpath 二次校验 | 读取时父目录被换 junction 可能读到白名单外 `state.json` | 只读、影响面小于写；后续可与写侧共用 `ensureRealBridgeDir` |
| 模型流完全不返回（既不 yield 也不结束） | `for await` 会被挂住；AbortSignal 只能通知，不能强制结束迭代器 | 已覆盖“迟到但最终返回”的实测缺陷；彻底解决需要可取消的流包装或宿主级超时 |
| 插件不读取/校验 `applied.json` | “消费一次”只是插件侧发布语义，mod 实际是否消费仍以 mod 为准 | 插件不写 applied，避免伪造回执 |
| viewer 倾向权重（t5）未接入 `isaac_decide` | 当前 `viewer` 仍只接受 `votes`/`note` | t5 设计已给出 `weights/label/sample_n` 扩展，属后续任务 |

> 如果 t10/t11 的 `impl-review.md` 后续落盘，应按本文件 §1 的格式追加“评审条目 → 测试/修复”对照；未修的条目保留在 §4 表格，不删除。

---

## 5. 改动文件

| 文件 | 改动 |
| --- | --- |
| `plugin/index.js` | 发布闸门（`publishState` / `registerRequest` / `evaluatePublishGate` / `publishDecision`）、消费一次即作废、`ensureRealBridgeDir` + 真实目录写入、丢弃日志与 `discarded` 返回 |
| `plugin/tests/plugin.test.mjs` | 原有 68 项断言迁移入库 + 43 项回归（R1/R2、换层、磁盘复核、消费、junction、令牌、迟到、requires/pool/pedestal、reason 字节、null 根） |
| `plugin/package.json` | `scripts.test`、`files` 加入 `tests` |
| `docs/reviews/plugin-fixes-t13.md` | 本对照说明 |

---

## 6. 验证命令

```bash
node --check plugin/index.js
node plugin/tests/plugin.test.mjs
# 或
npm --prefix plugin test
```

预期：`node --check` 退出 0；测试 `111 passed, 0 failed`，退出 0。

---

## 7. t18/t19 后续：draft.5 字段补齐

t18 补齐 `decision.session_id` 回显与 `plugin_status.json`；t19 修正本文件 D2/D4/D6 的过度收紧；t22 补 M1/M4/M6。测试现为 **218 项**（原 111 + t18 46 + t19 25 + t22 36）。完整「已实现/未实现」清单见 [draft5-plugin-fields.md](draft5-plugin-fields.md)。本文件 §1 的 D1–D6 已按 §8 更新。

---

## 8. 对独立评审三条的处置与依据（t19）

> 先核对 `docs/protocol.md`（1.0-draft.5）原文，再决定改代码还是反驳。

### D2：发布 ≠ 消费（采纳，撤销 t13 的 consumed）

**协议依据**：

- §6.7 第 6 条：「相同 `decision_id` 重复到达 → 忽略；相同 `request_id`、不同 `decision_id` → 允许，按接收时间取最新。」
- §6.7 第 5 条：消费发生在**生成时**（mod 侧）；「一次生成恰好消费一个 choice」由 mod 的 `outstanding` / `applied.json` 表达。
- §6.7 第 3 条：「为 R1 算出的结果可以在 R2 到达后发布，但只能绑定到发布时最新的请求（R2），并使用新的 `decision_id`；若指纹已变，丢弃旧结果。」

**处置**：

1. 删除 `publishState.consumed`；发布成功不再等于消费。
2. 去重只按 `decision_id`：同一 `decision_id` 再次发布 → `discarded/duplicate_decision`；相同 `request_id`、不同 `decision_id` → 允许。
3. 旧结果若命中最新请求且局面指纹（§6.7 #2：`session_id`、`gen_level_key`、血量、角色、items id/count、candidates item_id）不变 → **绑定最新请求**发布（新 `decision_id` 保留）；若新请求已有决策 → 丢弃（避免更慢的旧结果盖掉新结果）；指纹变/换层 → 丢弃。
4. 消费仍由 mod 侧 `outstanding` / `applied.json` 表达；插件不伪造消费回执。

**测试**：`same request first written`、`same request second allowed`、`same request second not discarded`、`same request new decision id`、`same request latest wins in file`、`duplicate decision first written`、`duplicate decision ignored`、`duplicate decision reason`、`disk rebind written/result request/decision request`、`rebind result/decision request`、`fingerprint change discarded/reason`。

### D4：硬截止（采纳，补 `Promise.race`）

**协议依据**：§6.1 给插件落盘预算（`validity_ms - 200ms`），§6.2 要求 mod 永不阻塞；插件不能因为模型不响应而把调用挂住。

**处置**：

- `withDeadline(promise, deadlineAt)` 用 `Promise.race` 在 `state.ts + validity_ms - 200ms` 硬切；到点立即走规则兜底（`source=rule, fallback=true, error_code=TIMEOUT, reason_code=timeout`），并放弃等待。
- 底层模型 promise 之后即使返回/拒绝，由 `Promise.race` 的处理器吸收，不再落盘；`publishedDecisionIds` 也不会记录它。
- 兜底写入仍在 validity 窗口内（200ms 写盘余量），不会变成 `late`。

**测试**：`late result returns before model resolves`（<650ms）、`late result fallback written/source/flag/error/reason_code`、`late result does not overwrite fallback`、`never-resolving model does not hang`、`never-resolving model returns near deadline`（<800ms）、`never-resolving fallback ...`、`never-resolving decision source/error`。

### D6：reason 超限（采纳“拒绝”，撤销 t13 的截断）

**协议依据**：

- §1.6：「超限即 `VALIDATION` / `out_of_range`，**不得截断后继续**（截断会让两端对同一请求理解不一致）。」
- §9：「大小上限：见 §1.6；**超限拒绝，不截断**。」
- §3.6：`invalid_reason` 归类 `VALIDATION`。

**处置**：

- `sanitizeReason` 只做单行化/控制字符清理，**不截断**。
- `normalizeDraft` 检查 280 字符 + 1024 UTF-8 字节；超限抛 `DraftError('invalid_reason')` → 模型重试一次，仍失败走规则兜底（`error_code=VALIDATION, reason_code=invalid_reason`）。
- 内部兜底句固定短（`rule.reason；suffix`）；若未来异常超限，改用固定短句 `本地规则兜底`，**不截断用户/模型文本**。
- 协议本身已明确“拒绝、不截断”，无需修改 protocol；t13 文档中“截断”的描述已在本文件 §1 修正。

**测试**：`overlong reason rejected`、`overlong reason fallback`、`overlong reason error`、`overlong reason code`、`overlong reason fallback source`、`overlong fallback reason chars/bytes`。

### 结果

```text
# t18 代码（3fcb2d3）跑 t19 测试
137 passed, 45 failed

# t19 代码
182 passed, 0 failed
```

---

## 9. t22：M1 / M4 / M6

第二线评审（t14）插件侧三条已修：未知 `provider_id` 前缀按 §3.5 接受并写 `x_provider_unknown`；`bridge.lock` 按 §1.10 实现（pid/started_at/heartbeat_at、5s 心跳、30s TTL、僵死抢占、退出释放、双进程测试）；补 major 低/高与 rename EPERM 写失败测试。完整对照见 [t22-m1-m4-m6.md](t22-m1-m4-m6.md)。

测试：t19 代码 **196 passed / 22 failed**；t22 代码 **218 passed / 0 failed**。
