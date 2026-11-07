--[[ ============================================================================
tests/lua_logic_test.lua — isaac_agent 离线逻辑测试
============================================================================
不启动游戏：用桩替代 Isaac / REPENTOGON API，直接驱动 mod 的钩子与内部函数。

覆盖（协议 docs/protocol.md 的契约测试矩阵子集）：
  T01 state.json 导出 + 原子写（无 .tmp 残留）
  T02 合法 llm 决策 → 回调 62 返回该 id，applied_by=llm
  T03 POST_PICKUP_INIT 核验 → applied.actual_item_id 落盘
  T04 非法 id（不存在）→ invalid_id，本地兜底
  T05 合法但不在候选池 → invalid_choice，本地兜底
  T06 超时无决策 → no_fresh_decision，本地兜底
  T07 major 版本不匹配 → version_major，本地兜底
  T08 缺必填字段 → missing_field
  T09 gen_level_key 不匹配 → level_mismatch
  T10 迟到决策（超过 validity）→ late 丢弃
  T11 valid:false 拒绝响应 → 不执行其 skip，走本地规则
  T12 本地规则：缺红心 → heal 候选
  T13 本地规则：缺输出 → damage 候选
  T14 本地规则：默认分支 → 数组第一个候选
  T15 Profile none（无文件能力）→ 本地规则 + 气泡写明“桥接不可用”
  T16 无中文字体时渲染不抛错（ASCII 降级）
  T17 回调内零磁盘 I/O（落盘只在 on_update）
  T18 重复 decision_id 忽略
  T19 Boss 房预取（trigger/validity/payload/event）
  T20 消费一次即作废（同一 request 的后续决策按 late 拒绝，第二次生成记 fallback）
  T21 过期缓存不得阻断刷新（decision_is_fresh + on_update 丢弃 + 新 request_id）
  T22 rename 失败保留旧 state（不删旧文件、不残留 tmp/.bak）
  T23 rejected 回执真值表（choice/source/provider_id=null、fallback=true、applied_by=none）
  T24 桥目录在探测后被替换（TOCTOU）→ 拒绝写入并降级
  T25 消费清整个 K（R1→R2→生成，R2 迟到按 late 丢弃）
  T26 兜底生成同样清整个 K（之后同 K 的决策不得再被接受）
  T27 回执只在核验通过后写；超窗结算为 rejected/applied_by=none
  T28 capabilities 字段必须已删除（draft.4 统一为 features）
  T29 ts 毫秒精度（墙钟锚点 + 单调增量）
  T30 有效期边界按毫秒判定，且 ts 不参与

运行：
  lua tests/lua_logic_test.lua
  python tests/run_lua_test.py          # 没有 lua.exe 时用 lupa 内嵌 Lua 5.4
退出码：0 全过；1 有失败；2 环境不满足。
============================================================================ ]]

local SCRIPT = (arg and arg[0]) or "tests/lua_logic_test.lua"
local ROOT = SCRIPT:gsub("[\\/][^\\/]+$", "")
if ROOT == "" or ROOT == SCRIPT then ROOT = "." end
ROOT = ROOT:gsub("[\\/][^\\/]+$", "")      -- 去掉 tests/
if ROOT == "" then ROOT = "." end
local MOD_DIR = ROOT .. "/mods/isaac_agent"

package.path = MOD_DIR .. "/?.lua;" .. MOD_DIR .. "/?/init.lua;" .. package.path

-- ============================================================
-- 断言与结果
-- ============================================================
local passed, failures, current = 0, {}, nil
local function section(name) current = name end
local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failures[#failures + 1] = "[" .. tostring(current) .. "] " .. msg
    end
end
local function eq(actual, want, msg)
    check(actual == want,
        (msg or "") .. "（实际=" .. tostring(actual) .. "，期望=" .. tostring(want) .. "）")
end
local function contains(s, sub, msg)
    check(type(s) == "string" and s:find(sub, 1, true) ~= nil,
        (msg or "") .. "（实际=" .. tostring(s) .. "，应包含 " .. tostring(sub) .. "）")
end

-- ============================================================
-- 桩：Isaac / REPENTOGON / 游戏对象
-- ============================================================
local clock_ms = 100000
local world = { stage = 2, room_index = 84, room_type = 4, stage_seed = 1234, frame = 100 }

local VALID, CONFIG = {}, {}
local IDS = {
    1, 2, 3, 4, 7, 8, 10, 12, 13, 14, 15, 16, 21, 22, 23, 24, 25, 26,
    27, 28, 32, 34, 38, 42, 45, 47, 54, 67, 105, 114, 118, 149, 169, 172, 224, 331,
}
for _, id in ipairs(IDS) do
    VALID[id] = true
    CONFIG[id] = { Name = "#ITEM_" .. id .. "_NAME", Quality = 2, Tags = 0 }
end
-- 55：合法 collectible，但不在候选池（用于 invalid_choice）
VALID[55] = true
CONFIG[55] = { Name = "#ITEM_55_NAME", Quality = 1, Tags = 0 }
-- 100：任务道具（TAG_QUEST=1），必须被候选池过滤
VALID[100] = true
CONFIG[100] = { Name = "#QUEST_ITEM_NAME", Quality = 0, Tags = 1 }

local POOL_HAS = {}
for _, id in ipairs(IDS) do POOL_HAS[id] = true end
POOL_HAS[55] = false

local player = {
    hearts = 4, soul = 2, max_hearts = 8, type_id = 0, dead = false,
    items = { 1 },
}
function player:GetHearts() return self.hearts end
function player:GetSoulHearts() return self.soul end
function player:GetMaxHearts() return self.max_hearts end
function player:GetPlayerType() return self.type_id end
function player:IsDead() return self.dead end
function player:HasCollectible(id)
    for _, v in ipairs(self.items) do
        if v == id then return true end
    end
    return false
end

local level_obj = {
    GetStage = function() return world.stage end,
    GetCurrentRoomIndex = function() return world.room_index end,
    GetCurrentRoomDesc = function()
        return { SafeGridIndex = world.room_index, Data = { Type = world.room_type, Name = "" } }
    end,
}
local room_obj = {
    GetType = function() return world.room_type end,
    GetBossID = function() if world.room_type == 5 then return 63 end return 0 end,
    IsClear = function() return false end,
}
local seeds_obj = {
    GetStageSeed = function() return world.stage_seed end,
    GetStartSeed = function() return 424242 end,
}
local pool_obj = {
    IsCollectibleInPool = function(_, id) return POOL_HAS[id] == true end,
}
local game_obj = {
    GetFrameCount = function() return world.frame end,
    GetLevel = function() return level_obj end,
    GetRoom = function() return room_obj end,
    GetSeeds = function() return seeds_obj end,
    GetItemPool = function() return pool_obj end,
}

local function cfg_proxy(id)
    local c = CONFIG[id]
    return {
        Name = c.Name,
        Quality = c.Quality,
        Tags = c.Tags,
        IsAvailable = function() return true end,
    }
end

local item_config_obj = {
    GetCollectibles = function() return { Size = 400 } end,
    GetCollectible = function(_, id)
        if CONFIG[id] == nil then return nil end
        return cfg_proxy(id)
    end,
}

local debug_lines = {}

_G.Isaac = {
    GetTime = function() return clock_ms end,
    DebugString = function(s) debug_lines[#debug_lines + 1] = tostring(s) end,
    GetPlayer = function() return player end,
    GetItemConfig = function() return item_config_obj end,
    GetScreenWidth = function() return 512 end,
    GetScreenHeight = function() return 288 end,
    RenderText = function() end,
}
_G.Game = function() return game_obj end
_G.ItemConfig = {
    TAG_QUEST = 1,
    Config = {
        IsValidCollectible = function(id) return VALID[id] == true end,
    },
}
_G.Font = nil

local callbacks = {}
local mod_stub = {
    AddCallback = function(_, id, fn) callbacks[id] = fn end,
    SaveData = function() end,
    LoadData = function() return nil end,
    HasData = function() return false end,
}
_G.RegisterMod = function() return mod_stub end
_G.ModCallbacks = {
    MC_PRE_GET_COLLECTIBLE = 62,
    MC_POST_UPDATE = 1,
    MC_POST_RENDER = 2,
    MC_POST_GAME_START = 15,
    MC_POST_GAME_END = 16,
    MC_POST_NEW_LEVEL = 18,
    MC_POST_NEW_ROOM = 19,
    MC_EXECUTE_CMD = 32,
    MC_POST_PICKUP_INIT = 35,
}

-- ============================================================
-- 载入 mod
-- ============================================================
local ok_load, M = pcall(dofile, MOD_DIR .. "/main.lua")
if not ok_load or type(M) ~= "table" then
    io.stderr:write("无法载入 mod：" .. tostring(M) .. "\n")
    os.exit(2)
end
local T = M._test
local NULL = T.JSON_NULL

-- 标签表（mod 在 on_game_start 才加载；测试直接注入，避免依赖 require 路径）
do
    local ok_tags, tags_mod = pcall(require, "data.item_tags")
    if ok_tags and type(tags_mod) == "table" then
        T.S.tag_table = tags_mod.tags
    else
        T.S.tag_table = {}
    end
end

-- ============================================================
-- 文件/目录工具
-- ============================================================
local function sh(cmd)
    local ok, _, code = os.execute(cmd)
    return ok == true or ok == 0 or code == 0
end

local function read_file(path)
    local f = io.open(path, "rb")
    if f == nil then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

local function write_file(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local TEMP = os.getenv("TEMP") or os.getenv("TMP") or "."
local BRIDGE_DIR = TEMP .. "\\isaac_agent_test_" .. tostring(os.time()) ..
    "_" .. tostring(math.random(1000, 9999))
sh('mkdir "' .. BRIDGE_DIR .. '" 2>nul')
local function bpath(name) return BRIDGE_DIR .. "\\" .. name end

-- 每个用例从干净的桥目录开始（否则上一条用例的 applied.json 会被误读）
local function clear_bridge_files()
    for _, name in ipairs({ "state.json", "event.json", "applied.json", "decision.json" }) do
        os.remove(bpath(name))
    end
end

-- 残留的 *.tmp.* 文件（原子写必须清理）
local function tmp_files()
    local out = {}
    local p = io.popen('dir /b "' .. BRIDGE_DIR .. '\\*.tmp.*" 2>nul')
    if p ~= nil then
        for line in p:lines() do out[#out + 1] = line end
        p:close()
    end
    return out
end

-- ============================================================
-- 世界控制
-- ============================================================
local function reset_world()
    clock_ms = 100000
    world.stage = 2
    world.room_index = 84
    world.room_type = 4          -- ROOM_TREASURE
    world.stage_seed = 1234
    world.frame = 100
    player.hearts = 4
    player.soul = 2
    player.max_hearts = 8
    player.dead = false
    player.items = { 1 }
    T.reset()
    T.S.boot = "t0001"
    T.S.tag_table = T.S.tag_table or {}
    clear_bridge_files()
    T.detect({ dir = BRIDGE_DIR })
end

local function clear_decision()
    os.remove(bpath("decision.json"))
end

local function begin_request(trigger, pool)
    T.S.items_cache = nil
    M.hooks.on_new_level()
    local rid = T.request_state(trigger or "room_enter", pool or "treasure")
    T.flush_writes()
    return rid, T.S.current.gen_level_key
end

-- 回调 + 落盘（生产里由 on_update 的 flush_writes 完成）
local function draw(pool)
    local r = callbacks[62](nil, pool or 0, false, 1)
    T.flush_writes()
    return r
end

local function pickup(sub)
    M.hooks.on_pickup_init(nil, { Variant = 100, SubType = sub })
    T.flush_writes()
end

local DECISION_N = 0
local function decision_doc(rid, key, choice, overrides)
    DECISION_N = DECISION_N + 1
    local doc = {
        protocol_version = "1.0",
        request_id = rid,
        decision_id = string.format("d-test-%06d", DECISION_N),
        gen_level_key = key,
        ts = 1793982600000,
        error_code = NULL,
        valid = true,
        decision = {
            choice = choice,
            reason = "测试理由：补红心",
            confidence = 0.72,
            fallback = false,
            source = "llm",
            provider_id = "llm:primary",
            reason_code = NULL,
        },
    }
    if type(overrides) == "table" then
        for k, v in pairs(overrides) do doc[k] = v end
    end
    return doc
end

local function publish(doc)
    clear_decision()
    write_file(bpath("decision.json"), T.encode(doc))
end

local function read_applied()
    local text = read_file(bpath("applied.json"))
    if text == nil then return nil end
    local doc = T.decode(text)
    return doc
end

-- ============================================================
-- T01 state.json 导出 + 原子写
-- ============================================================
do
    section("T01 state 导出")
    reset_world()
    local rid, key = begin_request("room_enter", "treasure")
    local text = read_file(bpath("state.json"))
    check(text ~= nil, "state.json 应存在")
    if text ~= nil then
        local doc = T.decode(text)
        check(doc ~= nil, "state.json 必须是合法 JSON")
        eq(doc.protocol_version, "1.0", "protocol_version")
        eq(doc.request_id, rid, "request_id 应与返回一致")
        eq(doc.gen_level_key, key, "gen_level_key 应一致")
        eq(doc.validity_ms, 1500, "room_enter 的 validity_ms")
        eq(doc.trigger.type, "room_enter", "trigger.type")
        eq(doc.trigger.payload.pool, "treasure", "trigger.payload.pool")
        eq(doc.state.player.red_hearts, 4, "红心（半颗）")
        eq(doc.state.player.max_red_hearts, 8, "红心上限")
        eq(doc.state.room.type, "treasure", "房间类型")
        eq(doc.state.floor, 2, "层数")
        check(#doc.state.candidates > 0, "候选池非空")
        check(#doc.state.candidates <= 64, "候选池不超过 64 条")
        check(rid:match("^[A-Za-z0-9_%-]+$") ~= nil and #rid >= 8, "request_id 格式")
        check(key:match("^[A-Za-z0-9_.:%-]+$") ~= nil, "gen_level_key 格式")
        contains(text, '"error_code":null', "error_code 必须显式 null")
        -- 任务道具必须被过滤（id=100 不在候选里）
        local has_quest = false
        for _, c in ipairs(doc.state.candidates) do
            if c.item_id == 100 then has_quest = true end
        end
        check(not has_quest, "TAG_QUEST 道具不应进入候选池")
    end
    local leftovers = tmp_files()
    eq(#leftovers, 0, "原子写不得残留 tmp 文件（实际=" .. tostring(#leftovers) .. "）")
end

-- ============================================================
-- T02 合法 llm 决策 → 命中
-- ============================================================
do
    section("T02 合法决策")
    reset_world()
    local rid, key = begin_request()
    local cand = T.S.current.candidates[1].item_id
    publish(decision_doc(rid, key, { type = "item", item_id = cand }))
    T.poll_decision()
    check(T.S.decision ~= nil, "应接受合法决策")
    local got = draw(0)
    eq(got, cand, "回调 62 应返回决策 id")
    check(read_file(bpath("applied.json")) == nil, "核验前不得写成功回执")
    pickup(cand)                                  -- 核验通过后才写 applied
    local applied = read_applied()
    check(applied ~= nil, "applied.json 应存在")
    if applied ~= nil then
        eq(applied.applied_by, "llm", "applied_by")
        eq(applied.phase, "applied", "phase")
        eq(applied.choice.item_id, cand, "applied.choice")
        eq(applied.source, "llm", "source")
    end
end

-- ============================================================
-- T03 POST_PICKUP_INIT 核验
-- ============================================================
do
    section("T03 底座核验")
    reset_world()
    local rid, key = begin_request()
    local cand = T.S.current.candidates[2].item_id
    publish(decision_doc(rid, key, { type = "item", item_id = cand }))
    T.poll_decision()
    draw(0)
    world.frame = world.frame + 1
    pickup(cand)
    local applied = read_applied()
    check(applied ~= nil, "核验后应写回 applied.json")
    if applied ~= nil then
        eq(applied.actual_item_id, cand, "actual_item_id 应等于核验到的 id")
        eq(applied.phase, "applied", "核验通过 phase")
    end
    contains(T.S.bubble.text, "AI", "核验通过后气泡应显示 [AI]")
end

-- ============================================================
-- T04 非法 id（不存在）
-- ============================================================
do
    section("T04 invalid_id")
    reset_world()
    local rid, key = begin_request()
    publish(decision_doc(rid, key, { type = "item", item_id = 9999 }))
    T.poll_decision()
    check(T.S.decision == nil, "非法 id 不应被接受")
    eq(T.S.rejected.reason_code, "invalid_id", "拒绝原因")
    local got = draw(0)
    check(got ~= nil, "应走本地规则并返回候选")
    pickup(got)
    local applied = read_applied()
    eq(applied.applied_by, "fallback", "兜底 applied_by")
    eq(applied.reason_code, "invalid_id", "兜底 reason_code 取最后被拒原因")
end

-- ============================================================
-- T05 合法但不在候选池
-- ============================================================
do
    section("T05 invalid_choice")
    reset_world()
    local rid, key = begin_request()
    publish(decision_doc(rid, key, { type = "item", item_id = 55 }))
    T.poll_decision()
    eq(T.S.rejected.reason_code, "invalid_choice", "拒绝原因")
end

-- ============================================================
-- T06 超时
-- ============================================================
do
    section("T06 超时")
    reset_world()
    begin_request()
    clear_decision()
    local got = draw(0)
    check(got ~= nil, "超时应走本地规则（仍有候选）")
    pickup(got)
    local applied = read_applied()
    eq(applied.error_code, "TIMEOUT", "超时 error_code")
    eq(applied.reason_code, "no_fresh_decision", "超时 reason_code")
    eq(applied.applied_by, "fallback", "超时 applied_by")
end

-- ============================================================
-- T07 版本不匹配
-- ============================================================
do
    section("T07 version_major")
    reset_world()
    local rid, key = begin_request()
    local doc = decision_doc(rid, key, { type = "item", item_id = T.S.current.candidates[1].item_id })
    doc.protocol_version = "2.0"
    publish(doc)
    T.poll_decision()
    check(T.S.decision == nil, "major 不匹配不得接受")
    eq(T.S.rejected.reason_code, "version_major", "拒绝原因")
end

-- ============================================================
-- T08 缺字段
-- ============================================================
do
    section("T08 missing_field")
    reset_world()
    local rid, key = begin_request()
    local doc = decision_doc(rid, key, { type = "item", item_id = T.S.current.candidates[1].item_id })
    doc.decision.confidence = nil
    publish(doc)
    T.poll_decision()
    eq(T.S.rejected.reason_code, "missing_field", "拒绝原因")
end

-- ============================================================
-- T09 gen_level_key 不匹配
-- ============================================================
do
    section("T09 level_mismatch")
    reset_world()
    local rid, key = begin_request()
    local doc = decision_doc(rid, key, { type = "item", item_id = T.S.current.candidates[1].item_id })
    doc.gen_level_key = "f9:r0:treasure:p-1:deadbeef"
    publish(doc)
    T.poll_decision()
    eq(T.S.rejected.reason_code, "level_mismatch", "拒绝原因")
end

-- ============================================================
-- T10 迟到
-- ============================================================
do
    section("T10 late")
    reset_world()
    local rid, key = begin_request()
    clock_ms = clock_ms + 2000        -- 超过 validity_ms=1500
    publish(decision_doc(rid, key, { type = "item", item_id = T.S.current.candidates[1].item_id }))
    T.poll_decision()
    check(T.S.decision == nil, "迟到决策必须丢弃")
    eq(T.S.rejected.reason_code, "late", "拒绝原因")
    local got = draw(0)
    check(got ~= nil, "迟到后仍应本地兜底")
end

-- ============================================================
-- T11 valid:false 拒绝响应
-- ============================================================
do
    section("T11 valid=false")
    reset_world()
    local rid, key = begin_request()
    local doc = decision_doc(rid, key, { type = "action", action = "skip" }, {
        error_code = "MODEL",
        valid = false,
        decision = {
            choice = { type = "action", action = "skip" },
            reason = "模型失败",
            confidence = 1.0,
            fallback = true,
            source = "rule",
            provider_id = "rule:guard",
            reason_code = "model_error",
        },
    })
    publish(doc)
    T.poll_decision()
    check(T.S.decision == nil, "valid:false 不得接受")
    eq(T.S.rejected.reason_code, "model_error", "保留对端 reason_code")
    local got = draw(0)
    check(got ~= nil, "不得执行其 skip，应走本地规则")
    pickup(got)
    local applied = read_applied()
    eq(applied.applied_by, "fallback", "本地规则 applied_by")
end

-- ============================================================
-- T12 本地规则：缺红心 → heal
-- ============================================================
do
    section("T12 规则-heal")
    reset_world()
    player.hearts = 0
    player.max_hearts = 8
    T.S.items_cache = nil
    local rid, key = begin_request()
    local got = draw(0)
    check(got ~= nil, "应返回 heal 候选")
    local heal = { [15] = true, [16] = true, [22] = true, [23] = true, [24] = true, [25] = true, [26] = true, [45] = true }
    check(heal[got] == true, "应命中 heal 标签候选（实际=" .. tostring(got) .. "）")
    pickup(got)
    local applied = read_applied()
    contains(applied.reason, "红心", "理由应说明补红心")
end

-- ============================================================
-- T13 本地规则：缺输出 → damage
-- ============================================================
do
    section("T13 规则-damage")
    reset_world()
    player.hearts = 4
    player.items = { 1 }              -- 没有 damage 标签
    T.S.items_cache = nil
    begin_request()
    local got = draw(0)
    local dmg = { [4] = true, [7] = true, [12] = true, [13] = true, [34] = true, [114] = true,
        [118] = true, [149] = true, [169] = true, [172] = true, [331] = true }
    check(dmg[got] == true, "应命中 damage 标签候选（实际=" .. tostring(got) .. "）")
end

-- ============================================================
-- T14 本地规则：默认分支
-- ============================================================
do
    section("T14 规则-默认")
    reset_world()
    player.hearts = 4
    player.items = { 4 }              -- 已持有 damage → 跳过规则 4
    T.S.items_cache = nil
    begin_request()
    local got = draw(0)
    eq(got, IDS[1], "默认分支取数组第一个候选")
end

-- ============================================================
-- T15 Profile none
-- ============================================================
do
    section("T15 无文件能力")
    reset_world()
    T.detect({ io_available = false })
    eq(T.S.profile, "none", "Profile 应为 none")
    local rid = T.request_state("room_enter", "treasure")
    check(rid ~= nil, "无桥时仍应在内存里建请求（供本地规则用）")
    local got = draw(0)
    check(got ~= nil, "无桥时走本地规则")
    world.frame = world.frame + 1
    pickup(got)
    contains(T.S.bubble.text, "桥接不可用", "气泡必须说明桥接不可用")
    -- 恢复 Profile A，避免污染后续用例
    T.detect({ dir = BRIDGE_DIR })
end

-- ============================================================
-- T16 无字体渲染
-- ============================================================
do
    section("T16 渲染降级")
    reset_world()
    clock_ms = clock_ms + 10
    T.S.bubble.until_ms = clock_ms + 6000
    T.S.bubble.text = "测试气泡"
    T.S.bubble.ascii = "[AI] item#1"
    local ok_draw = pcall(M.hooks.on_render)
    check(ok_draw, "没有 Font 时渲染不得抛错")
end

-- ============================================================
-- T17 回调内不做磁盘 I/O
-- ============================================================
do
    section("T17 回调无 I/O")
    reset_world()
    local rid, key = begin_request()
    publish(decision_doc(rid, key, { type = "item", item_id = T.S.current.candidates[1].item_id }))
    T.poll_decision()
    os.remove(bpath("applied.json"))
    os.remove(bpath("state.json"))
    callbacks[62](nil, 0, false, 1)          -- 故意不 flush
    check(read_file(bpath("applied.json")) == nil, "回调 62 内不得写 applied.json")
    check(read_file(bpath("state.json")) == nil, "回调 62 内不得写 state.json")

    T.request_state("room_enter", "treasure")   -- 也只是入队，不是写盘
    check(read_file(bpath("state.json")) == nil, "request_state 不得立刻写盘")
    T.flush_writes()
    check(read_file(bpath("state.json")) ~= nil, "状态机 tick 落盘后 state.json 才出现")
    check(read_file(bpath("applied.json")) == nil, "回执要等核验通过才写，不能随 flush 出现")
    local pv = T.S.pending_verify
    pickup(pv and pv.item_id)
    check(read_file(bpath("applied.json")) ~= nil, "核验通过后 applied.json 才落盘")
end

-- ============================================================
-- T18 重复投递同一 decision_id
-- ============================================================
do
    section("T18 重复投递")
    reset_world()
    local rid, key = begin_request()
    local doc = decision_doc(rid, key, { type = "item", item_id = T.S.current.candidates[1].item_id })
    publish(doc)
    T.poll_decision()
    local first = T.S.decision
    check(first ~= nil, "第一条应被接受")
    publish(doc)
    T.poll_decision()
    check(T.S.decision == first, "相同 decision_id 重复到达必须忽略")
end

-- ============================================================
-- T19 Boss 房预取（trigger/validity/payload/event）
-- ============================================================
do
    section("T19 Boss 房预取")
    reset_world()
    world.room_type = 5              -- ROOM_BOSS
    M.hooks.on_new_room()
    T.flush_writes()
    local doc = T.decode(read_file(bpath("state.json")))
    check(doc ~= nil, "Boss 房应写出 state.json")
    if doc ~= nil then
        eq(doc.trigger.type, "boss_approach", "Boss 房触发类型")
        eq(doc.validity_ms, 5000, "Boss 长预取窗口")
        eq(doc.state.room.type, "boss", "房间类型")
        eq(doc.trigger.payload.pool, "boss", "池猜测")
        eq(doc.trigger.payload.boss_id, 63, "boss_id")
    end
    local ev = T.decode(read_file(bpath("event.json")))
    check(ev ~= nil, "应写出 event.json")
    if ev ~= nil then eq(ev.type, "boss_approach", "事件类型") end
end

-- ============================================================
-- T20 消费一次即作废：同一 request 的后续决策必须按 late 拒绝
--     （回归：消费后 request 仍留在 outstanding，第二次生成又记成 llm）
-- ============================================================
do
    section("T20 消费一次即作废")
    reset_world()
    local rid, key = begin_request()
    local cand1 = T.S.current.candidates[1].item_id
    local cand2 = T.S.current.candidates[2].item_id
    publish(decision_doc(rid, key, { type = "item", item_id = cand1 }))
    T.poll_decision()
    local got1 = draw(0)
    eq(got1, cand1, "第一次生成应使用决策")
    check(T.S.outstanding[rid] == nil, "消费后该 request 必须移出在途表")
    local consumed = T.S.consumed_requests
    check(consumed ~= nil and consumed[rid] == true, "消费过的 request 必须被记住")

    -- 同一个 request_id 再投一条新 decision（重复投递 / 生成后才到）
    publish(decision_doc(rid, key, { type = "item", item_id = cand2 }))
    T.poll_decision()
    check(T.S.decision == nil, "已消费请求的后续决策不得被接受")
    eq(T.S.rejected and T.S.rejected.reason_code, "late", "应按 late 拒绝")

    draw(0)
    local got2 = T.S.pending_verify and T.S.pending_verify.item_id
    check(got2 ~= nil, "第二次生成应走本地规则并返回候选")
    pickup(got2)
    local applied = read_applied()
    eq(applied.applied_by, "fallback", "第二次生成必须是兜底，不得复用已消费请求")
    eq(applied.source, "rule", "兜底 source 必须是 rule")
end

-- ============================================================
-- T21 过期缓存不得阻断刷新
--     （回归：S.decision 非空就一直压住 refresh，新请求发不出去）
-- ============================================================
do
    section("T21 过期缓存恢复刷新")
    reset_world()
    local rid, key = begin_request()
    publish(decision_doc(rid, key, { type = "item", item_id = T.S.current.candidates[1].item_id }))
    T.poll_decision()
    check(T.S.decision ~= nil, "先接受一条决策")
    local fresh_fn = T.decision_is_fresh
    check(fresh_fn ~= nil, "应暴露 decision_is_fresh（缓存失效判据）")
    if fresh_fn ~= nil then
        check(fresh_fn(T.S.decision) == true, "刚接受时应是新鲜的")
    end

    clock_ms = clock_ms + 2000                    -- 超过 validity_ms=1500
    if fresh_fn ~= nil then
        check(fresh_fn(T.S.decision) == false, "过期后必须判为不新鲜")
    end
    for _ = 1, 6 do
        world.frame = world.frame + 1
        M.hooks.on_update()
    end
    check(T.S.decision == nil, "过期缓存必须被丢弃")
    check(T.S.current ~= nil and T.S.current.request_id ~= rid,
        "丢弃过期缓存后必须重新发请求（新 request_id）")
end

-- ============================================================
-- T22 rename 失败必须保留旧 state（宁可不更新，也不能丢）
--     （回归：旧实现先 os.remove(target) 再重试，两次失败就把旧文件删了）
-- ============================================================
do
    section("T22 写入失败保留旧文件")
    reset_world()
    begin_request()
    local before = read_file(bpath("state.json"))
    check(before ~= nil, "先要有一份旧 state")

    local real_rename = os.rename
    os.rename = function() return false end
    T.request_state("room_enter", "treasure")
    T.flush_writes()
    os.rename = real_rename

    local after = read_file(bpath("state.json"))
    check(after ~= nil, "rename 失败后旧 state.json 必须还在")
    eq(after, before, "rename 失败不得改写/删除旧 state.json")
    eq(#tmp_files(), 0, "失败后不得残留 tmp 文件")
    check(read_file(bpath("state.json.bak")) == nil, "失败后不得残留 .bak 备份")
end

-- ============================================================
-- T23 rejected 回执真值表（协议 §5.4 行 3）
--     （回归：rejected 时仍带 llm + fallback=false + item）
-- ============================================================
do
    section("T23 rejected 回执真值表")
    reset_world()
    local rid, key = begin_request()
    local cand = T.S.current.candidates[1].item_id
    local other = T.S.current.candidates[2].item_id
    publish(decision_doc(rid, key, { type = "item", item_id = cand }))
    T.poll_decision()
    draw(0)
    world.frame = world.frame + 1
    pickup(other)                                  -- 实际生成的不是决策道具

    local applied = read_applied()
    check(applied ~= nil, "应写出 applied.json")
    if applied ~= nil then
        eq(applied.phase, "rejected", "phase")
        eq(applied.applied_by, "none", "applied_by")
        check(applied.choice == T.JSON_NULL, "choice 必须为 null")
        check(applied.source == T.JSON_NULL, "source 必须为 null")
        check(applied.provider_id == T.JSON_NULL, "provider_id 必须为 null")
        eq(applied.fallback, true, "fallback 必须为 true")
        eq(applied.reason_code, "not_applied", "reason_code")
    end
end

-- ============================================================
-- T24 桥目录在校验后被替换（TOCTOU）→ 必须拒绝写入
-- ============================================================
do
    section("T24 目录被替换")
    reset_world()
    begin_request()
    check(read_file(bpath("state.json")) ~= nil, "先有一份 state")

    -- 模拟：探测时的目录被改名，原路径上换成一个没有所有者令牌的新目录
    local moved = BRIDGE_DIR .. "_moved"
    sh('rmdir /s /q "' .. moved .. '" 2>nul')
    check(os.rename(BRIDGE_DIR, moved) == true, "目录改名应成功")
    sh('mkdir "' .. BRIDGE_DIR .. '" 2>nul')

    T.request_state("room_enter", "treasure")
    T.flush_writes()

    check(read_file(bpath("state.json")) == nil, "被替换的目录里不得写出 state.json")
    eq(T.S.profile, "none", "校验失败后应降级为 Profile none")
    eq(T.Bridge.kind, "none", "Bridge 应停用")

    -- 收尾：恢复原目录并重新探测，供后续用例使用
    sh('rmdir /s /q "' .. BRIDGE_DIR .. '" 2>nul')
    os.rename(moved, BRIDGE_DIR)
    T.detect({ dir = BRIDGE_DIR })
    eq(T.S.profile, "A", "恢复后应重新回到 Profile A")
end

-- ============================================================
-- T25 消费要清整个 K：R1 → R2 → 生成，R2 的迟到决策必须被丢弃
--     （协议 §6.7.1「生成发生后立即清空该 K 的未决项」/ §6.7.5「消费后该 K 的其余决策全部作废」）
-- ============================================================
do
    section("T25 消费清整个 K")
    reset_world()
    local rid1, key = begin_request()                        -- R1
    local rid2 = T.request_state("room_enter", "treasure")   -- R2（同 K，新 request_id）
    T.flush_writes()
    check(rid1 ~= rid2, "刷新请求必须有新的 request_id")
    check(T.S.current.gen_level_key == key, "R2 的 gen_level_key 应保持不变")
    check(T.S.outstanding[rid2] ~= nil, "R2 应在途")

    local item1 = T.S.current.candidates[1].item_id
    local item2 = T.S.current.candidates[2].item_id
    publish(decision_doc(rid1, key, { type = "item", item_id = item1 }))
    T.poll_decision()
    check(T.S.decision ~= nil, "R1 的决策应被接受")

    local got = draw(0)
    eq(got, item1, "生成应消费 R1 的决策")
    check(T.S.outstanding[rid2] == nil, "消费时必须一并清掉同 K 的 R2")
    local consumed = T.S.consumed_requests
    check(consumed ~= nil and consumed[rid2] == true, "R2 也必须记入已消费集合")

    -- R2 的决策迟到：必须丢弃，不能留给下一次生成
    publish(decision_doc(rid2, key, { type = "item", item_id = item2 }))
    T.poll_decision()
    check(T.S.decision == nil, "R2 的迟到决策不得被接受")
    eq(T.S.rejected and T.S.rejected.reason_code, "late", "应判 late")
end

-- ============================================================
-- T26 兜底生成同样是一次“生成”：也必须清空该 K 的未决项
-- ============================================================
do
    section("T26 兜底也清 K")
    reset_world()
    local rid1, key = begin_request()
    local rid2 = T.request_state("room_enter", "treasure")
    T.flush_writes()
    clear_decision()
    local got = draw(0)                                       -- 无决策 → 本地规则
    check(got ~= nil, "无决策时应走本地规则并返回候选")
    check(T.S.outstanding[rid1] == nil, "兜底后 R1 必须清掉")
    check(T.S.outstanding[rid2] == nil, "兜底后 R2 必须清掉")

    publish(decision_doc(rid1, key, { type = "item", item_id = T.S.current.candidates[1].item_id }))
    T.poll_decision()
    check(T.S.decision == nil, "兜底之后同 K 的决策不得再被接受")
    eq(T.S.rejected and T.S.rejected.reason_code, "late", "应判 late")
end

-- ============================================================
-- T27 回执只在核验通过后写；失败/超窗必须 rejected + applied_by=none
-- ============================================================
do
    section("T27 回执只在核验后写")
    reset_world()
    local rid, key = begin_request()
    local cand = T.S.current.candidates[1].item_id
    publish(decision_doc(rid, key, { type = "item", item_id = cand }))
    T.poll_decision()
    draw(0)
    check(read_file(bpath("applied.json")) == nil, "核验前不得写出成功回执")

    -- 不调 pickup，直接把帧推过核验窗口
    world.frame = world.frame + 10
    M.hooks.on_update()
    T.flush_writes()
    local applied = read_applied()
    check(applied ~= nil, "超窗后应结算一条回执")
    if applied ~= nil then
        eq(applied.phase, "rejected", "超窗 phase 必须是 rejected")
        eq(applied.applied_by, "none", "超窗 applied_by 必须是 none")
        check(applied.choice == T.JSON_NULL, "rejected 的 choice 必须为 null")
        check(applied.source == T.JSON_NULL, "rejected 的 source 必须为 null")
        eq(applied.reason_code, "not_applied", "reason_code")
    end

    -- 迟到的核验不得把已经结算的 rejected 改写回成功
    pickup(cand)
    local after = read_applied()
    eq(after.applied_by, "none", "超窗后的迟到核验不得改写为成功")
end

-- ============================================================
-- T28 `capabilities` 字段必须已删除（draft.4 统一为 features）
--     （回归：build_state_doc 又把 capabilities 写回来了，两端口径分叉）
-- ============================================================
do
    section("T28 capabilities 已删除")
    reset_world()
    begin_request()
    local text = read_file(bpath("state.json"))
    check(text ~= nil, "state.json 应存在")
    local doc = T.decode(text)
    check(doc.features ~= nil and #doc.features > 0, "features 必须存在且非空")
    check(doc.capabilities == nil, "capabilities 字段必须已删除")
    check(text:find('"capabilities"', 1, true) == nil, "state.json 文本里不得出现 capabilities")
end

-- ============================================================
-- T29 ts 毫秒精度（协议预算用毫秒；秒级 ts 会让 validity 差最多 1s）
-- ============================================================
do
    section("T29 ts 毫秒精度")
    reset_world()
    M.hooks.on_new_level()
    -- 模拟“已对齐墙钟”：锚点落在整秒边界
    local clock = T.CLOCK
    check(clock ~= nil, "应暴露 CLOCK 锚点（ts 毫秒精度的前提）")
    if clock ~= nil then
        clock.synced = true
        clock.epoch_base = 1793982600000
        clock.mono_base = clock_ms
    end

    T.request_state("room_enter", "treasure")
    T.flush_writes()
    local ts1 = T.decode(read_file(bpath("state.json"))).ts

    clock_ms = clock_ms + 40                    -- 同一秒内推进 40ms
    T.request_state("room_enter", "treasure")
    T.flush_writes()
    local doc2 = T.decode(read_file(bpath("state.json")))

    eq(ts1 % 1000, 0, "锚点应落在整秒边界")
    eq(doc2.ts - ts1, 40, "40ms 后 ts 必须差 40（秒级实现会是 0 或 1000）")
    eq(doc2.x_clock, "epoch", "已对齐时 x_clock 应为 epoch")
end

-- ============================================================
-- T30 有效期边界按毫秒判定，且 ts 不参与判定
-- ============================================================
do
    section("T30 有效期毫秒边界")
    -- 恰好等于 validity_ms：仍可用（<= 边界）
    reset_world()
    local rid1, key1 = begin_request()
    local cand1 = T.S.current.candidates[1].item_id
    clock_ms = clock_ms + 1500
    publish(decision_doc(rid1, key1, { type = "item", item_id = cand1 }))
    T.poll_decision()
    check(T.S.decision ~= nil, "恰好等于 validity_ms 时应接受")

    -- 多 1ms：必须迟到
    reset_world()
    local rid2, key2 = begin_request()
    local cand2 = T.S.current.candidates[1].item_id
    clock_ms = clock_ms + 1501
    publish(decision_doc(rid2, key2, { type = "item", item_id = cand2 }))
    T.poll_decision()
    check(T.S.decision == nil, "超过 validity_ms 1ms 必须判迟到")
    eq(T.S.rejected and T.S.rejected.reason_code, "late", "reason_code")

    -- ts 写得很旧但实际未过期：判定应只看单调毫秒，不看 ts
    reset_world()
    local rid3, key3 = begin_request()
    local cand3 = T.S.current.candidates[1].item_id
    local doc3 = decision_doc(rid3, key3, { type = "item", item_id = cand3 })
    doc3.ts = 1
    publish(doc3)
    T.poll_decision()
    check(T.S.decision ~= nil, "ts 极旧但实际未过期，仍应接受（判定用单调毫秒）")
end

-- ============================================================
-- 汇总
-- ============================================================
local function cleanup()
    -- 调试用：ISAAC_AGENT_KEEP_TEST_DIR=1 时保留桥目录，便于用外部工具检查 JSON
    if os.getenv("ISAAC_AGENT_KEEP_TEST_DIR") == "1" then
        io.write("保留测试目录：" .. BRIDGE_DIR .. "\n")
        return
    end
    sh('rmdir /s /q "' .. BRIDGE_DIR .. '" 2>nul')
end
cleanup()

local total = passed + #failures
io.write(string.format("\nlua_logic_test: %d/%d 断言通过\n", passed, total))
local exit_code = 0
if #failures > 0 then
    io.write("失败项：\n")
    for _, f in ipairs(failures) do io.write("  - " .. f .. "\n") end
    exit_code = 1
else
    io.write("全部通过\n")
end

-- 被 Python 宿主（tests/run_lua_test.py）嵌入时不能 os.exit：那会杀掉宿主进程，
-- 让 runner 的 subst 清理来不及执行（见 docs/lessons.md）。此时返回退出码由 runner 透传。
if os.getenv("ISAAC_AGENT_EMBEDDED") == "1" then
    return exit_code
end
os.exit(exit_code)
