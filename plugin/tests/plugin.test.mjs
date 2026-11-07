import { promises as fsp } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const moduleUrl = process.env.PLUGIN_ENTRY
  ? pathToFileURL(path.resolve(process.env.PLUGIN_ENTRY))
  : new URL('../index.js', import.meta.url)
const mod = await import(moduleUrl.href)
const { __testing: T } = mod

const tmpRoot = path.join(os.tmpdir(), `isaac-t4-${process.pid}-${Date.now()}`)
const bridgeDir = path.join(tmpRoot, 'bridge')
process.env.ISAAC_AGENT_DIR = bridgeDir

let passed = 0
let failed = 0
function ok(name, cond, detail = '') {
  if (cond) {
    passed += 1
    console.log(`PASS ${name}${detail ? ` — ${detail}` : ''}`)
  } else {
    failed += 1
    console.log(`FAIL ${name}${detail ? ` — ${detail}` : ''}`)
  }
}
function eq(name, actual, expected) {
  ok(name, Object.is(actual, expected) || JSON.stringify(actual) === JSON.stringify(expected), `actual=${JSON.stringify(actual)}`)
}

const example = JSON.parse(
  await fsp.readFile(new URL('../../protocol/examples/01-success.json', import.meta.url), 'utf8'),
)
const baseState = structuredClone(example.files['state.json'])

// ── 1. validation ─────────────────────────────────────────────────────────────
eq('validate example state', T.validateStateDoc(baseState).ok, true)

{
  const bad = structuredClone(baseState)
  delete bad.request_id
  const result = T.validateStateDoc(bad)
  eq('missing request_id is fatal', result.fatal, true)
  eq('missing request_id reason', result.reasonCode, 'missing_field')
}
{
  const bad = structuredClone(baseState)
  bad.protocol_version = '2.0'
  const result = T.validateStateDoc(bad)
  eq('major mismatch is fatal', result.fatal, true)
  eq('major mismatch reason', result.reasonCode, 'version_major')
}
{
  const bad = structuredClone(baseState)
  bad.state.candidates[1].pedestal_index = 3
  const result = T.validateStateDoc(bad)
  eq('pedestal mismatch rejected', result.reasonCode, 'state_invalid')
}
{
  const bad = structuredClone(baseState)
  bad.validity_ms = 99
  eq('validity out of range', T.validateStateDoc(bad).reasonCode, 'out_of_range')
}

// ── 2. local rule ─────────────────────────────────────────────────────────────
eq('rule default picks array-first candidate', T.pickByLocalRules(baseState.state).choice.item_id, 4)
{
  const state = structuredClone(baseState)
  state.ts = Date.now()
  state.state.player.red_hearts = 0
  eq('rule low hp picks heal', T.pickByLocalRules(state.state).choice.item_id, 22)
}
{
  const state = structuredClone(baseState)
  state.ts = Date.now()
  state.state.player.max_red_hearts = 0
  state.state.player.red_hearts = 0
  eq('rule keeper ignores heal', T.pickByLocalRules(state.state).choice.item_id, 4)
}
{
  const state = structuredClone(baseState)
  state.ts = Date.now()
  state.state.items = [{ id: 1, name: 'Sad Onion', tags: ['tear'], count: 1 }]
  eq('rule no damage picks damage', T.pickByLocalRules(state.state).choice.item_id, 4)
}
{
  const state = structuredClone(baseState)
  state.ts = Date.now()
  state.state.player.is_dead = true
  const rule = T.pickByLocalRules(state.state)
  eq('rule dead skips', rule.choice.action, 'skip')
  eq('rule dead reason', rule.reasonCode, 'player_dead')
}
{
  const state = structuredClone(baseState)
  state.ts = Date.now()
  state.state.candidates = []
  eq('rule empty pool skips', T.pickByLocalRules(state.state).reasonCode, 'no_candidate')
}

// ── 3. model output parsing ───────────────────────────────────────────────────
eq('parse plain json', T.parseModelJson('{"item_id":22,"reason":"x","confidence":0.7}').item_id, 22)
eq('parse fenced json', T.parseModelJson('```json\n{"item_id":4}\n```').item_id, 4)
eq('parse json with prose', T.parseModelJson('好的：{"action":"skip"} 完毕').action, 'skip')
eq('parse garbage', T.parseModelJson('not json'), null)
{
  const draft = T.normalizeDraft({ item_id: 22, reason: '补红心\n第二行', confidence: 0.8 }, baseState.state)
  eq('normalize valid draft', draft.choice.item_id, 22)
  eq('normalize reason single line', /[\r\n]/.test(draft.reason), false)
}
{
  let code = null
  try {
    T.normalizeDraft({ item_id: 999 }, baseState.state)
  } catch (error) {
    code = error.reasonCode
  }
  eq('normalize rejects out-of-pool id', code, 'invalid_id')
}
{
  let code = null
  try {
    T.normalizeDraft({ action: 'reroll' }, baseState.state)
  } catch (error) {
    code = error.reasonCode
  }
  eq('normalize rejects reroll', code, 'invalid_action')
}
eq('normalize defaults confidence', T.normalizeDraft({ item_id: 4 }, baseState.state).confidence, 0.6)

// ── 4. budget ────────────────────────────────────────────────────────────────
{
  const now = Date.now()
  const state = structuredClone(baseState)
  state.ts = Date.now()
  state.ts = now
  state.validity_ms = 1500
  const budget = T.computeBudget(state, now)
  ok('budget remaining ~ validity-200', budget.remaining >= 1200 && budget.remaining <= 1300, String(budget.remaining))
  state.ts = now - 10_000
  ok('budget expired when state is old', T.computeBudget(state, now).remaining < 0, String(T.computeBudget(state, now).remaining))
}

// ── 5. path safety ───────────────────────────────────────────────────────────
{
  let code = null
  process.env.ISAAC_AGENT_DIR = 'relative/path'
  try {
    await T.resolveBridgeDir({})
  } catch (error) {
    code = error.reasonCode
  }
  eq('relative bridge dir rejected', code, 'io_error')
  process.env.ISAAC_AGENT_DIR = bridgeDir
}
{
  let code = null
  try {
    await T.readStateFile(bridgeDir)
  } catch (error) {
    code = error.reasonCode
  }
  eq('missing state.json is IO', code, 'io_error')
}

let freshSeq = 0
const freshState = () => {
  const s = structuredClone(baseState)
  s.ts = Date.now()
  freshSeq += 1
  s.request_id = `r-test-${String(freshSeq).padStart(6, '0')}`
  return s
}

// ── 6. atomic write + full tool flows ────────────────────────────────────────
function fakeCtx(responses, { calls } = { calls: { n: 0 } }) {
  return {
    get(name) {
      if (name !== 'llm') return undefined
      return {
        stream() {
          calls.n += 1
          const text = responses[Math.min(calls.n - 1, responses.length - 1)]
          return (async function* () {
            await new Promise((resolve) => setTimeout(resolve, 5))
            yield { type: 'text-delta', index: 0, text }
            yield { type: 'finish', reason: { kind: 'stop' } }
          })()
        },
      }
    },
  }
}
const fakeExec = { agent: { model: { current: () => ({ provider: 'fake', model: 'fake-1' }) } }, signal: new AbortController().signal }

{
  const calls = { n: 0 }
  const result = await T.runIsaacDecide({
    config: { bridgeDir },
    ctx: fakeCtx(['{"item_id":22,"reason":"红心告急，先补红心","confidence":0.8}'], { calls }),
    args: { state: freshState() },
    exec: fakeExec,
  })
  ok('decide ok', result.ok === true && result.written === true, result.text)
  eq('decide choice', result.choice.item_id, 22)
  eq('decide source', result.source, 'llm')
  eq('decide provider', result.provider_id, 'llm:primary')
  const written = JSON.parse(await fsp.readFile(path.join(bridgeDir, 'decision.json'), 'utf8'))
  eq('decision.json request echo', written.request_id, result.request_id)
  eq('decision.json choice', written.decision.choice.item_id, 22)
  eq('decision.json source', written.decision.source, 'llm')
  const leftovers = (await fsp.readdir(bridgeDir)).filter((name) => name.includes('.tmp.'))
  eq('no tmp leftovers', leftovers.length, 0)
}

{
  const calls = { n: 0 }
  const result = await T.runIsaacDecide({
    config: { bridgeDir },
    ctx: fakeCtx(['not json', '{"item_id":4,"reason":"补输出","confidence":0.6}'], { calls }),
    args: { state: freshState() },
    exec: fakeExec,
  })
  eq('retry once then success', calls.n, 2)
  eq('retry choice', result.choice.item_id, 4)
  eq('retry attempts', result.attempts, 2)
}

{
  const calls = { n: 0 }
  const result = await T.runIsaacDecide({
    config: { bridgeDir },
    ctx: fakeCtx(['nope', 'still nope'], { calls }),
    args: { state: freshState() },
    exec: fakeExec,
  })
  eq('fallback after two bad outputs', result.source, 'rule')
  eq('fallback flag', result.fallback, true)
  eq('fallback error code', result.error_code, 'MODEL')
  eq('fallback reason code', result.reason_code, 'model_error')
  eq('fallback still publishes', result.written, true)
}

{
  const calls = { n: 0 }
  const state = freshState()
  state.error_code = 'IO'
  state.reason_code = 'io_error'
  const result = await T.runIsaacDecide({
    config: { bridgeDir },
    ctx: fakeCtx(['{"item_id":22}'], { calls }),
    args: { state },
    exec: fakeExec,
  })
  eq('degraded state does not call llm', calls.n, 0)
  eq('degraded state error passthrough', result.error_code, 'IO')
}

{
  const calls = { n: 0 }
  const state = freshState()
  state.state.player.is_dead = true
  const result = await T.runIsaacDecide({
    config: { bridgeDir },
    ctx: fakeCtx(['{"item_id":22}'], { calls }),
    args: { state },
    exec: fakeExec,
  })
  eq('dead player guard', result.reason_code, 'player_dead')
  eq('dead player no llm', calls.n, 0)
  eq('dead player fallback', result.fallback, true)
}

{
  const calls = { n: 0 }
  const state = freshState()
  state.state.candidates = []
  const result = await T.runIsaacDecide({
    config: { bridgeDir },
    ctx: fakeCtx(['{"item_id":22}'], { calls }),
    args: { state },
    exec: fakeExec,
  })
  eq('empty pool guard', result.reason_code, 'no_candidate')
}

{
  const state = freshState()
  delete state.request_id
  const result = await T.runIsaacDecide({
    config: { bridgeDir },
    ctx: fakeCtx(['{"item_id":22}']),
    args: { state },
    exec: fakeExec,
  })
  eq('unreadable envelope writes nothing', result.written, false)
  eq('unreadable envelope ok=false', result.ok, false)
}

{
  const state = freshState()
  state.validity_ms = 300
  state.ts = Date.now() - 5000
  if (typeof T.resetPublishStateForTest === 'function') T.resetPublishStateForTest()
  const calls = { n: 0 }
  const result = await T.runIsaacDecide({
    config: { bridgeDir },
    ctx: fakeCtx(['{"item_id":22}'], { calls }),
    args: { state },
    exec: fakeExec,
  })
  eq('expired budget skips llm', calls.n, 0)
  eq('expired budget reason', result.reason_code, 'timeout')
  eq('expired budget error', result.error_code, 'TIMEOUT')
}

// ── 7. isaac_state + stale ───────────────────────────────────────────────────
{
  await fsp.mkdir(bridgeDir, { recursive: true })
  await fsp.writeFile(path.join(bridgeDir, 'state.json'), JSON.stringify(baseState), 'utf8')
  const fresh = await T.runIsaacState({ config: { bridgeDir } })
  ok('isaac_state reads fresh file', fresh.ok === true, fresh.text.split('\n')[0])
  eq('isaac_state not stale', fresh.stale, false)
  ok('isaac_state has mtime', Number.isFinite(fresh.mtime_ms) && fresh.mtime_ms > 0, String(fresh.mtime_ms))

  const old = new Date(Date.now() - 60_000)
  await fsp.utimes(path.join(bridgeDir, 'state.json'), old, old)
  const stale = await T.runIsaacState({ config: { bridgeDir } })
  eq('isaac_state marks stale', stale.stale, true)
  ok('isaac_state age > 30s', stale.age_ms > 30_000, String(stale.age_ms))
}

// ── 8. plugin registration ──────────────────────────────────────────────────
{
  const registered = []
  mod.apply({ inject: (deps, cb) => { eq('plugin injects tools', deps.join(','), 'tools'); cb({ tools: { register: (definition) => registered.push(definition) } }) } }, { bridgeDir })
  eq('register two tools', registered.length, 2)
  eq('tool names', registered.map((tool) => tool.name).join(','), 'isaac_state,isaac_decide')
  ok('isaac_state execute exported', typeof registered[0].execute === 'function')
  ok('isaac_decide execute exported', typeof registered[1].execute === 'function')
  eq('plugin name export', mod.name, 'dsh-isaac-agent')
  const stateResult = await registered[0].execute({}, { signal: new AbortController().signal })
  ok('registered isaac_state runs', stateResult.ok === false || stateResult.ok === true, stateResult.text.split('\n')[0])
}

// ── 9. bad json in state.json ────────────────────────────────────────────────
{
  await fsp.writeFile(path.join(bridgeDir, 'state.json'), '{oops', 'utf8')
  const result = await T.runIsaacState({ config: { bridgeDir } })
  eq('bad state.json rejected', result.ok, false)
  eq('bad state.json code', result.error_code, 'VALIDATION')
}

// ── 10. R1/R2 竞态、消费一次即作废、junction TOCTOU ─────────────────────────
const resetPublish = typeof T.resetPublishStateForTest === 'function'
  ? T.resetPublishStateForTest
  : () => {}

function fakeLlmCtx(script) {
  let index = 0
  const calls = { n: 0 }
  return {
    calls,
    get(name) {
      if (name !== 'llm') return undefined
      return {
        stream() {
          const step = script[Math.min(index, script.length - 1)]
          index += 1
          calls.n += 1
          return (async function* () {
            if (step.before) await step.before()
            if (step.delayMs) await new Promise((resolve) => setTimeout(resolve, step.delayMs))
            yield { type: 'text-delta', index: 0, text: step.text }
            yield { type: 'finish', reason: { kind: 'stop' } }
          })()
        },
      }
    },
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

{
  // R1 慢、R2 快：R1 后完成，不能覆盖 R2。
  resetPublish()
  const r1 = freshState()
  r1.request_id = 'r-race-000001'
  r1.ts = Date.now()
  const r2 = freshState()
  r2.request_id = 'r-race-000002'
  r2.ts = Date.now() + 10
  const ctx = fakeLlmCtx([
    { delayMs: 150, text: '{"item_id":4,"reason":"慢的旧请求","confidence":0.9}' },
    { delayMs: 5, text: '{"item_id":22,"reason":"快的新请求","confidence":0.9}' },
  ])
  const firstRun = T.runIsaacDecide({
    config: { bridgeDir }, ctx, args: { state: r1 }, exec: fakeExec,
  })
  await sleep(30)
  const secondRun = T.runIsaacDecide({
    config: { bridgeDir }, ctx, args: { state: r2 }, exec: fakeExec,
  })
  const [oldResult, newResult] = await Promise.all([firstRun, secondRun])
  const written = JSON.parse(await fsp.readFile(path.join(bridgeDir, 'decision.json'), 'utf8'))
  eq('R1/R2 final request is R2', written.request_id, 'r-race-000002')
  eq('R1/R2 final item is R2 choice', written.decision.choice.item_id, 22)
  eq('R1/R2 old result discarded', oldResult.discarded, true)
  eq('R1/R2 old result not written', oldResult.written, false)
  eq('R1/R2 new result written', newResult.written, true)
}

{
  // 同一个 request_id 只能发布一次；第二次必须丢弃。
  resetPublish()
  const state = freshState()
  state.request_id = 'r-consume-0001'
  const ctx = fakeLlmCtx([
    { text: '{"item_id":22,"reason":"第一份","confidence":0.9}' },
    { text: '{"item_id":4,"reason":"第二份","confidence":0.9}' },
  ])
  const first = await T.runIsaacDecide({
    config: { bridgeDir }, ctx, args: { state }, exec: fakeExec,
  })
  const second = await T.runIsaacDecide({
    config: { bridgeDir }, ctx, args: { state }, exec: fakeExec,
  })
  const written = JSON.parse(await fsp.readFile(path.join(bridgeDir, 'decision.json'), 'utf8'))
  eq('consume first written', first.written, true)
  eq('consume second discarded', second.discarded, true)
  eq('consume second reason', second.discard_reason, 'already_consumed')
  eq('consume file keeps first choice', written.decision.choice.item_id, 22)
}

{
  // 换层（gen_level_key 变化）后，旧层结果不能覆盖新层。
  resetPublish()
  const k1 = freshState()
  k1.request_id = 'r-level-000001'
  k1.gen_level_key = 'f1:r1:treasure:p0:aaaa'
  k1.ts = Date.now()
  const k2 = freshState()
  k2.request_id = 'r-level-000002'
  k2.gen_level_key = 'f2:r2:treasure:p0:bbbb'
  k2.ts = Date.now() + 10
  const ctx = fakeLlmCtx([
    { delayMs: 150, text: '{"item_id":4,"reason":"旧层","confidence":0.9}' },
    { delayMs: 5, text: '{"item_id":22,"reason":"新层","confidence":0.9}' },
  ])
  const firstRun = T.runIsaacDecide({
    config: { bridgeDir }, ctx, args: { state: k1 }, exec: fakeExec,
  })
  await sleep(30)
  const secondRun = T.runIsaacDecide({
    config: { bridgeDir }, ctx, args: { state: k2 }, exec: fakeExec,
  })
  const [oldResult] = await Promise.all([firstRun, secondRun])
  const written = JSON.parse(await fsp.readFile(path.join(bridgeDir, 'decision.json'), 'utf8'))
  eq('level change final key is K2', written.gen_level_key, 'f2:r2:treasure:p0:bbbb')
  eq('level change old discarded', oldResult.discarded, true)
  eq('level change old reason', oldResult.discard_reason, 'level_changed')
}

{
  // 磁盘上的 state.json 已经换成 R2，而插件还没登记 R2：R1 仍须丢弃。
  resetPublish()
  const r1 = freshState()
  r1.request_id = 'r-disk-000001'
  r1.ts = Date.now()
  const r2 = freshState()
  r2.request_id = 'r-disk-000002'
  r2.ts = Date.now() + 10
  await fsp.mkdir(bridgeDir, { recursive: true })
  await fsp.writeFile(path.join(bridgeDir, 'state.json'), JSON.stringify(r1), 'utf8')
  const ctx = fakeLlmCtx([{
    before: async () => {
      await fsp.writeFile(path.join(bridgeDir, 'state.json'), JSON.stringify(r2), 'utf8')
    },
    text: '{"item_id":22,"reason":"磁盘已更新","confidence":0.9}',
  }])
  const result = await T.runIsaacDecide({
    config: { bridgeDir }, ctx, args: {}, exec: fakeExec,
  })
  eq('disk supersede discarded', result.discarded, true)
  eq('disk supersede reason', result.discard_reason, 'superseded')
  eq('disk supersede not written', result.written, false)
}

{
  // TOCTOU：校验通过后把父目录换成 junction，写入必须拒绝且不能落到白名单外。
  resetPublish()
  const root = path.join(tmpRoot, 'junction-case')
  const bridge = path.join(root, 'bridge')
  const bridgeOld = path.join(root, 'bridge-old')
  const outside = path.join(root, 'outside')
  await fsp.mkdir(bridge, { recursive: true })
  await fsp.mkdir(outside, { recursive: true })
  const ownerToken = 'mod-owner-token-v1'
  await fsp.writeFile(path.join(bridge, '.isaac_agent_owner'), ownerToken, 'utf8')

  const state = freshState()
  state.request_id = 'r-junction-0001'
  const ctx = fakeLlmCtx([{
    before: async () => {
      // 模拟攻击：把原目录整体挪走，再用 junction 顶替。令牌仍在 bridge-old 里，
      // 插件不得删除/改写它，也不得跟随 junction 写 outside。
      await fsp.rename(bridge, bridgeOld)
      await fsp.symlink(outside, bridge, 'junction')
    },
    text: '{"item_id":22,"reason":"junction","confidence":0.9}',
  }])
  const previousDir = process.env.ISAAC_AGENT_DIR
  process.env.ISAAC_AGENT_DIR = bridge
  let result
  try {
    result = await T.runIsaacDecide({
      config: { bridgeDir: bridge }, ctx, args: { state }, exec: fakeExec,
    })
  } finally {
    process.env.ISAAC_AGENT_DIR = previousDir
  }
  const outsideFiles = await fsp.readdir(outside)
  const ownerAfter = await fsp.readFile(path.join(bridgeOld, '.isaac_agent_owner'), 'utf8')
  eq('junction write rejected', result.ok, false)
  eq('junction outside untouched', outsideFiles.length, 0)
  eq('junction not reported as written', result.written, false)
  eq('junction owner token untouched', ownerAfter, ownerToken)

  // 只删 junction 链接，不跟随删除 outside 内容。
  await fsp.rmdir(bridge).catch(() => undefined)
}

async function withBridgeEnv(dir, fn) {
  const previous = process.env.ISAAC_AGENT_DIR
  process.env.ISAAC_AGENT_DIR = dir
  try {
    return await fn()
  } finally {
    process.env.ISAAC_AGENT_DIR = previous
  }
}

{
  // A) 模型忽略 AbortSignal：响应超过 validity，必须丢弃而不是写过期决策。
  resetPublish()
  const lateDir = path.join(tmpRoot, 'late-case')
  await fsp.mkdir(lateDir, { recursive: true })
  const state = freshState()
  state.request_id = 'r-late-000001'
  state.validity_ms = 600
  state.ts = Date.now()
  const ctx = fakeLlmCtx([{
    delayMs: 700,
    text: '{"item_id":22,"reason":"迟到的模型结果","confidence":0.9}',
  }])
  const result = await withBridgeEnv(lateDir, () => T.runIsaacDecide({
    config: { bridgeDir: lateDir }, ctx, args: { state }, exec: fakeExec,
  }))
  const exists = await fsp.stat(path.join(lateDir, 'decision.json')).then(() => true).catch(() => false)
  eq('late model result discarded', result.discarded, true)
  eq('late model result reason', result.discard_reason, 'late')
  eq('late model result error', result.error_code, 'TIMEOUT')
  eq('late model result reason_code', result.reason_code, 'late')
  eq('late model result not written', result.written, false)
  eq('late model result leaves no decision', exists, false)
}

{
  // B) requires 含未知能力：按 §7.4 拒绝，发布 valid:false 而不是当正常请求处理。
  const state = freshState()
  state.requires = ['unsupported:must']
  const validation = T.validateStateDoc(state)
  eq('unknown requires rejected', validation.ok, false)
  eq('unknown requires reason', validation.reasonCode, 'version_minor_feature')
  const result = await T.runIsaacDecide({
    config: { bridgeDir }, ctx: fakeLlmCtx([{ text: '{"item_id":22}' }]), args: { state }, exec: fakeExec,
  })
  eq('unknown requires publishes rejection', result.valid, false)
  eq('unknown requires rejection reason', result.reason_code, 'version_minor_feature')
  eq('unknown requires rejection written', result.written, true)

  const known = freshState()
  known.requires = ['transport:file_read']
  eq('known requires accepted', T.validateStateDoc(known).ok, true)

  const featuresOnly = freshState()
  featuresOnly.features = ['future:unknown']
  eq('unknown features ignored', T.validateStateDoc(featuresOnly).ok, true)
}

{
  // B) pool 目标与候选 pedestal_index 的一致性。
  const pool = freshState()
  pool.trigger.pedestal_index = null
  pool.state.candidates[0].pedestal_index = 1
  eq('pool candidate must be null', T.validateStateDoc(pool).reasonCode, 'state_invalid')

  const poolPayload = freshState()
  poolPayload.trigger.pedestal_index = null
  poolPayload.trigger.payload = { pool: null }
  eq('null pool payload rejected', T.validateStateDoc(poolPayload).reasonCode, 'invalid_type')

  const pedestalNull = freshState()
  pedestalNull.state.candidates[0].pedestal_index = null
  eq('specific pedestal candidate must match', T.validateStateDoc(pedestalNull).reasonCode, 'state_invalid')

  const pedestalRange = freshState()
  pedestalRange.state.candidates[0].pedestal_index = 64
  eq('pedestal index range checked', T.validateStateDoc(pedestalRange).reasonCode, 'out_of_range')
}

{
  // B) 根节点不是对象：信封不可读，不能进入拒绝决策路径（曾抛 INTERNAL）。
  const validation = T.validateStateDoc(null)
  eq('null root is fatal', validation.fatal, true)
  eq('null root reason', validation.reasonCode, 'invalid_type')
  const result = await T.runIsaacDecide({
    config: { bridgeDir }, ctx: fakeLlmCtx([{ text: '{"item_id":22}' }]), args: { state: null }, exec: fakeExec,
  })
  eq('null root not written', result.written, false)
  eq('null root not internal', result.error_code === 'INTERNAL', false)
}

{
  // C) reason 按 UTF-8 字节截断：280 个 emoji 不能写出 1120 字节。
  const state = freshState()
  const draft = T.normalizeDraft(
    { item_id: 22, confidence: 0.8, reason: '😀'.repeat(280) },
    state.state,
  )
  const doc = T.makeDecisionDoc(state, draft, {
    source: 'llm',
    providerId: 'llm:primary',
    fallback: false,
  })
  const chars = Array.from(doc.decision.reason).length
  const bytes = Buffer.byteLength(doc.decision.reason, 'utf8')
  ok('reason chars capped', chars <= 280, String(chars))
  ok('reason bytes capped', bytes <= 1024, String(bytes))
  ok('reason not empty after truncation', chars > 0 && bytes > 0, `${chars}/${bytes}`)
}

await fsp.rm(tmpRoot, { recursive: true, force: true })
console.log(`\n${passed} passed, ${failed} failed`)
if (failed > 0) process.exitCode = 1
