契约基线：fb9e25c（draft.5）
实现基线：0e4d66f（main，已含 t12/t13 修复）
与 DeepSeek 线的关系：独立评审，不互相覆盖

# 实现级评审：GPT 线（t10）

日期：2026-11-07。结论：**needs_revision，不作为游戏或真实 DSH 集成通过证据**。

本档保留最初独立发现的15项编号，并以0e4d66f作为当前交付对照基线。原始逐行审查及复现对象为Lua `8069d9f`、插件 `e3bdf81`；下文标为“原”的行号均指这两版，不能拿它直接定位修后代码。修复状态来自t12 `481e488`/`cffcbdc`、t13 `dbc5ddc`及0e4d66f合入内容；“已修”仅指注明的子项，不自动关闭整项。未完整复验修后行为处明确保留限制。

评审开始时main `ba5e61c`落后于draft.5、缺t8，这是**集成缺陷，不是设计主动回退**。本报告固定fb9e25c，不使用当时main中的draft.3冒充draft.5。当前实现修复提交与契约差异需分别核验。

## 1. draft.3 → draft.5 差异校正表

| 项目 | draft.5依据 | 本评审校正 |
| --- | --- | --- |
| session_id | protocol §1.5、§3.1、§4.1、§5.2 | 已正式登记且四文档必填；撤回旧评审“应改x_session_id”的建议，改查跨局隔离及回显 |
| provider前缀 | protocol §3.5 | 已知前缀冲突拒绝；未知前缀WARN放行，不能继续限定四个前缀 |
| 红心上限未知 | protocol §6.5.3 | 缺max_red_hearts必须跳过heal；旧两端一致不等于符合新契约 |
| 时间 | protocol §1.5 | 统一同机墙钟state.ts，超过5秒跳变须显式降级；不能再宣称单调时间实现符合draft.5 |
| capabilities | protocol §2.1、§3.2 | 合并到features；不能继续以旧capabilities隐式门控动作 |
| Profile | protocol §0、§1.4、§1.8 | 默认B、A需已显式开启luadebug、C推迟；不能诱导默认开luadebug，也不能假定mod可写 |
| 池目标 | protocol §2.1 | pool-level的trigger.payload.pool由SHOULD变MUST，候选pedestal均null |
| actual_item_id | protocol §5.2 | 必填可null；只能用真实核验结果表示成功 |
| plugin_status | protocol §1.11 | 可选诊断，相关更新是SHOULD；缺它不单独判硬性阻塞 |
| 去重/刷新 | protocol §1.5、§6.7 | 固定刷新间隔、在途合并有SHOULD/MAY语气；不能仅因未合并判MUST违约，但结果归属、指纹、终态隔离是明确义务 |

## 2. 十五项意见及修复状态

### G01 — blocker：生成终态没有完整隔离同K的响应

- **定位**：原Lua main.lua:1839 `consume`、:1425 `poll_decision`、:1064 `make_gen_level_key`；t12版main.lua:1988。
- **问题**：原实现只清S.decision，outstanding仍在，同房同池复用K。原版实测消费后新decision_id仍接受，第二次生成记llm。
- **改成什么**：所有生成终态（命中、fallback、skip）清同K全部请求及决策，记录结束身份；下一目标使用新的生成世代。回归必须含R1/R2刷新、消费D1、再投R2/D2，不只重复同request。
- **不改会怎样**：旧生成的决策可串到第二底座/重掷，破坏protocol §6.7.1/5。
- **状态**：**已修(t12，同request消费后再次投递子项)**；不能整项关闭。抽读t12显示仅删除doc.request_id，其它同K刷新请求及fallback终态未一并终结；需按上述跨request回放复核。

### G02 — high：缓存过期阻断刷新，活跃目标还有永久停止上限

- **定位**：原Lua main.lua:2063 `on_update`、:1845 `consume`、:57 MAX_REFRESHES。
- **问题**：S.decision非nil即不刷新，缓存过期直到生成才丢；无响应又在8次刷新后停止。原版推进3000ms、执行12次update，request_id不变。
- **改成什么**：tick淘汰过期决策；活跃目标继续获取新鲜请求或明确有界停止并上报能力限制。固定validity/2是SHOULD，不要求机械无限轮询；必须消除“持有过期缓存却当已就绪”。
- **不改会怎样**：Boss奖励前收到的早期决策反而在真正生成时不可用，长期等待退化成本地规则。
- **状态**：**已修(t12，过期缓存触发刷新子项，新增T21)**；8次上限、生成后是否继续旧目标刷新仍需分别验证，不重复计过期缓存已修分支。

### G03 — high：进程内发布队列没有实现跨进程实例锁

- **定位**：原plugin/index.js:280–293 `withWriteLock`、:1380 `apply`。
- **问题**：模块Promise只串行当前模块写入；没有bridge.lock、pid/启动时间核验、退出回收。
- **改成什么**：按protocol §1.10建立独占实例锁、存活检查及安全清理；两独立进程竞争同桥目录，断言仅一个能发布。不能用G04的请求序号代替实例锁。
- **不改会怎样**：两个DSH进程各自成功rename，单写者保证失效。
- **状态**：**待修/需当前基线专项复核**；t13的R1/R2排队修复不等于跨进程锁。

### G04 — high：旧异步请求完成后覆盖新请求

- **定位**：原plugin/index.js:1074 `runIsaacDecide`、:1286–1316发布、:317 `writeDecisionAtomic`。
- **问题**：没有发布代次/指纹与最新请求归属。原版mock令R1慢、R2快，R2落盘后放行R1，最终request_id为旧R1。
- **改成什么**：入发布队列后重新核对最新(session,K,指纹)、身份及预算；同指纹可重绑最新请求且新decision_id，指纹变化丢弃旧结果。测试同指纹反序和血量变化反序；缓存/在途合并不是消除错误覆盖的唯一方案。
- **不改会怎样**：旧局面决策占住唯一decision文件，丢失更新请求的有效结果。
- **状态**：**已修(t13，R1/R2覆盖子项，dbc5ddc)**；固定协议指纹和发布目标绑定仍应由复评验证，不能把递增序号一概等同完整缓存契约。

### G05 — high：目录校验与实际访问之间可以替换父目录

- **定位**：原plugin/index.js:181 `resolveBridgeDir`、:216 `safeFilePath`、:317–345写入。
- **问题**：resolve后把bridge替换成指向outside的junction，writeDecisionAtomic仍成功写入outside；原版隔离临时目录已复现。输入自身被定义白名单根，也缺独立批准根口径。
- **改成什么**：固定批准根与目录身份，在实际访问边界复验父目录realpath及目标；如声称抵御恶意并发替换，须固定目录句柄或限制并明确竞态威胁模型。补“resolve→换junction→write”以及读路径测试。
- **不改会怎样**：文件写到校验时桥目录之外。没有证据将其夸大为模型代码执行。
- **状态**：**已修(t13，父目录realpath重验子项)**；**已修(t12，目录所有者令牌探测子项)**。令牌存在不证明真实路径安全，复制令牌或检查后替换仍需单独评估；不宣称消除了任意TOCTOU。

### G06 — high：Lua替换失败会删掉已发布旧文件

- **定位**：原Lua main.lua:566–595 `bridge_write_raw`。
- **问题**：第一次rename失败就remove(target)，第二次失败旧文件已丢；flush/close返回值未完整校验。原版注入rename恒失败，old-state保留断言为false。
- **改成什么**：失败保留旧版本并清tmp；校验write/flush/close；若采用备份移动，测试目标挪走后发布失败及回滚失败，明确保留旧字节在哪里。protocol §1.3允许remove+rename却又要求失败保旧，需contract澄清，不能让实现背负自相矛盾承诺。
- **不改会怎样**：权限/磁盘/占用错误导致最后可用state/event/applied丢失。
- **状态**：**已修(t12，rename恒失败保旧分支，T22)**；双重失败、flush/close失败和备份恢复语义需复核，未把“有备份”写成严格原子性通过。

### G07 — high：生成回调冷缓存会扫描API，候选不可查时扩大全表

- **定位**：原Lua main.lua:1972 `on_pre_get_collectible`→`ensure_candidates`、:970 `build_candidates`、:990–998、:1865 fallback。
- **问题**：冷缓存在生成帧扫描全部道具并日志输出，本地规则可刷新持有快照；池API失败或空集时改用全部合法道具，混入其它池。
- **改成什么**：提前构建候选/持有快照；生成只查匹配K的内存，无局面返回nil并排队rejected/none。真实空池或无法证明池归属应安全跳过/降级，不能冒充全表候选。对冷缓存生成计数API扫描、io和日志，断言均不增长。
- **不改会怎样**：帧内开销不受控，且无可信池信息仍强行替换为其它池道具。
- **状态**：**待修**。现有T17只检查文件没出现，不能证明“只查内存”。

### G08 — high：核验前发布成功、失败回执不符合真值表

- **定位**：原Lua main.lua:1978 `write_applied`、:2010–2046 `on_pickup_init`。
- **问题**：核验前排队applied/llm；超2帧只清pending；不匹配仅改phase/applied_by，原版实测rejected+llm+fallback=false+item。
- **改成什么**：成功只在核验后发布；失败/超窗/无实体统一rejected/none，source/provider/choice=null、fallback=true；核验按目标身份关联，不能取两帧内任意collectible。增加无init、多抽取乱序init和mismatch。
- **不改会怎样**：未生效意图被记作llm成功，审计字段互相冲突。
- **状态**：**已修(t12，rejected字段清空真值表子项，T23)**；核验前排队、超窗、目标关联仍待修/复核，不能整项计关闭。

### G09 — high：插件state校验漏硬依赖和目标一致性

- **定位**：原plugin/index.js:384–533 `validateStateDoc`。
- **问题**：unknown requires、缺reason_code、trigger=null而candidate.pedestal_index=3，原版三项均返回ok:true；draft.5还须校验session_id及pool。
- **改成什么**：requires有界字符串数组，未知能力version_minor_feature；reason_code/session_id必填，null目标候选全null且payload.pool必填；body可关联时发valid:false，身份不足不得猜。
- **不改会怎样**：缺能力或目标矛盾仍照常做决策。
- **状态**：**已修(t13，requires/reason_code/pedestal校验子项)**；session及pool见下方补充D5-A，不能用原三项回归代表draft.5完整校验。

### G10 — high：Lua决策字段只有存在性检查，未落实全量契约

- **定位**：原Lua main.lua:1240–1368 `validate_decision`、:1213能力表。
- **问题**：原版decision_id=5、ts='not-time'、error_code='BOGUS'、rule/fallback且choice在池内时仍返回true；apply:morph登记可识别但没有该能力实现。未知provider在draft.5应WARN，旧校验反而拒绝。
- **改成什么**：按§3.1校验类型/正则/范围/五类码、session、requires，能力仅报告实际支持；valid:false先完成结构/身份校验再保留拒绝原因；已知prefix冲突拒绝，未知prefix告警放行。分别注入畸形字段，不能只测缺confidence。
- **不改会怎样**：非法文档可能执行或后续索引抛错，跨局隔离/扩展兼容失效。
- **状态**：**待修**；t12五项修复没有覆盖完整协议校验。

### G11 — high：超时只abort流，非合作上游仍能挂住工具

- **定位**：原plugin/index.js:745–808 `callModelOnce`、:1306–1316发布。
- **问题**：for-await必须等流结束；原版mock忽略signal，validity=700ms，1006ms后才返回并写TIMEOUT。流永不结束则兜底也不会到。
- **改成什么**：独立deadline竞争并隔离后台消费；截止后主路径在预算内结束，迟到流不能再发布；写队列内再次校验资格。用忽略signal的永不结束/延迟结束mock，外部测试超时必须有界。
- **不改会怎样**：上游不响应取消即无限挂起，取消和兜底保证依赖供应商配合。
- **状态**：**待专项复核**；不把R1/R2修复等同非合作取消已修。

### G12 — high（架构验收差距）：四类接口缺真实组装入口

- **定位**：原plugin/index.js:1074–1343 `runIsaacDecide`、:1380 `apply`；architecture §3/§4。
- **问题**：模型/规则固定调用；无EventSource start/stop注入、Enricher链、Presenter bus。viewer仅进LLM提示，不是确定性ViewerVoteProvider；两个工具本身无state监听。
- **改成什么**：若只交付手动工具，明确本阶段范围，不宣称四接口已验收；若本轮验收四接口，提供组装入口、统一预算/校验/隔离，每类替换一个离线实现而不改核心。无需为了演练真的联网B站/TTS/OBS。
- **不改会怎样**：新provider、事件、增强、展示都得改核心，文档的可插拔承诺未落实。
- **状态**：**未完成架构验收**；不将未来所有适配器都列为v1必做，也不把未启用可选服务算运行错误。

### G13 — medium：时钟扩展改必填语义，draft.5会话未端到端实现

- **定位**：原Lua main.lua:25–26、:128–133 `doc_ts`、:1116 state；插件:970 `computeBudget`、:940 `makeDecisionDoc`。
- **问题**：无os.time时ts发单调值+x_clock，注释声称插件按接收时间，实际插件始终按epoch减Date.now。原版state有session_id，但decision/event/applied均未完整回显/验证。
- **改成什么**：统一可靠epoch时钟并检测>5秒跳变；不可用显式降级，不让x_修改ts含义。session_id保留正式名字，在四文档及索引贯通；禁止沿用旧建议改x_session_id。
- **不改会怎样**：时钟降级路径立即判过期，跨局身份要求失效。
- **状态**：**待draft.5专项修复**。

### G14 — medium：未知信息的省略/null及本地规则不符合新契约

- **定位**：原Lua main.lua:1007、1087、1136–1137 `build_state_doc`；Lua:1518 / 插件:591本地规则。
- **问题**：必填name为nil被编码器省略；可选非nullable max/cid反而发null，插件拒绝；局部API失败静默默认而error_code仍null。两端都把max_red缺省当可回血，draft.5已要求跳过。
- **改成什么**：必填可null用JSON_NULL，非nullable可选未知省略；已知读取失败显式state降级；heal需max_red存在且>0。测试name未知、API抛错、max未知且heal排前damage在后的联测。
- **不改会怎样**：未知数据被导出为非法body，或本地规则基于未知角色错误优先回血。
- **状态**：**待修/新契约对齐**。

### G15 — medium：非法reason被清洗为llm成功

- **定位**：原plugin/index.js:737 `normalizeDraft`→:140–146 `sanitizeReason`。
- **问题**：原版'a\nb'变'a b'，281字符截280，掩盖模型违约；缺confidence默认0.6属于内部模型draft政策，应与线上必填校验分别说明。
- **改成什么**：模型reason先校验类型、1..280码点、≤1024字节、无控制字符，非法抛invalid_reason进入已有重试/兜底；自有展示文案清洗不得替代模型输出校验。
- **不改会怎样**：违约输出被计为模型成功，协议测试与产品统计分叉。
- **状态**：**已修(t13，reason严格校验子项)**；字节上限、空串及Unicode控制范围须由复评逐项核对。

## 3. draft.5补充与证据边界

**D5-A（high，契约对齐）**：原插件`validateStateDoc`不要求session_id，`makeDecisionDoc`不输出session_id；原Lua仅state含session，其余三文档/消费未贯通。原版直接调用实测missing_session_accepted={ok:true}、decision_session_missing=true。按§1.5/§3.1统一四文档与索引，错session拒绝session_mismatch。修后不能沿用旧夹具无session仍通过来证明draft.5。

**D5-B（medium，可扩展性）**：原插件`providerSourceMatches`对foo:primary返回false；makeDecisionDoc抛INTERNAL。draft.5 §3.5要求未知prefix WARN放行；已知rule前缀配llm仍应拒绝。不可把放行未知前缀误解为放宽source/fallback真值表。

**D5-C（high，产品能力）**：原Lua `bridge_detect`把可读能力依赖于可写io/os，写探测失败不会保留只读B；无io/os返回none并提示用luadebug。应先独立确认实际可用只读API，读通过但写失败进入B；拿不到只读API时明确none，不能把本地规则叫“B预置决策已可用”。游戏API可用性本轮拿不到，不猜其实现。

已读模型/观众输出按JSON数据处理，没有发现eval、Function或执行模型输出；未发现Lua/插件读取API key的实现。路径风险见G05，不能夸大为远程代码执行。无游戏启动、真实DSH工具加载、真实模型、真实B站或字体渲染验证。

命名整体遵守Lua snake_case/JS camelCase；原Lua约2183行，runIsaacDecide约270行且结果组装重复。可在缺陷修复中抽取发布/结果封装，不为“文件长”单独制造阻塞或要求重写。

## 4. 五条失败路径与测试证据

| 路径 | 原套件真实覆盖 | 本轮补充证据及缺口 |
| --- | --- | --- |
| 超时 | Lua T06生成时无响应，未推进时钟；插件作者套件旧ts不调模型 | 已缓存过期、非合作stream必须单测；原版700ms预算实测1006ms才返回 |
| 非法id | Lua T04/T05，不存在/池外；插件normalizeDraft池外 | 有真实断言；不能替代完整字段或池API失败校验 |
| 版本不匹配 | Lua T07 major；插件validate major fatal | 有原断言；unknown requires/minor/session需另测 |
| 写入失败 | 原Lua仅成功写后无tmp；插件原套件亦主要成功写 | 原Lua注入rename恒失败丢旧state；插件目标为含sentinel目录时失败保留sentinel、tmp=0；t12新增T22 |
| 迟到 | Lua T10超validity；T18仅相同decision_id重复 | 不覆盖生成后新id/同K另一request；原版已复现二次llm命中；t12 T20补同request子项 |

原Lua通过：在lupa.lua54中内存加载源码，受控替换os.exit，**74/74**；未把原run_lua_test.py直接退出导致的subst副作用带入复现。作者报Lua5.3也过属于依赖结果，本轮未重跑原5.3。原插件`node --check`退出0；仓库外作者脚本`E:/Temp/isaac-t4/test.mjs`本轮读取并运行，**68 passed / 0 failed，退出0**。该脚本未入原仓库，且将非法reason清洗视为通过，不能作为严格协议校验通过。

t12/t13修后作者报告Lua106、插件111项，已合入0e4d66f；这属于修复方证据，**本文件初版未完整重跑修后套件，不将其改写成GPT独立复验通过**。

## 5. 可执行复现方式（原实现）

所有复现离线；只使用隔离临时桥目录。先用git确认Lua工作树为8069d9f、插件工作树为e3bdf81，不能在修后基线上期待同样失败。下面代码作为诊断指令，不是实现补丁，也不应写入生产桥目录。

### 5.1 插件R1/R2反序及校验漏项

在原插件仓库运行 `node --input-type=module`，粘贴：

```js
import { __testing as t } from './plugin/index.js';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'isaac-review-'));
const s = () => ({protocol_version:'1.0',session_id:'s-review-0001',
 request_id:'r-review-0001',gen_level_key:'f2:r84:treasure:p0:a',
 ts:Date.now(),validity_ms:1500,error_code:null,reason_code:null,
 trigger:{type:'room_enter',pedestal_index:null,payload:{pool:'treasure'}},
 state:{player:{red_hearts:4,soul_hearts:2},items:[],
 room:{type:'treasure',is_boss_room:false},floor:2,boss:null,
 candidates:[{pedestal_index:null,item_id:4,name:null}]}});
const exec = {agent:{model:{current:()=>({provider:'mock',model:'offline'})}}};
const ctx = stream => ({get:n=>n==='llm'?{stream}:undefined});
let release, entered;
const gate = new Promise(r=>release=r);
const started = new Promise(r=>entered=r);
try {
 const old=s(), fresh=s(); fresh.request_id='r-review-0002';
 const slow=async function*(){entered();await gate;
  yield {type:'text-delta',text:'{"item_id":4,"reason":"old"}'};};
 const fast=async function*(){
  yield {type:'text-delta',text:'{"item_id":4,"reason":"new"}'};};
 const a=t.runIsaacDecide({config:{bridgeDir:dir},ctx:ctx(slow),args:{state:old},exec});
 await started;
 await t.runIsaacDecide({config:{bridgeDir:dir},ctx:ctx(fast),args:{state:fresh},exec});
 release();await a;
 console.log('final_request',JSON.parse(await fs.readFile(path.join(dir,'decision.json'),'utf8')).request_id);
 const req=s();req.requires=['review:unsupported'];
 console.log('unknown_requires',t.validateStateDoc(req));
 const target=s();target.state.candidates[0].pedestal_index=3;
 console.log('null_target',t.validateStateDoc(target));
} finally {release?.();await fs.rm(dir,{recursive:true,force:true});}
```

原版实测：final_request=r-review-0001，两个非法state均ok:true。修后预期不得写旧R1，两个非法state明确拒绝。

### 5.2 Lua原74条与消费后迟到

在原Lua工作树（已安装lupa）用Python读取测试源，在执行前将`pcall(dofile, MOD_DIR .. "/main.lua")`替换为`pcall(assert(load(review_main)))`；用Python按UTF-8读main/tags注入Lua全局，`package.preload['data.item_tags']`返回tags源码加载结果；把os.exit换为抛REVIEW_EXIT_n的函数，以免直接退出Python导致finally不运行。把下段插在测试源`local function cleanup()`之前，使用既有局部fixture，不创建新仓库文件：

```lua
reset_world()
local r,k=begin_request()
local id=T.S.current.candidates[1].item_id
publish(decision_doc(r,k,{type='item',item_id=id}))
T.poll_decision();draw(0);pickup(id)
print('outstanding_after_consume',T.S.outstanding[r]~=nil)
publish(decision_doc(r,k,{type='item',item_id=id}))
T.poll_decision()
print('post_generation_accepted',T.S.decision~=nil)
local _,rec=T.consume('treasure',k,T.S.current.candidates)
print('second_generation_applied_by',rec.applied_by)
```

原版实测true/true/llm。修后同request应为false/false/fallback；还必须把第二次publish改成消费前已发出的另一刷新request，验证同K全部终结。仅上面一条通过不关闭G01。

### 5.3 写入、缓存与核验故障注入

同一Lua fixture分别reset后：①begin_request→接收决策→clock_ms+=3000→12次on_update，检查request_id变化；②已有state写old-state→排队新state→临时令os.rename恒返回nil→flush→恢复rename，检查旧内容保留且无tmp；③合法决策→draw→pickup(999)，检查rejected/none及source/provider/choice=null、fallback=true。原版分别为未刷新、旧文件丢失、rejected+llm+false+item。

插件路径复现：mkdtemp下建bridge/outside，resolveBridgeDir(bridge)，把bridge重命名为original，fs.symlink(outside,bridge,'junction')，writeDecisionAtomic(已校验路径,{review:'escape'})；原版outside/decision.json存在。finally先删junction本身再清临时根。该复现只证明校验后父目录替换，没有证明任何远端攻击前提。

插件取消复现：validity_ms=700、新鲜ts，mock async generator忽略signal并延迟1000ms后yield合法item。原版约1006ms返回TIMEOUT且written=true；修复验证需独立外部截止，不能让永不结束mock挂住整套测试。

## 6. 分歧、补充及另一条评审线

DeepSeek独立档案由该线自己提交至`docs/reviews/impl-review-deepseek.md`（captain提供提交23771a7）。本GPT线不覆盖它、不冒认其检查结论；本版尚未读取其全文，因此没有证据声称两线一致或编造逐项分歧。交叉对照由后续复评追加，保留各自原文与基线。Claude实现评审本轮待补，不把任何模型当作第三份Claude意见。

本线对自己上一轮意见的实质修正：session_id不再要求x_；未知provider不能拒绝；去重/刷新SHOULD不提升为MUST；可选plugin_status缺失不单列阻塞；作者已修子项单列，不重复计分。对修复方案的保留：t12只清单request不能自动证明同K终结；所有者令牌不能自动证明路径原子安全；t13发布序号不能替代跨进程实例锁。这些是明确验收分歧点，不能用“已修五项”笼统抹平。

## 7. 必修清单（按严重度；当前状态优先）

| 顺序 | 项目 | 关闭条件 |
| --- | --- | --- |
| blocker | G01同K全部终态隔离 | R1/R2→消费→R2/D2迟到→第二次生成，不可再次llm；fallback也终结 |
| high | G03跨进程锁 | 两独立进程只有一个写者，存活锁拒绝，死锁安全回收 |
| high | G07生成冷缓存/池失败 | 回调无扫描和磁盘日志，无法证明池归属返回nil/安全降级 |
| high | G08剩余核验时序 | 无init/超窗/乱序目标均不产生虚假成功回执 |
| high | G10、D5-A决策/session校验 | 四文档session贯通，畸形字段及错session拒绝 |
| high | G11非合作取消 | 工具在预算内结束，迟到/不结束流不能占住发布链 |
| high | G12扩展点交付范围 | 四类离线替换演练，或明确本轮仅工具交付未验收架构 |
| high | D5-C默认只读能力 | 独立读探针及真实可读API证据，不能假装B可用 |
| high复核 | G02/G04/G05/G06/G08/G09已修子项 | t12/t13新套件和剩余跨分支用例分别验，不重复记原缺陷 |
| medium | G13时间、G14未知信息/规则、D5-B前缀 | epoch/跳变、null/省略、max未知跳过、未知prefix WARN |
| medium复核 | G15 reason | 控制/字节/码点/空串输入均按契约拒绝，非清洗成功 |

修复完成后应对新固定commit单独复评；本档的原版复现不是修后失败证明。未启动游戏或真实DSH，不能据此声称集成通过。
