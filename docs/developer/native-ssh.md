# 原生 SSH 引擎与已保存主机

远程机器、原生 SSH 标签和详情面板的受管旁路，默认都走 Aster 自带的 `aster-ssh`（Rust + russh），不再 exec `/usr/bin/ssh`。口令和私钥 passphrase 可以存进 macOS 钥匙串。设计参考 tty7（<https://github.com/l0ng-ai/tty7>，Apache-2.0，revision 458c923）：守护进程持有连接、主机配置对象、钥匙串按 endpoint 保存、认证弹窗排队。

契约全文见 [`SshRuntime/PROTOCOL.md`](../../SshRuntime/PROTOCOL.md)。本页讲结构、真值归属和失败语义。

## 组件

| 组件 | 位置 | 职责 |
| --- | --- | --- |
| `aster-ssh broker` | `SshRuntime/`，打包进 `Contents/MacOS/aster-ssh` | 每个 App 实例一个。持有全部 russh 连接（按 `user@host:port` 加跳板链共享），负责 keepalive、跳板、ProxyCommand、SOCKS/HTTP 代理、静态端口转发和 known_hosts 校验 |
| `aster-ssh client` | 同一个二进制 | 替代原来 exec `/usr/bin/ssh` 的所有位置，包括 Ghostty Pane 子进程。连到 broker socket，开一个 channel，转发 stdio、窗口大小和退出码 |
| `aster-ssh config` | 同一个二进制 | 解析 `~/.ssh/config`（Include、第一个匹配生效）；侧栏主机页的导入和 Open Quickly 别名都用它 |
| `aster-ssh keys` | 同一个二进制 | 解析、规范化与生成私钥（`inspect` / `generate`），stdin 进 JSON、stdout 出 JSON；私钥与 passphrase 从不进 argv |
| `SSHBrokerSupervisor` | `Sources/Aster/SSH/` | 拉起和重启 broker，读写 JSON Lines 控制通道，推送 `profiles.sync`，把 `link.state` 转给机器连接状态 |
| `SSHAuthCoordinator` | `Sources/Aster/SSH/` | 回答认证和主机密钥请求：先查钥匙串，再弹窗；按请求排队，同时只显示一个表单 |
| `SSHCredentialStore` | `Sources/Aster/SSH/` | 钥匙串读写 |
| `SSHHostProfile` / `SSHHostStore` / `SSHHostResolver` | `Sources/AsterCore/` | 主机模型、`hosts.json` 持久化、合并默认项并展开跳板链 |
| `SSHHostDirectory` | `Sources/Aster/SSH/` | App 侧主机列表的唯一权威，监听外部修改 |
| `SSHVaultKey` / `SSHVaultKeyStore` / `SSHVaultMigration` | `Sources/AsterCore/` | 保险库密钥元数据、`ssh-keys.json` 持久化、主机引用的迁移与清理 |
| `SSHVaultKeyDirectory` | `Sources/Aster/SSH/` | 保险库目录的唯一权威；保证目录与钥匙串一致 |
| `SSHVaultKeyActions` / `SSHVaultKeyRow` | `Sources/Aster/SSH/` | 保险库的用户动作（导入、生成、改名、复制公钥、删除、迁移引用、删除原文件）与展示行；与界面无关，侧栏主机页的「密钥」子页使用 |
| `HostsKeysViewController` | `Sources/Aster/Workspace/HostsPage/` | 侧栏「主机 → 密钥」原生子页：卡片、详情面板、菜单与确认框，动作交给 `SSHVaultKeyActions` |

## 真值归属

| 数据 | 权威位置 | 规则 |
| --- | --- | --- |
| 已保存主机 | `~/Library/Application Support/Aster/hosts.json` | 带版本号的 JSON，目录 0700、文件 0600，整份校验通过才替换；**类型上就没有秘密字段** |
| 「默认」项 | 同一文件，固定 ID `…d0d0` | 其它主机的空字段继承它；它自己的空字段用内置默认值（端口 22、auto 认证、keepalive 15s×3、超时 10s、校验主机密钥） |
| 口令 | 登录钥匙串，service `io.aster.ssh`，account `user@host:port` | 只在 broker 报告认证成功后写入；来自钥匙串的口令被拒时删除；共用同一 endpoint 的主机共用同一条口令 |
| 私钥 passphrase | 登录钥匙串，service `io.aster.ssh-key`，account 为私钥文件内容 SHA-512 hex | 同上 |
| 保险库私钥 | 登录钥匙串，service `io.aster.ssh-vault`，account 为保险库密钥 UUID，内容是未加密的 OpenSSH 私钥文本 | 导入或生成时写入；只在用户删除这把密钥时删除，服务器拒绝不删 |
| 保险库元数据 | `~/Library/Application Support/Aster/ssh-keys.json` | 带版本号，目录 0700、文件 0600；只有公钥、指纹、名称、来源，**类型上没有私钥字段** |
| 机器与主机的绑定 | `machines.json` 的可选键 `hostID` | 只在绑定时写出，未使用新功能的配置仍能被旧版本读取 |
| 主机使用频率 | UserDefaults `aster.hosts.usage.v1` | 只用于排序，不写进 `hosts.json`，避免每次连接都触发文件监听 |

用的是基于文件的登录钥匙串，不是 data protection 钥匙串：后者需要 `keychain-access-groups` entitlement，Aster 没有。broker 本身不访问钥匙串，秘密只经 App 与 broker 之间的私有管道进入内存，用完即丢，不写文件，也不写日志。

## 引擎选择与回退

- 优先级：环境变量 `ASTER_SSH_ENGINE`（`native` / `openssh`，不区分大小写）→ 设置「高级 → SSH → SSH 引擎」（`shell.sshEngine`，默认 native）。
- **引擎只在 App 启动时决定**，改设置后要重启 Aster 才生效。运行中切换会让已经连着 broker 的受管终端和 Pane 桥失效。
- 选了 native 但找不到二进制，或者拉不起 broker 时，回退到 openssh，并记诊断 `ssh.engine.fallback`。
- openssh 路径与改造前逐字节一致：私有临时配置、ControlMaster、`BatchMode=yes`。
- 用户在 Shell 里手敲的 `ssh` 永远是 OpenSSH，不受引擎影响。详情面板借用它的 ControlMaster（场景 A）也不受影响。

二进制定位顺序（DEBUG 构建）：`ASTER_SSH_BINARY` → `Contents/MacOS/aster-ssh` → 主程序同目录 → 开发构建的 `SshRuntime/target/{release,debug}/aster-ssh`。开发时运行 `scripts/build-ssh-runtime.sh .build/debug` 就能让 `swift build` 出来的 App 找到它。

发行版（非 DEBUG）只认 App 包内的 `Contents/MacOS/aster-ssh`，忽略 `ASTER_SSH_BINARY` 与开发产物。原因：App 的环境可以被同一用户的任何进程用 `launchctl setenv` 改写；若发行版照样认这个变量，伪造的 broker 就能收到保险库私钥（`auth.request` 的回答）和 `keys inspect` 的输入。App 调用的 `aster-ssh keys` / `known-hosts` 子命令（`SSHRuntimeTool.located()`）走同一个定位规则。

## broker 生命周期

- socket 位于 `/tmp/aster-sshb-<10 位>/b.sock`，目录 0700。路径在一个 App 进程内固定，broker 重启后不变，所以已经写进 Pane 命令行的桥仍然有效。
- ready 超时 5 秒。重启退避依次为 0.5/1/2/4/8/15/30 秒；连续运行满 30 秒后退避从头开始计。
- App 退出时发 `shutdown`，然后删除目录。broker 读到 stdin EOF（App 崩溃）时也会断开全部连接并退出。
- **channel 生命周期是硬约束**：client 进程一死，broker 立即对它的 channel 发 EOF 和 close，远端 pty 收到 SIGHUP，`aster-session terminal attach` 在 2 秒内退出并释放写租约。原来 ControlMaster 方案有滞留 62 秒的问题，共享连接不能再引入它。

## client 认证与威胁模型

broker socket 位于 0700 目录，但同一用户的任何进程都能连上它。socket 路径还写在 Pane 子进程的 argv 里，`ps` 就能看到。不加限制时，一个 coding agent 可以直接跑 `aster-ssh client --broker … --host-id …`，绕过 App 的批准和审计，用已保存主机的钥匙串凭证连到远端。

启动票据（契约见 `PROTOCOL.md` §3、§4.2）关掉这条路：

1. `SSHBrokerSupervisor` 每拉起一个 broker 实例，就由 `NativeSSHTicketIssuer` 生成一把 32 字节密钥，作为第一条控制消息 `tickets.key` 经 broker 的私有 stdin 下发。密钥不进 argv、环境变量和文件。broker 重启时换新密钥。App 关闭 broker 时作废密钥。
2. App 每拉起一个 `aster-ssh client`，就现签一张一次性票据（120 秒有效），经环境变量 `ASTER_SSH_TICKET` 交给它。`NativeSSHTicketing` 只给「可执行文件名是 aster-ssh，且第一个参数是 client」的进程注入，并总是先去掉继承来的同名变量。
3. client 读出票据后立刻把它从自己的环境里抹掉，放进 OPEN。broker 先验票再做别的事：HMAC、到期时间、nonce 防重放。

注入点（新增 `aster-ssh client` 启动点时必须接上，否则会稳定失败，这是安全的失败方式）：

| 启动点 | 位置 | 签票时机 |
| --- | --- | --- |
| 原生 SSH 标签 | `TerminalSession.applyNativeSSHLaunch` → `GhosttySurfaceView.launchEnvironmentProvider` | 每次真正创建 surface 时（后台标签可能很久后才创建；重新连接会重建 surface，再签一张） |
| 受管终端显示桥 | `ManagedTerminalCoordinator.bridgeLaunch` → 同上 | 同上 |
| 后台结构化命令、`config` 以外的短命调用 | `RemoteSSHProcessRunner.run` | 每次拉起进程前 |
| 文件上传下载 | `RemoteSSHStreamRunner.stream` | 同上 |
| 安装产物上传 | `RemoteSSHInstallExecutor.upload` | 同上 |
| 图片粘贴上传 | `RemoteManagedSessionClient.uploadImage` | 同上 |
| 事件订阅 | `ProcessSessionEventLineSource.start`（`SessionEventStreamClient.swift`） | 同上 |

签发入口在 App 启动时注册（`AsterApp` 里 `NativeSSHTicketing.install`）。没有注册（测试、CLI）或 broker 不在时不签票，client 会被拒，报 `authenticationRequired`。

**威胁模型：只约束配合的 agent，不防恶意软件。** 票据防的是「好好按规矩办事的 agent 走了捷径」：它不知道票据密钥，拿不到有效票据，直连 socket 会被拒；它从 `ps` 看到的 argv 里也没有票据。同一用户下的恶意进程仍然可以：读 App 进程内存（拿到密钥）、在 client 抹掉环境变量之前读到它的环境（票据一次性，client 启动即用掉，窗口很短）、用 ssh-agent、读 `~/.ssh` 下的私钥文件、模拟键盘鼠标操作 App。这些不在本机制的范围内，需要系统层面的隔离（沙箱、独立用户）。

调试时可以用 `ASTER_SSH_TICKETS=off` 启动 DEBUG 构建的 App（broker 继承这个环境变量）关闭校验。这个开关只在 debug 构建的 broker（`debug_assertions`）里生效；发行版 broker 由 `build-ssh-runtime.sh` 用 `cargo build --release` 构建，忽略它，非 DEBUG 的 App 也会在拉起 broker 前把它从环境里删掉（`SSHBrokerSupervisor.brokerEnvironment(from:)`）。

`ASTER_SSH_HOME`（替代 `$HOME` 找 `~/.ssh`）与 `ASTER_SSH_KNOWN_HOSTS`（单独指定 known_hosts）同样只供测试：只在 debug 构建的 aster-ssh 里生效（`env.rs` 的 `debug_override_env`，broker、`config`、`known-hosts` 子命令共用），非 DEBUG 的 App 也在拉起 broker 前删掉它们。否则同一用户的进程可以用 `launchctl setenv` 换掉 known_hosts，让中间人的主机密钥被直接信任，随后非交互地交出钥匙串里保存的密码。`ASTER_SSH_DEBUG` 在发行版仍然可用：它只打开 debug 日志，日志只含 ID、路径和错误，不含秘密。client 进程只读 `ASTER_SSH_TICKET` 和 `TERM`。

## 调用形状

| 场景 | OpenSSH | 原生 |
| --- | --- | --- |
| 后台结构化命令、事件订阅、安装 | `ssh -o BatchMode=yes … -- target 'cmd'` | `aster-ssh client --broker S (--host-id ID \| --target T) --no-prompt -- 'cmd'` |
| 显示桥（受管 Pane） | `ssh -tt …` | `… --tty`，不带 `--no-prompt`，允许交互认证 |
| 原生 SSH 标签 | 不适用（回退为在本地 Shell 里敲 `ssh target`） | `aster-ssh client … --tty`，不带命令，得到交互 Shell |

- 绑定了主机的机器用 `--host-id`，超时以主机配置为准。
- 按 target 连接的，沿用连接策略的超时。
- 失败分类：先读 stderr 最后一行 `aster-ssh-error {"kind":…}`（退出码 255），没有再回退到 OpenSSH 文本分类。

## 认证与主机密钥

认证顺序（每一跳各自决定）：

- `auto`：保险库密钥 → agent → `identityFiles` → 默认密钥（`~/.ssh/id_*`）→ 口令 → 键盘交互。
- `publicKey`：保险库密钥 → `identityFiles` → 默认密钥。
- 主机有保险库密钥或 `identityFiles` 时跳过默认密钥：保险库的意义就是不再读明文私钥文件。
- `identitiesOnly` 时，agent 只能为 `identityFiles` 与保险库里的公钥签名（只比密钥数据，不比注释）。

1. broker 需要凭证时发 `auth.request`。App 先查钥匙串（只在第一次尝试时查）。后台请求（`interactive:false`）只能用钥匙串作答，查不到就取消。
2. 交互请求弹出表单：口令或 passphrase 用安全输入框，「记住到钥匙串」默认勾选；键盘交互按提示逐项输入，回答不存钥匙串。
3. broker 每次尝试后发 `auth.result`。App 只在 `accepted=true` 且用户勾选了记住时写钥匙串；来自钥匙串的秘密被拒时删掉那条。挂起的秘密最多在内存里留 60 秒。
4. 主机密钥按 `~/.ssh/known_hosts` 校验（支持 hashed 条目和 `[host]:port`）：
   - 未知：显示算法和指纹，默认按钮是「取消」。
   - 变更：显示中间人攻击警告，必须手动输入 `yes` 才能继续；接受后替换旧行。
   - 后台连接遇到这两种情况，一律失败并进入 attention，不自动接受。
5. `link.state` 的 `authenticationRequired`、`hostKeyUnknown`、`hostKeyChanged` 立即让机器进入 attention。链路回到 connected 时，处在重连、attention 或断开状态的机器立即重连。

### 私钥保险库

目标：私钥不再以明文文件留在 `~/.ssh`，agent 或其它同用户工具 `cat` 不到；连接时 broker 按需向 App 要。

- **存放**：私钥统一转成未加密的 OpenSSH 文本存进钥匙串（钥匙串负责静态加密；再套一层 passphrase 只会多一个 ACL 相同的秘密）。导入加密私钥时只解密一次。元数据在 `ssh-keys.json`，指纹唯一，同一把私钥重复导入时复用已有条目。
- **主机引用**：`SSHHostProfile.vaultKeyIDs`（UUID 列表，按顺序尝试）。nil 表示继承「默认」项，空数组存成 nil。引用已删除的密钥是允许的，解析时跳过。删除密钥时 `SSHVaultKeyDirectory` 依次清理目录、钥匙串和所有主机（含默认项）里的引用。
- **钥匙串 I/O 不占主线程**：`SSHVaultKeyDirectory.add` / `remove` 在后台写、删钥匙串，主线程只改目录；顺序不变（新增先写钥匙串再存目录，目录保存失败就回滚钥匙串；删除先改目录再删钥匙串）。主机页「密钥」子页的「钥匙串中缺失」读 `keychainMissing` 缓存（经 `SSHVaultKeyActions.rows`），不在每次刷新时逐把查钥匙串。缓存在加载、目录变化（含外部修改 `ssh-keys.json`）、增删和打开「密钥」子页时由 `refreshKeychainPresence()` 在后台刷新，回到主线程按密钥 ID 写入，过期的刷新结果按代数丢弃。
- **下发**：`SSHHostResolver` 把引用换成 `{id, publicKey}` 放进 `ResolvedSpec.vaultKeys`（为空时不编码，旧 broker 收到的 JSON 不变）。`SSHBrokerSupervisor` 同时订阅主机目录与保险库目录，任一变化都重新 `profiles.sync`。
- **取用**：broker 轮到某把密钥时发 `auth.request kind=privateKey`（`vaultKeyID`，恒为 `interactive:false`）。`SSHAuthCoordinator` 只为目录里登记过的 ID 在后台读钥匙串，回答私钥文本；不弹窗，不进 `pending`，被拒也不删。目录里没有、钥匙串缺失或读取失败都回 null，broker 跳到下一把密钥。broker 先核对私钥与登记的公钥一致才拿去认证，私钥全程放在 `Zeroizing` 里。
- **Swift 侧的限制**：`String` 无法清零。私钥只经函数返回值短暂存在，不存进任何属性，也不写日志。
- **解析与生成**：都在 Rust（`aster-ssh keys`，见 `PROTOCOL.md` §6），经 `SSHRuntimeTool` 的 stdin/stdout 调用。生成只支持 ed25519，种子来自 `getentropy`，不加新依赖。导入支持 OpenSSH（含加密）、PKCS#1 RSA PEM、PKCS#8、SEC1 EC、PuTTY PPK；DSA、`sk-*` 安全密钥和 DES / AES-256 加密的旧式 PEM 返回 `unsupported`。
- **动作入口**：校验、互斥（`isBusy`，同一时刻只跑一个要等用户或子进程的动作）、错误文案与下面的安全规则都在 `SSHVaultKeyActions`；侧栏「主机 → 密钥」只负责展示与确认，不另写一份。
- **导入与迁移**：导入时用 NSOpenPanel 从 `~/.ssh` 选文件（显示隐藏文件），原生读取，私钥与 passphrase 不交给任何界面层（包括 WKWebView）；加密私钥最多问三次 passphrase。导入后可以把 `identityFiles` 指向原文件（展开 `~`、`%h`、`%r` 并解析软链后比较）的主机改用保险库密钥，原来继承的默认项保险库密钥会一起抄过来，实际尝试的密钥不变。
- **删除原文件**：先回读钥匙串并重新计算指纹，再核对磁盘上的文件仍是这把密钥，都一致才弹原生确认框。核对文件时先解析软链，解析后的真实路径不在 `~/.ssh` 下就拒绝（提示用户手动删除）；未加密的用 `keys inspect` 重算指纹，加密的不问 passphrase，改用旁边 `.pub` 文件的 SHA256 指纹（`SSHPublicKeyFingerprint`，先看解析后路径旁的，再看原路径旁的），对不上或没有 `.pub` 就拒绝。用户点确认后、`removeItem` 前再核对一次，删的就是刚核对过的解析路径，缩小「确认期间文件被替换」的窗口。确认框列出文件路径、仍引用它的主机和 `~/.ssh/config` 里 IdentityFile 指向它的 Host，并写明 OpenSSH 回退引擎、手敲的 `ssh` 会失效、备份里可能还有副本。直接 `removeItem`，不进废纸篓；路径是软链时删除真正的文件和留下的链接。同名 `.pub` 保留。
- **不提供**：私钥导出；Aster 自己的 ssh-agent（需要 agent 时用 `identityAgent` 指向 1Password、Secretive 等）。
- **限制**：OpenSSH 回退引擎和手敲的 `ssh` 用不到保险库密钥，主机页「密钥」在 openssh 引擎下显示提示。同用户的恶意进程仍可能通过钥匙串授权框或模拟点击拿到私钥，见威胁模型。

### ssh-agent 的选择（IdentityAgent）

每一跳（目标与每个跳板）各自决定用哪个 agent，规则只有一份，在 broker 的 `Env::agent_socket`（`SshRuntime/src/env.rs`）：

1. 优先级：主机的 `identityAgent` > 「默认」项的 `identityAgent` > broker 继承到的 `SSH_AUTH_SOCK`。`--target` 走 ssh_config 时按「第一个匹配生效」取 `IdentityAgent`。
2. 取值与 OpenSSH 一致（`none` 与 `SSH_AUTH_SOCK` 区分大小写）：
   - `none`：这一跳不用 agent。
   - `SSH_AUTH_SOCK`：用继承到的环境变量，同没写。
   - `$VAR`：路径取自环境变量；变量没设或为空就不用 agent，不回落到 `SSH_AUTH_SOCK`。
   - 其它：当作路径，展开 `%h`、`%p`、`%r`、`%u`、`%d`、`%%`、`${VAR}` 和开头的 `~`。
3. Swift 侧只做继承与去空白，把原文放进 `ResolvedSpec.identityAgent`。环境变量属于 broker 进程，所以展开留给 broker。
4. agent 转发用同一个 socket：`agentForward` 打开且这一跳解析得到 socket 时才请求转发。
5. 与 OpenSSH 的差异：`${VAR}` 没设时 OpenSSH 直接报错退出，这里记一条 debug 日志并跳过 agent；`%C`、`%i`、`%k`、`%L`、`%l`、`%n`、`%j` 不展开，原样保留。
6. 从 Dock 启动的 App 拿到的是 launchd 的 `SSH_AUTH_SOCK`（系统 agent），不是用户 Shell 里导出的值。用第三方 agent 的用户应当写 `IdentityAgent`。

## ~/.ssh/config 解析

Rust 实现，参考 tty7 的 `ssh_config.rs`：

- 支持：Include（相对路径按 `~/.ssh/` 解析，最多 16 层，检测循环）、Host 模式（`*`、`?`、`!`）、第一个匹配生效，以及 HostName、User、Port、IdentityFile、ProxyJump、ProxyCommand、三类 Forward、ServerAlive*、ConnectTimeout、ForwardAgent、StrictHostKeyChecking、UserKnownHostsFile、GlobalKnownHostsFile、IdentitiesOnly、IdentityAgent。
- 不支持：Match 块（整块跳过）、UseKeychain、GSSAPI*、Canonicalize* 等。这些指令按行列进 `ignored`，导入时展示给用户。
- 安全上限：单个文件 1MB，最多 64 个文件。
- 与 OpenSSH 的差异：Host 匹配不区分大小写。

## known_hosts 管理

- 解析只有一份：`aster-ssh known-hosts list|remove`（`SshRuntime/src/known_hosts_cli.rs`）复用连接校验用的 `known_hosts.rs`，能处理 hashed、`[host]:port`、通配、取反、`@revoked` 与 `@cert-authority`。请求走 stdin JSON，协议见 `SshRuntime/PROTOCOL.md`「known-hosts 子命令」。
- 查询参数（`SSHKnownHostsQuery`，AsterCore）：文件 = 默认文件 + 各主机（含跳板各跳）`knownHostsFiles` 的并集，系统级文件只读列出；`match` = 各可解析主机及其跳板的 `host:port`，再加没有绑定主机的旧机器 target。hashed 记录只能靠 `matches` 显示主机名。
- 删除防误删：`remove` 带 `lineDigest`（原行 SHA-256），行已变化时退出码 3（stale），App toast 提示并重新列出。`host` 非空时只删多主机行里命中的模式，其余字节不变。系统级文件一律拒绝。
- App 侧规则只有一份：`SSHKnownHostsService`（`Sources/Aster/SSH/`，与界面形式无关）只接受上一次列表里出现过、所在文件可写、摘要一致的记录；指定主机时它必须是该记录的 `matches` 之一。同一时刻只跑一个删除，删除后不论成败都重新列出，旧行号不再复用。列出用加载代次丢弃过期结果，子进程不占主线程。结果提示走服务的 `toast`，状态变化走 `didChange`。
- 使用方：侧栏主机页的「已知主机」子页（`KnownHostsPageViewController`，在 `HostsHubViewController.defaultFactories()` 登记）。设置里不再有已知主机页，网页页面与 `SettingsKnownHostsBridge` 已删除。
- 原生页面：分组、徽章、hashed 记录的名称、搜索与删除选项由纯函数 `KnownHostsPageContent` 推导。删除用 `NSAlert` sheet：单模式行只有「删除」，多模式行再给每个命中主机一个「只删除 <host>」。首次显示时自动列出一次；之后只在点「重新加载」或删除后重新列出，因为工作区每次整树重建（例如弹出 toast）都会回调 `pageDidAppear`。提示写到外壳所属窗口的 `AppModel.notice`。
- 写入修复：改写走 `atomic_file::write`，先顺着符号链接找到真实文件，在它的目录写临时文件（`create_new`）再 rename，保留原权限。之前 `replace()` 直接 rename 会把指向 dotfiles 的 `~/.ssh/known_hosts` 链接换成普通文件。

## 主机标签

- 模型：`SSHHostProfile.tags: [String]?`，nil 表示没有标签。默认项不使用标签，`SSHHostStore.normalized` 会把它清成 nil，标签也不参与继承。
- 规范化（`SSHHostStore.normalizedTags`）：去首尾空白、丢弃空串、不分大小写去重并保留第一次出现的写法，结果为空时存成 nil。
- 校验（`SSHHostStore.tagsAreValid`）：最多 16 个，每个不超过 32 个 UTF-8 字节，不含逗号、换行和控制字符；违反时原因是 `invalid tags`，编辑面板显示「标签过长或包含逗号/换行」。
- 兼容：`hosts.json` 版本号仍是 1，新字段是增量加的，旧文件没有 `tags` 键也能读。降级到旧版后再保存会丢掉标签。
- 字段同步：按字段手写的地方有 `SSHHostProfile.duplicated(name:)`（主机页的「复制」）、`SSHHostEditRules.sanitized`（控制字符扫描）和 `SSHHostDraft` 的 `init(profile:)` / `makeProfile()`（原生编辑面板）；以后加字段要同时改这几处，否则从编辑面板保存会悄悄丢字段。`SSHHostDraftTests` 的往返测试覆盖每个字段。
- 使用方：主机页的筛选与 chip、Open Quickly 主机行的 detail（`connectString · group · #tag1 #tag2`，模糊搜索能命中标签）、`host.list` 的 `tags` 输出与 `{tags:[…]}` 筛选（AND、不分大小写；CLI 为 `aster-cli host list --tag X`，可重复）。
## 侧栏主机页

侧栏「工作区」上方的「主机」行打开主机页，页面占据工作区内容区（Termius 式的卡片浏览）。

- 状态：`AppModel.isHostsPagePresented`，只属于本窗口、不持久化。`selectedTabID` 的 `didSet` 在任何选中标签的入口（侧栏、Open Quickly、开 SSH 标签、CLI）都把它关掉；点当前工作区也会先关它（`selectWorkspaceGroupItem`）。命令面板有 `hosts` 命令，横向标签栏布局用它打开。
- 管理入口只有这里：主机列表与编辑、密钥保险库、已知主机都不在设置里（子标签 主机 | 密钥 | 已知主机；设置「主机」分类只剩「Agent 访问」，页顶的「打开主机页」经桥接动作 `hosts.openHostsPage` 在最前面的工作区窗口打开本页）。
- 编辑入口：终端标签右键菜单的「编辑主机…」（原生 SSH 标签）与 Open Quickly 主机行的「编辑主机…」都调 `AppModel.showHostEditor(hostID:)`：打开主机页并带出该主机的编辑面板；主机已不存在时显示列表并给出提示。「新建工作区」面板的「添加主机…」打开主机页并带出新建主机面板。请求先记在 `AppModel.pendingHostEditor`，由 `HostsPageViewController.pageDidAppear` 消费，主机页未显示、正显示别的子页或已显示时都走同一条路径。
- 视图：`WorkspaceViewController.hostsPageController` 懒建并跨整树 `refresh()` 复用，搜索词、钻取的分组和滚动位置不丢；显示时终端视图不在树里，`refresh()` 不回焦终端，详情面板按钮隐藏。代码在 `Sources/Aster/Workspace/HostsPage/`，侧栏行在 `Workspace/Sidebar/HostsSidebarRowView.swift`（行自己订阅主机目录原地更新数量）。
- 规则：搜索、分组、标签筛选、排序与回车意图都在 `HostBrowserCatalog`（AsterCore，纯函数）。顶层不过滤时只列分组和未分组主机；过滤时平铺所有分组的匹配主机，分组只留名称命中的。回车顺序：名称或连接串完全相同的已保存主机 → 像地址的输入走 `QuickConnectTarget` 临时连接 → 只剩一台可见主机。「最近使用」排序用 `HostUsageLedger.lastUsedByID`。
- 真值与动作：主机只从 `SSHHostDirectory` 读；复制用 `SSHHostProfile.duplicated(name:)`，删除用 `SSHHostRemoval.remove`（口令清理规则只有这一份），导入用 `SSHHostDirectory.mergeSSHConfig`，连接走 `openNativeSSH(hostID:)` / `openNativeSSH(target:)`，编辑、新建与默认设置都在页内的编辑面板（见下一节）。
- 图标：代码库没有按主机持久化的远端系统识别结果，卡片统一用通用服务器图标，不为识别系统发起连接。
- 「密钥」子页：`HostsKeysViewController`（在 `HostsHubViewController.defaultFactories()` 登记）。数据来自 `SSHVaultKeyActions.rows(hosts:)`，订阅保险库目录（含 `keychainMissing`）、主机目录与 `isBusy` 后重算；动作经 `HostsKeysPrompts`（名称表单、删除 / 迁移确认，测试可替换）后交给 `SSHVaultKeyActions`。生成或重命名被服务拒绝时，带原因和原输入重弹表单。提示写到所在窗口的 `AppModel.notice`。详情面板只显示公开信息（指纹、公钥、来源、使用它的主机）。

## 主机编辑面板

主机页右侧滑出的原生编辑面板（AppKit，无 WebView），覆盖新建主机、编辑主机与「默认」项。它取代了原来设置里的网页表单，设置里已不再有主机编辑。

- 分层：
  - `SSHHostDraft`（AsterCore）：表单草稿。`init(profile:)` 把主机拆成文本与选项，`makeProfile()` 按网页表单同样的规则组装（空文本存 nil 表示继承；转发规则只写端口时绑定补 `127.0.0.1`、目标补 `localhost`；动态转发目标固定为 `{"", 0}`），格式问题收集成 `SSHHostDraftError`。保险库密钥按原顺序保留，勾选追加末尾，找不到的 ID 原样带回。
  - `SSHHostEditRules`（AsterCore）：`sanitized` 是保存前的边界清理（空列表与空白归一成 nil，超量条目、控制字符拒绝），网页 payload 与面板共用；`jumpCandidates` 沿跳板链（含默认项跳板）标出会成环的候选；`SSHHostInheritedValues` 计算占位符用的继承值，`SSHHostBuiltinDefaults` 是内置缺省值（与解析器的兜底一致）。
  - `SSHHostEditing`（App，`Sources/Aster/SSH/`）：`save`（清理 → `SSHHostStore.validate` + 解析器查环 → `upsert`；`requireExisting` 防止编辑期间被删的主机被保存加回来）、`duplicate`、`forgetPassword`、`deletionImpact`、`friendlyReason`、`describe` 与 `~/.ssh/config` 的建档和打开。主机页的所有保存、复制与删除路径都经这里。
  - 视图在 `Sources/Aster/Workspace/HostsPage/Editor/`：`HostEditorPanelController`（标题带、滚动表单、操作区、底栏；Esc 关闭，回车保存）、`HostEditorForm`（+`Sections`，控件与草稿互转）、`HostEditorForwardsView`、`HostEditorVaultKeysView`、`HostEditorControls`（填充底色的输入框、下拉、按钮与可折叠分区，全部动态色）。开合与宿主回调在 `HostsPageViewController+Editor.swift`，删除确认、忘记口令、添加为机器与编辑 `~/.ssh/config` 在 `HostsPageHostActions.swift`。
- 依赖：`HostsPageEditorServices` 注入保险库密钥、钥匙串、机器列表、「添加机器」流程与文本编辑器；测试用临时 hosts.json 与内存钥匙串。
- 线程：口令是否存在（决定是否显示「忘记保存的口令…」、删除确认里的口令去留）在后台查钥匙串；结果回到主线程时面板若已换成别的主机就丢弃。
- 未保存修改：面板记住打开时的草稿，切换到另一台主机或在面板里「创建副本」前若有修改，先确认是否放弃。

## Agent 主机终端

编程 agent 在已保存主机上执行命令时用的终端（[Agent 远程执行](agent-host-access.md)）也是原生 SSH 的使用方：

- 每个 agent 终端是一个**独立的** `TerminalSession`，绑定 `bindNativeSSH(.host(id))`，PTY 里跑 `aster-ssh client … --tty`
  （与原生 SSH 标签同一种调用形状）。它显示在浮动 NSPanel 里，**不注册进任何工作区标签**，所以 `pane.*`、
  `session.snapshot`、`agent.*` 与 Session Recording 都碰不到它。
- 连接前确认 PTY 前台进程是 `aster-ssh`。引擎回退到 OpenSSH 时，`TerminalSession` 会变成「本地 Shell 里预填 ssh」，
  这时 agent 命令会落到本机；因此前台不是 `aster-ssh` 就立刻结束该终端并报 `host_not_ready`，绝不执行。
- 认证、口令与主机密钥提示走 App 自己的认证表单（`SSHAuthCoordinator`），与普通原生 SSH 标签一致；
  agent 永远拿不到口令或私钥，sudo 口令也只能由用户在浮动终端里输入。

## 验证

- Rust：`cd SshRuntime && cargo test`。用进程内的 russh 服务端覆盖认证、known_hosts、exec 退出码、pty、channel 关闭时限、跳板链、结构化错误行和协议样例。
- Swift：`./scripts/test.sh --no-parallel --filter 'nativeTransport|sshBrokerSupervisor|machineHostBinding|sshAuthCoordinator|sshCredentialStore|sshHostProfile|sshHostStore|sshBrokerProtocol|sshConfigImport|nativeSSHTicket|nativeSSHRunners|Vault|vaultActions|hostsKeysPage|knownHosts|KnownHosts'`。保险库的真实二进制往返用例（`SSHVaultKeyToolTests`）需要先跑 `./scripts/build-ssh-runtime.sh .build/debug`，找不到二进制时跳过。
- 打包：`./scripts/build-app.sh` 会构建 aster-ssh、复制进 `Contents/MacOS/`、签名并运行 `--version` 自检。
