# 决策记录：M5（扩展点是否落代码）与 M7（Profile B 诚实表述）

> 任务：t24（M5/M7 决策）+ t25 修正（Profile B spike）。依据：第二线实现级评审
> `docs/reviews/impl-review-deepseek.md`（M5/M7）、当前实现（`plugin/index.js` 单体、
> `mods/isaac_agent/main.lua` 单体、探针失败即纯本地规则）、t25 spike
> `docs/spike-profile-b.md`（分支 `agent/t25-profile-b-spike`，cbea2fe）。
> 日期：2026-11-07。负责人：contract。
> 结论：**M5 选 A（v1 只在文档中作为设计约束，不是代码接口）；M7 v1 选 A（只支持
> Profile A + local-only，不把无桥接叫 Profile B）；B 单独不可行，C 可行但推迟 v1.1+**。

---

## 1. M5：四类扩展点在 v1 是概念约束，不是可插代码

### 1.1 选了什么

**v1 选 A：概念上的扩展点。** `DecisionProvider / EventSource / StateEnricher / Presenter`
在 `architecture.md` 里是 **设计约束 + 维护者实现指南**，不是 DSH 插件 API、不是注册表、
不承诺第三方可以“放一个模块进去就换掉行为”。

v1 的实际代码形态：

- 插件是单体 `plugin/index.js`；provider 选择通过配置（`provider`/`model`）发生，但
  Provider/Enricher/Presenter 没有代码接口、没有 `register*()`、没有依赖注入容器。
- mod 是单体 `mods/isaac_agent/main.lua`；事件源是固定游戏钩子，本地规则是同一文件里的函数。
- **改行为 = 改实现**：新增 provider / 事件源 / Enricher / Presenter，要改对应单体文件并跑
  回归测试；不是“热插拔”，也不是“写个插件包就能扩展”。

### 1.2 为什么

1. **稳定优先。** v1 还没有真实游戏内 smoke test；此时抽接口层会把“未验证的时序/失败路径”
   固化进 API，后面改接口比改单体更贵。
2. **扩展点目前没有真实数据链路。** 第二线评审已经指出：`StateEnricher` 的地图/敌人没有
   state 输入；`ViewerVoteProvider` 的 `votes` 数据来源在 v1 未落地（只有离线模拟）；
   气泡固定在 mod 侧。先抽“接口”会把假扩展点包装成真 API，误导第三方。
3. **代价可控。** 概念约束已经能指导维护者分层（谁该干什么、不能反向调用），不需要重构
   两个单体；v1.1 再按真实用例抽最小接口。

### 1.3 对使用者的影响

- **v1 不支持第三方扩展实现。** 你不能通过配置/插件包替换 DecisionProvider、Presenter 或
  EventSource；只能使用仓库内置行为，或修改源码。
- 配置层面仍可换 **模型**（`provider`/`model`），这是 DSH 模型选择，不是扩展点 API。
- README 的 Limitations 必须原样写出：“v1 extension points are conceptual only; changing
  behavior requires editing the implementation; no third-party extension API.”
- `architecture.md` §4 的“假想实现”改为“示意实现（未随 v1 交付）”；§8 的“改核心？”列
  改为“是（v1 需改实现）”，不再暗示零改动扩展。

### 1.4 以后怎么改（升级路径）

- **v1.1 路线图 B**：在真实需求出现后抽 **最小接口层**（只抽被两个以上实现复用的部分）：
  - `DecisionProvider`：`id/source/role/priority/canHandle/decide` 加注册表；
  - `Presenter`：只抽 voice/danmaku/overlay 三通道（气泡仍固定 mod 侧）；
  - `EventSource`：先支持插件侧文件/弹幕源，mod 侧事件仍固定；
  - `StateEnricher`：先补 state 输入字段，再抽接口。
- 接口层必须带契约测试；没有两个真实实现前不抽。
- 在 v1.1 发布前，README 继续写“概念扩展点”，不得提前宣称可插拔。

---

## 2. M7：v1 只支持 Profile A + 纯本地规则，不冒充 Profile B

### 2.1 选了什么

**v1 选 A（行为上）：只支持 Profile A 的实时桥；没有 Profile A 时走纯本地规则（local-only）。**
**不把“无桥接 + 本地规则”称为 Profile B。**
**B 单独不可行；C（共享 SaveData 中继）可行，但 v1 不做，列为 v1.1+ 的头号候选。**

> 注意：这里的 A/B/C 是 **M7 的选项**（v1 怎么表述）；下面提到的 **Profile C** 是协议里的传输形态。两者不是同一个 C。

具体口径：

| 场景 | v1 实际行为 | 是否叫 Profile |
| --- | --- | --- |
| 玩家用 `--luadebug`（或 REPENTOGON 暴露文件 API），探针读写通过 | mod 写 `state/event/applied`、读 `decision`；插件实时决策 | **Profile A** |
| 玩家不加启动项 / 沙箱无 `io` / 探针失败 | mod 不写任何桥文件、不读 `decision`；回调 62 只跑本地规则 + 气泡“桥接不可用（本地规则）” | **local-only**，不是 Profile B |
| 共享 `Mod:SaveData/LoadData` 数据文件中继 | v1 不实现 | **Profile C（v1.1+ 候选）** |

**Profile B 单独不可行**：只读解决不了“mod 把局面导出给插件”；默认沙箱无 `io`，REPENTOGON 的 `os` 也被裁到只剩 `date/time/clock/difftime`，mod 读不到任意 `decision.json`。v1 不实现，v1.1 也不再把它当目标形态——真正能落地的默认形态是 Profile C。

### 2.2 为什么

1. **B 单独不可行（spike 实测/源码）**：默认启动下 `io` 不存在；装了 REPENTOGON 后 `os` 也只有 `date/time/clock/difftime`，没有 `rename/remove/getenv`。纯 B 只读不写，插件拿不到局面，产品上不成立。
2. **C 可行**：`Mod:LoadData()` / `Mod:SaveData()` 本身就是文件读写，固定落在 `<游戏目录>/data/<mod>/save<槽位>.dat`，内容是纯文本；本机 `just_gambling/save1.dat` 实测就是 JSON。它不依赖 `--luadebug`，所以 v1.1 可以把它做成默认桥。
3. **v1 范围不变**：t25 spike 也建议 v1 仍按 A/local-only 发；C 需要 ~2.5–3 人日 + 真机联调，且最大的风险是存档覆盖/损坏（玩家丢进度），不适合塞进 v1。
4. **M7 选项 C 与 Profile C 的区别**：M7 任务里的“选项 C”是“文档改成无桥接走本地规则、桥接需要 --luadebug”的**措辞选项**；我们采纳其直白文案，但行为上仍是 A/local-only。协议里的 Profile C 是 SaveData 中继，是 v1.1 的实现路线，不是 v1 的措辞。

### 2.3 对使用者的影响

- **v1 实时 agent 必须 `--luadebug`**（或未来 REPENTOGON 文件 API）。默认安装只有本地规则，气泡明确提示，不假装 agent 可用。
- `README` 不再写“默认 Profile B”；改为“v1 支持 Profile A；无桥接 = local-only；B 单独不可行；C 是 v1.1 候选”。
- 安装说明把 `--luadebug` 写成“实时 agent 的前置条件”，不是可选增强；安全警告保留“给所有 mod 放开文件访问”。
- 没有实时 `state.json` 时，`isaac_state` 没有 live 数据；`isaac_decide` 可以用外部传入的完整 StateDoc 生成决策，但这不是从游戏内实时导出，不能与 A 混称。
- 不向用户承诺“默认安装即可用 agent”；也不把 C 说成已可用。

### 2.4 以后怎么改（升级路径）

- **v1.1 头号候选：Profile C（共享 SaveData 中继）**，分三档：
  1. **C1（兼容面最大，任意 REPENTOGON 含 1.0.12e）**：mod 与插件共享**同一个** `saveN.dat`，用 `epoch`/`turn` 栅栏防互相覆盖；先做这个。
  2. **C2（更干净，REPENTOGON ≥ 1.1.2e）**：用 `Isaac.LoadModDataFromFolder(folder)` 把 state/decision 拆成两个 mod 数据文件；1.1.3 是最新发布并含该 API。
  3. **C3（任意文件名，不依赖）**：`Mod:LoadData(filename)` / `Mod:SaveData(data, filename)` 只在 REPENTOGON 未发布的 main（changelog `v1.1.x`）里有，**1.1.3 没有**；不要依赖，最多用探针探测。
- **C 的红线**：**存档损坏 = 玩家丢进度**。实现必须做到“永不写半截、独立文件、版本字段、失败保留旧文件”；并且先真机验证两件事：`LoadData()` 是否每次读盘、游戏存档/退出会不会覆盖 `save<槽位>.dat`。未验证前不得宣称“实时”。
- 升级时必须：
  1. 先改协议（profile 语义/字段）并升 minor；
  2. 两端实现 + 契约测试；
  3. README/安装/安全说明同步；
  4. 不得在实现前宣称支持。
- 依据：t25 spike `docs/spike-profile-b.md`（分支 `agent/t25-profile-b-spike`，cbea2fe）。

---

## 3. 协议与版本文档变更

- **wire 协议字段不变**：`protocol_version` 仍为 `1.0`，`state/decision/event/applied` 的
  字段与校验不变。M5 不涉及 wire；M7 只改“Profile 语义/默认”，不改 JSON 结构。
- **规范文档 minor 升到 `1.1-draft.2`**：t24 先把默认从 B 改为“A only + local-only”（1.1-draft.1）；t25 spike 再修正为“B 单独不可行、C 可行但 v1.1+”（1.1-draft.2）。`protocol.md` §1.4、§0、§11、§12 与 `architecture.md` §0/§2/§4/§8 同步。
- 不在本次把 wire `protocol_version` 改成 `1.1`：那会迫使两端实现、测试、样例与已发布的
  `1.0` 快照一起改，却没有字段变化；等真正出现字段级 minor 时再统一升 wire。
- README 的版本行改为 `v1.1-draft.2 (wire 1.0)`，Limitations 写清 M5/M7 与 C 的 v1.1 候选。

## 4. 验收 / 回写位置

- `docs/reviews/decisions-m5-m7.md`：本文件（决策、理由、影响、升级路径）。
- `docs/architecture.md`：§0（默认形态）、§2（Profile 表）、§4（概念扩展点）、§8（扩展演练）。
- `docs/protocol.md`：§1.4（Profile 语义）、§0/§11（结论/已知取舍）、§12（变更记录）。
- `README.md`：Profiles 表、默认安装、安装步骤、Limitations、版本行（英文 + 中文）。
- 不在本任务改代码；M5/M7 是表述与产品范围决策，代码实现留给 v1.1 或后续修复任务。
