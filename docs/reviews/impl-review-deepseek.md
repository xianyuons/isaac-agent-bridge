# 实现第二线复评（DeepSeek 线）

> **这是复评（re-review），不是盲评。** 任务说明已告知 GPT 线存在 15 项实现评审；本轮也已经读到三方架构评审的 GPT/Claude/DeepSeek 结论。不能把本轮判断包装成互不知情的独立共识。
>
> **输入缺口：** 截至本稿写入时，指定的 `docs/reviews/impl-review.md` 在原仓库、整合树及 t10 工作树都不存在，`git log --all -- docs/reviews/impl-review.md` 也无记录。已请求主控提供原稿。本稿先给可复现的实现检查，**暂不宣称下面条目是 GPT 没提的新发现**；收到原稿后必须补逐项确认/反驳/边界对照，才能满足完整复评交付。
>
> 日期：2026-11-07（GMT+8）。审查基线：`7d4e10271292628716e095dd5174a109052902e4`，只读实现。协议/架构按 **draft.5**，不是 Lua 头注释中的 draft.3。Lua 实际为 2183 行，插件 1476 行；Lua 测试实际在根目录 `tests/`，不在 `mods/isaac_agent/tests/`。
>
> 工作树隔离：原任务目录停在 `agent/t4-plugin-tools`、无 Lua；实际整合树为 `isaac-agent-main`。复评专用分支 `review-deepseek` 从上述基线建立，只写本文件，未修改实现、测试、凭据或主控的文档改动。

## 结论与证据边界

**不通过。** 现有离线绿灯不能证明 draft.5 的单次消费、最终回执和超时隔离。原基线已复现重复消费、过期缓存阻止刷新、等待期间junction切换外写；并行修复后的确认见§9，不继续把已修分支当未修。修后仍最严重的三项是：**同K其他刷新请求与fallback生成后的迟到仍被接受；非合作模型流没有硬截止；核验超窗仍留下applied/llm假成功回执。**

本轮做了静态逐段读取与离线故障注入，没有运行游戏，没有证明 REPENTOGON 的真实回调签名、字体和文件沙箱能力。没有读取 API key，也没有调用真实模型。临时脚本只在 `E:\Temp\`，使用原实现及原 Lua 测试桩；没有把重写的算法当作实现测试。

## 1. 实际运行的检查

| 命令/环境 | 实际结果 | 能证明什么，不能证明什么 |
| --- | --- | --- |
| `node --check plugin/index.js`；Node v24.22.2 | exit 0 | ESM 语法可解析，不代表协议正确 |
| `python -m unittest discover -v`；Python 3.11.1 | exit 0，**Ran 0 tests** | 根目录默认发现没有发现测试，不能报“单元测试通过” |
| `python -m unittest discover -s tools/tests -v` | exit 0，15/15 | 只测弹幕模拟器，不覆盖桥接故障 |
| `python tests/run_lua_test.py` | exit 0，74/74 断言 | 使用已安装的 **lupa Lua 5.4**；PATH 没有 lua/luajit，未运行 lua.exe 或游戏 Lua |
| `python tools/mock_e2e.py` | exit 0，4/4 场景、52/52 断言 | 调真实插件、假模型，不执行真实 Lua 消费端 |
| `node E:\Temp\isaac-review-deepseek.mjs` | exit 0，逐项结果见 §8 | 调 `__testing`，串并发/超时/路径变更故障注入 |
| `python E:\Temp\isaac-review-deepseek-lua.py` | exit 0，逐项结果见 §8 | lupa 内存加载原 Lua 与原测试 fixture，避免中文路径/盘符依赖 |

`README.md:303–304` 明说插件开发期的 68 断言 harness 在仓库外，故本轮没有将其计入可复跑测试。第一次临时 Lua 复现误依赖已不存在的 Z: 映射，失败后已改用内存加载原源码并重跑成功；不将那次失败算实现缺陷。报告结果不依赖该盘符。

## 2. Q1：契约字段语义

### DS-01（high）：硬要求 `requires` 完全不校验，目标一致性又只在两边非 null 时检查

- **位置：** `plugin/index.js:384–533 validateStateDoc`；候选目标检查在 `512–520`。draft.5 protocol §2.1/§7.4 明确 `requires` 是能力硬依赖、池级候选与 trigger 必须同为 null。
- **证据：** `requires=['unsupported:must']` 返回 `{ok:true}`；`trigger.pedestal_index=null` 配 `candidates[0].pedestal_index=1` 也返回 `{ok:true}`。`features` 不作行为硬依赖本身是正确的；问题是 `requires` 也被当成无关信息。
- **应该改成什么：** 在 `validateStateDoc` 信封阶段区分 features 与 requires；校验类型/数量/字符串长度，对未知硬要求返回 `VALIDATION/version_minor_feature`。目标一致性用包含 null 的严格相等；池级还校验 `trigger.payload.pool`。落到这三个分支分别断言拒绝码及模型调用次数为零。
- **不改会怎样：** 需要新能力的请求会被旧实现按旧语义执行；混目标文档进入模型，候选属于哪个目标不再可靠。

### DS-02（medium）：未知名称被省略而非 null；快照读取失败被伪装成正常局面

- **位置：** Lua `main.lua:724–750 read_player`、`803–817 item_name`、`1004–1010 build_candidates`、`1079–1156 build_state_doc`；插件名称校验 `index.js:460–462,522–524`。
- **证据：** `item_name` 返回 nil 时，Lua table 的 `name=nil` 消失，原编码器输出缺少 `items[].name` 与 `candidates[].name`，而协议要求显式 string|null。把原桩的 `GetHearts()` 改为抛错，导出仍为 `red_hearts=0,error_code=null`；`snap.ok` 也不反映各子读取失败。
- **应该改成什么：** `name = item_name(id) or JSON_NULL`；未知的可选整数应省略，不输出 null。逐个收集关键快照读取错误，按 §6.4 设置 state 的错误/原因码；关键字段不足则显式拒绝，不用 0 冒充成功。用原 `build_state_doc` 的编码结果喂 `validateStateDoc`，断言未知名称仍合法，读取失败时不调 llm。
- **不改会怎样：** 真实 mod 道具缺名称时，自己产出的 state 被插件拒绝；读心量失败则看起来像“零红心”，模型和规则依据伪造事实选择。

### DS-03（medium）：安全 skip 被 Lua 的 `and nil or` 写成 TIMEOUT

- **位置：** `main.lua:1798–1835 make_applied_local`，尤其 `1828 error_code = guard_skip and nil or err_code`；协议 §5.4/§6.5。
- **证据：** 玩家已死生成一次，本地回执实测 `reason_code=player_dead,error_code=TIMEOUT,provider_id=rule:local`。Lua 中前半段的 nil 会继续走 `or err_code`，不能表达三元条件。
- **应该改成什么：** 用显式 if 将 guard 的 error_code 置 nil，并将实际安全路径 provider 置 `rule:guard`，安全 skip 不引用无关 rejected decision。对 `player_dead` 与空候选两个原分支分别断言编码后 error_code 为 null。
- **不改会怎样：** 正常安全跳过被报为故障，applied 的语义与真值表冲突；统计把死亡/空池当成超时。

### 其余 draft.5 对齐项（已有架构问题的实现核对，待 GPT 实现稿对照）

| 严重度 | 定位与判断 | 应该改成什么 | 不改会怎样 |
| --- | --- | --- | --- |
| high | `main.lua:1116` 只给 state 写 session；`1240 validate_decision` 不校验 session；event `1645`、applied `1580`、插件 decision `940` 都缺 session | 四类信封统一 session，拒绝不匹配；不是靠 request_id 随机性替代契约 | 跨局隔离不能由协议检查保证 |
| medium | Lua `1125 capabilities` 为 draft.5 已删除的非 x_ 字段；插件 `641–671 buildStateSummary` 读的是 GameState，却从其上找 trigger/capabilities，丢根信封 trigger 与 features | 删除 capabilities，正确传 StateDoc 的 trigger/features；消费既有 enrichments 时传给 provider | 扩展的真实上下文丢失，输出自己发明旧字段 |
| medium | Lua `1518`/插件 `591` 把缺省 max_red_hearts 当能回血；旧架构已指出未知不等于正值 | 严格存在且 >0 才走 heal；未知值跳过 R3 | 无红心容器未知角色会误选 heal |
| medium | Lua `1223` 版本只前缀匹配、`1269–1273` error_code 只验字符串；`1228` provider 仅验前缀且拒绝未知前缀 | 完整格式、五类错误枚举；draft.5 的未知 provider 前缀只 WARN，已知矛盾仍拒绝 | `1.0garbage`/ALIEN 错误被接受，合法未来 provider 被拒绝 |
| low | plugin_status 在 draft.5 §1.11 是可选/SHOULD，代码没有实现 | 作为诊断缺口记录，不能仅因没有文件就报 MUST 违约 | 失败仍可能只见 TIMEOUT，诊断较差 |

## 3. Q2：五条失败路径，哪些没有测试、哪些看起来测了

| 失败路径 | 定位、严重度 | 现有实际覆盖/缺口 | 应该改成什么（精确分支） | 不改会怎样 |
| --- | --- | --- | --- | --- |
| 超时 | **high**；Lua `on_update:2063`、插件 `callModelOnce:755–805` | Lua T06 `tests/lua_logic_test.lua:447–458` 不推进时钟，实际上是“无缓存立即兜底”；mock timeout 是 state 已过期，根本不调用模型。都没测调用中超时或已接收后过期 | 在 `callModelOnce` 注入忽略 signal 的挂起迭代器；在 `on_update` 收到决策后推进时钟超 validity/2/validity，断言刷新及硬退出 | 全绿仍可无限等或长期持有死缓存 |
| 非法 id | **medium**；Lua `1327–1336`/插件 `714–720` | T04 不存在 collectible，T05 合法但池外；mock 连续两次池外输出后兜底，是真覆盖。漏了已死亡但模型仍返回 item、候选缓存失效后的 id | 对 `consume` 死亡变化与 `ensure_candidates` 池内容变化分别注入；断言不复用旧 id，精确核对 `invalid_id`，别把池外报 invalid_choice | 生命周期变化后仍可能返回不该用的 item |
| 协议版本不匹配 | **medium**；Lua `1243–1246`/插件 `388–400` | T07 仅 Lua major=2 的拒绝；没有插件 major、未知 requires、patch/畸形字符串边界 | 调 `runIsaacDecide` 传 major=2，断言旧 decision 不变且模型零调用；另测 requires 与完整版本格式 | 一侧拒绝不代表两侧都兼容 |
| 写入失败 | **high**；Lua `567–598`/插件 `331–349` | 仓库中只有正常原子写与无 tmp 检查，没有强制 open/flush/close/rename 失败用例。**这一条只有错误分支、没有仓库失败测试** | 在原 `bridge_write_raw` 第二次 rename 强制失败，断言旧文件字节仍在；插件逐个 open/sync/rename 失败断言旧文件不变、临时文件清理、written=false | Lua 旧文件已经实测被删除，绿灯完全漏掉 |
| 迟到响应 | **high**；Lua `1424–1451 poll_decision`、`1839 consume` | T10 只覆盖“超过 validity 后才收到”；T18 只覆盖“相同 decision_id 到两次”。**没有生成后但仍在有效期内、新 decision_id 的迟到** | 接收D1→消费→发布同rid新D2→poll→下一抽，断言D2按late拒绝、applied不变；另断言消费清K全部outstanding | D2可服务下一次生成，本轮已复现 |

## 4. Q3：并发、刷新和消费

### DS-04（high）：生成后未清空 K 的 outstanding，新 decision_id 可重复服务下一抽

- **位置：** `main.lua:1839–1863 consume` 仅清 `S.decision`；`poll_decision:1424–1451` 只找 request，不识别已生成目标；`prune_outstanding:1200–1207` 等有效期再加 5 秒。
- **证据：** D1 接受→draw/pickup→同 rid 同 K 新 D2→poll，输出 `accepted=true,outstanding_present=true,second_draw=1`。不是相同 decision_id 重复投递，所以 T18 挡不住。
- **应该改成什么：** 生成无论走 llm 或本地规则，都终结该 K 的未决项、缓存和待发布归属；维护消费世代/终态，随后同世代响应必须 `TIMEOUT/late`。下一抽必须有新目标世代，不能只依靠同池 K 与已用 request。
- **不改会怎样：** 一次生成只消费一个 choice 的约束失效，迟到决策串给第二个底座，applied 无法解释独立抽取。

### DS-05（high）：缓存过期也占着“已有决策”位置，刷新被永久挡住

- **位置：** `main.lua:2063 on_update` 要求 `S.decision==nil` 才刷新；`prune_outstanding` 不清决策；缓存仅在下一次 `consume:1858–1862` 才清。`MAX_REFRESHES=8` 在 `57`，耗尽后也不会恢复。
- **证据：** 收D1后推进2000ms（validity=1500），执行12次 update，仍 `cache_present=true,same_request=true,age=2000`。Boss 5秒窗口同理：只要先收到过一条，长战斗没有后续新请求。
- **应该改成什么：** update 独立检查缓存与请求有效期，过期立即清除；按 validity/2 更新请求即使当前有缓存；若保留重试上限，应有明确冷却/新需求恢复状态而非把同一等待目标锁死。这里是生命周期缺陷；不把“刷新是 SHOULD”偷换成“未照固定频率即 MUST 违约”。
- **不改会怎样：** 收到一次早到结果反而停止补货，真正生成时只能丢弃旧决策，长期稳定退化为本地规则。

### DS-06（high）：只串行写盘不串行请求，旧调用可覆盖最新调用

- **位置：** `plugin/index.js:284–293 withWriteLock`、`1074–1343 runIsaacDecide`、最终 `1316 writeDecisionAtomic`。没有 `(session,K,fingerprint)` 最新请求记录，写前不重验。
- **证据：** 同 K 旧请求模型延迟220ms、新请求延迟20ms，先读磁盘为 `r-new-0002`，旧完成后读变 `r-old-0001`。文件没有撕裂，但业务顺序倒退。
- **应该改成什么：** 为每个 session/K 管理最新请求和固定指纹；写入锁内部校验发布资格，指纹不同丢弃旧结果，相同按契约重新封装到最新请求，使用新 decision_id。消费或取消要撤销发布资格。
- **不改会怎样：** 慢响应覆盖玩家新血量/新候选对应结果，latest-wins 变成“最后完成的旧任务胜出”。

### 单写者结论（high，已有架构要求的确认）

`withWriteLock` 确实覆盖插件四个发布分支（拒绝1141、安全跳过1180、兜底1225、llm1316），进程内同一模块无并发 rename。但 `index.js:280–283` 自行以“按调用”豁免 `bridge.lock`，不是 draft.5 允许的例外。`apply` 也没有独占创建或持有者校验；多个 DSH 进程/模块副本各有自己的 queue。**应该** 在桥生命周期获取进程锁、校验 pid+启动信息并安全回收；**不改** 多宿主仍可并写、跨请求覆盖。进程内队列不等于跨进程单写者。

## 5. Q4：安全边界

### DS-07（high）：路径校验与最终写之间存在已复现的 junction 窗口

- **位置：** `plugin/index.js:181–213 resolveBridgeDir` 只在工具开始时跑；模型可等待数秒；`311–351 writeDecisionAtomic` 只重查文件本身，`216 safeFilePath` 不重查父目录 realpath。
- **证据：** 创建普通 bridge→启动 decide→假模型暂停→把 bridge 重命名保留→原名建 junction 指向另一个目录→放行模型，输出 `written=true,outsideDecision=true`。只在 E:\Temp 的两个测试目录操作，未碰生产桥。路径和文件名均未由模型提供。
- **应该改成什么：** 分离由部署配置固定的可信白名单根与 override 请求路径（当前注释177把任意指定目录本身当白名单，校验等于自证）；每次读/写前校验整条父路径及最终目录身份。若要抵御有写权限的同机进程主动换目录，仅“再 realpath 一次”仍留竞态，应使用可固定目录身份的系统级打开方式/拒绝重解析点，或把威胁模型与桥目录 ACL 明确限制到可信单用户目录。不能声称一次 lstat 就封死竞态。
- **不改会怎样：** 初检看似安全，后续却能读写外侧文件。可信白名单与路径身份都不能保证。
- **范围核对：** 静态 symlink/junction 直指外侧或祖先 realpath 不同一般会被现有 `resolveBridgeDir` 拒绝；Windows 大小写归一是合理的，不作为绕过证明。UNC 没有单独白名单拒绝，不能声称已隔离远程共享；本轮没有真实 UNC 服务器实测。跨平台又无条件 toLowerCase，若保持 Linux/darwin 声明，要按平台处理，不能把两个大小写不同的真实路径当相同。

### DS-08（high）：AbortController 只是合作取消，没有硬截止

- **位置：** `index.js:755–805 callModelOnce`，timer 只 `abort()`；之后仍阻塞在 `for await` 等下一块；`finishWithFallback:1225` 和正常发布 `1316` 都不重验过期/取消。
- **证据：** validity600ms，模型桩忽略 signal 900ms 后才吐结果，实测904ms才返回并 `written=true,error_code=TIMEOUT`。如果迭代器永远不返回，就不会走到 finally/兜底。调用方取消也会落入 catch 后发布规则，取消不是撤销发布。
- **应该改成什么：** 独立 deadline 与迭代读取 race，计时到即返回；合作 abort 同时保留，但隔离迟到结果/错误并撤销写入资格。锁内发布还要检查 session/request deadline 与外层取消。测试必须注入忽略signal且不产出下一块的流，不能只测一开始 state 已过期。
- **不改会怎样：** 模型不合作时工具无限挂起；过期/已取消调用仍可覆盖有效决策。

### key 与模型输出的确认

没有看到 `eval`、`Function`、shell 或 Lua `load` 执行模型输出；模型结果只经 JSON.parse、候选校验、文档组装后写固定文件名。`ctx.get('llm')` 调宿主流，没有 API key 读取。不能据此扩张为“绝无泄露”：`reason` 内容只净化控制字符/长度，没有路径/账号模式检查，模型错误 message 也经 `shortText` 返回给工具用户（`786,804`）；部署宿主若把秘密塞进错误字符串仍会回显。**medium**：应在错误边界只暴露稳定分类与脱敏信息，输出reason的内容约束与长度一起校验；**不改** 提示词中的“不含路径/密钥”仅是期望，不能算强制边界。

## 6. Q5：可读性与维护性（均定位到行为）

### DS-09（medium）：理由被截断/改写后继续发布，字符上限与字节上限分裂

- **位置：** 插件 `139–147 sanitizeReason`、`737 normalizeDraft`、`918–922 assertDecisionLegal`；Lua `167–177 sanitize_reason`、`1349–1358 validate_decision`。
- **证据：** 280个 emoji 的 reason 为 **1120 UTF-8字节**，`normalizeDraft`→`makeDecisionDoc` 仍成功。插件仅验 code point≤280、不验1024字节；Lua也不验1024。控制字符/超长reason在插件先被“修好”再验，与协议 §1.6 超限拒绝相反。
- **应该改成什么：** 模型输入先严格校验原reason类型/非空/控制字符/code point/UTF-8字节，不合格触发原重试/兜底分支；展示阶段才可独立排版，不能改变线上内容后冒充通过校验。测试直接覆盖280个4字节字符和含控制字符的原输出。
- **不改会怎样：** 两端接受协议外文档，原始违规被抹掉，后续严格消费者会拒绝同一条“合法”决策。

### DS-10（medium）：定制 JSON 解码器不是严格 JSON，且消除了数组/对象区别

- **位置：** `main.lua:310–353 parse_string` 不拒绝未转义控制字符，`358–408` 数组/对象都返回普通 table，`432` 数字语法宽松；`1258–1264 requires` 用 ipairs。
- **证据：** JSON字符串中直接放原始换行仍 `accepted=true`。`requires={...}` 作为对象不会被数组类型拦下，ipairs没有值就绕过硬要求检查（该后果由分支直接推出）。
- **应该改成什么：** 保留array标记并严格按JSON词法解析；对未转义控制字节、数字文法及UTF-8做拒绝；或在不引入未批准依赖前提下封装已核验宿主JSON实现。对真实 `decode`→`validate_decision` 链测对象型requires与原始控制字符，不能只测编码器自产JSON。
- **不改会怎样：** 非协议文档被接受，能力数组伪装为对象时可能绕过要求；维护两套自定义序列化细节成本继续扩张。

### DS-11（medium）：候选签名只覆盖前8项，候选尾部变化不换K

- **位置：** `main.lua:1064–1071 make_gen_level_key`；缓存 `1015–1024 ensure_candidates` 只换层清；没有 reroll 回调注册（`2107–2114`）。
- **证据：** 两份长度10的候选，仅第9项由9改99，`make_key`实测 `same_key=true`。这不是散列理论碰撞，是有意忽略尾部。
- **应该改成什么：** 签名覆盖完整有序候选；重掷/池成员变更时显式作废对应池缓存、重建K与请求世代。对相同长度、前8项相同但尾部变化执行原 `make_key` 断言K不同。
- **不改会怎样：** 尾部候选或池内容变更后仍被看成相同生成上下文，重复使用旧决策/缓存。

### 结构与命名（low）

`runIsaacDecide:1074–1343` 为约270行，四次复制结果对象且分别发布；这解释了为什么预算/取消/会话发布检查难以统一。`validateStateDoc:384–533` 约150行，Lua `decode_impl:291–447` 约157行；长本身不是缺陷，缺陷是容易遗漏共同约束。`main.lua:1396` “回调只做内存”与 `on_update` 读盘范围应明确区分；`x_clock` 头注释声称插件据此改接收时间，但插件从未读该字段，且 draft.5 禁止用扩展字段改变ts语义。**应该** 抽统一发布守卫/返回视图，把旧注释更新到实际draft.5，不要求为行数重构；**不改** 接下来补一条约束容易漏掉一个发布分支或继续相信错误注释。

## 7. Q6：四类扩展点能否替换

| 扩展点、严重度 | 当前实现定位/判断 | 应该改成什么 | 不改会怎样 |
| --- | --- | --- | --- |
| DecisionProvider，**medium** | `runIsaacDecide:1249–1315` 写死降级→模型→规则；`apply:1380` 只给bridgeDir/provider/model配置，无 provider对象列表、role、priority、canHandle或注入入口。viewer只进prompt（`1282`），不是 ViewerVoteProvider | 组装层接受provider实例，统一draft验证/排序/尾部规则，模式选择组装而不是修改工具函数 | 换成确定性观众/预置/离线规则都要改核心；配置换模型不等于接口可插拔 |
| EventSource，**medium** | Lua `on_new_room/on_pickup_init` 直接调 `emit_event`，集中注册固定钩子；插件 `safeFilePath:217` 只接受state/decision，没有readEvent/start(sink)/stop | 提供事件适配器装配与sink/生命周期，保持通知用途；正式新事件仍按minor改协议 | 既无可靠总线，也无当前承诺的通知源替换入口；不能拿“latest-wins已知取舍”解释接口不存在 |
| StateEnricher，**medium** | `buildStateSummary:641–671` 固定字段投影，现有 `state.enrichments` 都没带给模型；无 enrich链/namespace/timeout/requires | 接收只读输入，组装并行限时enricher链，保留既有enrichments；地图/敌人仍需mod先导出，不凭空生成 | 连v1静态增强都不能只加实现，必须改prompt/核心 |
| Presenter，**medium** | 插件只在工具结果中拼text；Lua `bubble_from_applied:1885–1907` 直接调用show_bubble，render固定；没有PresenterBus/present(view)注入 | 插件在决策发布后统一composer→各presenter，独立超时/失败隔离；Lua气泡固定边界可以保留但对外用其视图接口 | 加语音/overlay要改核心；无法验证表现失败不影响决策；气泡边界已知但不是全部Presenter缺失的理由 |

以上是实现与已承诺接口的差距，不声称v1必须交付每个未来provider/地图/OBS功能。验收应是“可注入一个最小替身且核心不改”，不是接口名字出现在文档里。

## 8. 原实现复现摘录

插件脚本：`E:\Temp\isaac-review-deepseek.mjs`；最终一次输出目录：`E:\Temp\isaac-review-ds-M2fwqy\results.json`。

```text
unknown-requires                 validation={ok:true}
pool-target-mismatch             validation={ok:true}
unknown-red-capacity             choice={type:item,item_id:22}
malformed-root                   error_code=INTERNAL, written=false
reason-byte-limit                chars=280, bytes=1120
ignored-model-abort               elapsed=904ms, validity=600, TIMEOUT, written=true
older-call-overwrites-newer       afterNew=r-new-0002, afterOld=r-old-0001
junction-swap-after-validation    written=true, outsideDecision=true
NODE_REPRO_EXIT=0
```

Lua脚本：`E:\Temp\isaac-review-deepseek-lua.py`；最终测试目录：`E:\Temp\isaac_agent_test_1794016351_6852`。

```text
cached-expired-blocks-refresh     age=2000, cache_present=true, same_request=true
new-id-after-consumption         accepted=true, outstanding_present=true, second_draw=1
verify-window-expired            phase=applied, applied_by=llm, actual_is_null=true
local-guard-error                error_code=TIMEOUT, reason_code=player_dead
unknown-error-code              accepted=true
rename-failure-loses-old-file    old_existed=true, old_survived=false
candidate-key-tail-collision     same_key=true
json-unescaped-control          accepted=true
unknown-item-name-omitted        candidate_name_missing=true, held_item_name_missing=true
partial-snapshot-not-degraded    red_hearts=0, error_code_is_null=true
LUA_REPRO_EXIT=0
```

### 另两项必须修的已验证失败（待与 GPT 对照，不重复计作新增）

1. **high｜写失败会删旧文件。** Lua `bridge_write_raw:587–595` 第一次rename失败即remove(target)，第二次rename仍失败后只删tmp。注入rename恒失败，旧state消失。应该保留可恢复旧版本并在成功发布后清理，逐项检查write/flush/close返回；不改会让消费者在失败时丢掉最后可用文档。Windows允许remove→rename不是§1.3“失败保留旧文件”的豁免。
2. **high｜核验未发生却已有成功回执。** `on_pre_get_collectible:1978` 先排 applied；`on_pickup_init:2013–2015` 超两帧直接丢pending，不改回执。实测晚3帧仍applied/llm/actual=null。另 `2034–2039` mismatch只改phase/applied_by，未清source/provider/choice和设fallback=true，违反§5.4完整行。应该核验完成才发布终态；核验超时/覆盖也明确rejected/none并规范各字段；不改会让“实际生效唯一权威”报假成功。单槽pending遇到同帧多抽/无实体抽取也应针对原分支验证，不能用正常T03替代。

## 9. 并行修复后的追加复核（不改写原基线证据）

审查中主控将 t12/t13 合入 main。追加检查固定到 `0e4d66f`（包含 Lua `cffcbdc`、插件 `dbc5ddc`），本报告分支仍保留 `7d4e102` 基线，不移动实现。最新 main 跑 `node --check` exit0、`node plugin/tests/plugin.test.mjs` **111 passed/0 failed**、`python tests/run_lua_test.py` **106/106**，均实际执行，不是转述修复报告。

**这里不等于对 GPT 原稿逐条复核。** `docs/reviews/plugin-fixes-t13.md` 是实现者的修复对照，并非任务指定的 GPT 15项评审原文；只是可以用来交叉核对修复声称。以下只确认/反驳/补遗漏边界，不把同一问题再计为“新发现”。

| 原问题/修复声称 | 0e4d66f 实测结论 | 精确遗漏边界、应该改成什么与后果 |
| --- | --- | --- |
| DS-01 requires/目标不一致、null root | **确认已修所测分支**：未知requires被拒，pool/null不一致被拒，nullroot回VALIDATION而非INTERNAL | session、时间基准、未知容量仍未跟draft.5对齐；不能把三项校验修复泛化成全部协议完成 |
| DS-04 同rid新decision_id生成后重用 | **确认单rid路径已修，补充同K边界** | **high**：当前 `main.lua:1988–1995` 只清消费的rid；`2007–2021` fallback分支完全不清未决项。实测 R1/R2同K→消费R1→R2到达，`accepted=true,rid2_outstanding=true`；先fallback生成再收原rid也`accepted=true`。应在任何生成结果后清同K全部未决项与终结目标世代；不改仍串给下一抽 |
| DS-05 过期缓存挡刷新 | **确认已修原复现**：age=0、cache_present=false、same_request=false，出现新请求 | `MAX_REFRESHES=8`耗尽后无恢复策略、已有缓存时不是validity/2刷新仍存在；后一项是SHOULD偏离，单独以持续活性验收，不夸大成阻断 |
| DS-06 R1慢覆盖R2、DS-07等待期间junction切换 | **确认已修本轮所测窗口**：磁盘保持r-new；junction written=false且outside无decision | 仍需可信白名单根/跨进程锁；修复报告已承认realpath→rename残余窗口。不得宣称目录级原子身份已证明 |
| DS-08 超时fallback过期仍写 | **确认过期拒写已修；反驳“硬截止已解决”** | **high**：`plugin/index.js:1047–1111 callModelOnce`仍只abort再等for-await。永不产出且忽略signal的流，validity600ms，观察1200ms时`completed=false`。应独立race期限并隔离未决流；不改仍可无限挂工具 |
| 插件修复D2：成功发布即记consumed | **反驳：新增语义违约** | **high**：`plugin/index.js:523–524,613` 在没有游戏消费回执时以发布当消费。实测同rid、生成前两次合法输出，firstWritten=true/secondWritten=false/`already_consumed`。draft.5 §6.7.6允许同rid不同decision_id更新。应区分published与consumed，以真实生成终态/新世代撤销；不改临时规则→最终LLM覆盖被阻止 |
| DS-09 reason1024字节上限 | **确认输出字节上限修到1024；反驳“契约校验完整”** | **medium**：280emoji被截为256emoji/1024字节仍发布，协议§1.6要求超限拒绝，不是截断后继续。应拒绝原输出并进入重试/兜底；不改仍掩盖非法输出 |
| Lua原写失败删除旧state | **确认原恒失败复现已修**：old_survived=true | 新backup/rollback复杂路径仍应分别注入flush/close、临时发布失败且恢复失败；不将一个恒失败桩等价为所有写失败已证明 |
| mismatch回执字段不完整 | **确认差异中已补清source/provider/choice与fallback** | **high**：`main.lua:2121`仍在核验前写成功；`2156–2158`超2帧直接丢pending。实测仍phase=applied/applied_by=llm/actual=null。应核验或明确失败后发布唯一终态；不改仍假成功 |

修后独立复现脚本未改实现：插件仍用 `E:\Temp\isaac-review-deepseek.mjs`，设 `ISAAC_REVIEW_REPO=E:\Yuki\工作\isaac-agent-main`；最终JSON在 `E:\Temp\isaac-review-ds-30syla\results.json`。Lua用同环境变量与原复现脚本，最终桥目录 `E:\Temp\isaac_agent_test_1794016684_4945`。新增结果摘录：

```text
same-request-new-decision-before-generation  firstWritten=true secondWritten=false already_consumed
noncooperative-stream-hard-deadline          validity=600 observationMs=1200 completed=false
same-key-other-request-after-generation     accepted=true rid2_outstanding=true
response-after-fallback-generation          accepted=true
verify-window-expired                       phase=applied applied_by=llm actual_is_null=true
```

原基线故障中已确认修复的部分以本节状态为准，不能继续当作当前main未修问题。

## 10. 必修清单（一页，按严重度排序；以修后0e4d66f为准）

| 顺序/严重度 | 修复范围与定位 | 可核验完成条件 / 不改的后果 |
| --- | --- | --- |
| 1 high | Lua `consume:1988–2021` 全K终态 | R1/R2同K及fallback后迟到全部拒绝；否则仍串到下一抽 |
| 2 high | 插件 `callModelOnce:1047` 硬截止 | 忽略signal永不吐块也在预算内退出；否则工具无限挂起 |
| 3 high | Lua `on_pre_get_collectible:2121/on_pickup_init:2156` 回执 | 未核验不报成功，超窗完整rejected/none；否则applied报假成功 |
| 4 high | 插件 `evaluatePublishGate:523/publishDecision:613` 发布≠消费 | 同rid不同decision_id生成前可更新；否则临时规则挡最终模型结果 |
| 5 high | 两侧session信封、`withWriteLock`跨进程锁 | 四类session齐全，错session拒绝，多宿主单写者；否则隔离仅靠随机碰运气 |
| 6 medium | Lua `read_player/build_state_doc`（DS-02） | 未知name显式null，API失败显式降级；否则拒绝自产state或对伪造血量决策 |
| 7 medium | Lua `make_applied_local`、两侧规则（DS-03） | guard error=null，未知max_red跳过heal；否则安全跳过被误报、未知角色误选 |
| 8 medium | 两侧reason/JSON校验（DS-09/10） | reason原输出超限拒绝，对象型requires/控制字节拒绝；否则非法输出被掩盖 |
| 9 medium | Lua `make_gen_level_key/ensure_candidates`（DS-11） | 尾部变化K变化、重掷作废缓存；否则旧上下文继续复用 |
| 10 medium | 四类扩展接口（§7具体函数） | 每类可注入最小替身，无需改核心；否则接口只是纸面承诺 |
| 11 low | 两侧旧注释、`runIsaacDecide`统一守卫 | 注释与draft.5一致，发布约束集中；否则后续分支漏验继续复发 |

原 R1慢覆盖R2、等待期间junction切换、未知requires、缓存过期不清、单rid重复消费、rename恒失败丢旧文件，已有修复的所测分支应保留回归，不列作当前尚未修好的主问题。路径仍需明确可信根/ACL及残余窗口；不能把一次复现被挡住提升为完整竞态证明。

**交付限制：** 必须取得指定 GPT 15项原稿，补逐项确认/反驳/遗漏边界，才可称“复评对照完整”。本稿如实记录输入缺失，未以架构旧评审或实现者自述代替原稿。
