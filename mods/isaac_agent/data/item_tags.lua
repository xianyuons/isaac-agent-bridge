-- data/item_tags.lua
-- 静态道具标签表（协议 §2.6）。由 mod 侧生成并写进 state.candidates[].tags；
-- 插件侧不得维护第二份表，避免两端判定分叉。
--
-- 口径（保守子集）：只收录高置信度、含义稳定的原版道具。未收录 = 无标签，
-- 规则会走默认分支（安全，不会误判）。宁缺勿错：错误的 heal/damage 标签
-- 会让本地规则挑出与玩家处境相反的道具。
--
-- 维护：新增标签请同时更新 tests/lua_logic_test.lua 的标签用例。

local TAGS = {
    -- heal：回红心 / 加红心容器（规则 3 依赖）
    [15]  = { "heal" },   -- <3
    [16]  = { "heal" },   -- Raw Liver
    [22]  = { "heal" },   -- Lunch
    [23]  = { "heal" },   -- Dinner
    [24]  = { "heal" },   -- Dessert
    [25]  = { "heal" },   -- Breakfast
    [26]  = { "heal" },   -- Rotten Meat
    [45]  = { "heal", "active" },  -- Yum Heart

    -- damage：提升输出（规则 4 依赖）
    [4]   = { "damage" },           -- Cricket's Head
    [7]   = { "damage" },           -- Blood of the Martyr
    [12]  = { "damage" },           -- Magic Mushroom
    [13]  = { "damage" },           -- The Virus
    [34]  = { "damage" },           -- The Book of Belial
    [114] = { "damage" },           -- Mom's Knife
    [118] = { "damage" },           -- Brimstone
    [149] = { "damage" },           -- Ipecac
    [169] = { "damage" },           -- Polyphemus
    [172] = { "damage" },           -- Sacred Heart
    [331] = { "damage" },           -- Godhead

    -- tear：射速 / 弹道
    [1]   = { "tear" },             -- Sad Onion
    [2]   = { "tear" },             -- The Inner Eye
    [3]   = { "tear" },             -- Spoon Bender
    [32]  = { "tear" },             -- Wire Coat Hanger
    [224] = { "tear" },             -- Cricket's Body

    -- speed
    [14]  = { "speed" },            -- Roid Rage
    [27]  = { "speed" },            -- Wooden Spoon
    [28]  = { "speed" },            -- The Belt

    -- defense
    [10]  = { "defense" },          -- Halo of Flies

    -- utility（信息 / 资源）
    [21]  = { "utility" },          -- The Compass
    [54]  = { "utility" },          -- Treasure Map
    [105] = { "utility", "active" },-- The D6

    -- familiar
    [8]   = { "familiar" },         -- Brother Bobby
    [67]  = { "familiar" },         -- Sister Maggy

    -- active
    [38]  = { "active" },           -- Tammy's Head
    [42]  = { "active" },           -- Bob's Rotten Head
    [47]  = { "active" },           -- Doctor's Remote
}

return { version = 1, tags = TAGS }
