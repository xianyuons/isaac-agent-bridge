--[[ ============================================================================
spike/profile_b_probe — 一次性回答：默认启动（不加 --luadebug）下 mod 能读什么文件
============================================================================
这不是产品代码，只是探针。装上后进一次游戏，在 log.txt 里搜 `[PROBE]`。

它回答四件事：
  1) io / os / package / debug / jit 在默认启动下是否存在（os 有哪些函数）；
  2) Mod:LoadData() 能不能读到自己的 save<槽位>.dat，内容是什么；
  3) Mod:SaveData() 写下去之后立刻回读，能否读到刚写的明文（判断是否“每次读盘”）；
  4) REPENTOGON 版本能力：Isaac.LoadModDataFromFolder（≥1.1.2e）、
     Mod:LoadData("文件名")（≥1.1.3-unstable）。

⚠️ 本探针会覆盖 isaac_agent_probe 这个 mod **自己的**存档数据（它不存别的），
   不会碰其它 mod 的文件。不想要这份数据就删掉 data/isaac_agent_probe/ 整个目录。
============================================================================ ]]

local mod = RegisterMod("isaac_agent_probe", 1)
local done = false
local waited = 0

local function out(key, value)
    pcall(function()
        Isaac.DebugString("[PROBE] " .. tostring(key) .. " = " .. tostring(value))
    end)
end

local function read_self(tag)
    local ok, v = pcall(function() return mod:LoadData() end)
    if not ok then
        out(tag, "ERROR " .. tostring(v))
        return nil
    end
    if v == nil then
        out(tag, "<nil>（文件不存在或读不到）")
        return nil
    end
    local s = tostring(v)
    out(tag, string.format("len=%d head=%q", #s, s:sub(1, 80)))
    return s
end

local function probe()
    if done then return end
    done = true

    out("game_version_note", "以下结果用于判断 Profile B/C 可行性（见 docs/spike-profile-b.md）")

    -- ① 标准库存在性
    out("type(io)", type(io))
    out("type(os)", type(os))
    local names = {}
    if type(os) == "table" then
        for k in pairs(os) do names[#names + 1] = tostring(k) end
    end
    table.sort(names)
    out("os_fields", table.concat(names, ","))
    out("type(package)", type(package))
    out("type(debug)", type(debug))
    out("type(jit)", type(jit))
    out("type(loadlib)", (type(package) == "table") and type(package.loadlib) or "n/a")

    -- ② 读自己的 save<slot>.dat
    local before = read_self("LoadData()_before")

    -- ③ 写一份可识别数据并立刻回读（判断是不是每次读盘）
    local payload = string.format('{"probe":"isaac_agent_probe","t":%d}', math.floor(Isaac.GetTime()))
    local okw, ew = pcall(function()
        mod:SaveData(payload)
        return true
    end)
    out("SaveData(payload)", okw and "ok" or ("ERROR " .. tostring(ew)))
    local after = read_self("LoadData()_after")
    out("save_then_load_equal", (after == payload) and "true（说明 SaveData 立即落盘、LoadData 立即读到）"
        or "false（可能被缓存或被游戏覆盖）")
    out("before_was_nil", (before == nil) and "true" or "false")

    -- ④ 版本能力
    out("Isaac.LoadModDataFromFolder", type(Isaac.LoadModDataFromFolder))
    if type(Isaac.LoadModDataFromFolder) == "function" then
        local ok, v = pcall(function() return Isaac.LoadModDataFromFolder("isaac_agent_probe") end)
        if ok then
            out("LoadModDataFromFolder(self)", v == nil and "<nil>" or ("len=" .. #tostring(v)))
        else
            out("LoadModDataFromFolder(self)", "ERROR " .. tostring(v))
        end
    end

    local okf, vf = pcall(function() return mod:LoadData("probe.json") end)
    out("LoadData('probe.json')", okf and (vf == nil and "<nil>" or ("len=" .. #tostring(vf))) or ("ERROR " .. tostring(vf)))
    out("filename_api_supported",
        (okf and vf == nil and after ~= nil and after ~= vf) and "可能不支持（返回 nil）"
        or "见上面数值；若 SaveData(data,'probe.json') 后能读到就是支持")

    local oks = pcall(function() mod:SaveData('{"f":"probe.json"}', "probe.json") end)
    out("SaveData(data,'probe.json')", oks and "ok(或该版本忽略第二参数)" or "ERROR")
    local okr, vr = pcall(function() return mod:LoadData("probe.json") end)
    out("LoadData('probe.json')_after_save", okr and tostring(vr) or ("ERROR " .. tostring(vr)))

    out("done", "true")
end

-- 进游戏后跑一次
mod:AddCallback(ModCallbacks.MC_POST_GAME_START, function()
    pcall(probe)
end)

-- 兜底：主菜单/没触发 GAME_START 时，60 帧后也跑一次
mod:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
    if done then return end
    waited = waited + 1
    if waited >= 60 then pcall(probe) end
end)

-- 控制台可重跑：isaac_agent_probe
mod:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, cmd)
    if type(cmd) == "string" and cmd:lower() == "isaac_agent_probe" then
        done = false
        pcall(probe)
    end
    return nil
end)
