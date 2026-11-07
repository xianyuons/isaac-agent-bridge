# 踩坑记录（谁都可以加，谁都必须先读）

规则：
- **开工前先读这一页**，尤其是自己那一节。
- 犯了新错，**当场加一行**，别等收尾；写清「现象 → 根因 → 怎么避」。
- 不删别人的条目；错误改正了就在后面标 `[已避]`。

---

## 全员

| 现象 | 根因 | 怎么避 |
| --- | --- | --- |
| git remote 里内嵌了 PAT，`git remote -v` 直接能看到 | 用 `https://x-access-token:TOKEN@github.com/...` 图省事 | remote 永远用干净 URL；认证走 `GIT_ASKPASS`（读私有文件），token 不进配置、不进命令行 |
| PowerShell 里 `git push` 明明成功，退出码却是 1 | stderr 有输出被当成错误 | 判成功看输出里有没有 `->` / `up-to-date`，别只看 exit code |
| 以为 `claude-sonnet-5-5` 存在，结果 503 `model_not_found` | 配置里写的模型名没跟上游核对 | 用某模型前先 `GET /v1/models` 确认它真的在列表里 |
| ginka 全部 502 时反复重试，浪费 20 分钟 | 把"上游挂了"当成"线路问题" | 先判断是上游还是网络：换 host、换直连/代理都不通，且**每次都卡同一个超时值**（43s），就是上游；停手并记录证据 |

## captain（妹妹）

| 现象 | 根因 | 怎么避 |
| --- | --- | --- |
| 把 token 写进 git remote | 图省事 | 见上：askpass |
| 派活时写了不存在的模型名（sonnet-5-5） | 凭记忆写配置 | 派活前查 `/v1/models` |

## contract

（还没有条目；抓到就加）

## mod-lua

| 现象 | 根因 | 怎么避 |
| --- | --- | --- |
| t2 之前以为"1500ms 是 mod 阻塞等待" | 没先读参考实现 | 改道具的钩子（`MC_PRE_GET_COLLECTIBLE`）**必须当帧返回**；1500ms 是决策有效期，不是等待时长 |

## plugin-ts

（还没有条目；抓到就加）

## qa

| 现象 | 根因 | 怎么避 |
| --- | --- | --- |
| 同一台机跑几次 `tests/run_lua_test.py` 后报"没有可用盘符做 subst，无法在非 ASCII 路径下运行" | 用例末尾的 `os.exit()` 会直接结束 **Python 宿主进程**，runner 的 `finally: subst <drive>: /d` 根本来不及执行，盘符映射一直残留（G–Z 全被占满后就没有空闲盘符） | 先 `subst` 列出残留映射，逐个 `subst <drive>: /d` 清掉；根治要改 runner：清理放在映射之前（复用/回收旧映射），或让 Lua 用例返回状态而不是 `os.exit()` |

## claude / gpt（外部评审）

| 现象 | 根因 | 怎么避 |
| --- | --- | --- |
| 评审意见写得很漂亮但没落到字段上 | 只讲原则不讲位置 | 每条意见必须带「哪一节 / 哪个字段 / 应该改成什么」，否则不算采纳项 |

## 2026-11-07 补记（t3 提出，captain 采纳）

| 现象 | 根因 | 怎么避 |
| --- | --- | --- |
| 共享工作树在别人分支上、还有未提交改动，差点被 git add -A 卷进别人的提交 | 所有人共用一个 worktree | **每个任务固定一个独立 worktree**（如 `E:\Yuki\工作\isaac-agent-t3`），提交完再回共享树 |
| 以为 Lua 沙箱能随便写盘 | IsaacDocs Standard-Library：`io`/`os` **只在 `--luadebug` 下可用** | 游戏侧默认走 Profile B（mod 只读 decision，插件负责写）；要 Profile A 就明写"需要 `--luadebug` 启动"，并在 README 提示这会放开 mod 的文件权限 |
| 目录口径两套：任务书写 `mods/isaac_agent/`，规范写 `lua/` | 规范起草时没对齐游戏的真实目录结构 | **统一到 `mods/<mod名>/`**（游戏要求），规范里补一句：游戏侧按 mod 结构，其余照原规范 |
