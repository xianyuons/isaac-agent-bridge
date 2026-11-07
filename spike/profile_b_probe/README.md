# profile_b_probe — 默认启动下 mod 能读什么文件

配套文档：[docs/spike-profile-b.md](../../docs/spike-profile-b.md)。

## 怎么跑（真机，约 3 分钟）

1. 把整个 `profile_b_probe/` 目录复制到游戏的 mods 目录：
   `<Steam>/steamapps/common/The Binding of Isaac Rebirth/mods/isaac_agent_probe/`
2. 启动游戏（**不要**加 `--luadebug`），在 Mods 菜单里启用 `isaac_agent_profile_b_probe`。
   如果之前没开 mods：主菜单 → Mods → 打开 Enable Mods，重启游戏。
3. 进一局游戏（任意存档位）或直接进主菜单等 60 帧。
4. 退出后打开 `log.txt`（在存档目录，通常是
   `C:\Users\<你>\Documents\My Games\Binding of Isaac Repentance+\log.txt`），
   搜 `[PROBE]`。

## 输出怎么读

| 行 | 含义 |
| --- | --- |
| `type(io) = nil` | 默认启动没有原生 `io`（预期）。若为 `table`，说明沙箱被放开（`--luadebug`？） |
| `os_fields = clock,date,difftime,time` | `os` 存在但被 REPENTOGON 裁到 4 个函数（无 rename/remove/getenv） |
| `type(package) = nil` / `type(jit) = nil` | 没有 loadlib、没有 FFI（预期） |
| `LoadData()_before` | 读到自己的 `data/isaac_agent_probe/save<槽位>.dat`（首次应为 `<nil>`） |
| `SaveData(payload) = ok` 且 `save_then_load_equal = true` | **关键**：写下去后立刻能读回原文，说明 `LoadData` 是每次读盘、`SaveData` 立即落盘 → 实时中继可行 |
| `save_then_load_equal = false` | 说明有缓存或被游戏覆盖 → Profile C 需要重新设计写入时机 |
| `Isaac.LoadModDataFromFolder = function` | REPENTOGON ≥ 1.1.2e（可做双文件方案 C2） |
| `LoadData('probe.json')_after_save` 能读到 `{"f":"probe.json"}` | REPENTOGON ≥ 1.1.3-unstable（可做任意文件名方案 C3） |

## 副作用

探针会写 `data/isaac_agent_probe/save<槽位>.dat`（本 mod 自己的数据文件，内容是一行 JSON）。
不想要就删掉整个 `data/isaac_agent_probe/` 目录；不会影响其它 mod 的数据。
