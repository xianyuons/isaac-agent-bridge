--[[ ============================================================================
isaac_agent — 游戏侧 Lua mod（依赖 REPENTOGON / Repentance+）
============================================================================
职责（只做这四件事）：
  1. 读局面：把玩家/房间/层/已持有道具/候选池导出成 protocol 的 state.json；
  2. 读决策：轮询 <bridge>/decision.json，校验版本、字段、候选与时效；
  3. 生成当帧：在 MC_PRE_GET_COLLECTIBLE（回调 62）里只查内存，返回 item_id 或 nil；
  4. 事后核验 + 本地兜底：POST_PICKUP_INIT 比较实际生成的底座 id，核验后弹气泡；
     没有新鲜决策时走 §6.5 的本地规则 v1（缺红心→heal，缺输出→damage）。

协议：docs/protocol.md（1.0-draft.3）。红线（协议 §9）：
  · 不联网、不读 key、不写注册表、不执行远端代码；
  · 不在游戏回调里做磁盘 I/O / 阻塞等待（1500ms 是决策有效期，不是等待时长）；
  · 只通过官方 API 改变道具生成，不做帧级输入操作。

传输（协议 §1.4 / §1.8 三种 Profile，启动探针判定）：
  · Profile A（目标）：Lua 侧有 io + os.rename → 原子写 state/event/applied，读 decision；
  · Profile B / none（保底）：没有文件能力 → 只跑本地规则，气泡明确写“桥接不可用”。
  ⚠ 实测约束：原版 REPENTOGON 沙箱不提供 io/os（参考实现亦只在 Mod:SaveData 上搭桥），
    因此 Profile A 目前需要 `--luadebug` 启动项，或等 REPENTOGON 暴露文件 API。
    桥目录由插件侧创建（mod 只探测、不调 shell、不建目录）。
    探针失败 **不会** 让游戏坏掉：退回本地规则，并在气泡/日志里说明。
  ⚠ Profile C（SaveData 中继）按协议 §1.4 属研究形态、默认关闭，本版不实现。

时间：所有超时判定用 Isaac.GetTime() 的单调毫秒；没有 os.time 时 ts 用单调值并
     附 `x_clock: "monotonic"`（协议 §1.7 扩展字段），插件据此改用接收时刻。
============================================================================ ]]

local MOD_NAME = "isaac_agent"
local MOD_VERSION = "0.1.0"
local PROTOCOL_VERSION = "1.0"
local PROTOCOL_MAJOR = 1
local PROTOCOL_MINOR = 0

local mod = RegisterMod(MOD_NAME, 1)

-- ============================================================
-- 常量
-- ============================================================
local DEFAULT_VALIDITY_MS = 1500     -- 近场/反应式（协议 §6.1）
local BOSS_VALIDITY_MS    = 5000     -- Boss 奖励等长预取
local MIN_VALIDITY_MS     = 300
local MAX_VALIDITY_MS     = 10000

local POLL_EVERY_FRAMES   = 6        -- 30fps 下 5Hz 轮询 decision.json
local MAX_CANDIDATES      = 64       -- 协议 §1.6
local MAX_ITEMS           = 1024
local MAX_REASON_CHARS    = 280
local MAX_STATE_BYTES     = 256 * 1024
local MAX_DECISION_BYTES  = 8 * 1024
local MAX_EVENT_BYTES     = 16 * 1024
local MAX_APPLIED_BYTES   = 16 * 1024
local OUTSTANDING_KEEP_MS = 5000     -- 过期后再留 5s 宽限，便于识别 late
local ITEMS_CACHE_MS      = 1000     -- 已持有道具快照的缓存时长
local BUBBLE_HOLD_MS      = 6000
local LOG_RATE_MS         = 5000     -- 同类错误限频（协议 §6.6）
local MAX_REFRESHES       = 8        -- 同一 gen_level_key 的刷新上限（≈ 8×validity/2）
local DECISION_SEEN_KEEP  = 16

local BRIDGE_DIR_ENV      = "ISAAC_AGENT_DIR"
local BRIDGE_DIR_NAME     = "IsaacAgent"

local COLLECTIBLE_VARIANT = 100      -- PickupVariant.PICKUP_COLLECTIBLE

-- 道具池：ItemPoolType 数字 → 协议用的 snake_case 名
local POOL_NAMES = {
    [0] = "treasure", [1] = "shop", [2] = "boss", [3] = "devil", [4] = "angel",
    [5] = "secret", [6] = "library", [7] = "shell_game", [8] = "golden_chest",
    [9] = "red_chest", [10] = "beggar", [11] = "demon_beggar", [12] = "curse",
    [13] = "key_master", [14] = "battery_bum", [15] = "moms_chest",
    [16] = "greed_treasure", [17] = "greed_boss", [18] = "greed_shop",
    [19] = "greed_devil", [20] = "greed_angel", [21] = "greed_curse",
    [22] = "greed_secret", [23] = "crane_game", [24] = "ultra_secret",
    [25] = "bomb_bum", [26] = "planetarium", [27] = "old_chest",
    [28] = "baby_shop", [29] = "wooden_chest", [30] = "rotten_beggar",
}
local POOL_IDS = {}
do
    for id, name in pairs(POOL_NAMES) do POOL_IDS[name] = id end
end

-- 房间类型：RoomType 数字 → 协议 §2.4 枚举
local ROOM_TYPE_NAMES = {
    [1] = "default", [2] = "shop", [3] = "unknown", [4] = "treasure",
    [5] = "boss", [6] = "default", [7] = "secret", [8] = "super_secret",
    [9] = "arcade", [10] = "curse", [11] = "challenge", [12] = "library",
    [13] = "sacrifice", [14] = "devil", [15] = "angel", [16] = "unknown",
    [17] = "boss_rush", [18] = "isaac", [19] = "barren", [20] = "chest",
    [21] = "dice", [22] = "black_market", [23] = "unknown", [24] = "planetarium",
    [25] = "teleporter", [26] = "teleporter_exit", [27] = "unknown",
    [28] = "blue", [29] = "ultra_secret",
}

-- 房间类型 → 预取用的道具池（v1 只做“最可能的那一个池”，协议 §11.1 已注明局限）
local ROOM_TO_POOL = {
    [2] = "shop", [4] = "treasure", [5] = "boss", [7] = "secret", [8] = "secret",
    [10] = "curse", [12] = "library", [14] = "devil", [15] = "angel",
    [20] = "golden_chest", [24] = "planetarium", [29] = "ultra_secret",
}

-- ============================================================
-- 基础工具
-- ============================================================
local function clamp_int(v, lo, hi, default)
    if type(v) ~= "number" or v ~= v then return default end
    v = math.floor(v)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- 单调毫秒：Isaac.GetTime() 是进程启动以来的毫秒数（暂停/菜单里继续走）。
local function now_ms()
    local ok, v = pcall(function() return Isaac.GetTime() end)
    if ok and type(v) == "number" and v >= 0 then return math.floor(v) end
    local okF, f = pcall(function() return Game():GetFrameCount() end)
    if okF and type(f) == "number" and f >= 0 then return math.floor(f * 33) end
    return 0
end

-- 墙钟毫秒：只有 --luadebug（os 可用）时才有；否则返回 nil。
local function wall_ms()
    local ok, t = pcall(function() return os.time() end)
    if ok and type(t) == "number" and t > 0 then return t * 1000 end
    return nil
end

-- 协议 ts 字段：优先墙钟；没有墙钟就用单调值，并靠 x_clock 标注（协议 §1.7）。
local function doc_ts()
    local w = wall_ms()
    if w ~= nil then return w, "epoch" end
    return now_ms(), "monotonic"
end

local function frame()
    local ok, f = pcall(function() return Game():GetFrameCount() end)
    if ok and type(f) == "number" then return f end
    return 0
end

local function hash_num(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return h
end

local function hex8(n) return string.format("%08x", n % 4294967296) end

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- UTF-8 字符迭代（Lua 5.1/5.3 通吃；不依赖 utf8 库）
local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"
local function utf8_chars(s)
    local out = {}
    for c in string.gmatch(tostring(s or ""), UTF8_CHAR) do out[#out + 1] = c end
    return out
end

local function utf8_len(s) return #utf8_chars(s) end

-- reason 只允许单行、无控制字符（协议 §3.3.6）
local function sanitize_reason(v)
    if type(v) ~= "string" then return nil end
    local s = v:gsub("[%z\1-\31\127]", " ")
    s = trim(s)
    if s == "" then return nil end
    if utf8_len(s) > MAX_REASON_CHARS then
        local chars, out = utf8_chars(s), {}
        for i = 1, MAX_REASON_CHARS do out[i] = chars[i] end
        s = table.concat(out)
    end
    return s
end

-- ============================================================
-- JSON（协议 §1.1：严格 JSON、无 NaN/Inf、字段名 snake_case）
-- 自实现编解码，避免依赖 Isaac 内置 json 的 null 语义（协议要求 error_code 显式 null）
-- ============================================================
local JSON_NULL = setmetatable({}, { __tostring = function() return "null" end })
local ARRAY_MT = {}
local function arr(t)
    t = t or {}
    return setmetatable(t, ARRAY_MT)
end
local function is_null(v) return v == nil or v == JSON_NULL end

local ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encode_string(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        local e = ESCAPES[c]
        if e ~= nil then
            out[#out + 1] = e
        else
            local b = s:byte(i)
            if b < 32 then
                out[#out + 1] = string.format("\\u%04x", b)
            else
                out[#out + 1] = c
            end
        end
    end
    return '"' .. table.concat(out) .. '"'
end

local encode_value

local function encode_table(v, buf)
    if getmetatable(v) == ARRAY_MT then
        buf[#buf + 1] = "["
        for i = 1, #v do
            if i > 1 then buf[#buf + 1] = "," end
            encode_value(v[i], buf)
        end
        buf[#buf + 1] = "]"
        return
    end
    local keys = {}
    for k in pairs(v) do
        if type(k) == "string" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    buf[#buf + 1] = "{"
    for i = 1, #keys do
        if i > 1 then buf[#buf + 1] = "," end
        local k = keys[i]
        buf[#buf + 1] = encode_string(k)
        buf[#buf + 1] = ":"
        encode_value(v[k], buf)
    end
    buf[#buf + 1] = "}"
end

encode_value = function(v, buf)
    local tv = type(v)
    if v == nil or v == JSON_NULL then
        buf[#buf + 1] = "null"
    elseif tv == "boolean" then
        buf[#buf + 1] = v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            buf[#buf + 1] = "null"          -- 不允许 NaN/Inf（协议 §1.1）
        elseif v % 1 == 0 and math.abs(v) < 9007199254740992 then
            buf[#buf + 1] = string.format("%d", v)
        else
            buf[#buf + 1] = string.format("%.14g", v)
        end
    elseif tv == "string" then
        buf[#buf + 1] = encode_string(v)
    elseif tv == "table" then
        encode_table(v, buf)
    else
        buf[#buf + 1] = "null"
    end
end

local function json_encode(v)
    local buf = {}
    encode_value(v, buf)
    return table.concat(buf)
end

-- 码点 → UTF-8（不依赖 utf8 库）
local function utf8_char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local json_decode

do
    local function decode_impl(text)
        local pos = 1
        local depth = 0

        local function fail(msg)
            error({ json_error = msg, json_pos = pos }, 0)
        end

        local function skip_ws()
            while true do
                local c = text:sub(pos, pos)
                if c == " " or c == "\t" or c == "\n" or c == "\r" then
                    pos = pos + 1
                else
                    return
                end
            end
        end

        local function parse_string()
            pos = pos + 1                       -- 跳过起始引号
            local out = {}
            while true do
                local c = text:sub(pos, pos)
                if c == "" then fail("unterminated string") end
                if c == '"' then
                    pos = pos + 1
                    return table.concat(out)
                end
                if c == "\\" then
                    local n = text:sub(pos + 1, pos + 1)
                    pos = pos + 2
                    if n == '"' then out[#out + 1] = '"'
                    elseif n == "\\" then out[#out + 1] = "\\"
                    elseif n == "/" then out[#out + 1] = "/"
                    elseif n == "b" then out[#out + 1] = "\b"
                    elseif n == "f" then out[#out + 1] = "\f"
                    elseif n == "n" then out[#out + 1] = "\n"
                    elseif n == "r" then out[#out + 1] = "\r"
                    elseif n == "t" then out[#out + 1] = "\t"
                    elseif n == "u" then
                        local hex = text:sub(pos, pos + 3)
                        pos = pos + 4
                        local cp = tonumber(hex, 16)
                        if cp == nil then fail("bad \\u escape") end
                        -- 代理对
                        if cp >= 0xD800 and cp <= 0xDBFF and text:sub(pos, pos + 1) == "\\u" then
                            local hex2 = text:sub(pos + 2, pos + 5)
                            local cp2 = tonumber(hex2, 16)
                            if cp2 ~= nil and cp2 >= 0xDC00 and cp2 <= 0xDFFF then
                                cp = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
                                pos = pos + 6
                            end
                        end
                        out[#out + 1] = utf8_char(cp)
                    else
                        fail("bad escape")
                    end
                else
                    out[#out + 1] = c
                    pos = pos + 1
                end
            end
        end

        local parse_value

        local function parse_array()
            pos = pos + 1
            local out = {}
            skip_ws()
            if text:sub(pos, pos) == "]" then
                pos = pos + 1
                return out
            end
            while true do
                out[#out + 1] = parse_value()
                skip_ws()
                local c = text:sub(pos, pos)
                if c == "," then
                    pos = pos + 1
                elseif c == "]" then
                    pos = pos + 1
                    return out
                else
                    fail("expected , or ]")
                end
            end
        end

        local function parse_object()
            pos = pos + 1
            local out = {}
            skip_ws()
            if text:sub(pos, pos) == "}" then
                pos = pos + 1
                return out
            end
            while true do
                skip_ws()
                if text:sub(pos, pos) ~= '"' then fail("expected key") end
                local k = parse_string()
                skip_ws()
                if text:sub(pos, pos) ~= ":" then fail("expected :") end
                pos = pos + 1
                out[k] = parse_value()
                skip_ws()
                local c = text:sub(pos, pos)
                if c == "," then
                    pos = pos + 1
                elseif c == "}" then
                    pos = pos + 1
                    return out
                else
                    fail("expected , or }")
                end
            end
        end

        parse_value = function()
            skip_ws()
            depth = depth + 1
            if depth > 40 then fail("nesting too deep") end
            local c = text:sub(pos, pos)
            local v
            if c == "{" then
                v = parse_object()
            elseif c == "[" then
                v = parse_array()
            elseif c == '"' then
                v = parse_string()
            elseif text:sub(pos, pos + 3) == "true" then
                pos = pos + 4
                v = true
            elseif text:sub(pos, pos + 4) == "false" then
                pos = pos + 5
                v = false
            elseif text:sub(pos, pos + 3) == "null" then
                pos = pos + 4
                v = JSON_NULL
            else
                local num = text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
                if num == nil or #num == 0 then fail("unexpected token") end
                pos = pos + #num
                local n = tonumber(num)
                if n == nil then fail("bad number") end
                v = n
            end
            depth = depth - 1
            return v
        end

        local v = parse_value()
        skip_ws()
        if pos <= #text then fail("trailing garbage") end
        return v
    end

    json_decode = function(text)
        if type(text) ~= "string" then return nil, "invalid_type" end
        local ok, res = pcall(decode_impl, text)
        if not ok then
            local msg = "decode_error"
            if type(res) == "table" and res.json_error ~= nil then
                msg = tostring(res.json_error)
            end
            return nil, msg
        end
        if type(res) ~= "table" then return nil, "not_object" end
        return res, nil
    end
end

-- ============================================================
-- 模块状态
-- ============================================================
local S = {
    boot = nil,
    counter = 0,
    profile = "none",

    validity_ms = DEFAULT_VALIDITY_MS,
    decision = nil,          -- { doc = table, received_ms = number }
    rejected = nil,          -- 最近一次被拒的决策（用于 applied 审计）
    outstanding = {},        -- request_id -> { sent_ms, validity, gen_level_key, ... }
    outstanding_n = 0,
    current = nil,           -- 当前请求上下文（candidates 等）
    last_request_id = nil,

    cand_cache = {},         -- pool_name -> { candidates array }
    items_cache = nil,       -- { ids = {...}, at_ms = n }
    tag_table = nil,
    pool_api = nil,          -- nil=未探测, true/false

    level = { floor = 0, grid = -1, room_type = 0, is_boss = false, stage_seed = 0 },
    next_pedestal_index = 0,

    pending_verify = nil,    -- 等待 POST_PICKUP_INIT 核验的记录
    seen_decisions = {},     -- decision_id -> true
    seen_order = {},
    -- 已消费的 request_id：消费即作废（协议 §6.7.5）。迟到的同 request 决策按 late 拒绝，
    -- 不能因为“它还在 outstanding 里”就再被下一次生成用掉。
    consumed_requests = {},
    consumed_n = 0,

    bubble = { text = "", until_ms = 0, fallback = false, ascii = "" },
    font = { tried = false, ok = false, obj = nil },

    poll_counter = 0,
    error_seq = 0,
    log_rate = {},           -- key -> last_ms
    stats = { draws = 0, hits = 0, fallback = 0, rejected = 0, timeout = 0, io_err = 0 },
}

-- 回调期间排队、由 on_update 状态机统一落盘（架构 §3.2：回调内不做磁盘 I/O）
local Pending = { state = nil, event = nil, applied = nil }

local function log(level, module, msg, fields)
    local parts = { "[isaac_agent]", "[" .. level .. "]", "[" .. module .. "]" }
    if type(fields) == "table" then
        if fields.request_id ~= nil then parts[#parts + 1] = "request_id=" .. tostring(fields.request_id) end
        if fields.decision_id ~= nil then parts[#parts + 1] = "decision_id=" .. tostring(fields.decision_id) end
        if fields.error_code ~= nil then parts[#parts + 1] = "error_code=" .. tostring(fields.error_code) end
        if fields.reason_code ~= nil then parts[#parts + 1] = "reason_code=" .. tostring(fields.reason_code) end
    end
    parts[#parts + 1] = tostring(msg)
    pcall(function() Isaac.DebugString(table.concat(parts, " ")) end)
end

-- 同类错误限频（协议 §6.6）；被限频的条数在下次输出时一并说明。
local function log_limited(level, module, key, msg, fields)
    local t = now_ms()
    local last = S.log_rate[key]
    if last ~= nil and (t - last) < LOG_RATE_MS then
        S.error_seq = S.error_seq + 1
        return
    end
    S.log_rate[key] = t
    if S.error_seq > 0 then
        msg = msg .. "（另有 " .. tostring(S.error_seq) .. " 条同类被限频）"
        S.error_seq = 0
    end
    log(level, module, msg, fields)
end

-- ============================================================
-- 桥（传输层，协议 §1.3 / §1.8）
-- ============================================================
local Bridge = {
    kind = "none",
    dir = nil,
    can_write = false,
    can_read = false,
    last_error = nil,
    seq = 0,
}

local function io_available()
    return type(io) == "table" and type(io.open) == "function"
end

local function os_available()
    return type(os) == "table"
        and type(os.rename) == "function"
        and type(os.remove) == "function"
end

local function env_get(name)
    if type(os) ~= "table" or type(os.getenv) ~= "function" then return nil end
    local ok, v = pcall(os.getenv, name)
    if ok and type(v) == "string" and v ~= "" then return v end
    return nil
end

local function join_path(dir, name)
    if dir:sub(-1) == "\\" or dir:sub(-1) == "/" then return dir .. name end
    return dir .. "\\" .. name
end

-- 目录所有权令牌：探针时写入，之后每次写入前后各校验一次。
-- 防 TOCTOU：探测时的 <bridge> 与真正写入时的 <bridge> 可能已被替换（改名/junction）。
local OWNER_FILE = ".isaac_agent_owner"

local function bridge_read_owner()
    if Bridge.dir == nil then return nil end
    local f = io.open(join_path(Bridge.dir, OWNER_FILE), "rb")
    if f == nil then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

local function bridge_verify_dir()
    if Bridge.dir == nil then return false, "no_dir" end
    if Bridge.owner == nil or Bridge.owner == "" then return false, "no_owner" end
    local text = bridge_read_owner()
    if text == nil then return false, "owner_missing" end
    if text ~= Bridge.owner then return false, "owner_mismatch" end
    return true, nil
end

local function bridge_downgrade(reason)
    Bridge.can_write = false
    Bridge.can_read = false
    Bridge.kind = "none"
    S.profile = "none"
    log_limited("error", "bridge", "downgrade_" .. tostring(reason),
        "桥目录校验失败（" .. tostring(reason) .. "）→ 停止写入并降级为本地规则",
        { error_code = "IO", reason_code = "io_error" })
end

-- 原子写：同目录唯一 tmp → 旧文件挪 .bak → rename → 双校验 → 删 .bak。
-- 不变量：任何失败路径都必须保留旧文件（宁可不更新，也不能丢）。
local function bridge_write_raw(name, text)
    if not Bridge.can_write or Bridge.dir == nil then
        return false, "bridge_unavailable"
    end

    -- ① 写前校验父目录仍是探针时那个（TOCTOU）
    local ok_dir, dir_err = bridge_verify_dir()
    if not ok_dir then
        bridge_downgrade(dir_err)
        return false, "io_error"
    end

    Bridge.seq = Bridge.seq + 1
    local tmp = join_path(Bridge.dir,
        name .. ".tmp." .. tostring(Bridge.boot) .. "." .. tostring(Bridge.seq))
    local f, err = io.open(tmp, "wb")
    if f == nil then
        Bridge.last_error = tostring(err)
        return false, "io_error"
    end
    local okw = f:write(text)
    f:flush()
    f:close()
    if not okw then
        pcall(function() os.remove(tmp) end)
        return false, "io_error"
    end

    local target = join_path(Bridge.dir, name)
    local bak = target .. ".bak"

    -- ② 先把旧文件挪到 .bak（不是删除）；挪不动就放弃这次更新，旧文件原封不动
    local had_old = false
    local tf = io.open(target, "rb")
    if tf ~= nil then
        tf:close()
        had_old = true
        pcall(function() os.remove(bak) end)
        if not os.rename(target, bak) then
            pcall(function() os.remove(tmp) end)
            Bridge.last_error = "backup_failed"
            return false, "io_error"
        end
    end

    local okr = os.rename(tmp, target)
    if not okr then
        -- 回滚：把 .bak 改回原名（协议 §1.3：失败必须保留旧文件）
        if had_old then
            if not os.rename(bak, target) then
                log_limited("error", "bridge", "restore_fail",
                    "旧文件恢复失败，原文件保留在 " .. tostring(bak),
                    { error_code = "IO", reason_code = "io_error" })
            end
        end
        pcall(function() os.remove(tmp) end)
        Bridge.last_error = "rename_failed"
        return false, "io_error"
    end
    if had_old then pcall(function() os.remove(bak) end) end

    -- ③ 写后校验：目录没被换掉，且落盘内容与预期一致（防“写到了被替换的目录”）
    local ok_after, after_err = bridge_verify_dir()
    if not ok_after then
        bridge_downgrade(after_err)
        return false, "io_error"
    end
    local rf = io.open(target, "rb")
    if rf == nil then
        Bridge.last_error = "verify_open_failed"
        return false, "io_error"
    end
    local back = rf:read("*a")
    rf:close()
    if back ~= text then
        Bridge.last_error = "verify_mismatch"
        log_limited("error", "bridge", "verify_mismatch",
            "写入校验失败：落盘内容与预期不一致", { error_code = "IO", reason_code = "io_error" })
        return false, "io_error"
    end
    return true, nil
end

local function bridge_read_raw(name)
    if not Bridge.can_read or Bridge.dir == nil then
        return nil, "bridge_unavailable"
    end
    local f, err = io.open(join_path(Bridge.dir, name), "rb")
    if f == nil then
        -- 目标文件短暂不存在是可重试状态（协议 §1.3），下一帧再读即可
        return nil, "missing"
    end
    local text = f:read("*a")
    f:close()
    if type(text) ~= "string" or text == "" then return nil, "empty" end
    return text, nil
end

local function bridge_probe_dir(dir)
    if dir == nil or dir == "" then return false, nil end
    local probe = join_path(dir, ".probe.tmp")
    local f, err = io.open(probe, "wb")
    if f == nil then return false, tostring(err) end
    f:write("isaac_agent probe")
    f:flush()
    f:close()
    local rf = io.open(probe, "rb")
    if rf == nil then
        pcall(function() os.remove(probe) end)
        return false, "readback_failed"
    end
    local back = rf:read("*a")
    rf:close()
    pcall(function() os.remove(probe) end)
    if back ~= "isaac_agent probe" then return false, "readback_mismatch" end
    -- 读 decision.json 的权限单独探测：不存在视为“可读待创建”（协议 §1.8）
    local df = io.open(join_path(dir, "decision.json"), "rb")
    if df ~= nil then df:close() end

    -- 目录所有权令牌：之后每次写入前后都校验它，防父目录在探测后被替换（TOCTOU）
    local token = tostring(Bridge.boot) .. ":" ..
        hex8(hash_num(tostring(now_ms()) .. "|" .. tostring(math.random(0, 999999)) .. "|" .. tostring(dir)))
    local of = io.open(join_path(dir, OWNER_FILE), "wb")
    if of == nil then return false, "owner_write_failed" end
    of:write(token)
    of:flush()
    of:close()
    local ck = io.open(join_path(dir, OWNER_FILE), "rb")
    if ck == nil then return false, "owner_readback_failed" end
    local token_back = ck:read("*a")
    ck:close()
    if token_back ~= token then return false, "owner_readback_mismatch" end
    Bridge.owner = token
    return true, nil
end

-- 启动探针（只在 on_game_start 调用一次；不在帧回调里）
local function bridge_detect(opts)
    opts = opts or {}
    Bridge.boot = S.boot
    Bridge.dir = nil
    Bridge.owner = nil
    Bridge.can_write = false
    Bridge.can_read = false
    Bridge.last_error = nil

    -- 测试可显式指定能力；生产路径不传 opts，走真实探测
    local can_io, can_os
    if opts.io_available == true then
        can_io, can_os = true, true
    elseif opts.io_available == false then
        can_io, can_os = false, false
    else
        can_io, can_os = io_available(), os_available()
    end

    if not (can_io and can_os) then
        Bridge.kind = "none"
        S.profile = "none"
        log("warn", "bridge",
            "无文件能力（io/os 不可用）→ Profile B/本地规则；" ..
            "如需 agent 决策，请用 --luadebug 启动，或在支持文件 API 的 REPENTOGON 上运行")
        return "none"
    end

    local dirs = {}
    if type(opts.dir) == "string" and opts.dir ~= "" then dirs[#dirs + 1] = opts.dir end
    local override = env_get(BRIDGE_DIR_ENV)
    if override ~= nil and override ~= opts.dir then dirs[#dirs + 1] = override end
    local base = env_get("LOCALAPPDATA")
    if base ~= nil then dirs[#dirs + 1] = join_path(base, BRIDGE_DIR_NAME) end

    if #dirs == 0 then
        Bridge.kind = "none"
        S.profile = "none"
        log("warn", "bridge", "拿不到 LOCALAPPDATA，也没有 ISAAC_AGENT_DIR → 本地规则")
        return "none"
    end

    for _, dir in ipairs(dirs) do
        local ok, err = bridge_probe_dir(dir)
        if ok then
            Bridge.dir = dir
            Bridge.can_write = true
            Bridge.can_read = true
            Bridge.kind = "file"
            S.profile = "A"
            log("info", "bridge", "Profile A：桥目录可用 " .. tostring(dir))
            return "A"
        end
        Bridge.last_error = tostring(err)
    end

    Bridge.kind = "none"
    S.profile = "none"
    log_limited("warn", "bridge", "probe_fail",
        "桥目录不可写（" .. tostring(Bridge.last_error) .. "）→ 本地规则；" ..
        "如需 agent 决策请先创建目录或用 --luadebug")
    return "none"
end

-- 写给插件的三份文档（协议 §1.4 Profile A）
local function bridge_write_doc(name, doc, max_bytes)
    if Bridge.kind ~= "file" then return false, "bridge_unavailable" end
    local text = json_encode(doc)
    if #text > max_bytes then
        log_limited("error", "bridge", "oversize_" .. name,
            "文档超过上限，拒绝写入：" .. tostring(#text) .. " > " .. tostring(max_bytes),
            { error_code = "VALIDATION", reason_code = "out_of_range" })
        return false, "out_of_range"
    end
    return bridge_write_raw(name, text)
end

-- ============================================================
-- 游戏侧只读快照
-- ============================================================
local function get_player()
    local ok, p = pcall(function() return Isaac.GetPlayer(0) end)
    if ok and p ~= nil then return p end
    return nil
end

local function read_player()
    local snap = {
        ok = false, red_hearts = 0, soul_hearts = 0,
        max_red_hearts = nil, character_id = nil, is_dead = false,
    }
    local p = get_player()
    if p == nil then return snap end
    snap.ok = true

    local function num(fn, default)
        local ok, v = pcall(fn)
        if ok and type(v) == "number" and v == v then return v end
        return default
    end

    -- Isaac 的 GetHearts/GetSoulHearts/GetMaxHearts 都是“半颗心”为单位（协议 §2.2）
    snap.red_hearts = clamp_int(num(function() return p:GetHearts() end, 0), 0, 24, 0)
    snap.soul_hearts = clamp_int(num(function() return p:GetSoulHearts() end, 0), 0, 24, 0)
    local max_red = num(function() return p:GetMaxHearts() end, nil)
    if max_red ~= nil then snap.max_red_hearts = clamp_int(max_red, 0, 24, 0) end
    local cid = num(function() return p:GetPlayerType() end, nil)
    if cid ~= nil then snap.character_id = clamp_int(cid, 0, 255, 0) end
    local dead = false
    pcall(function() dead = p:IsDead() end)
    snap.is_dead = (dead == true)
    return snap
end

local function max_collectible_id()
    local ok, size = pcall(function()
        return Isaac.GetItemConfig():GetCollectibles().Size
    end)
    if ok and type(size) == "number" and size > 1 and size < 2000 then
        return math.floor(size) - 1
    end
    return 750
end

local function get_item_config(id)
    local ok, cfg = pcall(function() return Isaac.GetItemConfig():GetCollectible(id) end)
    if ok and cfg ~= nil then return cfg end
    return nil
end

local function is_valid_collectible(id)
    local ok, v = pcall(function() return ItemConfig.Config.IsValidCollectible(id) end)
    if ok and type(v) == "boolean" then return v end
    -- 回退：能取到配置也算合法（不同版本 API 名称可能有差异）
    local okc, cfg = pcall(function() return Isaac.GetItemConfig():GetCollectible(id) end)
    return okc and cfg ~= nil
end

local function item_available(cfg)
    local ok, v = pcall(function() return cfg:IsAvailable() end)
    if ok and type(v) == "boolean" then return v end
    return true
end

-- ItemConfig 的 Tags 是位掩码；没有常量时跳过检查
local function mask_bit(tags, mask)
    if type(tags) ~= "number" or type(mask) ~= "number" or mask <= 0 then return false end
    return math.floor(tags / mask) % 2 == 1
end

local function is_quest_item(cfg)
    local okMask, mask = pcall(function() return ItemConfig.TAG_QUEST end)
    if not okMask or type(mask) ~= "number" then return false end
    local ok, tags = pcall(function() return cfg.Tags end)
    if not ok then return false end
    return mask_bit(tags, mask)
end

local function item_quality(cfg)
    local ok, q = pcall(function() return cfg.Quality end)
    if ok and type(q) == "number" then return clamp_int(q, 0, 4, 0) end
    return nil
end

-- Name 是本地化 key（如 "#THE_D6_NAME"）；取不到可读名就返回 nil（协议 §2.3）
local function item_name(id)
    local cfg = get_item_config(id)
    if cfg == nil then return nil end
    local ok, name = pcall(function() return cfg.Name end)
    if not ok or type(name) ~= "string" then return nil end
    name = trim(name)
    if name == "" then return nil end
    if name:sub(1, 1) == "#" then
        name = name:sub(2):gsub("_NAME$", ""):gsub("^THE_", ""):gsub("_", " ")
        name = trim(name):lower()
    end
    if name == "" then return nil end
    if #name > 128 then name = name:sub(1, 128) end
    return name
end

-- 已持有道具：GetCollectibles() 在本版本返回 userdata，只能按 id 逐个 HasCollectible
local function collect_items()
    local ids = {}
    local p = get_player()
    if p == nil then return ids end
    local maxId = max_collectible_id()
    for id = 1, maxId do
        local ok, has = pcall(function() return p:HasCollectible(id) end)
        if ok and has == true then
            ids[#ids + 1] = id
            if #ids >= MAX_ITEMS then break end
        end
    end
    return ids
end

local function items_snapshot()
    local t = now_ms()
    local c = S.items_cache
    if c ~= nil and (t - c.at_ms) < ITEMS_CACHE_MS then return c.ids, c.tags end
    local ids = collect_items()
    local tagset = {}
    local tags = S.tag_table or {}
    for _, id in ipairs(ids) do
        local tl = tags[id]
        if tl ~= nil then
            for _, tag in ipairs(tl) do tagset[tag] = true end
        end
    end
    S.items_cache = { ids = ids, tags = tagset, at_ms = t }
    return ids, tagset
end

local function load_tags()
    local mod_data = nil
    local ok, res = pcall(require, "data.item_tags")
    if ok and type(res) == "table" then mod_data = res end
    if mod_data == nil then
        -- 不同版本的 require 解析规则略有差异：退回到 include（Isaac 提供的全局函数）
        local ok_inc, res2 = pcall(function() return include("data/item_tags.lua") end)
        if ok_inc and type(res2) == "table" then mod_data = res2 end
    end
    if mod_data ~= nil and type(mod_data.tags) == "table" then
        S.tag_table = mod_data.tags
        log("info", "data", "标签表已加载（" .. tostring(mod_data.version or "?") .. "）")
        return
    end
    S.tag_table = {}
    log_limited("warn", "data", "tags_missing", "标签表不可用 → 规则只会走默认分支")
end

local function item_tags(id)
    local tags = S.tag_table
    if type(tags) ~= "table" then return nil end
    local tl = tags[id]
    if tl == nil then return nil end
    return arr(tl)
end

local function read_level()
    local lv = { floor = 0, grid = -1, room_type = 0, is_boss = false, stage_seed = 0 }
    pcall(function()
        local level = Game():GetLevel()
        lv.floor = clamp_int(level:GetStage(), 0, 63, 0)
        local idx = level:GetCurrentRoomIndex()
        if type(idx) == "number" then lv.grid = idx end
        local seeds = Game():GetSeeds()
        local ok, s = pcall(function() return seeds:GetStageSeed() end)
        if ok and type(s) == "number" then lv.stage_seed = s end
    end)
    pcall(function()
        local room = Game():GetRoom()
        local rt = room:GetType()
        if type(rt) == "number" then
            lv.room_type = rt
            lv.is_boss = (rt == 5)
        end
    end)
    return lv
end

local function pool_name_of(pool_id)
    local name = POOL_NAMES[pool_id]
    if name ~= nil then return name end
    return "pool" .. tostring(pool_id)
end

local function guess_pool_for_room(room_type)
    return ROOM_TO_POOL[room_type] or "treasure"
end

-- ============================================================
-- 候选池（协议 §2.6）
-- ============================================================
local function pool_membership_supported()
    if S.pool_api ~= nil then return S.pool_api end
    local ok, v = pcall(function()
        local pool = Game():GetItemPool()
        return pool:IsCollectibleInPool(1, 0)
    end)
    S.pool_api = (ok and type(v) == "boolean")
    return S.pool_api
end

local function in_pool(id, pool_id)
    local ok, v = pcall(function()
        return Game():GetItemPool():IsCollectibleInPool(id, pool_id)
    end)
    return ok and v == true
end

-- 确定性抽样：先保住带规则标签的候选（heal/damage 很少），再按步长取其余。
local function sample_candidates(ids, limit, salt)
    if #ids <= limit then return ids end
    local priority, rest = {}, {}
    local tags = S.tag_table or {}
    for _, id in ipairs(ids) do
        local tl = tags[id]
        local hot = false
        if tl ~= nil then
            for _, tag in ipairs(tl) do
                if tag == "heal" or tag == "damage" then hot = true break end
            end
        end
        if hot then priority[#priority + 1] = id else rest[#rest + 1] = id end
    end
    local out = {}
    for _, id in ipairs(priority) do
        if #out >= limit then break end
        out[#out + 1] = id
    end
    if #out >= limit then return out end
    local room = limit - #out
    local stride = math.max(1, math.ceil(#rest / room))
    local offset = hash_num(salt) % stride
    local i = offset + 1
    while i <= #rest and #out < limit do
        out[#out + 1] = rest[i]
        i = i + stride
    end
    -- 步长取整可能没填满：从头部补齐（仍确定性）
    i = 1
    while #out < limit and i <= #rest do
        local dup = false
        for _, v in ipairs(out) do if v == rest[i] then dup = true break end end
        if not dup then out[#out + 1] = rest[i] end
        i = i + 1
    end
    return out
end

local function build_candidates(pool_name)
    local pool_id = POOL_IDS[pool_name] or 0
    local use_pool = pool_membership_supported()

    local function scan(use_filter)
        local ids = {}
        local maxId = max_collectible_id()
        for id = 1, maxId do
            if is_valid_collectible(id) then
                local cfg = get_item_config(id)
                if cfg ~= nil and item_available(cfg) and not is_quest_item(cfg) then
                    if (not use_filter) or in_pool(id, pool_id) then
                        ids[#ids + 1] = id
                    end
                end
            end
        end
        return ids
    end

    local ids = scan(use_pool)
    if use_pool and #ids == 0 then
        -- 池成员 API 存在但返回空集：多半是签名/参数顺序不同。宁可退化成全表，
        -- 也不能让候选池为空（空池 = 永远不替换，且规则只能 skip）。
        S.pool_api = false
        use_pool = false
        log_limited("warn", "candidates", "pool_api_empty",
            "池成员 API 返回空集（疑似签名不同）→ 回退为全表合法道具")
        ids = scan(false)
    end
    ids = sample_candidates(ids, MAX_CANDIDATES, pool_name .. "|" .. tostring(S.level.floor))
    local out = {}
    for _, id in ipairs(ids) do
        local cfg = get_item_config(id)
        out[#out + 1] = {
            pedestal_index = JSON_NULL,          -- 池级预取：目标不是某个具体底座
            item_id = id,
            name = item_name(id),
            tags = item_tags(id) or arr({}),
            quality = item_quality(cfg),
        }
    end
    return out
end

local function ensure_candidates(pool_name)
    local cached = S.cand_cache[pool_name]
    if cached ~= nil then return cached end
    local t0 = now_ms()
    local list = build_candidates(pool_name)
    S.cand_cache[pool_name] = list
    log("info", "candidates",
        string.format("池 %s 候选 %d 条（构建 %dms，池成员 API=%s）",
            pool_name, #list, now_ms() - t0, tostring(pool_membership_supported())))
    return list
end

local function candidate_idset(list)
    local set = {}
    for _, c in ipairs(list) do set[c.item_id] = true end
    return set
end

-- ============================================================
-- 请求 / 决策生命周期（协议 §1.5、§6.7）
-- ============================================================
local function next_request_id()
    S.counter = S.counter + 1
    return string.format("r-%s-%06d", tostring(S.boot), S.counter)
end

local function next_decision_seen(decision_id)
    if decision_id == nil then return end
    if S.seen_decisions[decision_id] then return end
    S.seen_decisions[decision_id] = true
    S.seen_order[#S.seen_order + 1] = decision_id
    while #S.seen_order > DECISION_SEEN_KEEP do
        local old = table.remove(S.seen_order, 1)
        S.seen_decisions[old] = nil
    end
end

local function decision_already_seen(decision_id)
    return decision_id ~= nil and S.seen_decisions[decision_id] == true
end

local function validity_for(trigger_type)
    if trigger_type == "boss_approach" then return BOSS_VALIDITY_MS end
    return DEFAULT_VALIDITY_MS
end

-- gen_level_key：层 + 房间 + 目标池 + 候选签名（协议 §1.5）。
-- v1 只做池级预取，底座位一律 -1，因此“同池的多个底座”共用一个 K——
-- 每次生成消费一条决策（协议 §6.7.5），第二个底座需要新决策或走本地规则。
local function make_gen_level_key(pool_name, candidates)
    local sig = hash_num(pool_name .. "|" .. tostring(#candidates) .. "|" .. tostring(S.level.stage_seed))
    for i = 1, math.min(#candidates, 8) do
        sig = (sig * 31 + candidates[i].item_id) % 4294967296
    end
    return string.format("f%d:r%d:%s:p-1:%s",
        S.level.floor, S.level.grid, pool_name, hex8(sig))
end

local function capabilities_list()
    local caps = { "hook:pre_get_collectible", "apply:prefetch" }
    if Bridge.kind == "file" then caps[#caps + 1] = "transport:file_write" end
    return arr(caps)
end

local function build_state_doc(request_id, gen_key, trigger_type, pool_name, candidates, validity)
    local ts, clock = doc_ts()
    local player = read_player()
    local ids = items_snapshot()
    local items = {}
    for _, id in ipairs(ids) do
        items[#items + 1] = {
            id = id,
            name = item_name(id),
            tags = item_tags(id) or arr({}),
            count = 1,
        }
    end

    local room_type_name = ROOM_TYPE_NAMES[S.level.room_type] or "unknown"

    local is_clear = false
    pcall(function() is_clear = Game():GetRoom():IsClear() == true end)

    local boss = JSON_NULL
    pcall(function()
        local bid = Game():GetRoom():GetBossID()
        if type(bid) == "number" and bid > 0 then
            boss = { id = bid, name = JSON_NULL }
        end
    end)

    local payload = { pool = pool_name }
    if trigger_type == "boss_approach" then
        pcall(function()
            local bid = Game():GetRoom():GetBossID()
            if type(bid) == "number" and bid > 0 then payload.boss_id = bid end
        end)
    end

    local doc = {
        protocol_version = PROTOCOL_VERSION,
        session_id = "s-" .. tostring(S.boot) .. "-0001",
        request_id = request_id,
        gen_level_key = gen_key,
        ts = ts,
        validity_ms = validity,
        error_code = JSON_NULL,
        reason_code = JSON_NULL,
        features = capabilities_list(),
        requires = arr({}),
        capabilities = capabilities_list(),
        trigger = {
            type = trigger_type,
            event_seq = S.event_seq or 0,
            pedestal_index = JSON_NULL,
            payload = payload,
        },
        state = {
            player = {
                red_hearts = player.red_hearts,
                soul_hearts = player.soul_hearts,
                max_red_hearts = player.max_red_hearts or JSON_NULL,
                character_id = player.character_id or JSON_NULL,
                is_dead = player.is_dead,
            },
            items = arr(items),
            room = {
                type = room_type_name,
                is_boss_room = S.level.is_boss,
                grid_index = S.level.grid >= 0 and S.level.grid or JSON_NULL,
                is_clear = is_clear,
            },
            floor = S.level.floor,
            boss = boss,
            candidates = arr(candidates),
        },
        x_clock = clock,
        -- 候选来源：pool = 按道具池过滤；all_valid = 本版本没有池成员 API，退化为全表合法道具
        x_candidate_source = (S.pool_api == true) and "pool" or "all_valid",
        mod = { name = MOD_NAME, version = MOD_VERSION },
    }
    return doc
end

-- 写请求：v1 在换层/进房/Boss 前 + 等待期间按 validity/2 刷新（协议 §1.5、§6.1）
local function request_state(trigger_type, pool_name)
    local t = now_ms()
    local candidates = ensure_candidates(pool_name)
    local gen_key = make_gen_level_key(pool_name, candidates)
    local request_id = next_request_id()
    local validity = validity_for(trigger_type)
    local doc = build_state_doc(request_id, gen_key, trigger_type, pool_name, candidates, validity)

    S.outstanding[request_id] = {
        sent_ms = t,
        validity = validity,
        gen_level_key = gen_key,
        pool = pool_name,
        candidates = candidates,
        trigger = trigger_type,
    }
    S.outstanding_n = S.outstanding_n + 1
    local refreshes = 1
    if S.current ~= nil and S.current.gen_level_key == gen_key then
        refreshes = (S.current.refreshes or 0) + 1
    end
    S.current = {
        request_id = request_id,
        gen_level_key = gen_key,
        pool = pool_name,
        candidates = candidates,
        trigger = trigger_type,
        sent_ms = t,
        validity = validity,
        refreshes = refreshes,
    }
    S.last_request_id = request_id

    if Bridge.kind == "file" then
        -- 只入队；真正落盘在 on_update 的 flush_writes（协议 §6.2：回调内不做 I/O）
        Pending.state = doc
    end
    return request_id
end

local function prune_outstanding()
    local t = now_ms()
    for rid, rec in pairs(S.outstanding) do
        if (t - rec.sent_ms) > ((rec.validity or S.validity_ms) + OUTSTANDING_KEEP_MS) then
            S.outstanding[rid] = nil
            S.outstanding_n = math.max(0, S.outstanding_n - 1)
        end
    end
end

-- ============================================================
-- 决策校验（协议 §3.3、§3.5、§7）
-- ============================================================
local KNOWN_CAPABILITIES = {
    ["transport:file_write"] = true,
    ["hook:pre_get_collectible"] = true,
    ["apply:prefetch"] = true,
    ["apply:morph"] = true,
    ["action:reroll"] = false,   -- 本端 v1 不支持
}

local function parse_version(v)
    if type(v) ~= "string" then return nil end
    local major, minor = v:match("^(%d+)%.(%d+)")
    if major == nil then return nil end
    return tonumber(major), tonumber(minor) or 0
end

local function provider_prefix_ok(source, provider_id)
    if type(provider_id) ~= "string" then return false end
    local prefix = provider_id:match("^([a-z][a-z0-9_]*):")
    if prefix == nil then return false end
    if source == "llm" then return prefix == "llm" end
    if source == "rule" then
        return prefix == "rule" or prefix == "viewer" or prefix == "preset"
    end
    return false
end

-- 返回 ok, error_code, reason_code
local function validate_decision(doc, ctx)
    if type(doc) ~= "table" then return false, "VALIDATION", "invalid_type" end

    -- 版本：先选 codec 再判拒绝（协议 §7.3）
    local major = parse_version(doc.protocol_version)
    if major == nil then return false, "VALIDATION", "invalid_type" end
    if major ~= PROTOCOL_MAJOR then return false, "VALIDATION", "version_major" end

    for _, f in ipairs({ "request_id", "decision_id", "gen_level_key", "ts" }) do
        if doc[f] == nil or doc[f] == JSON_NULL then
            return false, "VALIDATION", "missing_field"
        end
    end
    if type(doc.valid) ~= "boolean" then return false, "VALIDATION", "missing_field" end
    if type(doc.decision) ~= "table" then return false, "VALIDATION", "missing_field" end
    if doc.error_code == nil then return false, "VALIDATION", "missing_field" end

    -- requires 里有本端不认识的能力 → 拒绝（协议 §7.4.2）
    if doc.requires ~= nil and doc.requires ~= JSON_NULL then
        if type(doc.requires) ~= "table" then return false, "VALIDATION", "invalid_type" end
        for _, need in ipairs(doc.requires) do
            if KNOWN_CAPABILITIES[need] ~= true then
                return false, "VALIDATION", "version_minor_feature"
            end
        end
    end

    local d = doc.decision
    local err = doc.error_code
    if err ~= JSON_NULL and err ~= nil then
        if type(err) ~= "string" then return false, "VALIDATION", "invalid_type" end
    else
        err = nil
    end

    if d.confidence == nil then return false, "VALIDATION", "missing_field" end
    if type(d.confidence) ~= "number" then return false, "VALIDATION", "invalid_type" end
    if d.confidence ~= d.confidence or d.confidence < 0 or d.confidence > 1 then
        return false, "VALIDATION", "out_of_range"
    end
    if d.fallback == nil then return false, "VALIDATION", "missing_field" end
    if type(d.fallback) ~= "boolean" then return false, "VALIDATION", "invalid_type" end
    if d.source == nil then return false, "VALIDATION", "missing_field" end
    if d.source ~= "llm" and d.source ~= "rule" then return false, "VALIDATION", "invalid_type" end
    if d.provider_id == nil then return false, "VALIDATION", "missing_field" end
    if not provider_prefix_ok(d.source, d.provider_id) then
        return false, "VALIDATION", "invalid_type"
    end

    local reason_code = d.reason_code
    if reason_code == JSON_NULL or reason_code == nil then reason_code = nil
    elseif type(reason_code) ~= "string" then return false, "VALIDATION", "invalid_type" end

    -- 真值表（协议 §3.3）
    if doc.valid == false then
        if err == nil then return false, "VALIDATION", "missing_field" end
        if d.fallback ~= true then return false, "VALIDATION", "invalid_type" end
        if d.source ~= "rule" then return false, "VALIDATION", "invalid_type" end
        if reason_code == nil then return false, "VALIDATION", "missing_field" end
        local ch = d.choice
        if type(ch) ~= "table" or ch.type ~= "action" or ch.action ~= "skip" then
            return false, "VALIDATION", "invalid_choice"
        end
        -- 合法但“不可执行”：mod 不执行其 skip，走本地规则（协议 §3.3 真值表第 4 行）
        return false, err, reason_code
    end

    if d.fallback then
        if d.source ~= "rule" then return false, "VALIDATION", "invalid_type" end
        if err == nil then
            if reason_code ~= "no_candidate" and reason_code ~= "player_dead" then
                return false, "VALIDATION", "invalid_type"
            end
        end
    else
        if err ~= nil then return false, "VALIDATION", "invalid_type" end
    end
    if d.source == "llm" and (d.fallback or err ~= nil) then
        return false, "VALIDATION", "invalid_type"
    end

    -- choice
    local ch = d.choice
    if type(ch) ~= "table" or type(ch.type) ~= "string" then
        return false, "VALIDATION", "invalid_choice"
    end
    -- 候选池与校验：先判“是不是合法 collectible”，再判“在不在候选池”
    if ch.type == "item" then
        local id = ch.item_id
        if type(id) ~= "number" or id ~= math.floor(id) or id < 1 then
            return false, "VALIDATION", "invalid_id"
        end
        if not is_valid_collectible(id) then
            return false, "VALIDATION", "invalid_id"
        end
        if not ctx.candidate_set[id] then
            return false, "VALIDATION", "invalid_choice"
        end
    elseif ch.type == "action" then
        if ch.action == "reroll" then
            -- 回调 62 里必须当帧返回 id，reroll 不可执行（协议 §3.2）
            return false, "VALIDATION", "invalid_action"
        elseif ch.action ~= "skip" then
            return false, "VALIDATION", "invalid_action"
        end
    else
        return false, "VALIDATION", "invalid_choice"
    end

    -- reason：可选；有则必须单行、≤280 字符
    local reason = d.reason
    if reason ~= nil and reason ~= JSON_NULL then
        if type(reason) ~= "string" then return false, "VALIDATION", "invalid_type" end
        if reason:find("[%z\1-\31\127]") ~= nil then
            return false, "VALIDATION", "invalid_reason"
        end
        if utf8_len(reason) > MAX_REASON_CHARS then
            return false, "VALIDATION", "invalid_reason"
        end
    end

    -- 本轮协议级校验
    if doc.request_id ~= ctx.request_id then
        return false, "VALIDATION", "request_mismatch"
    end
    if doc.gen_level_key ~= ctx.gen_level_key then
        return false, "VALIDATION", "level_mismatch"
    end
    return true, nil, nil
end

local function accept_decision(doc, ctx, t)
    S.decision = {
        doc = doc,
        received_ms = t,
        request_id = doc.request_id,
        gen_level_key = doc.gen_level_key,
        ctx = ctx,
    }
    next_decision_seen(doc.decision_id)
    S.stats.hits = S.stats.hits + 1
    log("info", "decision", string.format(
        "接受决策 %s（%s/%s，fallback=%s）",
        tostring(doc.decision_id), tostring(doc.decision.source),
        tostring(doc.decision.provider_id), tostring(doc.decision.fallback)),
        { request_id = doc.request_id, decision_id = doc.decision_id })
end

local function reject_decision(doc, error_code, reason_code)
    S.rejected = { doc = doc, error_code = error_code, reason_code = reason_code, at_ms = now_ms() }
    S.stats.rejected = S.stats.rejected + 1
    next_decision_seen(doc and doc.decision_id or nil)
    log_limited("warn", "decision", "reject_" .. tostring(reason_code),
        "拒绝决策：" .. tostring(error_code) .. "/" .. tostring(reason_code),
        {
            request_id = doc and doc.request_id or nil,
            decision_id = doc and doc.decision_id or nil,
            error_code = error_code,
            reason_code = reason_code,
        })
end

-- 轮询 decision.json（每 6 帧一次；回调里只做内存操作，I/O 在这里做）
local function poll_decision()
    if Bridge.kind ~= "file" then return end
    local text, rerr = bridge_read_raw("decision.json")
    if text == nil then
        if rerr ~= "missing" and rerr ~= "empty" then
            log_limited("warn", "bridge", "read_decision",
                "decision.json 读取失败：" .. tostring(rerr),
                { error_code = "IO", reason_code = tostring(rerr) })
        end
        return
    end
    if #text > MAX_DECISION_BYTES then
        reject_decision(nil, "VALIDATION", "out_of_range")
        return
    end

    local doc, derr = json_decode(text)
    if doc == nil then
        reject_decision(nil, "VALIDATION", "invalid_type")
        log_limited("warn", "decision", "parse",
            "decision.json 解析失败：" .. tostring(derr), { error_code = "VALIDATION", reason_code = "invalid_type" })
        return
    end

    -- 重复投递：相同 decision_id 直接忽略（协议 §6.7.6）
    if decision_already_seen(doc.decision_id) then return end

    local t = now_ms()
    -- 找这条决策对应的在途请求；找不到 = 旧回合/别家（request_mismatch），
    -- 或者该请求已经被用掉了（生成之后才到 → late，协议 §6.3）
    local out = S.outstanding[doc.request_id]
    if out == nil then
        if S.consumed_requests[doc.request_id] then
            reject_decision(doc, "TIMEOUT", "late")
        else
            reject_decision(doc, "VALIDATION", "request_mismatch")
        end
        return
    end

    local ctx = {
        request_id = out.request_id or doc.request_id,
        gen_level_key = out.gen_level_key,
        candidate_set = candidate_idset(out.candidates or {}),
        pool = out.pool,
    }
    -- 决策可能属于刷新前的请求：以在途记录为准
    local ok, ecode, rcode = validate_decision(doc, ctx)
    if not ok then
        reject_decision(doc, ecode, rcode)
        return
    end

    -- 有效期：接收时必须在窗口内（协议 §1.5 第一步）
    if (t - out.sent_ms) > (out.validity or S.validity_ms) then
        reject_decision(doc, "TIMEOUT", "late")
        return
    end

    accept_decision(doc, ctx, t)
end

-- ============================================================
-- 本地规则 v1（协议 §6.5；与插件 rule:fallback 同一套判定）
-- ============================================================
local LocalRule = { id = "rule:local", source = "rule" }

-- 排序口径（协议 §6.5.6）：non-null pedestal_index 升序 → 数组下标（null 时按出现顺序）
local function candidate_ped(c)
    local p = c.pedestal_index
    if type(p) == "number" then return p end
    return nil
end

local function has_tag(c, tag)
    local tags = c.tags
    if tags == nil then return false end
    for _, t in ipairs(tags) do
        if t == tag then return true end
    end
    return false
end

local function first_matching(candidates, tag)
    local best, best_ped = nil, nil
    for _, c in ipairs(candidates) do
        if has_tag(c, tag) then
            local ped = candidate_ped(c)
            if best == nil then
                best, best_ped = c, ped
            elseif ped ~= nil and (best_ped == nil or ped < best_ped) then
                best, best_ped = c, ped
            end
        end
    end
    return best
end

local function first_candidate(candidates)
    local best, best_ped = nil, nil
    for _, c in ipairs(candidates) do
        local ped = candidate_ped(c)
        if best == nil then
            best, best_ped = c, ped
        elseif ped ~= nil and (best_ped == nil or ped < best_ped) then
            best, best_ped = c, ped
        end
    end
    return best
end

-- ctx = { candidates, player, held_tags }
-- 返回 { choice = {...}, reason = "...", confidence = 1.0, reason_code = "..." }
function LocalRule.decide(ctx)
    local player = ctx.player or read_player()
    if player.is_dead then
        return { choice = { type = "action", action = "skip" },
            reason = "角色已死亡，保持原样", confidence = 1.0, reason_code = "player_dead" }
    end
    local candidates = ctx.candidates or {}
    if #candidates == 0 then
        return { choice = { type = "action", action = "skip" },
            reason = "没有可用候选，保持原样", confidence = 1.0, reason_code = "no_candidate" }
    end

    -- 规则 3：缺红心 → heal（max_red_hearts == 0 的角色跳过本规则）
    local has_red_containers = (player.max_red_hearts == nil) or (player.max_red_hearts > 0)
    if player.red_hearts == 0 and has_red_containers then
        local pick = first_matching(candidates, "heal")
        if pick ~= nil then
            return { choice = { type = "item", item_id = pick.item_id },
                reason = "红心见底，先补红心", confidence = 1.0, reason_code = "no_fresh_decision" }
        end
    end

    -- 规则 4：已持有道具里没有 damage 标签 → 优先 damage
    local held = ctx.held_tags or {}
    if not held["damage"] then
        local pick = first_matching(candidates, "damage")
        if pick ~= nil then
            return { choice = { type = "item", item_id = pick.item_id },
                reason = "输出偏低，先补输出", confidence = 1.0, reason_code = "no_fresh_decision" }
        end
    end

    -- 规则 5：默认分支
    local pick = first_candidate(candidates)
    if pick == nil then
        return { choice = { type = "action", action = "skip" },
            reason = "没有可用候选，保持原样", confidence = 1.0, reason_code = "no_candidate" }
    end
    return { choice = { type = "item", item_id = pick.item_id },
        reason = "按默认规则取候选", confidence = 1.0, reason_code = "no_fresh_decision" }
end

-- ============================================================
-- 回执（applied.json，协议 §5）
-- ============================================================
local function choice_to_wire(choice)
    if choice == nil then return JSON_NULL end
    if choice.type == "item" then
        return { type = "item", item_id = choice.item_id }
    end
    return { type = "action", action = choice.action }
end

local function applied_by_of(source, fallback, phase)
    if phase == "rejected" then return "none" end
    if fallback then return "fallback" end
    if source == "llm" then return "llm" end
    return "provider"
end

local function write_applied(rec)
    if Bridge.kind ~= "file" then
        -- Profile B：失败必须仍然可见（协议 §1.9），走日志 + 气泡
        log("info", "applied", string.format("phase=%s applied_by=%s reason_code=%s",
            tostring(rec.phase), tostring(rec.applied_by), tostring(rec.reason_code)),
            { request_id = rec.request_id, decision_id = rec.decision_id,
              error_code = rec.error_code, reason_code = rec.reason_code })
        return
    end
    -- 游戏回调里不做 I/O（协议 §6.2 / 架构 §3.2）：只入队，由 on_update 的状态机落盘
    Pending.applied = rec
end

local function build_applied_doc(rec)
    local ts, _ = doc_ts()
    return {
        protocol_version = PROTOCOL_VERSION,
        request_id = rec.request_id or JSON_NULL,
        gen_level_key = rec.gen_level_key or JSON_NULL,
        ts = ts,
        phase = rec.phase,
        decision_id = rec.decision_id or JSON_NULL,
        source = rec.source or JSON_NULL,
        provider_id = rec.provider_id or JSON_NULL,
        fallback = rec.fallback == true,
        applied_by = rec.applied_by,
        error_code = rec.error_code or JSON_NULL,
        reason_code = rec.reason_code or JSON_NULL,
        choice = choice_to_wire(rec.choice),
        reason = rec.reason or JSON_NULL,
        latency_ms = rec.latency_ms or JSON_NULL,
        pedestal_index = rec.pedestal_index or JSON_NULL,
        actual_item_id = rec.actual_item_id or JSON_NULL,
    }
end

-- 把回调期间排队的三份文档落盘（latest-wins，协议 §4.1 / §5.1）
local function flush_writes()
    if Bridge.kind ~= "file" then
        Pending.state, Pending.event, Pending.applied = nil, nil, nil
        return
    end
    if Pending.state ~= nil then
        local doc = Pending.state
        Pending.state = nil
        local ok, err = bridge_write_doc("state.json", doc, MAX_STATE_BYTES)
        if not ok then
            S.stats.io_err = S.stats.io_err + 1
            log_limited("error", "bridge", "write_state",
                "state.json 写入失败：" .. tostring(err),
                { request_id = doc.request_id, error_code = "IO", reason_code = tostring(err) })
        end
    end
    if Pending.event ~= nil then
        local doc = Pending.event
        Pending.event = nil
        local ok, err = bridge_write_doc("event.json", doc, MAX_EVENT_BYTES)
        if not ok then
            log_limited("warn", "bridge", "write_event",
                "event.json 写入失败：" .. tostring(err),
                { error_code = "IO", reason_code = tostring(err) })
        end
    end
    if Pending.applied ~= nil then
        local rec = Pending.applied
        Pending.applied = nil
        local ok, err = bridge_write_doc("applied.json", build_applied_doc(rec), MAX_APPLIED_BYTES)
        if not ok then
            S.stats.io_err = S.stats.io_err + 1
            log_limited("error", "bridge", "write_applied",
                "applied.json 写入失败：" .. tostring(err),
                { request_id = rec.request_id, error_code = "IO", reason_code = tostring(err) })
        end
    end
end

local function emit_event(etype, payload, request_id)
    if Bridge.kind ~= "file" then return end
    S.event_seq = (S.event_seq or 0) + 1
    local ts, _ = doc_ts()
    local doc = {
        protocol_version = PROTOCOL_VERSION,
        event_seq = S.event_seq,
        ts = ts,
        type = etype,
        request_id = request_id or JSON_NULL,
        payload = payload or {},
    }
    Pending.event = doc          -- latest-wins（协议 §4.1）
end

-- ============================================================
-- 气泡（协议 §6.6：兜底必须可见）
-- ============================================================
local FONT_CANDIDATES = {
    "resources-dlc3.zh/font/teammeatfontextended12.fnt",
    "resources.zh/font/teammeatfontextended12.fnt",
}

local function ensure_font()
    local f = S.font
    if f.tried then return f.ok and f.obj or nil end
    f.tried = true
    if type(Font) ~= "table" and type(Font) ~= "function" then
        log_limited("warn", "bubble", "no_font_api", "Font API 不可用（非 REPENTOGON？）→ 气泡降级为 ASCII")
        return nil
    end
    for _, path in ipairs(FONT_CANDIDATES) do
        local ok, obj = pcall(function()
            local font = Font()
            font:Load(path)
            return font
        end)
        if ok and obj ~= nil then
            local okW, w = pcall(function() return obj:GetStringWidthUTF8("中") end)
            if okW and type(w) == "number" and w > 0 then
                f.ok, f.obj = true, obj
                log("info", "bubble", "中文字体已加载：" .. path)
                return obj
            end
        end
    end
    f.ok = false
    log_limited("warn", "bubble", "font_fail", "官方中文字体不可用 → 气泡只显示 ASCII 标记")
    return nil
end

local function render_text_ascii(text, x, y)
    pcall(function() Isaac.RenderText(tostring(text), x, y, 1, 1, 1, 1) end)
end

local function show_bubble(text, ascii, is_fallback)
    S.bubble.text = tostring(text or "")
    S.bubble.ascii = tostring(ascii or "")
    S.bubble.fallback = (is_fallback == true)
    S.bubble.until_ms = now_ms() + BUBBLE_HOLD_MS
end

local function wrap_lines(font, text, max_w, scale)
    local lines = {}
    if font == nil then
        lines[1] = text
        return lines
    end
    local chars = utf8_chars(text)
    local cur = {}
    local width = 0
    for _, ch in ipairs(chars) do
        if ch == "\n" then
            lines[#lines + 1] = table.concat(cur)
            cur, width = {}, 0
        else
            local ok, w = pcall(function() return font:GetStringWidthUTF8(ch) end)
            if not ok or type(w) ~= "number" then w = 8 end
            w = w * scale
            if width + w > max_w and #cur > 0 then
                lines[#lines + 1] = table.concat(cur)
                cur, width = {}, 0
            end
            cur[#cur + 1] = ch
            width = width + w
        end
    end
    if #cur > 0 then lines[#lines + 1] = table.concat(cur) end
    if #lines == 0 then lines[1] = "" end
    return lines
end

local function draw_bubble()
    if S.bubble.until_ms <= 0 or now_ms() >= S.bubble.until_ms then return end
    if S.bubble.text == "" and S.bubble.ascii == "" then return end

    local sw, sh = 1280, 720
    pcall(function()
        sw = Isaac.GetScreenWidth() or sw
        sh = Isaac.GetScreenHeight() or sh
    end)
    local font = ensure_font()
    if font == nil then
        local text = S.bubble.ascii
        if text ~= "" then render_text_ascii(text, 20, sh - 40) end
        return
    end

    local scale = 0.6
    local max_w = sw - 40
    local lines = wrap_lines(font, S.bubble.text, max_w, scale)
    local x, y = 20, sh - 24 - (#lines * 12)
    if y < 40 then y = 40 end
    for i, line in ipairs(lines) do
        local ok_draw = pcall(function()
            font:DrawStringScaledUTF8(line, x, y + (i - 1) * 12, scale, scale,
                KColor(1, 0.95, 0.6, 1), 0, false)
        end)
        if not ok_draw then
            -- 签名不兼容时不能每帧报错：累计 3 次就永久停用自绘，退回 ASCII
            S.font.draw_fail = (S.font.draw_fail or 0) + 1
            if S.font.draw_fail >= 3 then
                S.font.ok = false
                log_limited("warn", "bubble", "draw_fail",
                    "DrawStringScaledUTF8 不可用 → 气泡退回 ASCII 标记")
                return
            end
        end
    end
end

-- ============================================================
-- 消费（回调 62）：只查内存，当帧返回
-- ============================================================
local function make_applied_from_decision(doc, gen_key, pedestal_index)
    local d = doc.decision
    local out = S.outstanding[doc.request_id]
    local rec = {
        request_id = doc.request_id,
        gen_level_key = gen_key,
        decision_id = doc.decision_id,
        source = d.source,
        provider_id = d.provider_id,
        fallback = (d.fallback == true),
        phase = "applied",
        choice = d.choice,
        reason = sanitize_reason(d.reason),
        error_code = (doc.error_code ~= JSON_NULL and doc.error_code) or nil,
        reason_code = (d.reason_code ~= JSON_NULL and d.reason_code) or nil,
        pedestal_index = pedestal_index,
        latency_ms = (out ~= nil) and (now_ms() - out.sent_ms) or nil,
        actual_item_id = nil,
    }
    rec.applied_by = applied_by_of(d.source, d.fallback, rec.phase)
    return rec
end

local function make_applied_local(rule, gen_key, pedestal_index, reason_code_override)
    local reason = sanitize_reason(rule.reason)
    if Bridge.kind ~= "file" then
        -- 协议 §1.9：Profile B 必须让玩家看见“桥接不可用”
        reason = "桥接不可用（本地规则）" .. (reason and ("：" .. reason) or "")
    end

    -- 安全跳过（无候选/已死亡）不是错误；其余兜底要写清“为什么没等到决策”
    local guard_skip = (rule.reason_code == "no_candidate" or rule.reason_code == "player_dead")
    local err_code, rsn_code = "TIMEOUT", "no_fresh_decision"
    if not guard_skip and S.rejected ~= nil and S.rejected.doc ~= nil
        and (now_ms() - (S.rejected.at_ms or 0)) < 5000 then
        -- 协议 §5.4 行 2：error_code / reason_code 取“最后被拒”的失败原因
        err_code = S.rejected.error_code or err_code
        rsn_code = S.rejected.reason_code or rsn_code
    end

    local rec = {
        request_id = S.last_request_id,
        gen_level_key = gen_key,
        -- 协议 §5.4：兜底时记“最后被拒决策”的 id，便于审计（没有则 null）
        decision_id = (S.rejected ~= nil and S.rejected.doc ~= nil
            and (now_ms() - (S.rejected.at_ms or 0)) < 5000)
            and S.rejected.doc.decision_id or nil,
        source = "rule",
        provider_id = LocalRule.id,
        fallback = true,
        phase = "applied",
        choice = rule.choice,
        reason = reason,
        error_code = guard_skip and nil or err_code,
        reason_code = reason_code_override or (guard_skip and rule.reason_code or rsn_code),
        pedestal_index = pedestal_index,
        latency_ms = nil,
        actual_item_id = nil,
    }
    rec.applied_by = "fallback"
    return rec
end

-- 决策是否仍可用：必须同时满足
--   ① 请求仍在在途表（未被消费/未被清理）；② K 与请求一致；③ 未过有效期。
-- 缓存的失效判据就在这里，不能只看“收到过一条决策”。
local function decision_is_fresh(d, t)
    if d == nil then return false end
    local out = S.outstanding[d.request_id]
    if out == nil then return false end
    if d.gen_level_key ~= out.gen_level_key then return false end
    if type(d.received_ms) ~= "number" then return false end
    t = t or now_ms()
    if t < d.received_ms then return false end
    return (t - out.sent_ms) <= (out.validity or S.validity_ms)
end

-- 生成当帧：优先用内存里的新鲜决策，否则本地规则（协议 §6.2）
local function consume(pool_name, gen_key, candidates)
    local t = now_ms()
    local d = S.decision
    if d ~= nil then
        local doc = d.doc
        local same_target = (doc.gen_level_key == gen_key)
        local fresh = decision_is_fresh(d, t)
        if same_target and fresh then
            -- 先算回执（latency 要读在途记录的 sent_ms），再作废请求
            local rec = make_applied_from_decision(doc, gen_key, S.ped_index)
            local item_id = nil
            if doc.decision.choice.type == "item" then
                item_id = doc.decision.choice.item_id
            end

            -- 消费一次即作废（协议 §6.7.5）：
            --   ① 该 request 立刻移出在途表；② 记住它已消费 → 迟到决策按 late 拒绝。
            -- 不这么做的话，同一 request 的新 decision_id 会继续被接受，
            -- 下一次生成又记成 llm（重复消费 / 归属错）。
            S.outstanding[doc.request_id] = nil
            S.outstanding_n = math.max(0, (S.outstanding_n or 0) - 1)
            S.consumed_requests[doc.request_id] = true
            S.consumed_n = (S.consumed_n or 0) + 1
            if S.consumed_n > 256 then
                S.consumed_requests, S.consumed_n = {}, 0
            end
            S.decision = nil
            if S.current ~= nil then S.current.refreshes = 0 end
            S.stats.draws = S.stats.draws + 1
            return item_id, rec
        end
        -- 过期或跨目标：丢弃，不留给下一次生成
        if same_target and not fresh then
            S.stats.timeout = S.stats.timeout + 1
        end
        S.decision = nil
    end

    -- 本地规则
    local player = read_player()
    local _, held_tags = items_snapshot()
    local rule = LocalRule.decide({
        candidates = candidates,
        player = player,
        held_tags = held_tags,
    })
    local rec = make_applied_local(rule, gen_key, S.ped_index)
    S.stats.draws = S.stats.draws + 1
    S.stats.fallback = S.stats.fallback + 1
    if rule.choice.type == "item" then
        return rule.choice.item_id, rec
    end
    return nil, rec
end

-- ============================================================
-- 气泡文本合成
-- ============================================================
local function bubble_from_applied(rec, item_id)
    local name = nil
    if item_id ~= nil then
        name = item_name(item_id)
    end
    local label
    if rec.applied_by == "fallback" then
        label = "[规则]"
    elseif rec.applied_by == "llm" then
        label = "[AI]"
    else
        label = "[预置]"
    end
    local head = label .. " " .. (name and (name .. " #" .. tostring(item_id)) or ("#" .. tostring(item_id or "?")))
    local body = rec.reason or ""
    if body == "" then body = rec.reason_code or "" end
    local text = head
    if body ~= "" then text = head .. "：" .. body end
    local ascii = (rec.applied_by == "fallback" and "[RULE]" or "[AI]")
        .. " item#" .. tostring(item_id or "skip")
        .. (rec.reason_code and (" " .. tostring(rec.reason_code)) or "")
    show_bubble(text, ascii, rec.applied_by == "fallback")
end

-- ============================================================
-- 钩子
-- ============================================================
local function on_game_start()
    S.boot = hex8(hash_num(tostring(now_ms()) .. tostring(math.random(0, 999999)))):sub(1, 8)
    S.counter = 0
    S.decision = nil
    S.outstanding = {}
    S.outstanding_n = 0
    S.current = nil
    S.cand_cache = {}
    S.items_cache = nil
    S.next_pedestal_index = 0
    S.pending_verify = nil
    S.seen_decisions, S.seen_order = {}, {}
    S.consumed_requests, S.consumed_n = {}, 0
    S.event_seq = 0

    bridge_detect()
    load_tags()
    log("info", "start", string.format(
        "isaac_agent %s 已加载；协议 %s；Profile=%s；validity=%dms（Boss=%dms）",
        MOD_VERSION, PROTOCOL_VERSION, S.profile, DEFAULT_VALIDITY_MS, BOSS_VALIDITY_MS))
end

local function on_new_level()
    S.level = read_level()
    S.cand_cache = {}            -- 候选签名含层信息，换层重建
    S.items_cache = nil
    S.next_pedestal_index = 0
    S.decision = nil
    log("info", "level", string.format("进入第 %d 层（stage_seed=%d）",
        S.level.floor, S.level.stage_seed), { error_code = "", reason_code = "" })
end

local function on_new_room()
    S.level = read_level()
    S.next_pedestal_index = 0
    S.decision = nil

    local trigger = "room_enter"
    if S.level.is_boss then trigger = "boss_approach" end
    local pool_name = guess_pool_for_room(S.level.room_type)

    emit_event(trigger, {
        room_type = ROOM_TYPE_NAMES[S.level.room_type] or "unknown",
        floor = S.level.floor,
        is_boss_room = S.level.is_boss,
        grid_index = S.level.grid >= 0 and S.level.grid or JSON_NULL,
    }, nil)

    -- 预取一次（协议 §6.2：生成前就要有决策；room_enter 往往已经偏晚，这里尽力而为）
    request_state(trigger, pool_name)
end

-- 回调 62：池抽取完成、底座生成之前
local function on_pre_get_collectible(_, pool, decrease, seed)
    local pool_id = tonumber(pool) or 0
    local pool_name = pool_name_of(pool_id)
    local ped = S.next_pedestal_index
    if ped > 63 then ped = 63 end
    S.next_pedestal_index = S.next_pedestal_index + 1
    S.ped_index = ped

    local candidates = ensure_candidates(pool_name)
    local gen_key = make_gen_level_key(pool_name, candidates)
    local item_id, applied = consume(pool_name, gen_key, candidates)

    if applied ~= nil then
        applied.pedestal_index = ped
        write_applied(applied)
        if item_id ~= nil then
            S.pending_verify = {
                item_id = item_id,
                applied = applied,
                frame = frame(),
                gen_key = gen_key,
            }
            log("info", "draw", string.format(
                "pool=%s ped=%d → 返回 %d（%s）",
                pool_name, ped, item_id, tostring(applied.applied_by)),
                { request_id = applied.request_id, decision_id = applied.decision_id })
        else
            S.pending_verify = nil
            log("info", "draw", string.format(
                "pool=%s ped=%d → 保持原版（%s/%s）",
                pool_name, ped, tostring(applied.error_code), tostring(applied.reason_code)),
                { request_id = applied.request_id, reason_code = applied.reason_code })
        end
    end
    return item_id
end

-- 底座实体初始化：核验“返回的 id == 实际生成的 id”，核验后才弹气泡
local function on_pickup_init(_, pickup)
    if pickup == nil then return end
    local ok, variant = pcall(function() return pickup.Variant end)
    if not ok or variant ~= COLLECTIBLE_VARIANT then return end
    local sub = nil
    pcall(function() sub = pickup.SubType end)
    if type(sub) ~= "number" then return end

    local pv = S.pending_verify
    if pv == nil then return end
    local cur = frame()
    if (cur - pv.frame) > 2 then
        S.pending_verify = nil
        return
    end

    if pv.item_id == sub then
        pv.applied.actual_item_id = sub
        pv.applied.phase = "applied"
        write_applied(pv.applied)
        bubble_from_applied(pv.applied, sub)
        emit_event("pedestal_spawn", {
            pedestal_index = pv.applied.pedestal_index or 0,
            item_id = sub,
            item_name = item_name(sub),
            room_type = ROOM_TYPE_NAMES[S.level.room_type] or "unknown",
        }, pv.applied.request_id)
        log("info", "verify", string.format("核验通过：%d（decision=%s）",
            sub, tostring(pv.applied.decision_id)),
            { request_id = pv.applied.request_id, decision_id = pv.applied.decision_id })
    else
        -- 决策没真正生效（别的来源覆盖 / 未生成）
        -- 协议 §5.4 行 3：rejected ⇒ applied_by=none、choice=null、source=null、
        -- provider_id=null、fallback=true。保留 llm/item/fallback=false 会让回执自相矛盾。
        pv.applied.phase = "rejected"
        pv.applied.applied_by = "none"
        pv.applied.source = nil
        pv.applied.provider_id = nil
        pv.applied.fallback = true
        pv.applied.choice = nil
        pv.applied.error_code = "INTERNAL"
        pv.applied.reason_code = "not_applied"
        pv.applied.actual_item_id = sub
        write_applied(pv.applied)
        show_bubble("[兜底] 决策未生效（实际 " .. tostring(sub) .. "）",
            "[RULE] not_applied", true)
        log_limited("warn", "verify", "not_applied",
            string.format("返回 %s，实际生成 %s", tostring(pv.item_id), tostring(sub)),
            { request_id = pv.applied.request_id, error_code = "INTERNAL", reason_code = "not_applied" })
    end
    S.pending_verify = nil
end

local function on_update()
    -- 回调期间排队的文档每帧落盘（无排队时是 3 次 nil 判断）
    flush_writes()

    S.poll_counter = S.poll_counter + 1
    if S.poll_counter < POLL_EVERY_FRAMES then return end
    S.poll_counter = 0

    poll_decision()
    prune_outstanding()

    -- 缓存过期就丢掉：否则 S.decision 非空会一直压住刷新（协议 §6.7.4 / §6.7.8），
    -- 新请求发不出去，下一个底座只能吃旧决策或兜底。
    if S.decision ~= nil and not decision_is_fresh(S.decision) then
        S.decision = nil
        log_limited("info", "cache", "stale_decision",
            "缓存决策已过期 → 丢弃并恢复刷新", { reason_code = "no_fresh_decision" })
    end

    -- 刷新：等待生成期间每 validity/2 发一次新请求（同 K，新 request_id），
    -- 有上限：对端一直不回时不能无限重发（每 K 最多 MAX_REFRESHES 次）
    local c = S.current
    if c ~= nil and S.decision == nil and (c.refreshes or 0) < MAX_REFRESHES then
        local age = now_ms() - c.sent_ms
        if age >= math.floor((c.validity or S.validity_ms) / 2) then
            request_state(c.trigger, c.pool)
        end
    end
    flush_writes()
end

local function on_render()
    draw_bubble()
end

local function on_game_end()
    S.decision = nil
    S.outstanding = {}
    S.outstanding_n = 0
    S.current = nil
    S.pending_verify = nil
    S.bubble.until_ms = 0
    log("info", "end", string.format(
        "本局结束：抽取 %d / 命中 %d / 兜底 %d / 拒绝 %d / 超时 %d / IO 错误 %d",
        S.stats.draws, S.stats.hits, S.stats.fallback, S.stats.rejected,
        S.stats.timeout, S.stats.io_err))
end

-- ============================================================
-- 注册（standards.md：on_<事件> 命名、集中注册、回调包 pcall）
-- ============================================================
local function guard(module, fn)
    return function(...)
        local ok, res = pcall(fn, ...)
        if not ok then
            log_limited("error", module, "callback_" .. module,
                "回调异常：" .. tostring(res), { error_code = "INTERNAL", reason_code = "internal_error" })
            return nil
        end
        return res
    end
end

local CB = ModCallbacks or {}
local PRE_GET_COLLECTIBLE = CB.MC_PRE_GET_COLLECTIBLE or 62

mod:AddCallback(PRE_GET_COLLECTIBLE, guard("draw", on_pre_get_collectible))
if CB.MC_POST_UPDATE ~= nil then mod:AddCallback(CB.MC_POST_UPDATE, guard("update", on_update)) end
if CB.MC_POST_RENDER ~= nil then mod:AddCallback(CB.MC_POST_RENDER, guard("render", on_render)) end
if CB.MC_POST_NEW_LEVEL ~= nil then mod:AddCallback(CB.MC_POST_NEW_LEVEL, guard("level", on_new_level)) end
if CB.MC_POST_NEW_ROOM ~= nil then mod:AddCallback(CB.MC_POST_NEW_ROOM, guard("room", on_new_room)) end
if CB.MC_POST_PICKUP_INIT ~= nil then mod:AddCallback(CB.MC_POST_PICKUP_INIT, guard("pickup", on_pickup_init)) end
if CB.MC_POST_GAME_START ~= nil then mod:AddCallback(CB.MC_POST_GAME_START, guard("start", on_game_start)) end
if CB.MC_POST_GAME_END ~= nil then mod:AddCallback(CB.MC_POST_GAME_END, guard("end", on_game_end)) end

-- 调试入口（控制台 isaac_agent status）——只读，不执行任何模型输出
if CB.MC_EXECUTE_CMD ~= nil then
    mod:AddCallback(CB.MC_EXECUTE_CMD, function(_, cmd, args)
        if type(cmd) == "string" and cmd:lower() == "isaac_agent" then
            local sub = tostring(args or ""):lower()
            if sub == "status" then
                log("info", "cmd", string.format(
                    "profile=%s dir=%s cached=%s outstanding=%d decision=%s",
                    S.profile, tostring(Bridge.dir), tostring(#(S.current and S.current.candidates or {})),
                    S.outstanding_n, tostring(S.decision ~= nil)))
            elseif sub == "refreshtags" then
                load_tags()
            else
                log("info", "cmd", "用法：isaac_agent status")
            end
        end
        return nil     -- MC_EXECUTE_CMD 返回非 nil 会崩游戏
    end)
end

-- 供离线测试使用（不写全局；测试通过 dofile 的返回值取）
return {
    name = MOD_NAME,
    version = MOD_VERSION,
    protocol_version = PROTOCOL_VERSION,
    hooks = {
        on_game_start = on_game_start,
        on_new_level = on_new_level,
        on_new_room = on_new_room,
        on_pre_get_collectible = on_pre_get_collectible,
        on_pickup_init = on_pickup_init,
        on_update = on_update,
        on_render = on_render,
        on_game_end = on_game_end,
    },
    _test = {
        S = S,
        Bridge = Bridge,
        JSON_NULL = JSON_NULL,
        arr = arr,
        detect = bridge_detect,
        request_state = request_state,
        poll_decision = poll_decision,
        validate_decision = validate_decision,
        local_rule = LocalRule.decide,
        encode = json_encode,
        decode = json_decode,
        make_key = make_gen_level_key,
        ensure_candidates = ensure_candidates,
        write_applied = write_applied,
        flush_writes = flush_writes,
        decision_is_fresh = decision_is_fresh,
        consume = consume,
        reset = function()
            S.decision = nil
            S.rejected = nil
            S.outstanding = {}
            S.outstanding_n = 0
            S.current = nil
            S.pending_verify = nil
            S.seen_decisions, S.seen_order = {}, {}
            S.consumed_requests, S.consumed_n = {}, 0
            S.stats = { draws = 0, hits = 0, fallback = 0, rejected = 0, timeout = 0, io_err = 0 }
            S.next_pedestal_index = 0
            S.cand_cache = {}
            S.items_cache = nil
            Pending.state, Pending.event, Pending.applied = nil, nil, nil
        end,
    },
}
