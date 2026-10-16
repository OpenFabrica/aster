# Agent 远程执行（agent host access）

## 背景与概念

编程 agent（Claude Code、Codex 等）经 Aster 在**已保存的 SSH 主机**上执行命令，自己永远拿不到
口令或私钥。命令敲进一个真实的原生 SSH 终端（`aster-ssh client`），终端显示在浮动窗口里，用户
全程看得见、随时能接手；每台主机的访问都要用户批准，所有执行与授权变化写审计。

入口有三个，都落到控制协议的 `host.*` 方法：

- `aster host exec|wait|read|interrupt|close|open|terminals`（CLI，Aster Pane 里的 agent 用）；
- `aster mcp`（stdio MCP server，Codex 的沙箱多半连不上控制 socket，MCP 是它的主路径）；
- 直接走控制 socket（`host.exec` 等，见 [工作流和代理](workflows-and-agents.md)）。

威胁模型：约束的是**配合的** agent，不是恶意软件。同一用户下的恶意进程仍能读用户文件、用
ssh-agent、模拟点击。这不是沙箱。目标是：agent 拿不到秘密；每次远程访问都经按主机的批准并留痕；
明显的绕路被堵上；用户能接手。broker 票据与原生 SSH Pane 的敏感判定见 [原生 SSH](native-ssh.md)。

## 组成

| 位置 | 职责 |
|---|---|
| `Sources/AsterCore/AgentHostAccess/AgentHostControlProtocol.swift` | 方法名、参数、结果、上限（snake_case） |
| `…/AgentHostCommandFraming.swift` | 注入行构造、屏幕文本解析、输出截断（纯函数） |
| `…/AgentHostCommandTracker.swift` | 当前命令状态推进：完成 / 等输入 / 恢复 / 中断 / 结束 |
| `…/AgentHostPromptHeuristics.swift` | `needs_input` 判断 |
| `…/AgentHostGrant.swift` | 授权条目、目标指纹、授权簿（判断、冷却、过期） |
| `…/AgentHostAuditRecord.swift`、`AgentHostCommandRedactor.swift` | 审计 schema 与命令脱敏 |
| `…/AgentHostMCPTools.swift` 等 | `aster mcp` 的协议处理（工具目录、参数映射、渲染） |
| `…/MCPJSONRPC.swift` | JSON-RPC 类型（由 aster-memory-mcp 与 aster mcp 共用） |
| `Sources/Aster/AgentHosts/` | 终端、注册表、浮动面板、批准、授权存储、审计落盘、MCP 安装、运行时装配 |
| `Sources/Aster/Control/AgentHostControlCommands.swift` | `host.*` 方法的分发 |
| `Sources/Aster/SettingsAgentAccessBridge.swift`、`Resources/settings-ui/agent-access.js` | 设置「主机 → Agent 访问」 |
| `Sources/AsterCLI/HostExecCommands.swift`、`MCPCommand.swift` | CLI 与 MCP 前端 |

## 控制方法

所有方法带 `agent: {session, client?, caller_pane?}`：`session` 是 1–128 字节的会话键；`client`
只进审计；`caller_pane` 来自 `$ASTER_PANE_ID`。服务端若能把 `caller_pane` 解析成正在跑 agent 的
Pane，就把 provider 与 agent session ID 并进**有效会话键**（`<session>#<provider>:<sessionID>`），
新开的 Claude 会话因此不会继承旧会话的「本会话允许」。`host` 是主机 UUID 或精确名称；重名
`ambiguous_target`，找不到 / 默认项 `not_found`。

| 方法 | 参数 | 结果 |
|---|---|---|
| `host.list`（已有） | — | 行里新增 `agentAccess`：`always` / `ask` |
| `host.open` | host, timeout_ms? | `HostTerminalInfo`（批准后建立或复用终端并等就绪） |
| `host.exec` | host, command（≤16 KiB，单行 ≤4000 B，无 NUL/ESC/CR）, reason?（≤512 B）, timeout_ms?（默认 120000，上限 600000）, max_output_bytes?（默认 64 KiB，上限 1 MiB） | `HostExecResult` |
| `host.wait` | command_id, timeout_ms?, max_output_bytes? | `HostExecResult`（只有发起会话能等） |
| `host.read` | host 或 terminal_id, lines?（≤500，默认 100） | `{terminal_id, text}`（活动屏幕） |
| `host.interrupt` | command_id 或 host | `HostExecResult(interrupted)` |
| `host.close` | host 或 terminal_id | OK |
| `host.terminals` | agent? | `{terminals: [HostTerminalInfo]}`；带 agent 时只列本会话 |

`HostExecResult`：`command_id`（`c-` + 12 位十六进制）、`terminal_id`（`t-…`）、`host_id`、
`host_name`、`status`（`completed | running | needs_input | interrupted | ended`）、`exit_code`
（只有 completed 有）、`output`、`output_truncated`（超预算时保留开头 8 KiB 与结尾，中间写
`[… N bytes omitted …]`）、`prompt`（needs_input 时屏幕最后一行）、`duration_ms`。

`running` / `needs_input` 不是错误：命令仍在终端里，调 `host.wait` 继续。新增错误码：
`agent_access_disabled`、`approval_pending`、`approval_denied`、`agent_paused`、`host_not_ready`、
`terminal_ended`、`limit_exceeded`；沿用 `not_found`、`ambiguous_target`、`pane_busy`、
`invalid_params`。错误消息是给 agent 的协议文本，与其它控制方法一样不走界面本地化。

`host.*` 不走 IPC 写门禁（Allow Send Keys），有自己的总开关与按主机批准。v1 **没有**授予权限或
发送任意输入的方法：sudo 口令只能由用户在浮动终端里输入。

## 执行流程

`host.exec`：参数校验 → 解析主机 → 总开关关着则 `agent_access_disabled` → 授权簿判断（见下）→
需要批准时弹面板，最多等 `min(剩余期限, 50 s)`，超时 `approval_pending`（面板保留）→ 终端被用户
暂停则 `agent_paused` → 取或建终端并显示面板 → 期限内没就绪 `host_not_ready` → 排队、必要时
重新同步、敲入命令、写 `exec.started` → 轮询 → 完成写 `exec.finished`；返回时仍在跑写一次
`exec.pending`，之后真正结束时（无论有没有人 `host.wait`）补写 `exec.finished`。

50 秒是因为 Codex 的工具调用默认 60 秒超时；MCP 工具把 `timeout_seconds` 限在 1–50。等待类方法
（exec / wait / open / interrupt）占用每连接 4 个等待名额；等待只是挂起的 Task，同一连接上的其它
请求照常处理，主线程不被阻塞。

## 标记符协议（AgentHostCommandFraming）

每条命令一个 12 位十六进制 nonce `N`，注入一行：

```
\x15 printf '\074aster:%s\076\n' Nb; eval '<cmd，' 写成 '\''>'; printf '\074aster:%s:%s\076\n' Ne $?\r
```

- **回显免疫**：`<` `>` 写成八进制、nonce 作独立参数，回显的命令行里永远不会出现 `<aster:Nb>` 原文。
- **eval 在当前 Shell**：`cd`、`export` 跨命令保留；语法错误时 eval 返回非零，结束标记照样打印，不会卡在 PS2。
- **多行**：换行留在单引号里，Shell 进 PS2 续读；PS2 噪声落在开始标记之前，不进输出。
- **Tab**：直接敲进行编辑器会触发补全，改成在引号外拼 `$(printf '\011')`。
- **行首**：Ctrl-U 清掉提示符上用户没提交的半行；行首空格配合下面的历史设置不进远端历史。
- 只用 POSIX `printf`。

解析（纯函数）：取最后一个 `<aster:Nb>`；输出是它下一行起到 `<aster:Ne:CODE>` 之前，去掉一个尾换行；
结束标记在行内任意位置都算（输出没有尾换行时紧跟其后）；标记中间被插入的换行也能容忍；旧 nonce
一律无视；`\r` 先去掉（Swift 把 `\r\n` 当一个字符，按标量判断）。开始标记滚出读取范围时只返回尾部并
标 `output_truncated`。

轮询：每 200 ms 读一次**活动屏幕**找结束标记；找到后若开始标记不在活动屏幕，再读一次回滚（最多
10000 行）取完整输出。Ghostty 读屏会把软折行接回一行、去掉行尾空格（端到端测试覆盖窄窗口长行）。

### 就绪与重新同步

- 连接：等 SSH 首次输出后屏幕静默 700 ms，发探针
  ` export PAGER=cat GIT_PAGER=cat MANPAGER=cat SYSTEMD_PAGER=cat; [zsh] setopt HIST_IGNORE_SPACE; [bash] HISTCONTROL=ignorespace…; true $?; printf '\074aster:%s:ready\076\n' N`，
  4 秒无回应重试，最多 3 次；之后报 `host_not_ready`，下一次请求再试一轮。
- `true $?` 是 fish 的绊线：fish 解析期就拒绝 `$?` 并打印 `fish: …`，据此报「不支持的 Shell」。
- 下一条命令前，若上次结束后活动屏幕变过（用户打字、程序输出）或刚中断过，先发探针（3 秒）；
  不回应即 `pane_busy`。处在**备用屏**（vim、less、top）时什么都不敲，直接 `pane_busy`，否则
  探针会被当成 vim 普通模式命令执行。
- 连接前确认 PTY 前台进程是 `aster-ssh`（`proc_pidpath`）。引擎不可用时 `TerminalSession` 会回退成
  「本地 Shell 里预填 ssh」，此时立即结束该终端并报 `host_not_ready`：agent 命令绝不在本机执行。

### 等输入、超时、中断

- `needs_input`：开始标记已出现、结束标记未出现、屏幕静止 ≥2 秒、最后一行像提示（`[sudo] password for`、
  `Password:`、`passphrase`、`(yes/no`、`[y/N]`、`[Y/n]`、`Continue?`、`Press ENTER`、`--More--`、
  `(END)`，或以 `:` / `?` 结尾）。此时面板置前、请求注意、发系统通知；`host.exec` 立即返回
  `needs_input`。`host.wait` 只对等待开始之后**新一轮**等输入提前返回，避免对同一提示空转。
- 期限到达返回 `running` 与已有输出，命令不被杀。
- 中断：发 `0x03`，1.5 秒宽限期内看到结束标记按完成（命令自己处理了 SIGINT），否则 `interrupted`
  （无退出码），下一条命令前重新同步。交互式 Shell 收到 SIGINT 会放弃整行，结束标记通常不会打印。
- Shell 退出 / 连接断开：运行中的命令记 `ended`。

### 并发与上限

一个终端同时只跑一条命令，FIFO 排队最多 4 条（取消友好）；期限内轮不到 `pane_busy` 并点名挡路的
command_id；排队已满 `limit_exceeded`。终端总数上限 8，每个有效会话 4 个。

## 终端与面板（Sources/Aster/AgentHosts）

- `AgentHostTerminal`：持有一个独立 `TerminalSession`（`bindNativeSSH(.host(id))` 后再 `makeTerminalHost`，
  写法同 Quick Terminal），**不注册进任何 AppModel 标签**，所以 `pane.*`、`session.snapshot`、
  `agent.*` 都碰不到它，也不进 Session Recording。状态 `connecting → ready ⇄ busy / needs_input → ended`。
  认证仍走 App 自己的认证表单（`SSHAuthCoordinator`）。
- `AgentHostTerminalRegistry`：按（有效会话键，主机）复用；空闲 30 分钟自动关闭；作为
  `WorkspaceTerminationParticipant` 随 App 退出（有命令在跑时确认）；主机被删除时关闭终端并作废授权，
  主机改名同步标题。
- `AgentHostTerminalPanelController`：每个终端一个浮动 NSPanel（`.nonactivatingPanel`、`.floating`、
  `hidesOnDeactivate = false`、错位排列、强调色边框）；标题「Claude Code → prod-db (deploy@10.0.0.5:22)」；
  头部显示状态与「中断 / 暂停 agent / 关闭终端」。标题栏关闭只隐藏，「窗口 → Agent 终端」找回。
  用户随时可以点进终端打字接手；暂停后新命令一律 `agent_paused`，已在跑的不受影响。
  布局用 frame 而不是约束，与 Quick Terminal 一样避免对长期复用的终端宿主混用约束。

## 批准与授权

- `AgentHostApprovalCoordinator` + `AgentHostApprovalPanel`：非模态浮动面板，绝不 `runModal` / sheet。
  同一（会话、主机）的并发请求合并成一个面板。显示 agent（provider / 客户端 / Pane）、主机与
  `user@host:port`、理由、**完整原始命令**（只读等宽滚动文本）。按钮：拒绝 / 允许一次 / 本会话允许 /
  一直允许此主机；默认按钮是拒绝，回车只会拒绝；关掉面板按拒绝处理。新面板出现时发系统通知（命令先脱敏，
  通知中心会长期留存）并 `requestUserAttention`。
- 回答先生效（授权或冷却），再唤醒等待方。所有等待方都已超时时，「允许一次」落成一次性授权：
  5 分钟内被该会话对该主机的下一次执行消耗。拒绝：该会话对该主机 10 分钟内直接 `approval_denied`。
- 授权范围：once / session（只在内存，退出 App 或 12 小时不活动失效）/ always（任意会话，存钥匙串）。
  判断顺序 always → session → 拒绝冷却 → once。
- 目标指纹 `host|user|port|跳板链`（跳板按 `user@host:port`）：地址、用户、端口或跳板变了，旧授权作废、
  重新询问；只改主机名称不影响。
- always 授权：一个钥匙串 generic password 条目，service `io.aster.agent-host-grants`、account `always`，
  值是授权数组 JSON；读写放后台（securityd 可能弹授权框）。放钥匙串而不是 defaults / 文件：agent 能改
  defaults 和用户文件，却不能静默改钥匙串条目，也就没法给自己加授权。读失败按「没有 always 授权」处理
  （只会多问，不会多放行）。
- 总开关「允许编程 agent 申请主机访问」默认关（`aster.agent-hosts.enabled.v1`）。它在 defaults 里，
  agent 改得到它，但改了也只是能**申请**，每台主机仍要批准。改动写 `setting.changed` 审计。

## 审计

`~/Library/Application Support/Aster/audit/agent-hosts-YYYY-MM.jsonl`：目录 0700、文件 0600，只追加，
串行后台队列写入，保留 13 个月（启动时清理更早的月文件）。同时镜像到 os_log
（subsystem `io.local.aster`、category `agent-hosts`，命令标 private）。写失败只记诊断事件，不阻断执行。

每条记录的值都是字符串：

| 字段 | 内容 |
|---|---|
| `id`、`time` | UUID；带时区偏移的 ISO 8601（`2026-10-16T09:30:12+08:00`） |
| `category` / `action` | `exec`（`exec.started/finished/pending`）、`grant`（`grant.created/revoked/denied/expired/invalidated`）、`setting`（`setting.changed`） |
| `actor` | `{kind: agent, session, client, pane, provider, agentSessionID}`、`{kind: user, account, name}`（account 是唯一的 macOS 短账户名）或 `{kind: system}` |
| `approver` | `{kind: user, account, scope}` 或 `{kind: grant, scope, grantID}` |
| `host` | `{id, name, target}` |
| `commandID`、`terminalID`、`command`、`commandRedacted`、`reason` | 命令先脱敏 |
| `result` | `{status, exitCode, durationMs, outputBytes}`——**从不记录输出内容** |
| `changes` | `[{field, before, after}]`：新建 before 固定 `（新建）`、删除 after 固定 `（已删除）`，都记授权的完整快照（grantID、scope、hostID、hostName、targetFingerprint、grantedAt、grantedBy、session） |

脱敏（`AgentHostCommandRedactor`）：`--password/--token/--secret/--api-key…` 的值、`NAME=value`
（名字含 PASSWORD / PASSWD / TOKEN / SECRET / CREDENTIAL / API_KEY，或有一段恰好是 `KEY`）、
`scheme://user:pass@`、`Authorization:` 头、mysql 系 `-p<口令>`、私钥块、常见平台令牌形态（`ghp_`、`sk-`、
`AKIA`…）替换为 `***`。公开标识白名单（`AWS_ACCESS_KEY_ID`、`*_KEY_ID`、`*_PUBLIC_KEY`、`PUBKEY`…）
原样保留：即使完整公开也不构成权限提升，脱掉反而丢排查线索。规则都没命中而
`AutocompleteSecretDetector` 仍判定含凭据时，整条只留可执行名。正反两组都有表驱动测试。

## CLI 与 MCP

- `aster host exec <host> [--session K] [--reason R] [--timeout S] [--max-output N] [--json] -- <command…>`：
  只解析 `--` 之前的选项（`--` 之后的 `--json` 属于命令本身）；多个词以单个空格拼接。会话键
  `--session` > `$ASTER_AGENT_SESSION` > `pane:$ASTER_PANE_ID` > `cli:default`；client 按环境猜
  （`CLAUDECODE=1` → claude-code，`CODEX_*` → codex）。文本模式输出命令输出、以远端退出码退出；
  未完成（running / needs_input / interrupted / ended）时 stderr 一行 `{status, command_id, prompt}`，
  退出码 75。客户端超时 = `timeout_ms` + 15 秒。
- `aster mcp`：同步 stdio JSON-RPC（initialize 记录 `clientInfo.name`、tools/list、tools/call、ping；
  通知忽略）；每次调用新建控制连接；会话键 `mcp:<进程启动时的 UUID>`，`caller_pane` 取
  `$ASTER_PANE_ID`。工具：`list_hosts`、`host_exec`（`timeout_seconds` 1–50，默认 40）、`host_wait`、
  `host_read`、`host_interrupt`、`host_close`。结果是文本（状态行 + 代码块输出）加 `structuredContent`；
  错误是 `isError: true` 的工具结果，带按错误码给出的下一步提示。
- 设置里的「安装到 Claude Code / Codex」：执行 `claude mcp add --scope user aster -- <aster> mcp` /
  `codex mcp add aster -- <aster> mcp`（先 remove 再 add，便于 App 移动后覆盖旧路径）；CLI 路径优先用
  `aster` 稳定 symlink。命令找不到或失败时把手动配置片段放进剪贴板。不直接改它们的配置文件。

## 设置页

「主机 → Agent 访问」子页（`agent-access.js`，入口 `window.AsterAgentAccess.render(container, hostsSnapshot, send, ui)`，`ui.t` 为翻译函数，`send` 返回的 Promise 失败时忽略、以下一次快照为准；
数据在 `hosts.agentAccess`）：总开关、授权列表与撤销、agent 终端列表、MCP 安装、分页活动记录
（`hosts.agentAuditPage {before?, limit≤50}`，结果经消息 `agentAccessAuditPage` 异步送回；修改显示
`字段 原值 → 新值`，新建 / 删除显示属性清单）。动作在 `SettingsAgentAccessBridge`。

## 限制

- 只支持 POSIX Shell（bash、zsh、dash/sh、ksh）；fish 会被识别并拒绝。
- 备用屏全屏程序（vim、top）里的内容不会被捕获；agent 应使用非交互参数。
- 行编辑器处在 vi 插入以外的模式时 Ctrl-U 不清行；bash 的历史展开在多行命令的续行里可能展开 `!`。
- 远端 bash / zsh 之外的 Shell 可能把注入行记进历史；探针只为 bash 与 zsh 关掉空格开头行的记录。
- 不是沙箱：命令以登录用户身份在远端执行，批准是对「这个会话可以访问这台主机」，不是逐条审查。

## 验证

- `./scripts/test.sh --filter AgentHost`：AsterCore（标记符——对真实 sh / bash / zsh 执行注入行、
  授权簿、脱敏、审计、跟踪器、MCP、协议）与 AsterTests（替身终端上的批准 / 拒绝 / 超时重试 /
  暂停 / 排队 / 等输入 / 中断 / 结束 / 会话隔离 / 回退拒绝，批准合并与存储，`pane.*` 隔离，以及在真实
  Ghostty surface 上对本地 sh / bash / zsh 跑的端到端）。端到端测试把 `HISTCONTROL`、`HISTFILE`、`ZDOTDIR`
  指到无害值，不污染开发者的 Shell 历史。
- 手工验收按 [远程工作验收](remote-work-acceptance.md) 的主机准备：口令主机、sudo 提示（needs_input →
  面板里输入 → `host_wait`）、命令中途接手、中断、撤销授权；审计文件里应能看到真实的 exec 与撤销记录。
