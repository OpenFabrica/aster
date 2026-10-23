# Agent 远程执行（agent host access）

## 背景与概念

编程 agent（Claude Code、Codex 等）经 Aster 在**已保存的 SSH 主机**上执行命令，自己永远拿不到
口令或私钥。命令敲进一个真实的原生 SSH 终端（`aster-ssh client`），终端默认停靠在调用 agent 的
Pane 底部（也可以弹成独立浮窗），用户全程看得见、随时能接手；每台主机的访问都要用户批准，所有执行与授权变化写审计。

入口有三个，都落到控制协议的 `host.*` 方法：

- `aster host exec|wait|read|interrupt|close|open|terminals`（CLI，Aster Pane 里的 agent 用）；
- `aster mcp`（stdio MCP server，Codex 的沙箱多半连不上控制 socket，MCP 是它的主路径）；
- 直接走控制 socket（`host.exec` 等，见 [工作流和代理](workflows-and-agents.md)）。

威胁模型：约束的是**配合的** agent，不是恶意软件。同一用户下的恶意进程仍能读用户文件、用
ssh-agent、模拟点击。这不是沙箱。目标是：agent 拿不到秘密；每次远程访问都经按主机的批准并留痕；
明显的绕路被堵上；用户能接手。broker 票据与原生 SSH Pane 的敏感判定见 [原生 SSH](native-ssh.md)。

在这个模型下仍要明确的几点：

- **会话键是调用方自报的**。控制 socket 只对本人开放，但任何同用户进程都能连上并自称任意 `session`。
  因此会话键当凭据用的前提是它不外泄：任何协议结果与 CLI 输出都不回显会话键（`host.terminals`
  只列调用方自己的终端，`HostTerminalInfo` 不含 session），拒绝冷却按主机而不按会话计，
  挂起的批准请求有全局上限。
- **always 授权的钥匙串条目可能被预埋**：同用户进程能新建同名条目。读取前核对条目 ACL，见「批准与授权」。
- **批准看到的就是要执行的**：只合并内容完全相同的请求，批准按钮在面板出现或内容变化后延迟 1 秒启用，
  授权绑定请求发起时的目标指纹。

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
| `Sources/Aster/AgentHosts/` | 终端、注册表、呈现（Pane 停靠区与浮窗）、批准、授权存储、审计落盘、MCP 安装、运行时装配 |
| `Sources/Aster/Control/AgentHostControlCommands.swift` | `host.*` 方法的分发 |
| `Sources/Aster/SettingsAgentAccessBridge.swift`、`Resources/settings-ui/agent-access.js` | 设置「主机」分类（只含 Agent 访问） |
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
| `host.terminals` | agent（必填） | `{terminals: [HostTerminalInfo]}`；只列调用方本会话的终端 |

`HostTerminalInfo`：`terminal_id`、`host_id`、`host_name`、`target`、`state`、`running_command_id`；
**不含会话键**（会话键是授权凭据，回显出去就能被别的进程冒充）。

`HostExecResult`：`command_id`（`c-` + 12 位十六进制）、`terminal_id`（`t-…`）、`host_id`、
`host_name`、`status`（`completed | running | needs_input | interrupted | ended`）、`exit_code`
（只有 completed 有）、`output`、`output_truncated`（超预算时保留开头 8 KiB 与结尾，中间写
`[… N bytes omitted …]`）、`prompt`（needs_input 时屏幕最后一行）、`duration_ms`。

`running` / `needs_input` 不是错误：命令仍在终端里，调 `host.wait` 继续。新增错误码：
`agent_access_disabled`、`approval_pending`、`approval_denied`、`agent_paused`、`host_not_ready`、
`terminal_ended`、`limit_exceeded`；沿用 `not_found`、`ambiguous_target`、`pane_busy`、
`invalid_params`。错误消息是给 agent 的协议文本，与其它控制方法一样不走界面本地化。

`host.*` 不走 IPC 写门禁（Allow Send Keys），有自己的总开关与按主机批准。v1 **没有**授予权限或
发送任意输入的方法：sudo 口令只能由用户接管终端后自己输入。

## 执行流程

`host.exec`：参数校验 → 解析主机 → 总开关关着则 `agent_access_disabled` → 终端被用户暂停则
`agent_paused`（在授权簿之前查，暂停时不消耗一次性授权）→ 授权簿判断（见下）→ 需要批准时弹面板，
最多等 `min(剩余期限, 50 s)`，超时 `approval_pending`（面板保留）→ 批准后复核目标指纹，等待期间
主机被删或目标变了则这次批准作废（`grant.invalidated`）并报 `host_not_ready` → 再查一次暂停 →
取或建终端并显示（停靠区展开或浮窗置前）→ 期限内没就绪 `host_not_ready` → 排队、必要时重新同步、敲入命令、写
`exec.started` → 轮询 → 完成写 `exec.finished`；返回时仍在跑写一次 `exec.pending`，之后真正
结束时（无论有没有人 `host.wait`）补写 `exec.finished`。

等过用户批准后，连接与执行改用新期限：剩余不足 30 秒时补足，但最多比原期限多 10 秒（CLI 与 MCP
客户端只比 `timeout_ms` 多等 15 秒），也不超过从批准时起的请求超时。命令最终没敲进终端（连接失败、
排队超时、暂停、前台未确认）时退还 once 授权：从授权簿消耗的原样放回；当场「允许一次」的落成一条
绑定该命令的一次性授权（写 `grant.created`），重试同一条命令不用再问。

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
- **Tab 与非 ASCII**：注入行只含可打印 ASCII 与换行。命令中每个不属于 0x20–0x7E 的字节（Tab、
  UTF-8 多字节字符等）都移到单引号外，写成 `'"$(printf '\ooo…')"'`，连续字节合成一组。Tab 直接敲
  会触发补全；远端在 C / POSIX locale 下，bash readline 把 0x80 以上的字节当成 Meta 键（例如 0xAE
  是 M-.，会插入上一条命令的最后一个参数），中文或 emoji 原样敲入会变成一串编辑命令。`$(…)` 只去掉
  结尾换行，而换行始终留在引号内，所以 `eval` 收到的字节与原命令完全一致。代价是非 ASCII 字节转义后
  约为原长的 4 倍；单行上限（4000 字节）按每行转义后的长度计算，纯 ASCII 行与原字节数一致。
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
- 发首个探针前、以及之后每次敲命令或探针前，都确认 PTY 前台进程是 `aster-ssh`（`proc_pidpath`）。
  引擎不可用时 `TerminalSession` 会回退成「本地 Shell 里预填 ssh」，此时立即结束该终端并报
  `host_not_ready`：agent 命令绝不在本机执行。判断不了（pid 未知或 `proc_pidpath` 失败）也按未确认
  处理：什么都不敲，继续等，到期限报 `host_not_ready`。

### 等输入、超时、中断

- `needs_input`：开始标记已出现、结束标记未出现、屏幕静止 ≥2 秒、最后一行像提示（`[sudo] password for`、
  `Password:`、`passphrase`、`(yes/no`、`[y/N]`、`[Y/n]`、`Continue?`、`Press ENTER`、`--More--`、
  `(END)`，或以 `:` / `?` 结尾）。此时终端被选中并展开（浮窗则置前）、请求注意、发系统通知；`host.exec` 立即返回
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
  认证仍走 App 自己的认证表单（`SSHAuthCoordinator`）。停靠在 Pane 底部也只是借位显示，不是那个 Pane 的一部分。
- `AgentHostTerminalRegistry`：按（有效会话键，主机）复用；空闲 30 分钟自动关闭；作为
  `WorkspaceTerminationParticipant` 随 App 退出（有命令在跑时确认）；主机被删除时关闭终端并作废授权，
  主机改名同步标题。

### 呈现：停靠在 Pane 底部，或独立浮窗

- `AgentHostTerminalPresenter`：每个终端一个，持有**一份**内容 `AgentHostTerminalContentView`（终端 + 遮罩 +
  控制胶囊 + 强调色边框），整体在两个去处之间搬：`.docked(paneUUID)` 停靠在调用 agent 的 Pane 底部，
  或 `.window` 独立浮窗。搬动在同一轮主循环里先摘后装，不调 `stop`，surface 与远端命令都不断。
- 调用方 Pane：`AgentHostControlCommands.resolveAgentHostCallerPane` 把 `$ASTER_PANE_ID`（短 ID）解析成
  `record.runtime.id`，存进 `AgentHostResolvedCaller.paneUUID`。它只用于呈现，不进会话键、不进审计。
- 新终端的去处：偏好 `AppPreferences.agentHostTerminalPresentation`（键 `aster.agent-hosts.terminal-presentation.v1`，
  默认 `docked`，未知值按 `docked`）是停靠、`paneUUID` 有值、`AgentHostPaneLocator` 说 Pane 还在 → 停靠；
  否则浮窗（agent 不在 Aster 里跑、控制服务没起来，行为与停靠功能之前相同）。
- **停车位**：浮窗在呈现器创建时就建好，内容先装进去并强制布局一次。Ghostty surface 要等终端视图进了窗口
  且尺寸非零才创建，从没显示过的面板也算有窗口，所以停靠模式下（调用方 Pane 可能在后台标签里）SSH 也立刻连上；
  之后搬进停靠区，停靠时浮窗永不显示。
- `show(attention:)`（每次 `obtain`、等输入）：浮窗置前；停靠时只展开停靠区并选中这个终端，**不动任何窗口**。
  `reveal()`（「窗口 ▸ Agent 终端」）：停靠时还经定位器切到那个 Pane 所在标签（标签正放大着别的 Pane 时先还原）
  并前置窗口。
- 用户点停靠区的「弹出为独立窗口」→ 搬进浮窗并把偏好写成 `window`；接管中把浮窗设为 key 并交焦点，否则不抢。
  浮窗标题栏右侧「停靠到 Pane」（`NSTitlebarAccessoryViewController`，Pane 不在时隐藏）→ 搬回 Pane、
  偏好写成 `docked`、切到那个 Pane；焦点交给工作区按活动 Pane 落，不抢。只有这两个动作写偏好。
- Pane 关了：`ControlBridgeAgentHostPaneLocator` 订阅 `pane.closed`，下一轮主队列让注册表逐个核对，
  停在已关 Pane 里的终端转成浮窗显示，**不写偏好、不关终端**（不误杀远端命令）。关**附加**工作区窗口时
  控制桥不会为它的 Pane 发 `pane.closed`（模型随窗口释放），所以 `AsterApp.windowWillClose` 在
  `commitTermination()` 之前调 `AgentHostRuntime.workspaceWillClose(model:)` 做同样的事。
  主窗口关闭不销毁模型，Pane 还在，停靠区等窗口再显示时装回。显示与找回前也会兜底核对一次。
- 「接管」：浮窗时让浮窗成为 key；停靠时让停靠区所在的工作区窗口成为 key；再把焦点交给终端。

### 停靠区

- `AgentHostPaneDocks`（共享注册表，测试各建一份）按 Pane UUID 记：停靠区视图、终端条目（顺序）、选中项、
  是否收起、高度比例（默认 0.4，拖动夹在 0.2–0.75）。新终端停进来时被选中并展开；`show` / `reveal` / 点标签
  都会选中并展开，所以收起后下一条命令会自动展开；最后一个终端摘掉时整个停靠区撤掉。出现、消失、收起、
  调高度、换显示的终端经 `changes`（Pane UUID）通知工作区局部装卸；状态刷新只改标签，不重装。
- `AgentHostPaneDockView`（frame 布局）：28pt 头部 + 选中终端的内容。头部左边每台主机一个标签（状态色点：
  运行蓝、等输入橙、空闲绿、接管黄、结束灰；悬停显示「调用方 → 主机 (目标)」），右边「弹出为独立窗口」
  「收起 / 展开」；头部空白处上下拖动调高度。**只有选中且展开的终端内容挂在视图树里**，其余终端不在树里，
  surface 照跑，按键只会进看得见的那个。背景与分隔线在 `draw(_:)` 里解析动态颜色：停靠区是长期视图，
  不随 `refresh()` 重建，不能在创建时把 CGColor 冻结。停靠区自己吞掉 `mouseDown`（不冒泡到
  `ActivePaneHostView` 去激活 Pane），并注册与 Pane 宿主相同的拖放类型、一律拒收，文件和文本不会粘进
  agent 自己的终端，也不会拆出新 Pane。

### 接入工作区（WorkspaceView / ActivePaneHostView）

- `ActivePaneHostView.setAgentHostDock(_:height:)`：底部第二个槽，约束链为内容 → [Prompt Queue，8pt 内边距] →
  [停靠区，贴边] → 底边。展开时 `高 = Pane 高 × 比例 @200`、`≥ 200pt @210`（约 10 行，agent 的探针只读可见屏幕）、
  `内容高 ≥ 100pt @220`（Pane 太矮时先压停靠区）；收起时固定 28pt。三条都**低于 250**：分屏给每个 Pane 的
  回退约束是 250、窗口保持尺寸是 500，停靠区只能在 Pane 现有高度里分配，不能推分隔条或撑大窗口。
  停靠区会被新的 host 接走，所以只有它确实是本 host 的子视图时才移除或建约束，被丢弃的旧 host 不再碰它。
- `WorkspaceViewController`（注册表可注入，默认 `.shared`）：
  1. `refresh()` 重建 Pane 后（Prompt Queue 之后）给每个 `paneHosts` 装回停靠区；`changes` 只装卸那一个 Pane。
     Pane 不在当前视图树里（后台标签、放大了别的 Pane、主机页）时什么也不做，回来时 `refresh()` 自动装回。
  2. `refresh()` 开头若 first responder 在停靠区里就记下，装回后**同步**还给它并跳过异步 `focusActivePane`；
     否则接管后正在输入的 sudo 口令会被一次 toast 或主题刷新送进 agent 自己的终端。局部变化后焦点落回窗口本身时
     （摘下的正是焦点所在的终端）交还活动 Pane。
  3. 点击监视器经 `paneHost(forClickOn:)` 沿 superview 找 Pane 容器，碰到停靠区就返回 nil：点停靠区不激活 Pane、
     不抢焦点。

### 浮窗、控制胶囊与遮罩

- `AgentHostTerminalPanelController`：浮窗外壳，每个终端一个 NSPanel（`.nonactivatingPanel`、`.floating`、
  `hidesOnDeactivate = false`、错位排列），contentView 是固定容器，内容作为子视图进出；
  标题「Claude Code → prod-db (deploy@10.0.0.5:22)」。
- 控制胶囊参照 ego lite 的 agent 控制条（`AgentHostTerminalControlBar`，固定深色外观、首选宽度 520pt），
  浮在终端上，默认底部居中；按住按钮以外的地方（左侧有把手）可以拖动，位置限制在内容范围内，尺寸缩小时收回。
  胶囊里是状态图标（运行与连接时转圈）、两行文字「调用方 → 主机」与状态（运行蓝、等输入橙、暂停黄），
  以及「中断 / 接管（接管后为「交还 agent」）/ 关闭终端」（关闭为红字）。
  胶囊宽度不随标题、命令或状态变化，窄时两侧保留 8pt；文字单行尾部截断，悬停显示完整内容。
  接管按钮按两种本地化文案的最大宽度预留空间，切换时按钮位置保持稳定。
- 除非用户接管（`isPaused`）或终端已结束，终端上一直盖着 `AgentHostTerminalControlOverlay` 遮罩
  （规则在 `AgentHostTerminal.blocksUserInput`）：连接、空闲、运行命令、等输入都盖，遮罩不再随每条命令闪一次，
  空闲时的按键也不会混进 agent 的终端。遮罩是四周蓝色光晕加点阵，只在连接中、命令运行中缓慢呼吸
  （`isBreathing`；空闲、等输入时静止，不暗示「正在跑」，也不让动画在空闲终端上一直耗电；
  系统开「减少动态效果」时始终静止），边缘光晕 alpha 为 0.55、点阵 alpha 为 0.7，
  呼吸不透明度在 0.75–1 之间变化，停下时平滑回到常亮；中间透明不挡输出。遮罩**挡住输入**：点击、拖动、右键落在遮罩上，
  键盘焦点从终端移到遮罩上、按键被吞掉，这时顶部短暂提示「Agent 正在控制，点「接管」后可以输入」；
  滚轮照常穿透给终端回看输出（选中、复制输出要先接管）。等输入时也不撤：状态行提示「点「接管」后在终端里回答」，
  用户接管后回答 sudo 口令，答完点「交还 agent」。不自动交还：接管与交还都只由用户手动操作。
  终端结束时遮罩淡出，焦点还给终端。「接管」就是暂停（`isPaused`）：遮罩撤掉、焦点交给终端；
  「交还 agent」恢复，遮罩随即重新盖上。用户随时可以点「接管」接手；暂停后新命令一律 `agent_paused`，
  已在跑的不受影响。布局用 frame 而不是约束，与 Quick Terminal 一样避免对长期复用的终端宿主混用约束。

### 关闭快捷键与菜单

- 浮窗：标题栏关闭和 ⌘W / ⌥⌘W 都只隐藏，「窗口 → Agent 终端」找回。停靠区：焦点在停靠区里时 ⌘W / ⌥⌘W
  只把停靠区收起。`AsterApp.closePaneOrTab` / `closePane` 在 Quick Terminal、画中画小窗之后先问
  `AgentHostRuntime.handleCloseShortcut()`（注册表认浮窗，`AgentHostPaneDocks.handleCloseShortcut(in:)` 认停靠区），
  绝不落到背后工作区的活动 Pane。
- 键盘在 agent 终端里（浮窗是 key，或 key 窗口的焦点在停靠区里）时，只作用于活动 Pane 的菜单命令
  （分屏类、清屏、查找、只读、Live View、Prompt Queue、复制路径、在访达中显示）置灰，同 Quick Terminal；
  ⌥⌘W 保持可用，由它收起 agent 终端。

## 批准与授权

- `AgentHostApprovalCoordinator` + `AgentHostApprovalPanel`：非模态浮动面板，绝不 `runModal` / sheet。
  显示 agent（provider / 客户端 / Pane）、主机与 `user@host:port`、理由、**完整原始命令**（只读等宽
  滚动文本）。按钮：拒绝 / 允许一次 / 本会话允许 / 一直允许此主机；默认按钮是拒绝，回车只会拒绝；
  关掉面板按拒绝处理。面板出现时发系统通知（命令先脱敏，通知中心会长期留存）并 `requestUserAttention`。
- **合并与排队**：只有内容完全相同的请求（会话、主机、目标指纹、理由、命令都相同）合并成一个面板。
  不同请求各自排队，一次只显示一个面板，回答只作用于显示中的那一条，答完再显示下一条。全局最多
  挂起 4 个不同请求，再来的直接 `limit_exceeded`。
- **防误点**：面板出现或内容变化（合并进新的相同请求）后，三个批准按钮禁用 1 秒；「拒绝」始终可点。
  避免用户正要点别处时面板恰好弹出，一次误点就批准了没看过的命令。
- 回答先生效（授权或冷却），再唤醒等待方。「允许一次」只放行最早的一个等待方，其余相同请求重新出面板。
  所有等待方都已超时时，「允许一次」落成一次性授权：5 分钟内只给该会话对该主机的**同一条命令**消耗。
  拒绝：这台主机 10 分钟内对**所有会话**直接 `approval_denied`（会话键自报，按会话计会被换名绕开）；
  任何新授权都解除这台主机的冷却。
- 授权绑定**请求发起时**的目标指纹，不在回答时重新解析：面板挂着期间主机被改，用户批准的仍是面板上的
  目标；等待方拿到批准后再复核一次，不符即作废。主机被删或目标变化时，针对旧目标的挂起面板被撤掉。
- 授权范围：once / session（只在内存，退出 App 或 12 小时不活动失效）/ always（任意会话，存钥匙串）。
  判断顺序 always → session → 拒绝冷却 → once。
- 目标指纹 `host|user|port|跳板链`（跳板按 `user@host:port`）：地址、用户、端口或跳板变了，旧授权作废、
  重新询问；只改主机名称不影响。
- `host.list` 的 `agentAccess` 只在 always 授权的指纹与主机当前目标一致时报 `always`。
- always 授权：一个钥匙串 generic password 条目，service `io.aster.agent-host-grants`、account `always`，
  值是授权数组 JSON；读写放后台（securityd 可能弹授权框）。放钥匙串而不是 defaults / 文件：agent 能改
  defaults 和用户文件。但同一用户下的任何进程都能新建同名条目（如 `security add-generic-password -A`），
  所以读明文之前先用 SecKeychain ACL API（`SecKeychainItemCopyAccess` 等，已弃用但文件钥匙串的 ACL
  没有别的读法，集中在 `AgentHostKeychainAccessCheck`）核对访问控制：只要有一条管解密（Decrypt 或 Any）
  的 ACL 信任「任何 App」，或没有 ACL，就判定不是 Aster 用默认 ACL 建的——按「没有 always 授权」处理，
  记诊断事件 `agent_hosts.grants_untrusted` 与一条 `grant.invalidated` 审计，**不删除**条目，留给用户排查。
  Aster 写入时不带 `kSecAttrAccess`，默认 ACL 的解密项只信任 Aster 自身；发现已有条目不可信时先删再建。
  剩余限制：用显式受信任列表建的条目（如 `-T /Applications/Aster.app`）与 Aster 自己建的分不出来，
  这类预埋只能靠审计和设置页「主机」分类里的授权列表发现。读失败同样按「没有 always 授权」处理（只会多问，不会多放行）。
- 总开关「允许编程 agent 申请主机访问」默认关（`aster.agent-hosts.enabled.v1`）。它在 defaults 里，
  agent 改得到它，但改了也只是能**申请**，每台主机仍要批准。改动写 `setting.changed` 审计。
  关掉时撤掉全部挂起的批准面板并关闭全部 agent 终端；`host.read` 也要求开关开着。
- 用户撤销授权时关掉失去依据的终端：撤销 always 关这台主机的全部 agent 终端，撤销 session / once
  只关该会话在这台主机上的终端；「全部撤销」按每条撤销处理。

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
| `changes` | `[{field, before, after}]`：新建 before 固定 `（新建）`、删除 after 固定 `（已删除）`，都记授权的完整快照（grantID、scope、hostID、hostName、targetFingerprint、grantedAt、grantedBy、session，once 授权另有脱敏后的 command） |

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
  `codex mcp add aster -- <aster> mcp`（先 remove 再 add，便于覆盖旧路径）。`<aster>` **只能**是 PATH 里的
  `aster` 稳定 symlink（`AgentHostMCPInstallService.stableCommandPath`），没装时先由 `AsterCLIInstaller` 装上；
  从不写 App 包内的 `aster-cli` 绝对路径——开发构建删除、App 移动或换装正式版后它会失效，客户端启动即报错。
  symlink 指向另一个 Aster 时照样写稳定路径，并提示那个版本需支持 `aster mcp`。
  命令找不到或失败时把手动配置片段放进剪贴板。不直接改它们的配置文件。
- 登记检查：设置页在后台只读 `~/.claude.json` 的 `mcpServers.aster.command` 与 `~/.codex/config.toml` 的
  `[mcp_servers.aster]`（`AgentHostMCPRegistration`）。登记的命令不是稳定路径、在 App 包内或已不存在时，
  按钮变成「修复 …」并显示原因。

## 设置页

设置「主机」分类只承载这一页（没有子标签；页顶有指向侧栏「主机」页的说明与「打开主机页」按钮，动作 `hosts.openHostsPage`）。页面由 `hosts.js` 挂载 `agent-access.js`（入口 `window.AsterAgentAccess.render(container, hostsSnapshot, send, ui)`，`ui.t` 为翻译函数，`send` 返回的 Promise 失败时忽略、以下一次快照为准；
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
  暂停 / 排队 / 等输入 / 中断 / 结束 / 会话隔离 / 回退拒绝，批准合并、排队与按钮延迟，目标绑定与
  once 退还，开关与撤销关终端，钥匙串 ACL 核对，`pane.*` 隔离，以及在真实 Ghostty surface 上对本地
  sh / bash / zsh 跑的端到端，含 `LC_ALL=C` 下的 UTF-8 命令）。端到端测试把 `HISTCONTROL`、`HISTFILE`、`ZDOTDIR`
  指到无害值，不污染开发者的 Shell 历史。
- 停靠与浮窗：`AgentHostTerminalPresentationTests`（去处判定、弹出 / 停靠写偏好、Pane 关闭转浮窗不写偏好、
  显示与找回）、`AgentHostPaneDockTests`（注册表、只挂选中内容、头部按钮与拖动、关闭快捷键收起）、
  `AgentHostPaneDockLayoutTests`（Pane 宿主里的叠放与高度规则、旧宿主不碰停靠区、工作区重建后焦点留在停靠区）、
  `AgentHostCloseShortcutTests`，以及停车位端到端（真实 Ghostty 终端在从没显示过的浮窗里启动，
  搬进停靠区再弹回，进程不断）。改到工作区布局时加跑 `PaneChrome|PaneFloatingTerminal|WorkspaceBehavior`。
- 手工验收按 [远程工作验收](remote-work-acceptance.md) 的主机准备：口令主机、sudo 提示（needs_input →
  遮罩不撤 → 接管后在终端里输入 → 交还 agent → `host_wait`）、命令中途接手、中断、撤销授权；
  审计文件里应能看到真实的 exec 与撤销记录。停靠相关：终端出现在 agent 的 Pane 底部；弹出、停靠回来并切到该 Pane；
  收起后下一条命令自动展开；停靠区里 ⌘W 只收起；接管后在停靠区打字时切主题、拆分别的 Pane、出 toast，焦点不跑；
  切走标签再回来、放大别的 Pane 再还原；关掉 agent 的 Pane 或它所在的附加窗口，终端变成浮窗。
